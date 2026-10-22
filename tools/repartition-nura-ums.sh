#!/usr/bin/env bash
# repartition-nura.sh over U-Boot USB Mass Storage instead of EDL (no stock Android left to
# `adb reboot edl`). Same layout and checks; see repartition-nura.sh for the layout.
# Offline tests: NURA_NO_ELEVATE=1 skips pkexec when DEV is a regular file you own (images
# only, see docs/re-tools/test-repartition-nura.sh on the docs branch); NURA_OUT overrides the output directory (default ./repartition-<date>).
#   tools/repartition-nura-ums.sh /dev/sdX <pmOS_boot img> <pmOS_root img> [swap GiB, default 8]
# Arch Linux Ports: RS6_PART_PREFIX=arch names the four entries arch_* instead of nura_* (lib/nura-gpt.sh).
# U-Boot: volume up at boot -> menu -> USB Mass Storage; /dev/sdX is the whole eMMC user area.
set -euo pipefail
SELF=$(realpath "$0")
source "$(dirname "$SELF")/lib/nura-gpt.sh"
DEV=$1
BOOT=$(realpath "$2")
ROOT=$(realpath "$3")
SWAP_GIB=${4:-8}
nura_layout "$SWAP_GIB"
TOTAL=$NURA_TOTAL

if [ "$(id -u)" != 0 ]; then
	[ -b "$DEV" ] || [ -f "$DEV" ] || { echo "$DEV: not a block device"; exit 1; }
	[ "$SWAP2_SECT" -gt 0 ] || { echo "swap ${SWAP_GIB} GiB fits in nura_swap1 alone; adjust the layout"; exit 1; }
	for f in "$BOOT:$((BOOT_SECT * 512))" "$ROOT:$(((TOTAL - 34 - ROOT_START) * 512))"; do
		img=${f%:*} max=${f##*:} sz=$(stat -c%s "${f%:*}")
		[ "$sz" -le "$max" ] && [ $((sz % 512)) = 0 ] || { echo "$img: size $sz does not fit (max $max)"; exit 1; }
	done
	command -v sgdisk >/dev/null || { echo "need sgdisk (gptfdisk on Arch, gdisk on Debian)"; exit 1; }
	command -v mkswap >/dev/null || { echo "need mkswap (util-linux)"; exit 1; }
	if [ -n "${NURA_NO_ELEVATE:-}" ] && [ -f "$DEV" ] && [ -O "$DEV" ]; then
		export OWNER="$(id -u):$(id -g)"	# test mode: regular image file, stay unprivileged
	else
		exec systemd-run --user --wait --pipe --quiet -p WorkingDirectory="$PWD" \
			pkexec env RS6_PART_PREFIX="$PFX" OWNER="$(id -u):$(id -g)" "$SELF" "$DEV" "$BOOT" "$ROOT" "$SWAP_GIB"
	fi
fi

# identity: exact size and the stock partition table
sz=$(( $(blockdev --getsize64 "$DEV" 2>/dev/null || stat -c%s "$DEV") / 512 ))
[ "$sz" = "$TOTAL" ] || { echo "$DEV has $sz sectors, the RS6 eMMC has $TOTAL; stopping"; exit 1; }

OUT=${NURA_OUT:-$PWD/repartition-$(date +%Y%m%d-%H%M)}
mkdir -p "$OUT"
sgdisk --backup="$OUT/gpt.orig.sgdisk" "$DEV" >/dev/null
dd if="$DEV" of="$OUT/gpt-primary.orig" bs=512 count=34 status=none
dd if="$DEV" of="$OUT/gpt-backup.orig" bs=512 skip=$((TOTAL - 33)) count=33 status=none

# identity checks, edit on a sparse copy, validate the NEW table (names, no holes, sectors,
# untouched entries identical) before anything is written to the disk
nura_build_gpt "$OUT" "$SWAP_GIB"

# write the checked GPT (backup first), then contents by sector
dd if="$OUT/gpt-backup.new" of="$DEV" bs=512 seek=$((TOTAL - 33)) conv=notrunc,fsync status=none
dd if="$OUT/gpt-primary.new" of="$DEV" bs=512 conv=notrunc,fsync status=none
cmp "$OUT/gpt-primary.new" <(dd if="$DEV" bs=512 count=34 status=none) && echo "primary GPT readback matches"
cmp "$OUT/gpt-backup.new" <(dd if="$DEV" bs=512 skip=$((TOTAL - 33)) count=33 status=none) && echo "backup GPT readback matches"
sgdisk -v "$DEV" | grep -q 'No problems found' || { echo "sgdisk -v on the device reports problems"; exit 1; }
sgdisk -p "$DEV" | tee "$OUT/sgdisk.dev.txt"

nura_swaphdr "${PFX}_swap1" "$SWAP1_SECT" | dd of="$DEV" bs=512 seek="$SWAP1_START" conv=notrunc,fsync status=none
nura_swaphdr "${PFX}_swap2" "$SWAP2_SECT" | dd of="$DEV" bs=512 seek="$UD_START" conv=notrunc,fsync status=none
dd if="$BOOT" of="$DEV" bs=4M seek=$((SYS_START * 512)) oflag=seek_bytes conv=notrunc,fsync status=progress
dd if="$ROOT" of="$DEV" bs=4M seek=$((ROOT_START * 512)) oflag=seek_bytes conv=notrunc,fsync status=progress
# clear misc: a leftover bootonce-bootloader makes ABL drop to fastboot
dd if=/dev/zero of="$DEV" bs=512 seek="$MISC_START" count="$MISC_SECT" conv=notrunc,fsync status=none
sync
cmp "$BOOT" <(dd if="$DEV" bs=4M skip=$((SYS_START * 512)) iflag=skip_bytes,count_bytes count=$(stat -c%s "$BOOT") status=none) &&
	echo "${PFX}_boot readback matches"
cmp "$ROOT" <(dd if="$DEV" bs=4M skip=$((ROOT_START * 512)) iflag=skip_bytes,count_bytes count=$(stat -c%s "$ROOT") status=none) &&
	echo "${PFX}_root readback matches"
cmp <(head -c $((MISC_SECT * 512)) /dev/zero) <(dd if="$DEV" bs=512 skip="$MISC_START" count="$MISC_SECT" status=none) &&
	echo "misc is zero"
blkid -p -O $((SWAP1_START * 512)) "$DEV"
blkid -p -O $((UD_START * 512)) "$DEV"
chown -R "${OWNER:-$(id -u):$(id -g)}" "$OUT"
echo "saved to $OUT; eject UMS in U-Boot and boot: U-Boot (boot_a) -> ABL -> extlinux on ${PFX}_boot"
