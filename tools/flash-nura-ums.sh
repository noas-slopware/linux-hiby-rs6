#!/usr/bin/env bash
# Write a boot + root image into <prefix>_boot / <prefix>_root over U-Boot USB Mass Storage.
# The partition table is only read, never written. Run on the machine the RS6 is plugged into:
#   tools/flash-nura-ums.sh /dev/sdX <boot img> <root img>
# RS6_PART_PREFIX=nura (default, Nura) or arch (Arch Linux Ports) picks the entries.
# An image with a .bmap next to it (foo.img.bmap or foo.bmap, for foo.img or a compressed
# foo.img.xz/.zst/.gz/...) goes through bmaptool into the partition's block device: only the mapped
# blocks are written (decompressed on the fly), then only those are read back and compared with the
# bmap's checksums (bmap-readback.py). An image without a .bmap must be uncompressed; it is written
# whole with dd and read back whole.
# U-Boot: volume up at boot -> menu -> USB Mass Storage.
set -euo pipefail
SELF=$(realpath "$0")
HERE=$(dirname "$SELF")
DEV=$1
BOOT=$(realpath "$2")
ROOT=$(realpath "$3")
TOTAL=122142720		# RS6 eMMC user area, sectors
PFX=${RS6_PART_PREFIX:-nura}
case $PFX in nura|arch) ;; *) echo "RS6_PART_PREFIX must be nura or arch, not '$PFX'"; exit 1 ;; esac

# the .bmap of an image, if there is one
bmapof() {
	local b=${1%.*} f
	case $1 in *.img) b=$1 ;; esac
	for f in "$b.bmap" "${b%.img}.bmap"; do
		[ -f "$f" ] && { echo "$f"; return; }
	done
	return 0
}

if [ "$(id -u)" != 0 ]; then
	for img in "$BOOT" "$ROOT"; do
		if [ -n "$(bmapof "$img")" ]; then
			command -v bmaptool >/dev/null || { echo "$img has a .bmap: install bmaptool"; exit 1; }
		else
			case $img in *.img) ;; *) echo "$img: compressed and no .bmap next to it; unpack it first"; exit 1 ;; esac
		fi
	done
	exec systemd-run --user --wait --pipe --quiet pkexec env RS6_PART_PREFIX="$PFX" "$SELF" "$DEV" "$BOOT" "$ROOT"
fi

sz=$(( $(blockdev --getsize64 "$DEV") / 512 ))
[ "$sz" = "$TOTAL" ] || { echo "$DEV has $sz sectors, the RS6 has $TOTAL; stopping"; exit 1; }
! lsblk -nro MOUNTPOINTS "$DEV" | grep -q . || { lsblk -o NAME,PARTLABEL,MOUNTPOINTS "$DEV" | grep -E '/|MOUNT'; echo "unmount the partitions above first"; exit 1; }
P=$(sgdisk -p "$DEV")
num() { awk -v n="$1" '$NF == n { print $1 }' <<< "$P"; }
for n in "${PFX}_boot" "${PFX}_root" system_a system_b misc boot_a boot_b; do
	[ -n "$(num "$n")" ] || { echo "no $n entry (RS6_PART_PREFIX=$PFX); stopping"; exit 1; }
done
# No holes: XBL skips empty entries, so every later partition handle shifts by one and ABL's
# position-based mmcblk0pN and attribute write-back hit the wrong entries (docs/boot-and-partitions.md on the docs branch)
last=$(awk 'f && NF { n = $1 } /^Number/ { f = 1 } END { print n }' <<< "$P")
used=$(awk 'f && NF { c++ } /^Number/ { f = 1 } END { print c }' <<< "$P")
[ "$last" = "$used" ] || { echo "GPT has holes ($used entries, last is $last); stopping"; exit 1; }

first() { sgdisk -i "$(num "$1")" "$DEV" | awk '/First sector/ { print $3 }'; }
lastsec() { sgdisk -i "$(num "$1")" "$DEV" | awk '/Last sector/ { print $3 }'; }
# the kernel's block device for entry $1 of $DEV, checked against the table (start and size)
partdev() {
	local n d s
	n=$(num "$1")
	for d in /sys/class/block/"$(basename "$DEV")"/*/partition; do
		[ "$(cat "$d")" = "$n" ] || continue
		d=${d%/partition}
		s=$(cat "$d/start")
		[ "$s" = "$(first "$1")" ] && [ "$(cat "$d/size")" = $(( $(lastsec "$1") - s + 1 )) ] ||
			{ echo "/dev/${d##*/} does not match $1 in the table (start $s); stopping" >&2; return 1; }
		[ -b "/dev/${d##*/}" ] || { echo "no /dev/${d##*/}" >&2; return 1; }
		echo "/dev/${d##*/}"
		return
	done
	echo "the kernel has no partition $n ($1) on $DEV" >&2
	return 1
}
for p in "${PFX}_boot:$BOOT" "${PFX}_root:$ROOT"; do
	n=${p%%:*} img=${p#*:}
	s=$(first "$n") e=$(lastsec "$n")
	bmap=$(bmapof "$img")
	if [ -n "$bmap" ]; then
		isz=$(sed -n 's|.*<ImageSize> *\([0-9]*\) *</ImageSize>.*|\1|p' "$bmap")
		[ $(( (e - s + 1) * 512 )) -ge "$isz" ] || { echo "$img does not fit $n"; exit 1; }
		pd=$(partdev "$n")
		echo "== $img -> $n ($pd, $bmap)"
		bmaptool copy --bmap "$bmap" "$img" "$pd"
		blockdev --flushbufs "$pd"
		python3 -I "$HERE/bmap-readback.py" "$bmap" "$pd" || { echo "$n readback does not match; stopping"; exit 1; }
	else
		[ $(( (e - s + 1) * 512 )) -ge "$(stat -c%s "$img")" ] || { echo "$img does not fit $n"; exit 1; }
		echo "== $img -> $n (sector $s)"
		dd if="$img" of="$DEV" bs=4M seek=$((s * 512)) oflag=seek_bytes conv=notrunc,fsync status=progress
		blockdev --flushbufs "$DEV"
		cmp "$img" <(dd if="$DEV" bs=4M skip=$((s * 512)) iflag=skip_bytes,count_bytes count=$(stat -c%s "$img") status=none) ||
			{ echo "$n readback does not match; stopping"; exit 1; }
		echo "$n readback matches"
	fi
done
sync
echo "done; eject UMS in U-Boot and boot"
