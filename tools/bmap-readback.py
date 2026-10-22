#!/usr/bin/env python3
# Read back only the mapped ranges of a bmap from a written block device and compare each range
# with the checksum the bmap carries (bmaptool copy checks the image as it reads it, never the
# device). Used by flash-nura-ums.sh after bmaptool copy.
#   tools/bmap-readback.py <file.bmap> <block device>
import hashlib
import os
import sys
import xml.etree.ElementTree as ET

bmap, dev = sys.argv[1:3]
root = ET.parse(bmap).getroot()
major = int(root.get("version", "0").split(".")[0])
if major < 2:
    sys.exit(f"{bmap}: bmap format {root.get('version')}, need 2.x (sha256 checksums)")
bs = int(root.findtext("BlockSize"))
ctype = root.findtext("ChecksumType").strip()
ranges = root.find("BlockMap").findall("Range")
mapped = int(root.findtext("MappedBlocksCount"))

fd = os.open(dev, os.O_RDONLY)
try:
    if os.lseek(fd, 0, os.SEEK_END) < int(root.findtext("ImageSize")):
        sys.exit(f"{dev} is smaller than the image")
    done = 0
    for r in ranges:
        first, _, last = r.text.strip().partition("-")
        first = int(first)
        last = int(last or first)
        h = hashlib.new(ctype)
        left = (last - first + 1) * bs
        os.lseek(fd, first * bs, os.SEEK_SET)
        while left:
            buf = os.read(fd, min(left, 4 << 20))
            if not buf:
                sys.exit(f"{dev}: short read at block {first}")
            h.update(buf)
            left -= len(buf)
        if h.hexdigest() != r.get("chksum"):
            sys.exit(f"{dev}: blocks {first}-{last} do not match the bmap")
        done += last - first + 1
finally:
    os.close(fd)
if done != mapped:
    sys.exit(f"{bmap}: ranges cover {done} blocks, MappedBlocksCount says {mapped}")
print(f"{dev}: {len(ranges)} mapped ranges ({done * bs // 2**20} MiB) read back, all match")
