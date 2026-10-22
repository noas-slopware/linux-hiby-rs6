#!/usr/bin/env python3
"""Pull the HiBy RS6 hm100 FPGA bitstreams and tables out of a stock kernel.

Usage: extract-hm100-blobs.py <Image> <kallsyms.txt> <outdir>

<Image> is the decompressed stock arm64 kernel (from boot_a.bin, appended
DTBs stripped or not, doesn't matter). <kallsyms.txt> is the output of
`kallsyms-finder <Image>` from vmlinux-to-elf.
"""
import hashlib
import os
import sys

TEXT_BASE = 0xFFFFFF8008080000  # stock 4.4 arm64 KIMAGE base, as vmlinux-to-elf guesses it

# Bitstreams: stock streams FS_*_data as is, hbc3000_get_fw_pages() = 1737 pages of 256 bytes
# (hbc3000_program_ram: hbc3000_jtag_program_ram(&FS_chksum, &FS_data, pages << 8)), and takes
# the USERCODE from the first two bytes of the 8-byte FS_*_chksum that follows it. Each file is
# the data followed by its checksum.
FW_PAGES = 1737
CHKSUM = 8
BITSTREAMS = {"FS_data": "FS_chksum", "FS_dsd_data": "FS_dsd_chksum"}
# Only in newer kernels (stock 2.10 on): bitstreams for units with a GW1N-9C (JTAG IDCODE
# 0x1100481b) instead of the GW1N-9 (0x1100581b); rs6_hbc3000_program_ram and
# hm100_program_by_hw_param pick them by ID code. Same layout.
OPTIONAL = {"FS_gw1n9c_data": "FS_gw1n9c_chksum", "FS_gw1n9c_dsd_data": "FS_gw1n9c_dsd_chksum"}
# symbol -> size in bytes
BLOBS = {"hm100_fir_coef_default": 0x1000}
TABLES = ["dsd_i2s_table_hm100", "njw1195a_volume_db"]


def load_syms(path):
    syms = []
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 3:
                syms.append((int(parts[0], 16), parts[2]))
    syms.sort()
    return syms


def main():
    image_path, kallsyms_path, outdir = sys.argv[1:4]
    image = open(image_path, "rb").read()
    syms = load_syms(kallsyms_path)
    addr = {name: a for a, name in syms}
    os.makedirs(outdir, exist_ok=True)

    def next_sym(a):
        return next(s for s, _ in syms if s > a)

    def write(name, data):
        path = os.path.join(outdir, name + ".bin")
        open(path, "wb").write(data)
        print(f"{name:24} size={len(data):7} sha256={hashlib.sha256(data).hexdigest()}")

    def dump(name, size):
        off = addr[name] - TEXT_BASE
        data = image[off:off + size]
        write(name, data)
        return data

    streams = dict(BITSTREAMS)
    streams.update({k: v for k, v in OPTIONAL.items() if k in addr})
    for name, chk in streams.items():
        size = FW_PAGES * 256
        # the checksum follows the data directly, and is CHKSUM bytes long
        if addr[chk] != addr[name] + size or next_sym(addr[chk]) - addr[chk] != CHKSUM:
            sys.exit(f"{name}/{chk}: not {size} + {CHKSUM} bytes back to back")
        off = addr[name] - TEXT_BASE
        data = image[off:off + size + CHKSUM]
        write(name, data)
        sync = data.find(b"\xa5\xc3")
        print(f"{'':24} magic={data[:4].hex()} sync@{sync} idcode={data[sync + 6:sync + 10].hex()} "
              f"usercode={data[size:size + 2].hex()}")

    for name, size in BLOBS.items():
        dump(name, size)

    # Tables: size runs up to the next symbol.
    for name in TABLES:
        a = addr[name]
        nxt = next(s for s, _ in syms if s > a)
        dump(name, nxt - a)


if __name__ == "__main__":
    main()
