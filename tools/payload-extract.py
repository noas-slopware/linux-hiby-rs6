#!/usr/bin/env python3
"""List, extract or apply an Android A/B OTA (payload.bin, bare or inside the OTA zip).

  payload-extract.py info    <ota.zip|payload.bin>
  payload-extract.py extract <ota.zip|payload.bin> <outdir> [partition ...]
  payload-extract.py apply   <ota.zip|payload.bin> <outdir> <partition>=<old image> ...

extract handles full payloads; apply handles deltas (and full payloads too) given the old
image of every partition the payload updates. Every op of payload minor version <= 5 is
implemented the way update_engine does it:
  REPLACE, REPLACE_BZ, REPLACE_XZ   blob (bz2/lzma from stdlib) to the dst extents
  ZERO, DISCARD                     zeros (left as holes: outputs are sparse files; REPLACE
                                    and SOURCE_COPY skip all-zero blocks too. That is only
                                    right because every dst block is written once, which
                                    the final new_partition_info hash check proves)
  SOURCE_COPY                       src extents to dst extents
  SOURCE_BSDIFF, BROTLI_BSDIFF      AOSP bspatch, src/dst as byte extents cut to src_length/dst_length
  PUFFDIFF                          AOSP puffin's PuffPatch over the src/dst block extents
bspatch and puffpatch are AOSP's own code, built by tools/ota-patch/build.sh (looked up
in $RS6_OTA_PATCH, default ~/.cache/rs6-ota-patch). Checked on the way: the old image
against old_partition_info's SHA-256 before anything is written, every data blob against
data_sha256_hash, the source data of every source op against src_sha256_hash, and every
output image against new_partition_info's SHA-256. Field numbers follow AOSP
system/update_engine/update_metadata.proto.
"""
import bz2
import hashlib
import lzma
import os
import struct
import subprocess
import sys
import tempfile
import time
import zipfile

OPS = {0: "REPLACE", 1: "REPLACE_BZ", 2: "MOVE", 3: "BSDIFF", 4: "SOURCE_COPY",
       5: "SOURCE_BSDIFF", 6: "ZERO", 7: "DISCARD", 8: "REPLACE_XZ", 9: "PUFFDIFF",
       10: "BROTLI_BSDIFF", 11: "ZUCCHINI", 12: "LZ4DIFF_BSDIFF", 13: "LZ4DIFF_PUFFDIFF"}
FULL_OPS = {0, 1, 6, 7, 8}
SOURCE_OPS = {4, 5, 9, 10}


def varint(b, p):
    r = s = 0
    while True:
        x = b[p]
        p += 1
        r |= (x & 0x7F) << s
        s += 7
        if x < 0x80:
            return r, p


def fields(b):
    """Yield (field number, wire type, value) of one protobuf message."""
    p = 0
    while p < len(b):
        key, p = varint(b, p)
        fn, wt = key >> 3, key & 7
        if wt == 0:
            v, p = varint(b, p)
        elif wt == 1:
            v = struct.unpack_from("<Q", b, p)[0]
            p += 8
        elif wt == 2:
            n, p = varint(b, p)
            v = b[p:p + n]
            p += n
        elif wt == 5:
            v = struct.unpack_from("<I", b, p)[0]
            p += 4
        else:
            raise ValueError(f"wire type {wt}")
        yield fn, wt, v


def extent(b):
    e = dict.fromkeys(("start", "num"), 0)
    for fn, _, v in fields(b):
        if fn == 1:
            e["start"] = v
        elif fn == 2:
            e["num"] = v
    return e


def pinfo(b):
    i = {"size": 0, "hash": b""}
    for fn, _, v in fields(b):
        if fn == 1:
            i["size"] = v
        elif fn == 2:
            i["hash"] = bytes(v)
    return i


def operation(b):
    op = {"type": 0, "off": 0, "len": 0, "src": [], "dst": [], "src_len": None,
          "dst_len": None, "sha": b"", "src_sha": b""}
    for fn, _, v in fields(b):
        if fn == 1:
            op["type"] = v
        elif fn == 2:
            op["off"] = v
        elif fn == 3:
            op["len"] = v
        elif fn == 4:
            op["src"].append(extent(v))
        elif fn == 5:
            op["src_len"] = v
        elif fn == 6:
            op["dst"].append(extent(v))
        elif fn == 7:
            op["dst_len"] = v
        elif fn == 8:
            op["sha"] = bytes(v)
        elif fn == 9:
            op["src_sha"] = bytes(v)
    return op


def partition(b):
    pu = {"name": "", "old": None, "new": None, "ops": []}
    for fn, _, v in fields(b):
        if fn == 1:
            pu["name"] = bytes(v).decode()
        elif fn == 6:
            pu["old"] = pinfo(v)
        elif fn == 7:
            pu["new"] = pinfo(v)
        elif fn == 8:
            pu["ops"].append(operation(v))
    return pu


