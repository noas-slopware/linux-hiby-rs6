#!/usr/bin/env python3
# Offline model of how the stock RS6 XBL (1.80 == 1.50, BOOT.XF.1.4-00277-S660LZB-1) reads the
# eMMC GPT, written from the Ghidra decompile in docs/boot-and-partitions.md. Two independent parsers:
#   loader: XBL loader hotplug GPT parser (0x14046ce8, 0x14046d98, 0x14046ef0, 0x140472c8,
#           partition nodes in 0x140465e0, lookup by type GUID in 0x140454f8)
#   uefi:   XBL core PartitionDxe (edk2 Gpt.c: 0x25c0, 0x3008, 0x31b4, 0x3668), whose child
#           handles (with the fe2555be partition record) are what ABL enumerates
# Usage: docs/re-tools/xbl-gpt-check.py <disk image> [total sectors]   (image may be sparse)
import struct, sys, uuid, zlib

BS = 512
img = sys.argv[1]
f = open(img, "rb")
f.seek(0, 2)
TOTAL = int(sys.argv[2]) if len(sys.argv) > 2 else f.tell() // BS
LAST = TOTAL - 1
def rd(lba, n=1):
    f.seek(lba * BS); return f.read(n * BS)
def g(b): return uuid.UUID(bytes_le=bytes(b))
Z = b"\0" * 16
# XBL loader config table (seg 0x1407a000, entries at 0x1407a728, GUIDs at 0x1407b590..0x1407b660)
LOADER = [("xbl (XBL core / UEFI)", "dea0ba2c-cbdd-4805-b4f9-f428251c3e98", "mandatory"),
          ("tz", "a053aa7f-40b8-4b1c-ba08-2f68ac71a4f4", "mandatory"),
          ("hyp", "e1a6a689-0c8d-4cc6-b4e8-55a4320fbd8a", "mandatory"),
          ("rpm", "098df793-d712-413d-9d4e-89d711772228", "cancel fn 0x14023888"),
          ("pmic", "c00eef24-7709-43d6-9799-dd2b411e7a3c", "cancel fn 0x14023798"),
          ("devcfg", "f65d4b16-343d-4e25-aafc-be99b6556a6d", "skipped if absent (0x14023844)"),
          ("apdp", "e6e98da2-e22a-4d12-ab33-169e7deaa507", "skipped if absent (0x140237b4)"),
          ("sti", "aa9a5c4c-4f1f-7d3a-014a-22bd33bf7191", "skipped if absent (0x14023a2c)"),
          ("abl", "bd6928a1-4ce0-a038-4f3a-1495e3eddffb", "skipped if absent (0x14023b4c)"),
          ("ddr", "20a0c19c-286a-42fa-9ce7-f64c3226a794", "training data"),
          ("sec", "303e6ac3-af15-4c54-9e9b-d9a8fbecf401", "fuse blow data"),
          ("fsc", "57b90a16-22c9-e33b-8f5d-0e81686a68cb", "EFS cookie"),
          ("cdt", "a19f205f-ccd8-4b6d-8f1e-2d9bc24cffb1", "absent on stock: 'Using default CDT'")]
fails = 0
def bad(msg):
    global fails; fails += 1; print("FAIL:", msg)

