# Offline test of repartition-nura-ums.sh and repartition-nura.sh (EDL, via an edl stand-in)
# against sparse disk images. Never touches a device. The stock GPT is the first 34 sectors of
# your own RS6's eMMC (gpt_main0.bin from the 1.80 EDL dump zip: the real 68-entry table), given
# in NURA_GPTDUMP. The backup array is put at the end of the disk (TOTAL-18), not
# where ABL rewrites it, so the run also proves the scripts move it; a second UMS run starts from
# TOTAL-33, where HiBy's factory package puts it (docs/boot-and-partitions.md). Every result goes through
# abl-gpt-check.py and xbl-gpt-check.py, the offline models of the stock ABL and XBL
# (docs/boot-and-partitions.md), which live next to this script.
# The scripts under test live on the main branch: NURA_TOOLS=<checkout of main>/tools
# (default: ../../tools relative to this file, i.e. both branches merged into one tree).
# Usage: NURA_GPTDUMP=gpt_main0.bin [NURA_TOOLS=...] docs/re-tools/test-repartition-nura.sh [scratch dir]
set -euo pipefail
HERE=$(dirname "$(realpath "$0")")
TOOLS=$(realpath "${NURA_TOOLS:-$HERE/../../tools}")
[ -f "$TOOLS/lib/nura-gpt.sh" ] || { echo "no $TOOLS/lib/nura-gpt.sh: set NURA_TOOLS to the tools/ dir of the main branch"; exit 1; }
GPTDUMP=${NURA_GPTDUMP:?set NURA_GPTDUMP to gpt_main0.bin from your 1.80 EDL dump}
source "$TOOLS/lib/nura-gpt.sh"
W=${1:-$(mktemp -d)}
mkdir -p "$W"
export RS6_LOADER=$W/loader.stub	# the scripts only realpath it; the edl stand-in ignores it
: > "$RS6_LOADER"

# gpt_backup <image> <entries lba>: rewrite the backup GPT (header at the last LBA, entries at
# <lba>) from the primary, leaving the primary header untouched
gpt_backup() {
	python3 -I - "$1" "$2" <<'EOF'
import struct, sys, zlib
img, elba = sys.argv[1], int(sys.argv[2])
with open(img, "r+b") as f:
    f.seek(512); h = bytearray(f.read(512))
    last, = struct.unpack_from("<Q", h, 32); pe, n, esz = struct.unpack_from("<QII", h, 72)
    f.seek(pe * 512); ents = f.read(n * esz)
    struct.pack_into("<QQ", h, 24, last, 1); struct.pack_into("<Q", h, 72, elba)
    struct.pack_into("<I", h, 16, 0); struct.pack_into("<I", h, 16, zlib.crc32(bytes(h[:92])))
    f.seek(elba * 512); f.write(ents); f.seek(last * 512); f.write(h)
EOF
}

mkstock() {	# $1 = image
	truncate -s $((NURA_TOTAL * 512)) "$1"
	dd if="$GPTDUMP" of="$1" conv=notrunc status=none
	echo "stock GPT: $GPTDUMP"
	gpt_backup "$1" $((NURA_TOTAL - 18))
}

fail() { echo "TEST FAIL: $*"; exit 1; }
expect_fail() { local d=$1; shift; if ( "$@" ) >"$W/neg.log" 2>&1; then fail "$d was accepted"; else echo "ok: $d rejected ($(tail -n 1 "$W/neg.log"))"; fi; }

STOCK=$W/stock.img
mkstock "$STOCK"
sgdisk -v "$STOCK" | grep -q 'No problems found' || fail "stock image invalid"
read -r used last < <(nura_counts "$STOCK")
echo "stock image: $used entries, last $last, table holds $(nura_hdr "$STOCK" 1 | awk '{ print $7 }')"
[ "$used" = 67 ] && [ "$last" = 67 ] || fail "stock should have 67 gapless entries"
[ "$(nura_hdr "$STOCK" 1 | awk '{ print $7 }')" = 68 ] || fail "stock table should hold 68 entries"

head -c $((4 * 1024 * 1024)) /dev/urandom > "$W/boot.img"
head -c $((8 * 1024 * 1024)) /dev/urandom > "$W/root.img"
dirty_misc() {	# a stale bootonce-bootloader, as left by the failed boot
	local s; s=$(nura_field "$1" misc First)
	printf 'bootonce-bootloader' | dd of="$1" bs=512 seek="$s" conv=notrunc status=none
}

echo "=== UMS script on a sparse image"
D1=$W/ums.img; cp --sparse=always "$STOCK" "$D1"; dirty_misc "$D1"
NURA_NO_ELEVATE=1 NURA_OUT=$W/out-ums "$TOOLS/repartition-nura-ums.sh" "$D1" "$W/boot.img" "$W/root.img" 8
nura_layout 8; nura_validate "$D1"
sgdisk -v "$D1"; sgdisk -p "$D1" | sed -n '1,10p;/^ *4[6-9] /p;/^ *5[0-3] /p;/^ *6[5-9] /p'
cmp <(head -c $((MISC_SECT * 512)) /dev/zero) <(dd if="$D1" bs=512 skip="$MISC_START" count="$MISC_SECT" status=none) || fail "misc not zero"
python3 -I "$HERE/abl-gpt-check.py" "$D1" | tee "$W/abl-ums.txt" | grep -vE '^ok' || fail "ABL model rejects the UMS table"
python3 -I "$HERE/xbl-gpt-check.py" "$D1" > "$W/xbl-ums.txt" || fail "XBL model rejects the UMS table"
echo "UMS: PASS"