class Payload:
    def __init__(self, path):
        self.f = open(path, "rb")
        self.base = 0
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as z:
                zi = z.getinfo("payload.bin")
            if zi.compress_type != zipfile.ZIP_STORED:
                sys.exit("payload.bin is compressed inside the zip; unzip it first")
            self.f.seek(zi.header_offset)
            lh = self.f.read(30)
            fnl, exl = struct.unpack_from("<HH", lh, 26)
            self.base = zi.header_offset + 30 + fnl + exl
        self.f.seek(self.base)
        hdr = self.f.read(24)
        if hdr[:4] != b"CrAU":
            sys.exit("not a payload (no CrAU magic)")
        ver, msize = struct.unpack(">QQ", hdr[4:20])
        if ver != 2:
            sys.exit(f"payload major version {ver} not supported")
        sigsize = struct.unpack(">I", hdr[20:24])[0]
        self.data = self.base + 24 + msize + sigsize
        manifest = self.f.read(msize)
        self.block = 4096
        self.minor = 0
        self.parts = []
        for fn, _, v in fields(manifest):
            if fn == 3:
                self.block = v
            elif fn == 12:
                self.minor = v
            elif fn == 13:
                self.parts.append(partition(v))

    def is_delta(self, pu):
        return pu["old"] is not None or any(o["type"] not in FULL_OPS for o in pu["ops"])

    def blob(self, pu, op):
        self.f.seek(self.data + op["off"])
        blob = self.f.read(op["len"])
        if op["sha"] and hashlib.sha256(blob).digest() != op["sha"]:
            sys.exit(f"{pu['name']}: data blob hash mismatch at payload offset {op['off']}")
        return blob


def sha256_file(path, size=None):
    h = hashlib.sha256()
    left = os.path.getsize(path) if size is None else size
    with open(path, "rb") as f:
        while left:
            b = f.read(min(left, 1 << 22))
            if not b:
                sys.exit(f"{path}: shorter than {size} bytes")
            h.update(b)
            left -= len(b)
    return h.digest()


def byte_extents(exts, bs, limit=None):
    """'off:len,...' for bspatch/puffpatch, optionally cut to |limit| bytes in total."""
    out = []
    for e in exts:
        n = e["num"] * bs
        if limit is not None:
            n = min(n, limit)
            limit -= n
        if n:
            out.append(f"{e['start'] * bs}:{n}")
    return ",".join(out)


def find_tools(tools):
    d = tools or os.environ.get("RS6_OTA_PATCH") or os.path.join(
        os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "rs6-ota-patch")
    bsp, puf = os.path.join(d, "bspatch"), os.path.join(d, "puffpatch")
    if not (os.access(bsp, os.X_OK) and os.access(puf, os.X_OK)):
        sys.exit(f"no bspatch/puffpatch in {d}: run tools/ota-patch/build.sh first")
    return bsp, puf


