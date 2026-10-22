# firmware

The firmware files the HiBy RS6 Nura port needs: HiBy's stock firmware **2.10**
(`2.10_20250826-1521`) plus a newer Qualcomm GPU microcode file taken from Xiaomi SDM660 firmware. The
`firmware-hiby-rs6` package (`pmos` branch) fetches them from a GitHub archive of this branch.

TrustZone applications, the WCD CPE images, the modem's `qdsp6m.qdb` and `data.msc` are not included:
nothing on Linux loads them.

## Contents

| path | what | source |
|---|---|---|
| `image/` | NON-HLOS images: modem, ADSP, CDSP, Venus (video), MBA, `wlanmdsp.mbn` (WCN3990 WLAN firmware WLAN.HL.1.0.1.c2-00708, installed as is), their `.mdt`/`.bNN` split files and `.jsn` configs | stock `modem_b` partition, `image/` |
| `wlan/` | WCN3990 board data files `bdwlan.<board id>` | stock `modem_b` partition, `image/` |
| `bt/` | WCN3990 Bluetooth firmware and NVM (`apbtfw*`, `apnv*`, `crbtfw*`, `crnv*`) | stock `bluetooth_b` partition, `image/` |
| `gpu/a512_zap.mbn` | the Adreno 512 zap shader | stock `vendor_b` `/firmware/a512_zap.elf` |
| `gpu/a530_pm4.fw`, `gpu/a530_pfp.fw` | the CP microcode the stock driver loads for the A512 (PM4 0x5ff066, PFP 0x5ff112; newer than linux-firmware's 0x5ff063 / 0x5ff08a) | stock `vendor_b` `/firmware/` |
| `gpu/a530_pfp-0x5ff11a.fw` | Qualcomm PFP 0x5ff11a: stock 0x5ff112's code plus the CP_WHERE_AM_I/YIELD write-back, so mainline msm runs 4 rings with preemption; the package installs it as `a530_pfp.fw`, paired with the stock PM4 | Xiaomi tulip (SDM660) vendor firmware, `qcom/a530_pfp.fw` as packaged by Nura `vendor-xiaomi-tulip` |
| `hiby/` | hm100 FPGA bitstreams (PCM and DSD, GW1N-9 and GW1N-9C variants, data plus 8-byte checksum) and the default FIR table | stock 2.10 kernel symbols (`FS_data`, `FS_dsd_data`, `FS_gw1n9c_*`, `hm100_fir_coef_default`) |
| `darwin/` | the 11 Darwin FIR filters (`.flt`, 1024 bytes) and `filter.json` as stock Settings lists them | stock `Settings.apk` `assets/` |
| `sensors/` | `sns.reg`, the sensor registry the ADSP's Sensor Manager asks for | stock `persist` `/sensors/sns.reg` |
| `MANIFEST.tsv` | every file with its sha256, source and version | |
| `SHA256SUMS` | sha256 of every file (`sha256sum -c SHA256SUMS`) | |

`docs/gpu-a5xx.md` on the `docs` branch says why the Xiaomi PFP is used.

## Provenance

The HiBy files are built by `tools/make-firmware-tarball.sh` (on the `main` branch) from a 1.80 EDL dump
plus HiBy's own OTA deltas 1.80 -> 1.90 -> 2.10, fetched with `tools/fetch-hiby-firmware.py fetch --follow`.
Each OTA is applied with AOSP's own bspatch/puffpatch; every input image is checked against the OTA's
`old_partition_info` hash and every output against `new_partition_info`. The boot, system and vendor files
(`gpu/` stock files, `hiby/`, `darwin/`) therefore come from 2.10. The modem, Bluetooth and persist partitions
are never touched by the OTAs, so those files are the dump's (1.80) and equal 2.10's. `MANIFEST.tsv` records
this per file.

The only file taken from `persist` is `sensors/sns.reg`, the registry the stock sensor service wrote on a
running unit (it holds the sensor configuration, mostly zeros).

The Xiaomi file is added by hand on top of the script's output, with its own row in `MANIFEST.tsv` and
`SHA256SUMS`:

| file | sha256 |
|---|---|
| `gpu/a530_pfp-0x5ff11a.fw` | `2a51c25b1f7299cb84c3685d3d1fb88bf0504494456345b2dfde32816e13bc8e` |

## Regenerating

```
tools/fetch-hiby-firmware.py fetch --dump "HiBy RS6 1.80.zip" --follow -o ota/
tools/make-firmware-tarball.sh --ota ota/rs6-ota-1.80_20231018-1816-to-1.90_20240819-2000.zip \
    --ota ota/rs6-ota-1.90_20240819-2000-to-2.10_20250826-1521.zip "HiBy RS6 1.80.zip" out/
tar -xzf out/firmware-hiby-rs6.tar.gz -C out/    # then commit out/firmware-hiby-rs6/* to this branch's root
```

then copy the Xiaomi file in and add its row:

```
cd out/firmware-hiby-rs6
cp <tulip a530_pfp.fw> gpu/a530_pfp-0x5ff11a.fw
(find . -type f ! -name SHA256SUMS ! -name MANIFEST.tsv ! -name README.md | sort | xargs sha256sum) > ../SHA256SUMS
mv ../SHA256SUMS SHA256SUMS
# MANIFEST.tsv: one row (file, sha256, source, version) as on this branch, then sort the rows
```

The script output for the HiBy files matches this branch byte for byte (checked 2026-10-22 against the 1.80
dump and both OTAs). Needs `unzip`, `7z`, `mtools`, `debugfs`, `python3`, `kallsyms-finder`
(vmlinux-to-elf) and the build dependencies of `tools/ota-patch/build.sh`. Use your own 1.80 EDL dump.
