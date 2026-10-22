#!/usr/bin/env bash
# Give the whole user area of the RS6 eMMC to Nura. Run on the machine the RS6 is plugged
# into (EDL, 05c6:9008):
#   RS6_LOADER=prog_emmc_ufs_firehose_Sdm660_ddr.elf tools/repartition-nura.sh <pmOS_boot img> <pmOS_root img> [swap GiB, default 8]
# RS6_LOADER is the firehose programmer from HiBy's official burn package (not shipped here).
# EDL is the bkerler edl executable (default: edl from PATH).
#
# Removed: stock Android (system_a, system_b, vendor_a, vendor_b, userdata; the full EDL
# dump "HiBy RS6 1.80.zip" restores it). Everything else (xbl..persist, boot_a = U-Boot,
# boot_b, misc, keystore, devcfg, frp, modem/dsp/bluetooth, dtbo, vbmeta, ...) keeps its
# sectors and entry. New entries, in the two freed ranges:
#   0x034000000-0x218000000 (7.56 GiB): nura_boot 1 GiB, nura_swap1 (rest)
#   0x234000000-end        (49.4 GiB): nura_swap2 (swap GiB - nura_swap1), nura_root (rest)
# The stock ABL needs GPT entries named system_a and system_b (it builds root= from them and
# rejects a slot without one, or one whose type GUID equals boot_<slot>'s) and writes slot
# attributes back by entry position, so five freed slots become the four Nura entries plus a
# 1 MiB dummy system_a (sector 34), and a 1 MiB dummy system_b fills the last free slot of the
# 68-entry table (0x220020000). No holes; the backup array stays at TOTAL-33, where ABL
# rewrites it. misc is zeroed (U-Boot leaves bootonce-bootloader there). See docs/boot-and-partitions.md (docs branch).
# Layout and checks live in tools/lib/nura-gpt.sh (shared with repartition-nura-ums.sh).
# The GPT is edited offline (sgdisk on a sparse image carrying the dumped primary + backup
# GPT) and written back sector-exact; the result is printed and checked before writing.
# Offline tests: NURA_NO_ELEVATE=1 skips EDL detection and pkexec (EDL=<edl stand-in>);
# NURA_OUT overrides the output directory (default ./repartition-<date>). See docs/re-tools/test-repartition-nura.sh (docs branch).
set -euo pipefail
SELF=$(realpath "$0")
source "$(dirname "$SELF")/lib/nura-gpt.sh"
L=$(realpath "${RS6_LOADER:?set RS6_LOADER to the firehose programmer (prog_emmc_ufs_firehose_Sdm660_ddr.elf)}")
BOOT=$(realpath "$1")
ROOT=$(realpath "$2")
SWAP_GIB=${3:-8}
nura_layout "$SWAP_GIB"
TOTAL=$NURA_TOTAL

