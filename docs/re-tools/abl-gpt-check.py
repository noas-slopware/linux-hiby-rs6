#!/usr/bin/env python3
"""Offline model of what the RS6 stock ABL (LinuxLoader in abl_a, see docs/abl-gpt.md) does with
the eMMC GPT on a normal boot, applied to a disk image (sparse is fine). Reads only; the write-back
is simulated in memory.

  abl-gpt-check.py <disk image>

Exit 0 when ABL would pick a bootable slot, build root= from system_<slot>, and its attribute
write-back (MarkPtnActive -> UpdatePartitionAttributes, every boot) leaves both GPTs valid and
changes nothing but attribute bit 50.
"""
import struct
import sys
import zlib

SEC = 512
ABL_ENTRIES_SZ = 0x4000         # MAX_PARTITION_ENTRIES_SZ, hard-coded in UpdatePartitionAttributes
ABL_BLOCKS = ABL_ENTRIES_SZ // SEC + 1   # 33: header + 32 entry sectors
MAX_PTN = 0x80                  # PtnEntries[] capacity
ACTIVE, SUCCESS, UNBOOT = 1 << 50, 1 << 54, 1 << 55
fails = []


def check(ok, msg):
    print(("ok   " if ok else "FAIL ") + msg)
    if not ok:
        fails.append(msg)
    return ok


def hdr(blk):
    cur, alt, fu, lu = struct.unpack_from("<QQQQ", blk, 24)
    elba, n, esz, ecrc = struct.unpack_from("<QIII", blk, 72)
    hs, hcrc = struct.unpack_from("<II", blk, 12)
    h = bytearray(blk[:hs])
    h[16:20] = bytes(4)
    return dict(sig=blk[:8], hs=hs, hcrc_ok=zlib.crc32(bytes(h)) == hcrc, cur=cur, alt=alt, fu=fu,
                lu=lu, elba=elba, n=n, esz=esz, ecrc=ecrc)


def read(f, lba, count):
    f.seek(lba * SEC)
    return bytearray(f.read(count * SEC))


