#!/usr/bin/env bash
# Build the firmware-hiby-rs6 source tarball from the owner's own EDL dump.
#
#   tools/make-firmware-tarball.sh "HiBy RS6 1.80.zip" <outdir>
#
# With --ota, the stock A/B delta OTAs (tools/fetch-hiby-firmware.py fetch --follow) are
# applied, in the order given, to the dump's boot/system/vendor first, so the blobs come
# from that stock version instead of the dump's:
#
#   tools/make-firmware-tarball.sh \
#       --ota rs6-ota-1.80_20231018-1816-to-1.90_20240819-2000.zip \
#       --ota rs6-ota-1.90_20240819-2000-to-2.10_20250826-1521.zip \
#       "HiBy RS6 1.80.zip" <outdir>
#
# Every input image is checked against the OTA's old_partition_info hash and every output
# against new_partition_info (tools/payload-extract.py apply). The OTAs only carry boot,
# system and vendor: modem (NON-HLOS) and bluetooth are never updated by them, so on a
# stock unit that has taken the OTAs they are still the dump's, and they are taken from
# the dump as is. MANIFEST.tsv in the tarball says where each file came from.
#
# Needs: unzip, 7z, mtools, debugfs (e2fsprogs), python3, kallsyms-finder (vmlinux-to-elf);
# with --ota also what tools/ota-patch/build.sh needs (built on first use).
set -euo pipefail
HERE=$(dirname "$(realpath "$0")")
OTAS=()
while [ "${1:-}" = --ota ]; do
	OTAS+=("$(realpath "$2")")
	shift 2
done
ZIP=$(realpath "$1")
OUTDIR=$(realpath "$2")
W=$(mktemp -d -p "${TMPDIR:-/var/tmp}")	# the system image is 3 GiB: not tmpfs
trap 'rm -rf "$W"' EXIT

# Slot B = the stock 1.80 that ran (kernel #16, the modem/dsp/bluetooth/vendor it used).
# (awk reads the whole listing: grep -m1 would quit early and SIGPIPE unzip under pipefail)
pfx=$(unzip -Z1 "$ZIP" | awk '/(^|\/)modem_b\.bin$/ && !n { sub(/modem_b\.bin$/, ""); print; n = 1 }')
unzip -j -q "$ZIP" "${pfx}modem_b.bin" "${pfx}bluetooth_b.bin" "${pfx}vendor_b.bin" "${pfx}boot_b.bin" \
	"${pfx}persist.bin" -d "$W"
python3 -I - "$ZIP" "${pfx}system_b.bin" "$W/system_b.bin" <<'PY'
import sys, zipfile
src, name, dst = sys.argv[1:4]
with zipfile.ZipFile(src) as z, z.open(name) as f, open(dst, "wb") as o:
    while True:	# keep it sparse: 3 GiB, mostly zeros
        b = f.read(1 << 20)
        if not b:
            break
        if b.count(0) == len(b):
            o.seek(len(b), 1)
        else:
            o.write(b)
    o.truncate()
PY