def entries(hdr):
    elba, n, esz = struct.unpack_from("<QII", hdr, 72)
    raw = rd(elba, (n * esz + BS - 1) // BS)[: n * esz]
    out = []
    for i in range(n):
        e = raw[i * esz:(i + 1) * esz]
        s, l, a = struct.unpack_from("<QQQ", e, 32)
        out.append(dict(i=i + 1, type=e[:16], start=s, end=l, attr=a, raw=e,
                        name=e[56:128].decode("utf-16le", "replace").split("\0")[0]))
    return out

# ---------------- XBL loader ----------------
def loader_hdr(lba):	# 0x14046ef0
    h = rd(lba)
    if h[:8] != b"EFI PART": return None, "signature"
    hh = bytearray(h[:92]); crc, = struct.unpack_from("<I", hh, 16); hh[16:20] = b"\0" * 4
    if zlib.crc32(bytes(hh)) != crc: return None, "header CRC (over a fixed 0x5c bytes)"
    my, = struct.unpack_from("<Q", h, 24)
    if my != lba: return None, f"MyLBA {my} != {lba}"
    elba, n, esz, acrc = struct.unpack_from("<QIII", h, 72)
    if n == 0: return None, "no entries"
    if esz == 0 or esz & 0x7f: return None, "entry size"
    lastlba = elba + (n * esz - 1) // BS
    if not (elba <= lastlba <= TOTAL): return None, "array beyond the disk"
    if zlib.crc32(rd(elba, lastlba - elba + 1)[: n * esz]) != acrc: return None, "array CRC"
    return h, None

mbr = rd(0)
if mbr[510:512] == b"\x55\xaa":
    if not any(mbr[0x1c2 + 16 * k] == 0xEE for k in range(4)):
        bad("loader: MBR has 55AA but no 0xEE entry -> no GPT for the XBL loader (0x14046ce8)")
hdr, why = loader_hdr(1)
src = "primary"
if hdr is None:
    print(f"loader: primary GPT rejected ({why}); trying backup header at LBA {LAST}")
    hdr, why = loader_hdr(LAST); src = "backup"
    if hdr is None: bad(f"loader: backup GPT rejected too ({why}); XBL loader sees no partitions")
nodes = []
if hdr is not None:
    ents = entries(hdr)
    for e in ents:
        if e["type"] == Z: continue	# 0x140472c8 skips empty entries
        if len(nodes) == 64: break	# 0x140465e0: while (count < 0x40)
        nodes.append(e)
    used = [e for e in ents if e["type"] != Z]
    print(f"loader: {src} GPT ok, {len(ents)} slots, {len(used)} used, {len(nodes)} visible (cap 64)")
    if len(used) > 64:
        print("loader: not visible to the XBL loader:", ", ".join(f"#{e['i']} {e['name']}" for e in used[64:]))
    for name, gs, how in LOADER:
        gb = uuid.UUID(gs).bytes_le
        hit = [e for e in nodes if e["type"] == gb]
        hid = [e for e in used[64:] if e["type"] == gb]
        if hit:
            extra = f" (also {', '.join('#%d %s' % (e['i'], e['name']) for e in hit[1:])}, ignored)" if len(hit) > 1 else ""
            print(f"loader: {name:22s} -> #{hit[0]['i']} {hit[0]['name']}{extra}")
        else:
            msg = f"loader: {name:22s} -> none ({how})" + (" [exists past the 64 cap!]" if hid else "")
            if how == "mandatory" or hid: bad(msg)
            else: print(msg)

# ---------------- XBL core PartitionDxe ----------------
def uefi_hdr(lba):	# 0x3008 PartitionValidGptTable
    h = rd(lba)
    if h[:8] != b"EFI PART": return None
    hs, = struct.unpack_from("<I", h, 12)
    if hs == 0 or hs > BS: return None
    hh = bytearray(h[:hs]); crc, = struct.unpack_from("<I", hh, 16); hh[16:20] = b"\0" * 4
    if zlib.crc32(bytes(hh)) != crc: return None
    if struct.unpack_from("<Q", h, 24)[0] != lba: return None
    elba, n, esz, acrc = struct.unpack_from("<QIII", h, 72)
    if zlib.crc32(rd(elba, (n * esz + BS - 1) // BS)[: n * esz]) != acrc: return None
    return h
pm = [k for k in range(4) if mbr[0x1be + 16 * k] == 0 and mbr[0x1c2 + 16 * k] == 0xEE
      and struct.unpack_from("<I", mbr, 0x1c6 + 16 * k)[0] == 1]
if not pm: bad("uefi: no protective MBR entry (boot 0, type EE, start 1): PartitionDxe rewrites LBA 0")
p = uefi_hdr(1)
if p is None:
    b = uefi_hdr(LAST)
    if b is None: bad("uefi: neither GPT valid: no partition handles, ABL finds nothing")
    else: bad("uefi: primary invalid, PartitionDxe restores it from the backup on this boot")
    p = b
else:
    alt, = struct.unpack_from("<Q", p, 32)
    if alt != LAST:
        bad(f"uefi: primary AlternateLBA {alt} != LastBlock {LAST}: PartitionDxe rewrites the primary "
            "header (Alt=LastBlock, LastUsable=LastBlock-33) and the backup")
    else:
        b = uefi_hdr(LAST)
        if b is None or struct.unpack_from("<I", b, 88) != struct.unpack_from("<I", p, 88):
            lu, = struct.unpack_from("<Q", p, 48)
            bad(f"uefi: backup at LBA {LAST} invalid or array CRC differs: PartitionDxe rewrites it "
                f"(header at {LAST}, entries at LastUsable+1 = {lu + 1})")
        else:
            belba, = struct.unpack_from("<Q", b, 72)
            print(f"uefi: primary and backup valid, backup entries at {belba} (TOTAL-{TOTAL - belba}); no write")
if p is not None:
    fu, lu = struct.unpack_from("<QQ", p, 40)
    ents = entries(p)
    handles, dropped = [], []
    for e in ents:	# 0x3668 PartitionCheckGptEntry + install loop in 0x25c0
        if e["type"] == Z: continue
        why = []
        if e["end"] < e["start"] or not (fu <= e["start"] <= lu) or not (fu <= e["end"] <= lu): why.append("out of range")
        if any(o is not e and o["type"] != Z and o["start"] <= e["end"] and e["start"] <= o["end"] for o in ents): why.append("overlap")
        if e["attr"] & 2: why.append("attribute bit 1")
        (dropped.append((e, why)) if why else handles.append(e))
    for e, why in dropped: bad(f"uefi: #{e['i']} {e['name']} gets no handle ({', '.join(why)})")
    shifted = [e for k, e in enumerate(handles, 1) if e["i"] != k]
    print(f"uefi: {len(handles)} partition handles (HD path PartitionNumber = entry index)")
    if shifted:
        bad(f"uefi: handle order != entry number from #{shifted[0]['i']} {shifted[0]['name']} on "
            "(hole or dropped entry): ABL's position-based mmcblk0pN and attribute write-back shift")
print("XBL model:", "PASS" if not fails else f"FAIL ({fails})")
sys.exit(1 if fails else 0)