def gpt(f, lba, tag):
    h = hdr(read(f, lba, 1))
    ents = read(f, h["elba"], (h["n"] * h["esz"] + SEC - 1) // SEC)[:h["n"] * h["esz"]]
    check(h["sig"] == b"EFI PART" and h["hcrc_ok"] and zlib.crc32(ents) == h["ecrc"],
          f"{tag} GPT at LBA {lba}: signature, header CRC, entry-array CRC")
    return h, ents


def entries(ents, h):
    out = []
    for k in range(h["n"]):
        e = ents[k * h["esz"]:(k + 1) * h["esz"]]
        s, l, a = struct.unpack_from("<QQQ", e, 32)
        out.append(dict(type=bytes(e[:16]), uniq=bytes(e[16:32]), start=s, end=l, attr=a,
                        name=e[56:128].decode("utf-16le").split("\0")[0]))
    return out


def main(path):
    f = open(path, "rb")
    f.seek(0, 2)
    total = f.tell() // SEC
    ph, pents = gpt(f, 1, "primary")
    bh, bents = gpt(f, ph["alt"], "backup")
    check(pents == bents, "primary and backup entry arrays identical")
    check(ph["elba"] == 2, f"primary entries at LBA 2 (ABL reads LBA 1-33 blindly): {ph['elba']}")
    check(ph["alt"] == total - 1, f"backup header at the last LBA: {ph['alt']}")
    check(bh["elba"] == total - ABL_BLOCKS,
          f"backup entries at last LBA - 32 = {total - ABL_BLOCKS} (ABL reads/writes them there blindly): {bh['elba']}")
    check(ph["n"] * ph["esz"] <= ABL_ENTRIES_SZ and ph["esz"] == 128,
          f"entry array fits ABL's 16 KiB ({ph['n']} x {ph['esz']})")
    check(ph["hs"] == 92, f"header size 92 (ABL recomputes the header CRC over 0x5c bytes): {ph['hs']}")

    ents = entries(pents, ph)
    # XBL PartitionDxe hands ABL one BlockIo handle per entry. Model both a stop-at-first-empty
    # parser (Qualcomm/bkerler) and an EDK2 one (skips unused, out-of-range, overlapping,
    # attribute-bit-1 entries); ABL maps handle k to raw entry k, so both must give 0..N-1.
    stop = []
    for k, e in enumerate(ents):
        if e["type"] == bytes(16):
            break
        stop.append(k)
    used = [k for k, e in enumerate(ents) if e["type"] != bytes(16)]
    edk2 = []
    for k in used:
        e = ents[k]
        if not (ph["fu"] <= e["start"] <= e["end"] <= ph["lu"]) or e["attr"] & 2:
            continue
        if any(j != k and not (e["end"] < ents[j]["start"] or ents[j]["end"] < e["start"]) for j in used):
            continue
        edk2.append(k)
    check(stop == list(range(len(stop))) and stop == used == edk2,
          f"enumeration: {len(stop)} handles, gapless, same for stop-at-empty and EDK2 rules")
    check(all(e["uniq"] != bytes(16) for e in (ents[k] for k in used)),
          "every used entry has a unique GUID (bkerler edl stops at a zero one)")
    # the eMMC root handle (no partition record) takes PtnEntries[0], so partitions get 1..
    check(len(stop) + 1 <= MAX_PTN, f"<= {MAX_PTN - 1} partitions (PtnEntries[0] is the disk itself)")
    win = [ents[k]["name"] for k in used if ents[k]["start"] < ABL_BLOCKS + 1 or ents[k]["end"] > total - ABL_BLOCKS - 1]
    check(not win, f"no partition inside ABL's GPT write windows (LBA 1-33, last 33): {win}")
    ptn = [ents[k] for k in stop]
    idx = {e["name"]: k for k, e in reversed(list(enumerate(ptn)))}

    # PartitionHasMultiSlot(L"boot") @0x17298, GetActiveSlot @0x17368
    check("boot_a" in idx and "boot_b" in idx, "boot_a and boot_b present (multislot, GetActiveSlot)")
    if fails:
        return 1
    slot, prio = None, 0
    for s in ("_a", "_b"):
        a = ptn[idx["boot" + s]]["attr"]
        p = (a >> 48) & 3
        if a & ACTIVE and p > prio:
            slot, prio = s, p
    if slot is None:
        a = ptn[idx["boot_a"]]["attr"]
        first = (a >> 48) & 0xc7 == 0     # no priority/active/success/unbootable
        check(first, "an active boot slot (or a blank boot_a: ABL's first-boot default to _a)")
        slot = "_a"
    print(f"     active slot {slot}, boot{slot} attr byte 6 = {ptn[idx['boot' + slot]]['attr'] >> 48 & 0xff:#04x}")
    # FindBootableSlot @0x1a008
    a = ptn[idx["boot" + slot]]["attr"]
    retry = (a >> 51) & 7
    check(not a & UNBOOT and (a & SUCCESS or retry > 0),
          f"boot{slot} bootable (unbootable=0, successful=1 or retry>0): retry {retry}")
    # ValidateSlotGuids (inlined in FindBootableSlot)
    sysn = "system" + slot
    check(sysn in idx, f"{sysn} present (ValidateSlotGuids, GetSystemPath)")
    if sysn in idx:
        check(ptn[idx[sysn]]["type"] != ptn[idx["boot" + slot]]["type"],
              f"{sysn} type GUID differs from boot{slot}'s (ValidateSlotGuids)")
        print(f"     root=/dev/mmcblk0p{idx[sysn] + 1} (GetSystemPath @0x13038: PtnEntries index = entry number)")
    other = "_b" if slot == "_a" else "_a"
    check("system" + other in idx, f"system{other} present (needed after a slot switch)")

    # MarkPtnActive (StrStr on the suffix) + UpdatePartitionAttributes @0x17b38, simulated
    new = [dict(e) for e in ptn]
    for e in new:
        e["attr"] = e["attr"] | ACTIVE if slot in e["name"] else e["attr"] & ~ACTIVE
    for lba, hoff, eoff in ((1, 0, SEC), (total - ABL_BLOCKS, ABL_ENTRIES_SZ, 0)):
        buf = read(f, lba, ABL_BLOCKS)
        for k, e in enumerate(new):
            o = eoff + k * 128
            if struct.unpack_from("<Q", buf, o + 48)[0] != e["attr"] or buf[o:o + 16] != e["type"]:
                struct.pack_into("<Q", buf, o + 48, e["attr"])
                buf[o:o + 16] = e["type"]
        n, esz = struct.unpack_from("<II", buf, hoff + 80)
        struct.pack_into("<I", buf, hoff + 88, zlib.crc32(bytes(buf[eoff:eoff + n * esz])))
        struct.pack_into("<I", buf, hoff + 16, 0)
        struct.pack_into("<I", buf, hoff + 16, zlib.crc32(bytes(buf[hoff:hoff + 0x5c])))
        h = hdr(bytes(buf[hoff:hoff + SEC]))
        start = h["elba"] - lba
        arr = bytes(buf[start * SEC:start * SEC + h["n"] * h["esz"]]) if 0 <= start < ABL_BLOCKS else b""
        ok = h["hcrc_ok"] and arr and zlib.crc32(arr) == h["ecrc"]
        tag = "primary" if lba == 1 else "backup"
        check(bool(ok), f"after ABL's write-back the {tag} GPT is still valid")
        if ok:
            after = entries(bytearray(arr), h)
            diff = [(b["name"], hex(b["attr"] ^ x["attr"])) for b, x in zip(ents, after) if b != x]
            check(all(d[1] == hex(ACTIVE) for d in diff), f"{tag}: write-back only flips bit 50: {diff}")
    return 1 if fails else 0


if __name__ == "__main__":
    rc = main(sys.argv[1])
    print("ABL model: " + ("PASS" if rc == 0 else f"FAIL ({len(fails)})"))
    sys.exit(rc)
