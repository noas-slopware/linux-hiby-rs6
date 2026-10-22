#!/usr/bin/env bash
# Read-only EDL check: records the firehose loader hash, the GPT and the slot flags. Writes
# nothing to the device.
#   RS6_LOADER=/path/to/prog_emmc_ufs_firehose_Sdm660_ddr.elf tools/edl-check.sh
#   (or pass the loader as the first argument)
# EDL = the bkerler edl executable (default: edl from PATH). Output goes to ./edl-check-<date>.
set -eu
L=$(realpath "${1:-${RS6_LOADER:?give the firehose programmer as argument 1 or in RS6_LOADER}}")
EDL=${EDL:-$(command -v edl || true)}
[ -x "$EDL" ] || { echo "edl not found: install bkerler/edl or set EDL=/path/to/edl"; exit 1; }
OUT=${EDL_CHECK_OUT:-$PWD/edl-check-$(date +%Y%m%d-%H%M)}
mkdir -p "$OUT"
sha256sum "$L" | tee "$OUT/loader.sha256"
# polkit, not sudo; systemd-run puts pkexec in the user session so the prompt
# shows on the desktop even when this runs over ssh
edl() { systemd-run --user --wait --pipe --quiet -p WorkingDirectory="$PWD" pkexec "$EDL" "$@" --loader="$L"; }

if ! lsusb | grep -q 05c6:9008; then
	echo "rebooting to EDL"
	adb reboot edl || true
	for _ in $(seq 30); do lsusb | grep -q 05c6:9008 && break; sleep 1; done
fi
lsusb | grep 05c6:9008 || { echo "no 05c6:9008 device; enter EDL by hand and rerun"; exit 1; }

# getactiveslot fails on this unit (sector-size quirk); the slot is in the printgpt flags
edl printgpt 2>&1 | tee "$OUT/printgpt.txt"
edl reset 2>&1 | tail -n 3
echo "saved to $OUT"
