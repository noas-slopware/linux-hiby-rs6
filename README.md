# linux-hiby-rs6

Mainline-based Linux and U-Boot for the HiBy RS6 digital audio player, with the userspace
pieces, install tools and notes needed to run Nura on it. The port was done by Noa
Himesaka. It is not affiliated with HiBy.

## The device

The HiBy RS6 is an Android 9 DAP built on the Qualcomm SDM660 (PM660 + PM660L), with 4 GB RAM,
64 GB eMMC and a microSD slot. It has a 5" 1080x1920 Sharp LS050T1SX18 DSI panel, a Goodix GT1x
touchscreen, a CW2015 battery gauge, an LP5562 LED driver, a WCN3990 Wi-Fi/Bluetooth chip and a
volume wheel. The DAC is not a codec chip: it is a Gowin GW1N-9 FPGA ("hm100", HiBy's "Darwin"
R2R DAC) that is loaded over bit-banged JTAG and controlled over a shared bit-banged SPI, fed
over the SoC's secondary MI2S port, plus an NJW1195A volume IC. Outputs: single-ended (PO), line
(LO), balanced (BAL, BAL-LO).

The stock boot chain (XBL, ABL) is not unlocked, but it will boot an Android boot image from
`boot_a`. U-Boot is chainloaded from there; U-Boot then boots the Nura image with
extlinux from the eMMC.

## What works

As of 2026-10-22, on the author's unit, running the r29 build of exactly the published kernel series. "Verified" means seen working on the device.

- Boot: stock ABL -> U-Boot (in `boot_a`) -> extlinux -> Linux. Verified. U-Boot has an
  off-mode charging screen with battery digits (verified), and USB Mass Storage for flashing.
  The boot uses Nura's own splash; the screen blanks once when msm takes over from simpledrm.
- Display, backlight (PWM on the PM660L LPG), touchscreen, GPU (Adreno 512 with freedreno, a soak
  test of 60 kmscube cycles ran clean). Verified. Mesa carries six a5xx patches (`patches/mesa/`) for the
  Adreno 512's rendering artifacts and Qt text. The firmware set ships the Qualcomm PFP 0x5ff11a (from
  Xiaomi tulip) so that mainline runs 4 GPU rings with preemption; that the 4 rings come up on the unit
  is not recorded yet (`docs/gpu-a5xx.md`).
- Audio through the FPGA DAC: PCM at 44.1 and 48 kHz on the PO, BAL and LO outputs, verified by
  ear. The root cause of the long audio debugging was the FPGA's initial clock-family word
  (`0x0120` for the 44.1 kHz family, stock always initialises with it). Native DSD64, DSD128 and
  DSD256 verified by ear. The hm100 driver follows the headphone jacks and loads the stock
  bitstreams, FIR tables and Darwin filters from the `firmware` branch.
- Coaxial S/PDIF (USB-C coax): with nothing plugged in the driver selects the stock Spdif target, and the
  `rs6-spdif` ALSA plugin encodes IEC 60958 biphase-mark cells in software. Implemented; not verified on the
  unit (`docs/audio.md`).
- Suspend: s2idle reaches VDD min. Verified with one 60 s `rtcwake -m freeze` (RPM vmin count 0 -> 4, the
  whole sleep), and 300 s sleeps ran uninterrupted with no ADSP wake storm and no hardlockup reports
  (`docs/suspend.md`).
- Volume wheel, jack detection, USB networking (Nura default 172.16.42.1), Wi-Fi
  (WCN3990/ath10k with HiBy's stock WLAN.HL.1.0.1.c2-00708 firmware;
  connected-scan timing: RTT maximum during scans fell from 898 to 220 ms; `docs/wifi.md`).
- Bluetooth discovers other devices (a `Frame reassembly failed (-84)` error is still logged at boot).
- Plasma Mobile with PipeWire as the audio server; Elisa with a Subsonic source and a bit-perfect
  output mode; Firefox with hardware video decoding through the Venus V4L2 decoder (via an
  LD_PRELOAD shim, `userspace/firefox/`) and mobile-config-firefox patched to look like Firefox for
  Android on the narrow window.
- CPU frequency/voltage scaling (CPRh + OSM port for SDM630/SDM660), cluster idle and system
  idle through the MPM, CPU BWMON with stock's DDR floor per CPU frequency are in the kernel series. Whether
  each part was verified on the unit is not recorded in these notes.
- Accelerometer (auto-rotate) through the ADSP's SMGR: wired up (sensor registry in the
  `firmware` branch, `qcom_smgr` fixes in the series), checklist of what is still to be checked is in
  `docs/hardware.md` (section 13) on the `docs` branch.

Known problems: the WLAN firmware holds TX frames for a beacon interval about every 1.3 s (unexplained).

A flicker-free boot (silent U-Boot, display takeover from ABL, a Plymouth theme on the stock splash) was
tried and dropped; none of it is in these branches.

## Branches

| branch | contents |
|---|---|
| `main` | this README, `patches/`, `userspace/`, `tools/`, `LICENSES/` |
| `docs` | install guide, hardware and reverse-engineering notes, RE tooling (`docs/re-tools/`) |
| `firmware` | HiBy's stock firmware 2.10 file set (subset) plus the Xiaomi tulip a530 PFP, for the firmware package |
| `pmos` | Nura packages (`device/testing/*`, `main/boot-deploy`) for pmaports |