if [ "$(id -u)" != 0 ]; then
	[ "$SWAP2_SECT" -gt 0 ] || { echo "swap ${SWAP_GIB} GiB fits in nura_swap1 alone; adjust the layout"; exit 1; }
	for f in "$BOOT:$((BOOT_SECT * 512))" "$ROOT:$(((TOTAL - 34 - ROOT_START) * 512))"; do
		img=${f%:*} max=${f##*:} sz=$(stat -c%s "${f%:*}")
		[ "$sz" -le "$max" ] && [ $((sz % 512)) = 0 ] || { echo "$img: size $sz does not fit (max $max)"; exit 1; }
	done
	command -v sgdisk >/dev/null || { echo "need sgdisk (gptfdisk on Arch, gdisk on Debian)"; exit 1; }
	command -v mkswap >/dev/null || { echo "need mkswap (util-linux)"; exit 1; }
	if [ -n "${NURA_NO_ELEVATE:-}" ]; then
		export OWNER="$(id -u):$(id -g)" EDL=${EDL:?NURA_NO_ELEVATE needs EDL=<stand-in>}
	else
		if ! lsusb | grep -q 05c6:9008; then
			echo "rebooting to EDL"
			adb -d reboot edl 2>/dev/null || true
			for _ in $(seq 30); do lsusb | grep -q 05c6:9008 && break; sleep 1; done
		fi
		lsusb | grep -q 05c6:9008 || { echo "no 05c6:9008 device; enter EDL by hand and rerun"; exit 1; }
		exec systemd-run --user --wait --pipe --quiet -p WorkingDirectory="$PWD" \
			pkexec env RS6_LOADER="$L" EDL="${EDL:-$(command -v edl)}" OWNER="$(id -u):$(id -g)" "$SELF" "$BOOT" "$ROOT" "$SWAP_GIB"
	fi
fi

OUT=${NURA_OUT:-$PWD/repartition-$(date +%Y%m%d-%H%M)}
EDL=${EDL:-$(command -v edl || true)}
mkdir -p "$OUT"
edl() { "$EDL" "$@" --loader="$L" --memory=emmc; }

# 1. dump the current GPT (primary LBA 0-33, backup last 33 LBAs) and keep it
edl rs 0 34 "$OUT/gpt-primary.orig" 2>&1 | tail -n 2
edl rs $((TOTAL - 33)) 33 "$OUT/gpt-backup.orig" 2>&1 | tail -n 2
edl printgpt > "$OUT/printgpt.orig.txt" 2>&1

# 2. identity checks, edit on a sparse image, validate the NEW table (names, no holes,
#    sectors, untouched entries identical) before anything is written
nura_build_gpt "$OUT" "$SWAP_GIB"

# 3. swap signatures for the exact partition sizes (mkswap on sparse files, first 4 KiB)
nura_swaphdr nura_swap1 "$SWAP1_SECT" > "$OUT/swap1.hdr"
nura_swaphdr nura_swap2 "$SWAP2_SECT" > "$OUT/swap2.hdr"
head -c $((MISC_SECT * 512)) /dev/zero > "$OUT/misc.zero"

# 4. write: GPT first (backup, then primary), then the contents by sector
edl ws $((TOTAL - 33)) "$OUT/gpt-backup.new" 2>&1 | tail -n 2
edl ws 0 "$OUT/gpt-primary.new" 2>&1 | tail -n 2
edl rs 0 34 "$OUT/gpt-primary.readback" 2>&1 | tail -n 1
edl rs $((TOTAL - 33)) 33 "$OUT/gpt-backup.readback" 2>&1 | tail -n 1
cmp "$OUT/gpt-primary.new" "$OUT/gpt-primary.readback" && echo "primary GPT readback matches"
cmp "$OUT/gpt-backup.new" "$OUT/gpt-backup.readback" && echo "backup GPT readback matches"
nura_mkimg "$OUT/readback.img" "$OUT/gpt-primary.readback" "$OUT/gpt-backup.readback"
nura_validate "$OUT/readback.img"
sgdisk -p "$OUT/readback.img" | tee "$OUT/sgdisk.readback.txt"
rm -f "$OUT/readback.img"
edl ws "$SYS_START" "$BOOT" 2>&1 | tail -n 2
edl ws "$SWAP1_START" "$OUT/swap1.hdr" 2>&1 | tail -n 1
edl ws "$UD_START" "$OUT/swap2.hdr" 2>&1 | tail -n 1
edl ws "$ROOT_START" "$ROOT" 2>&1 | tail -n 2
# clear misc: a leftover bootonce-bootloader makes ABL drop to fastboot
edl ws "$MISC_START" "$OUT/misc.zero" 2>&1 | tail -n 1
edl rs "$SYS_START" $(( $(stat -c%s "$BOOT") / 512 )) "$OUT/boot.readback" 2>&1 | tail -n 1
cmp "$BOOT" "$OUT/boot.readback" && echo "nura_boot readback matches"
edl rs "$MISC_START" "$MISC_SECT" "$OUT/misc.readback" 2>&1 | tail -n 1
cmp "$OUT/misc.zero" "$OUT/misc.readback" && echo "misc is zero"
rm -f "$OUT/boot.readback" "$OUT/misc.readback" "$OUT/misc.zero"
edl printgpt > "$OUT/printgpt.new.txt" 2>&1
grep -E '^(nura_|system_|boot_|modem_|dsp_|bluetooth_|persist|keystore|frp|devcfg)' "$OUT/printgpt.new.txt"
edl reset 2>&1 | tail -n 2
chown -R "$OWNER" "$OUT"
echo "saved to $OUT; U-Boot (boot_a) -> ABL -> extlinux on nura_boot -> Nura"
