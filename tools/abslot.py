#!/usr/bin/env python3
"""Show or switch the Qualcomm A/B slot on a raw eMMC (e.g. U-Boot UMS block device).

  abslot.py /dev/sdX            show slot flags
  abslot.py /dev/sdX b          make slot b active

Does what bkerler/edl's setactiveslot does on this unit: for every *_a/*_b pair,
swap the partition type GUIDs (the active slot carries the real type), set
boot_<active> flags byte to 0x6f and boot_<inactive> to 0x3a, toggle the active
bit (0x04 in attribute byte 6) on the rest; then rewrite the entry arrays and
headers of both the primary and the backup GPT with fixed CRCs.
Only the GPT sectors are written. 512-byte sectors (eMMC).
"""
import struct
import sys
import zlib

SECTOR = 512
ACTIVE = 0x04


def read_gpt(f, lba):
    f.seek(lba * SECTOR)
    hdr = bytearray(f.read(SECTOR))
    assert hdr[:8] == b"EFI PART", f"no GPT header at LBA {lba}"
    hsize, = struct.unpack_from("<I", hdr, 12)
    ent_lba, nent, esize = struct.unpack_from("<QII", hdr, 72)
    f.seek(ent_lba * SECTOR)
    ents = bytearray(f.read(nent * esize))
    assert zlib.crc32(ents) == struct.unpack_from("<I", hdr, 88)[0], f"entry CRC mismatch (LBA {lba})"
    return hdr, hsize, ent_lba, nent, esize, ents


def parts(ents, nent, esize):
    out = {}
    for i in range(nent):
        e = ents[i * esize:(i + 1) * esize]
        if e[:16] == bytes(16):
            continue
        out[e[56:128].decode("utf-16le").rstrip("\0")] = i * esize
    return out


def switch(ents, p, slot):
    other = "a" if slot == "b" else "b"
    for name in p:
        if not name.endswith("_" + slot):
            continue
        base = name[:-2]
        on, off = p[name], p.get(base + "_" + other)
        if off is None:
            continue
        # the active slot carries the real type GUID; swap only if it is on the other side
        if ents[on + 6 + 48] & ACTIVE == 0 and ents[off + 6 + 48] & ACTIVE:
            ents[on:on + 16], ents[off:off + 16] = ents[off:off + 16], ents[on:on + 16]
        if base == "boot":
            ents[on + 48 + 6], ents[off + 48 + 6] = 0x6F, 0x3A
        else:
            ents[on + 48 + 6] |= ACTIVE
            ents[off + 48 + 6] &= ~ACTIVE & 0xFF


def write_gpt(f, lba, hdr, hsize, ent_lba, ents):
    struct.pack_into("<I", hdr, 88, zlib.crc32(ents))
    struct.pack_into("<I", hdr, 16, 0)
    struct.pack_into("<I", hdr, 16, zlib.crc32(bytes(hdr[:hsize])))
    f.seek(ent_lba * SECTOR)
    f.write(ents)
    f.seek(lba * SECTOR)
    f.write(hdr)


def show(ents, p):
    for name in sorted(p):
        if name[:-2] in ("boot", "system", "vendor", "abl", "xbl") and name[-2:] in ("_a", "_b"):
            o = p[name]
            print(f"{name:10} flags byte6=0x{ents[o + 54]:02x} type={ents[o:o + 4].hex()} active={bool(ents[o + 54] & ACTIVE)}")


def main():
    dev, slot = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else None)
    with open(dev, "r+b" if slot else "rb") as f:
        hdr, hsize, ent_lba, nent, esize, ents = read_gpt(f, 1)
        p = parts(ents, nent, esize)
        backup_lba, = struct.unpack_from("<Q", hdr, 32)
        bhdr, bhsize, bent_lba, _, _, bents = read_gpt(f, backup_lba)
        assert bents == ents, "primary and backup entry arrays differ, refusing"
        if slot is None:
            show(ents, p)
            return
        assert slot in ("a", "b")
        switch(ents, p, slot)
        write_gpt(f, backup_lba, bhdr, bhsize, bent_lba, bytearray(ents))
        write_gpt(f, 1, hdr, hsize, ent_lba, ents)
        f.flush()
    with open(dev, "rb") as f:
        hdr, _, _, nent, esize, ents = read_gpt(f, 1)
        show(ents, parts(ents, nent, esize))


if __name__ == "__main__":
    main()