fota_version() {	# ro.fota.version of a system image
	debugfs -R "cat /system/build.prop" "$1" 2>/dev/null | sed -n 's/^ro\.fota\.version=//p'
}
DUMPVER=$(fota_version "$W/system_b.bin")
VER=$DUMPVER
OTAVER=$DUMPVER	# version boot/system/vendor end up at
if [ ${#OTAS[@]} -gt 0 ]; then
	tools=${RS6_OTA_PATCH:-${XDG_CACHE_HOME:-$HOME/.cache}/rs6-ota-patch}
	[ -x "$tools/bspatch" ] && [ -x "$tools/puffpatch" ] || "$HERE/ota-patch/build.sh" "$tools" >/dev/null
	for ota in "${OTAS[@]}"; do
		RS6_OTA_PATCH=$tools python3 -I "$HERE/payload-extract.py" apply "$ota" "$W/ota" \
			boot="$W/boot_b.bin" system="$W/system_b.bin" vendor="$W/vendor_b.bin"
		for p in boot system vendor; do
			mv "$W/ota/$p.img" "$W/${p}_b.bin"
		done
		OTAVER=$(fota_version "$W/system_b.bin")
		echo "applied $(basename "$ota"): now $OTAVER"
	done
	VER=$OTAVER
fi

T=$W/firmware-hiby-rs6
mkdir -p "$T/wlan" "$T/gpu" "$T/hiby" "$T/image" "$T/bt" "$T/darwin" "$T/sensors"
SRC=$W/sources.tsv	# path<TAB>source partition<TAB>stock version
src() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SRC"; }
srcdir() { (cd "$T" && find "$1" -type f) | while read -r f; do src "$f" "$2" "$3"; done; }
if [ ${#OTAS[@]} -gt 0 ]; then
	NOTA="$DUMPVER (dump slot b; the OTAs never touch it, so also $VER's)"	# modem, bluetooth
	OVER="$VER (dump slot b $DUMPVER + OTA deltas, hash-verified)"	# boot, system, vendor
else
	NOTA="$DUMPVER (dump slot b)"
	OVER=$NOTA
fi

# NON-HLOS image/ (mba, modem, adsp, cdsp, venus, wlanmdsp, ...), everything msm-firmware-loader
# would have linked from modem_b, so Nura no longer needs the partition
(cd "$W" && 7z x -y -bso0 modem_b.bin 'image/*' -o"$W/modem")
cp -r "$W/modem/image/." "$T/image/"
# Left out, nothing on Linux loads them: TrustZone apps (Android's qseecomd loads these into
# QSEE: widevine, soter64, securemm, smplap32/64, cmnlib/cmnlib64, cppf, dhsecapp, gptest,
# haventkn, isdbtmm, mdtpseca, iris), the WCD9335/9340 codec CPE images (the RS6 has no WCD
# codec), the modem's diag decode database (qdsp6m.qdb, for host tools) and data.msc.
for f in widevine soter64 securemm smplap32 smplap64 cmnlib cmnlib64 cppf dhsecapp gptest \
	haventkn isdbtmm mdtpseca iris cpe_9335 cpe_9340; do
	rm -f "$T/image/$f".mdt "$T/image/$f".mbn "$T/image/$f".b[0-9][0-9]
done
rm -f "$T/image/qdsp6m.qdb" "$T/image/data.msc"
srcdir image "modem_b NON-HLOS image/" "$NOTA"
# WCN3990 board data files (bdwlan.<board id>), from NON-HLOS
cp "$W/modem/image/"bdwlan.* "$T/wlan/"
srcdir wlan "modem_b NON-HLOS image/" "$NOTA"

# WCN3990 Bluetooth patches/NVM (bluetooth_b image/, loaded from qca/)
# (mtools: the FAT header claims a 64 MiB volume in the 1 MiB partition, 7z errors on it)
mcopy -n -m -i "$W/bluetooth_b.bin" '::/image/*' "$T/bt/"
srcdir bt "bluetooth_b image/" "$NOTA"

# Adreno 512 zap shader, already squashed into one ELF by the vendor
debugfs -R "dump /firmware/a512_zap.elf $T/gpu/a512_zap.mbn" "$W/vendor_b.bin" 2>/dev/null
src gpu/a512_zap.mbn "vendor_b /firmware/a512_zap.elf" "$OVER"

# CP microcode stock kgsl loads for the A512 (a5xx parts share the a530 names); newer than
# linux-firmware's (pm4 0x5ff066 vs 0x5ff063, pfp 0x5ff112 vs 0x5ff08a)
for f in a530_pm4.fw a530_pfp.fw; do
	debugfs -R "dump /firmware/$f $T/gpu/$f" "$W/vendor_b.bin" 2>/dev/null
	src "gpu/$f" "vendor_b /firmware/$f" "$OVER"
done

# Sensor registry the ADSP's Sensor Manager (SMGR) asks the APSS for over QMI (service 0x10f)
# before it brings up any sensor; stock sensors.qti served /persist/sensors/sns.reg, on Nura
# the kernel's qcom_sns_reg does (as qcom/sensors/sns.reg-hiby,rs6). Group 2690 holds the
# KXTJ2 accelerometer: SSC I2C bus 3, address 0x0e, polled. docs/sensors.md (docs branch)
debugfs -R "dump /sensors/sns.reg $T/sensors/sns.reg" "$W/persist.bin" 2>/dev/null
[ "$(stat -c %s "$T/sensors/sns.reg")" -gt $((0x6200)) ]
src sensors/sns.reg "persist /sensors/sns.reg (written by stock sensors.qti)" "$DUMPVER (dump; no OTA touches persist)"

# hm100 FPGA bitstreams + default FIR table, out of the stock kernel by symbol
python3 -I - "$W/boot_b.bin" "$W/Image" <<'EOF'
import struct, sys, zlib
d = open(sys.argv[1], "rb").read()
ks = struct.unpack_from("<I", d, 8)[0]
ps = struct.unpack_from("<I", d, 36)[0]
open(sys.argv[2], "wb").write(zlib.decompressobj(16 + 15).decompress(d[ps:ps + ks]))
EOF
kallsyms-finder "$W/Image" > "$W/kallsyms.txt" 2>/dev/null
python3 -I "$HERE/extract-hm100-blobs.py" "$W/Image" "$W/kallsyms.txt" "$W/blobs" >/dev/null
cp "$W/blobs/FS_data.bin" "$T/hiby/hm100-pcm.bin"
cp "$W/blobs/FS_dsd_data.bin" "$T/hiby/hm100-dsd.bin"
cp "$W/blobs/hm100_fir_coef_default.bin" "$T/hiby/hm100-fir-default.bin"
KVER=$(grep -a -o -m1 'Linux version .*' "$W/Image" | sed -E 's/ \(.*\) #/ #/')
src hiby/hm100-pcm.bin "boot_b kernel symbols FS_data + FS_chksum ($KVER)" "$OVER"
src hiby/hm100-dsd.bin "boot_b kernel symbols FS_dsd_data + FS_dsd_chksum ($KVER)" "$OVER"
src hiby/hm100-fir-default.bin "boot_b kernel symbol hm100_fir_coef_default ($KVER)" "$OVER"
# stock 2.10 on also carries the bitstreams for GW1N-9C units (IDCODE 0x1100481b)
for k in pcm:FS_gw1n9c_data dsd:FS_gw1n9c_dsd_data; do
	[ -f "$W/blobs/${k#*:}.bin" ] || continue
	cp "$W/blobs/${k#*:}.bin" "$T/hiby/hm100-${k%%:*}-gw1n9c.bin"
	src "hiby/hm100-${k%%:*}-gw1n9c.bin" "boot_b kernel symbols ${k#*:} + checksum ($KVER)" "$OVER"
done

# Darwin filters, as stock Settings shows them: Settings.apk assets/filter.json (order and
# titles, kept as is) plus the .flt files it lists (docs/darwin-filters.md on the docs branch)
debugfs -R "dump /system/priv-app/Settings/Settings.apk $W/Settings.apk" "$W/system_b.bin" 2>/dev/null
rm -f "$W/system_b.bin"
python3 -I - "$W/Settings.apk" "$T/darwin" <<'PY'
import json, os, sys, zipfile
apk, out = sys.argv[1:3]
with zipfile.ZipFile(apk) as z:
    meta = z.read("assets/filter.json")
    open(os.path.join(out, "filter.json"), "wb").write(meta)
    for e in json.loads(meta)["list"]:
        f = os.path.basename(e["path"])
        data = z.read("assets/" + f)
        assert len(data) == 1024, f
        open(os.path.join(out, f), "wb").write(data)
PY
srcdir darwin "system_b /system/priv-app/Settings/Settings.apk assets/" "$OVER"

(cd "$T" && find . -type f | sort | xargs sha256sum) > "$W/SHA256SUMS"
# MANIFEST.tsv: file, sha256, source partition, stock version
{
	printf 'file\tsha256\tsource\tstock version\n'
	while IFS=$'\t' read -r f s v; do
		printf '%s\t%s\t%s\t%s\n' "$f" "$(sha256sum "$T/$f" | cut -d' ' -f1)" "$s" "$v"
	done < <(sort "$SRC")
} > "$W/MANIFEST.tsv"
mv "$W/SHA256SUMS" "$T/SHA256SUMS"
mv "$W/MANIFEST.tsv" "$T/MANIFEST.tsv"
# every shipped file has exactly one manifest line
[ "$(wc -l < "$T/SHA256SUMS")" -eq "$(($(wc -l < "$T/MANIFEST.tsv") - 1))" ] || {
	echo "MANIFEST.tsv does not cover every file" >&2
	exit 1
}
mkdir -p "$OUTDIR"
tar -C "$W" --sort=name --mtime=@0 --owner=0 --group=0 -czf "$OUTDIR/firmware-hiby-rs6.tar.gz" firmware-hiby-rs6
echo "wrote $OUTDIR/firmware-hiby-rs6.tar.gz ($VER)"
tar -tzf "$OUTDIR/firmware-hiby-rs6.tar.gz"
