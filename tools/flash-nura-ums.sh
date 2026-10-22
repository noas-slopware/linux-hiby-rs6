#!/usr/bin/env bash
# Write a Nura boot + root image into nura_boot / nura_root over U-Boot USB Mass Storage.
# The partition table is only read, never written. Run on the machine the RS6 is plugged into:
#   tools/flash-nura-ums.sh /dev/sdX <pmOS_boot img> <pmOS_root img>
# U-Boot: volume up at boot -> menu -> USB Mass Storage.
set -euo pipefail
SELF=$(realpath "$0")
DEV=$1
BOOT=$(realpath "$2")
ROOT=$(realpath "$3")
TOTAL=122142720		# RS6 eMMC user area, sectors

if [ "$(id -u)" != 0 ]; then
	exec systemd-run --user --wait --pipe --quiet pkexec "$SELF" "$DEV" "$BOOT" "$ROOT"
fi

sz=$(( $(blockdev --getsize64 "$DEV") / 512 ))
[ "$sz" = "$TOTAL" ] || { echo "$DEV has $sz sectors, the RS6 has $TOTAL; stopping"; exit 1; }
P=$(sgdisk -p "$DEV")
num() { awk -v n="$1" '$NF == n { print $1 }' <<< "$P"; }
for n in nura_boot nura_root system_a system_b misc boot_a boot_b; do
	[ -n "$(num $n)" ] || { echo "no $n entry; stopping"; exit 1; }
done
# No holes: XBL skips empty entries, so every later partition handle shifts by one and ABL's
# position-based mmcblk0pN and attribute write-back hit the wrong entries (docs/boot-and-partitions.md on the docs branch)
last=$(awk 'f && NF { n = $1 } /^Number/ { f = 1 } END { print n }' <<< "$P")
used=$(awk 'f && NF { c++ } /^Number/ { f = 1 } END { print c }' <<< "$P")
[ "$last" = "$used" ] || { echo "GPT has holes ($used entries, last is $last); stopping"; exit 1; }

first() { sgdisk -i "$(num "$1")" "$DEV" | awk '/First sector/ { print $3 }'; }
lastsec() { sgdisk -i "$(num "$1")" "$DEV" | awk '/Last sector/ { print $3 }'; }
for p in "nura_boot:$BOOT" "nura_root:$ROOT"; do
	n=${p%%:*} img=${p#*:}
	s=$(first $n) e=$(lastsec $n)
	[ $(( (e - s + 1) * 512 )) -ge "$(stat -c%s "$img")" ] || { echo "$img does not fit $n"; exit 1; }
	echo "== $img -> $n (sector $s)"
	dd if="$img" of="$DEV" bs=4M seek=$((s * 512)) oflag=seek_bytes conv=notrunc,fsync status=progress
	cmp "$img" <(dd if="$DEV" bs=4M skip=$((s * 512)) iflag=skip_bytes,count_bytes count=$(stat -c%s "$img") status=none) &&
		echo "$n readback matches"
done
sync
echo "done; eject UMS in U-Boot and boot"