def apply_partition(pl, pu, old, out, tools=None):
    """Write pu's new image to |out| (sparse), reading source data from |old|."""
    bs = pl.block
    name = pu["name"]
    if pu["old"] is not None:
        if old is None:
            sys.exit(f"{name}: delta, needs the old image")
        if sha256_file(old, pu["old"]["size"]) != pu["old"]["hash"]:
            sys.exit(f"{name}: {old} does not match old_partition_info "
                     f"(sha256 {pu['old']['hash'].hex()} over {pu['old']['size']} bytes)")
        print(f"{name}: old image OK ({pu['old']['size']} bytes, sha256 {pu['old']['hash'].hex()})")
    need_tools = {o["type"] for o in pu["ops"]} & {5, 9, 10}
    bsp, puf = find_tools(tools) if need_tools else (None, None)
    unknown = {o["type"] for o in pu["ops"]} - FULL_OPS - SOURCE_OPS
    if unknown:
        sys.exit(f"{name}: unsupported ops {sorted(OPS.get(t, t) for t in unknown)}")
    with open(out, "wb") as o:
        o.truncate(pu["new"]["size"])
    src = open(old, "rb") if old else None
    o = open(out, "r+b")
    t0 = time.monotonic()
    with tempfile.TemporaryDirectory() as w:
        patch = os.path.join(w, "patch")
        for i, op in enumerate(pu["ops"]):
            t = op["type"]
            if t in (6, 7):             # ZERO / DISCARD: the hole is already zero
                continue
            if t in SOURCE_OPS:
                if src is None:
                    sys.exit(f"{name}: {OPS[t]} op needs the old image")
                if op["src_sha"] or t == 4:
                    data = b"".join(_read(src, e, bs) for e in op["src"])
                    if op["src_sha"] and hashlib.sha256(
                            data[:op["src_len"]] if op["src_len"] else data).digest() != op["src_sha"]:
                        sys.exit(f"{name}: op {i} ({OPS[t]}) source data hash mismatch")
            if t in (0, 1, 8):
                blob = pl.blob(pu, op)
                if t == 1:
                    blob = bz2.decompress(blob)
                elif t == 8:
                    blob = lzma.decompress(blob)
                _scatter(o, op["dst"], bs, blob)
            elif t == 4:
                _scatter(o, op["dst"], bs, data)
            else:
                with open(patch, "wb") as f:
                    f.write(pl.blob(pu, op))
                o.flush()
                if t == 9:              # update_engine hands puffin whole blocks
                    cmd = [puf, old, out, patch, byte_extents(op["src"], bs),
                           byte_extents(op["dst"], bs)]
                else:                   # and bspatch extents cut to src/dst_length
                    cmd = [bsp, old, out, patch, byte_extents(op["src"], bs, op["src_len"]),
                           byte_extents(op["dst"], bs, op["dst_len"])]
                r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                if r.returncode:
                    sys.exit(f"{name}: op {i} ({OPS[t]}) failed: {r.stderr.decode(errors='replace')[-500:]}")
            if sys.stderr.isatty():
                print(f"\r{name}: op {i + 1}/{len(pu['ops'])}", end="", file=sys.stderr)
    o.close()
    if src:
        src.close()
    if sys.stderr.isatty():
        print(file=sys.stderr)
    digest = sha256_file(out)
    if pu["new"]["hash"] and digest != pu["new"]["hash"]:
        sys.exit(f"{name}: {out} sha256 {digest.hex()} != new_partition_info {pu['new']['hash'].hex()}")
    print(f"{name}: new image OK ({pu['new']['size']} bytes, sha256 {digest.hex()}, "
          f"{time.monotonic() - t0:.0f}s)  {out}")
    return digest.hex()


def _read(f, e, bs):
    f.seek(e["start"] * bs)
    d = f.read(e["num"] * bs)
    if len(d) != e["num"] * bs:
        sys.exit(f"source image too short for extent {e}")
    return d


def _scatter(o, exts, bs, data):
    p = 0
    for e in exts:
        n = e["num"] * bs
        chunk = data[p:p + n]
        p += n
        if chunk.count(0) == len(chunk):
            continue                    # stays a hole
        o.seek(e["start"] * bs)
        o.write(chunk)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("info", "extract", "apply"):
        sys.exit(__doc__)
    pl = Payload(sys.argv[2])
    if sys.argv[1] == "info":
        kind = "delta" if any(pl.is_delta(p) for p in pl.parts) else "full"
        print(f"{kind} payload, block {pl.block}, minor version {pl.minor}")
        for pu in pl.parts:
            ops = {}
            for o in pu["ops"]:
                ops[OPS.get(o["type"], o["type"])] = ops.get(OPS.get(o["type"], o["type"]), 0) + 1
            old = f" from {pu['old']['size']} {pu['old']['hash'].hex()[:16]}" if pu["old"] else ""
            print(f"  {pu['name']:12} {pu['new']['size']:>11} {pu['new']['hash'].hex()[:16]}{old}  "
                  + " ".join(f"{k}x{v}" for k, v in sorted(ops.items())))
        return
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    outdir = sys.argv[3]
    os.makedirs(outdir, exist_ok=True)
    names = {p["name"] for p in pl.parts}
    if sys.argv[1] == "extract":
        want = set(sys.argv[4:]) or names
        if want - names:
            sys.exit(f"not in payload: {' '.join(sorted(want - names))}")
        delta = [p["name"] for p in pl.parts if p["name"] in want and pl.is_delta(p)]
        if delta:
            sys.exit("delta payload: " + " ".join(delta) + " need the old images; use apply")
        for pu in pl.parts:
            if pu["name"] in want:
                apply_partition(pl, pu, None, os.path.join(outdir, pu["name"] + ".img"))
        return
    olds = {}
    for a in sys.argv[4:]:
        k, _, v = a.partition("=")
        olds[k] = v
    if olds.keys() - names:
        sys.exit(f"not in payload: {' '.join(sorted(olds.keys() - names))}")
    # apply the partitions given; with none given, all of them (each delta one needs its old image)
    want = set(olds) or names
    missing = [p["name"] for p in pl.parts if p["name"] in want and pl.is_delta(p) and p["name"] not in olds]
    if missing:
        sys.exit(f"old image missing for: {' '.join(missing)}")
    for pu in pl.parts:
        if pu["name"] in want:
            apply_partition(pl, pu, olds.get(pu["name"]), os.path.join(outdir, pu["name"] + ".img"))


if __name__ == "__main__":
    main()
