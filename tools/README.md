# tools

Install-path tools. The RE tooling (trace decoder, capture scripts, ABL/XBL GPT models, the offline
repartition test) is on the `docs` branch in `docs/re-tools/`.

- `fetch-hiby-firmware.py`: asks HiBy's FOTA backend (ABUP) which firmware it offers an RS6 and downloads the
  OTA deltas. First run needs `--dump <1.80 EDL zip>` or `--apk Abupdate.apk` to read the product id/secret
  from your own firmware. The registration cache is `~/.cache/hiby-rs6-fota/device.json`; do not share it.
  Uses a random serial unless you pass `--serial`.
- `payload-extract.py`, `ota-patch/`: apply Android A/B delta OTAs offline, with AOSP's bspatch and puffpatch
  (built by `ota-patch/build.sh`).
- `make-firmware-tarball.sh`: builds the firmware set (see the `firmware` branch) from a 1.80 EDL zip and the OTAs.
- `extract-hm100-blobs.py`: cuts the FPGA bitstreams and FIR table out of the stock kernel.
- `edl-check.sh`: read-only EDL check (loader hash, GPT, slot flags).
- `repartition-nura.sh`, `repartition-nura-ums.sh`, `lib/nura-gpt.sh`: repartition the eMMC for Nura and write
  the images, over EDL or over U-Boot USB Mass Storage.
- `flash-nura-ums.sh`: write new boot/root images over U-Boot USB Mass Storage, partition table untouched.
- `abslot.py`: show or switch the A/B slot flags on a raw eMMC (e.g. the U-Boot USB Mass Storage block device),
  the way `edl setactiveslot` does on this unit, without EDL.

Needs `RS6_LOADER` (HiBy's firehose programmer) for the EDL scripts, and bkerler's `edl` on PATH (or `EDL=`).