echo "=== UMS script, stock backup array at TOTAL-33 (where HiBy's factory package flashes it)"
D3=$W/ums33.img; cp --sparse=always "$STOCK" "$D3"; gpt_backup "$D3" $((NURA_TOTAL - 33)); dirty_misc "$D3"
sgdisk -v "$D3" | grep -q 'No problems found' || fail "TOTAL-33 stock image invalid"
NURA_NO_ELEVATE=1 NURA_OUT=$W/out-ums33 "$TOOLS/repartition-nura-ums.sh" "$D3" "$W/boot.img" "$W/root.img" 8 >"$W/ums33.log"
nura_validate "$D3"
cmp <(sgdisk -p "$D1" | sed 1d) <(sgdisk -p "$D3" | sed 1d) || fail "TOTAL-33 and TOTAL-18 stocks give different tables"
python3 -I "$HERE/abl-gpt-check.py" "$D3" > "$W/abl-ums33.txt" || fail "ABL model rejects the table from a TOTAL-33 stock"
python3 -I "$HERE/xbl-gpt-check.py" "$D3" > "$W/xbl-ums33.txt" || fail "XBL model rejects the table from a TOTAL-33 stock"
echo "UMS from factory-layout stock: PASS (same table)"

echo "=== EDL script via edl stand-in on a sparse image"
cat > "$W/edl-stub.sh" <<'STUB'
#!/usr/bin/env bash
# stand-in for bkerler edl: rs <start> <count> <file> | ws <start> <file> | printgpt | reset
img=$STUB_IMG
case $1 in
	rs) dd if="$img" of="$4" bs=512 skip="$2" count="$3" status=none ;;
	ws) dd if="$3" of="$img" bs=512 seek="$2" conv=notrunc status=none ;;
	printgpt) sgdisk -p "$img" | awk 'f && NF { print $NF ":", $0 } /^Number/ { f = 1 }' ;;
	reset) ;;
esac
STUB
chmod +x "$W/edl-stub.sh"
D2=$W/edl.img; cp --sparse=always "$STOCK" "$D2"; dirty_misc "$D2"
STUB_IMG=$D2 EDL=$W/edl-stub.sh NURA_NO_ELEVATE=1 NURA_OUT=$W/out-edl "$TOOLS/repartition-nura.sh" "$W/boot.img" "$W/root.img" 8
nura_validate "$D2"
sgdisk -v "$D2"; sgdisk -p "$D2" | sed -n '1,10p;/^ *4[6-9] /p;/^ *5[0-3] /p;/^ *6[5-9] /p'
cmp <(head -c $((MISC_SECT * 512)) /dev/zero) <(dd if="$D2" bs=512 skip="$MISC_START" count="$MISC_SECT" status=none) || fail "misc not zero"
cmp "$W/boot.img" <(dd if="$D2" bs=512 skip="$SYS_START" count=$((4 * 2048)) status=none) || fail "boot content"
cmp "$W/root.img" <(dd if="$D2" bs=512 skip="$ROOT_START" count=$((8 * 2048)) status=none) || fail "root content"
cmp <(sgdisk -p "$D1" | sed 1d) <(sgdisk -p "$D2" | sed 1d) || fail "UMS and EDL tables differ"
python3 -I "$HERE/abl-gpt-check.py" "$D2" > "$W/abl-edl.txt" || fail "ABL model rejects the EDL table"
python3 -I "$HERE/xbl-gpt-check.py" "$D2" > "$W/xbl-edl.txt" || fail "XBL model rejects the EDL table"
echo "EDL: PASS (same table as UMS)"

echo "=== negative cases"
expect_fail "re-run on an already converted disk" env NURA_NO_ELEVATE=1 NURA_OUT=$W/out-neg "$TOOLS/repartition-nura-ums.sh" "$D1" "$W/boot.img" "$W/root.img" 8
H=$W/hole.img; cp --sparse=always "$D1" "$H"; sgdisk -d 60 "$H" >/dev/null
expect_fail "table with a hole" bash -c 'source "$0"; nura_layout 8; nura_validate "$1"' "$TOOLS/lib/nura-gpt.sh" "$H"
expect_fail "XBL model on a table with a hole (handles shift)" python3 -I "$HERE/xbl-gpt-check.py" "$H"
M=$W/nosysb.img; cp --sparse=always "$D1" "$M"; sgdisk -d 68 "$M" >/dev/null
expect_fail "table without system_b" bash -c 'source "$0"; nura_layout 8; nura_validate "$1"' "$TOOLS/lib/nura-gpt.sh" "$M"
B=$W/badbackup.img; cp --sparse=always "$D1" "$B"; gpt_backup "$B" $((NURA_TOTAL - 18))
expect_fail "backup array not where ABL rewrites it" bash -c 'source "$0"; nura_layout 8; nura_validate "$1"' "$TOOLS/lib/nura-gpt.sh" "$B"
# the stock dump has slot B active, so the slot ABL validates is B
G=$W/sameguid.img; cp --sparse=always "$D1" "$G"; sgdisk -t "$(nura_num "$G" system_b):$(nura_type "$G" boot_b)" "$G" >/dev/null
expect_fail "system_b with boot_b's type GUID" bash -c 'source "$0"; nura_layout 8; nura_validate "$1"' "$TOOLS/lib/nura-gpt.sh" "$G"
expect_fail "ABL model on system_b with boot_b's type GUID" python3 -I "$HERE/abl-gpt-check.py" "$G"
echo "ALL PASS (scratch: $W)"