The branches are independent histories. Check them out side by side with `git worktree`.

### `main`

- `patches/linux/`: 94-patch kernel series on sdm660-mainline `qcom-sdm660-7.2.y`
  (`34c0be5727a86528f82a0242f70e2273cdb2df37`, Linux 7.2.3).
- `patches/u-boot/`: 6-patch U-Boot series on sdm660-mainline `release/v2026.10-sdm660`
  (`608a227567373f0274617e8829398fb0c1f1c1a5`).
- `patches/<package>/`: patches for Mesa, Elisa, KIconThemes, mobile-config-firefox, Plasma
  Mobile, Plasma Keyboard, Qt 6 base and usb-moded-notify.
- `userspace/`: distribution-neutral sources and config: `audio/` (UCM, PipeWire, WirePlumber
  exclusive mode and output handover), `darwinctl/` (DAC filter control), `firefox/` (V4L2 shim, wrapper,
  prefs), `spdif/` (S/PDIF encoder and jack ALSA plugins), `system/` (udev, tmpfiles, logind, cmdline, swap,
  KWin), `touchboost/`, `vt-lock/`, `rs6-dac-plasma/` (Plasma KCM and quick settings).
- `tools/`: install-path tools: `fetch-hiby-firmware.py`, `payload-extract.py`, `ota-patch/`,
  `make-firmware-tarball.sh`, `extract-hm100-blobs.py`, `repartition-nura.sh`,
  `repartition-nura-ums.sh`, `flash-nura-ums.sh`, `edl-check.sh`, `abslot.py`, `lib/nura-gpt.sh`.

## Building

Nura is built from the `pmos` branch with pmbootstrap: copy `device/testing/*` and `main/boot-deploy`
into your pmaports checkout, select the device `hiby-rs6`, build `linux-postmarketos-qcom-sdm660`,
`firmware-hiby-rs6`, `rs6-spdif` and `device-hiby-rs6`, and run `pmbootstrap install`. Details are in the README
of the `pmos` branch. U-Boot is built from `patches/u-boot` as described in its README. The
kernel package applies `patches/linux` to a pinned sdm660-mainline commit.

## Installing

See `docs/install.md` on the `docs` branch. In short: back up the eMMC over EDL, write U-Boot to
`boot_a`, activate slot A, then `tools/repartition-nura.sh` repartitions the eMMC and writes the
Nura boot and root images. **This removes stock Android; recovery is EDL with HiBy's burn
package or your own backup.** You need the firehose programmer from HiBy's 1.50 burn package,
which is not in this repository.

## Firmware

The `firmware` branch holds the stock HiBy RS6 2.10 firmware subset the port needs (modem,
DSP, Venus, GPU zap shader and CP microcode, Wi-Fi board data, Bluetooth patches, FPGA bitstreams,
Darwin filters, sensor registry; the WLAN firmware is HiBy's own c2-00708), plus the Qualcomm a530 PFP
0x5ff11a from Xiaomi tulip. The HiBy part is regenerated with
`tools/make-firmware-tarball.sh` from a stock 1.80 EDL dump plus HiBy's own 1.80 -> 1.90 -> 2.10 OTA
deltas, which `tools/fetch-hiby-firmware.py` downloads from HiBy's update server (`--follow`); the Xiaomi
PFP is added on top (see the branch README).

## Authors and credits

- Noa Himesaka: the port, the RS6 device tree, hm100/DAC, panel, volume wheel, MPM/idle, SDM660
  CPRh/OSM data, U-Boot work, userspace, tools.
- AngeloGioacchino Del Regno and Giuseppe Maggio: the CPR3/CPRh and OSM-aware cpufreq-hw code
  (kernel patches 0001-0014, authors kept).
- Ulf Hansson (cpuidle psci probe deferral), Fabricio Akio (a5xx GPU reset on resume, ath10k TxBF,
  BLSP interconnect paths, SDM660 NoC keep_alive/sync_state, video core clock, Mesa A5xx fixes),
  Dmitry Baryshkov (a5xx GPMU registers), Richard Acayan (smp2p sleepstate binding), Arpit Saini (DSI AHB
  clock across suspend), Konrad Dybcio (icc-rpm negative QoS offset): patches carried with their original
  authorship.
- Alexey Minnekhanov and Dang Huynh: the lavender device tree the RS6 tree is based on.
- Konrad Dybcio: the CPR3 binding properties the SDM660 bindings follow.
- Stephan Gerhold: linux-mdss-dsi-panel-driver-generator, which produced the panel driver.
- The sdm660-mainline project (https://github.com/sdm660-mainline), the Nura project, and
  bkerler's `edl`.

## License

By directory (details in `LICENSES/README.md`):

- `patches/linux`, `patches/u-boot`: GPL-2.0-only.
- `patches/<other>`: the license of the patched project, stated in each directory's README.
- `userspace` C sources, `spdif/` and the `rs6-dac-plasma` code: MIT (SPDX headers in the files). Config,
  unit and rule files in `userspace/`, `tools/` and the docs carry no license header yet.
- `firmware` branch: HiBy's, Qualcomm's and Xiaomi's firmware files.
