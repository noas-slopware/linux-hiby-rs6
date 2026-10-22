# userspace

Distribution-neutral sources and configuration for the RS6. The `pmos` branch packages them as
`device-hiby-rs6`, `rs6-dac-plasma` and `rs6-spdif`; paths below are where that package installs them.

| dir | files | installed as |
|---|---|---|
| `audio/` | `ucm-card.conf`, `ucm-HiFi.conf` | `/usr/share/alsa/ucm2/conf.d/sdm660/HiBy RS6.conf`, `/usr/share/alsa/ucm2/HiBy/RS6/HiFi.conf` |
| | `pipewire-rs6.conf`, `pipewire-pulse-rs6.conf`, `wireplumber-rs6.conf` | `50-hiby-rs6.conf` in the matching `*.conf.d` |
| | `wireplumber-exclusive-takeover.lua` | `/usr/share/wireplumber/scripts/hiby-rs6/exclusive-takeover.lua` (the music player's exclusive stream takes the DAC over) |
| | `wireplumber-output-handover.lua` | `/usr/share/wireplumber/scripts/hiby-rs6/output-handover.lua` (frees the card PCM for the other output as soon as a jack is plugged or unplugged) |
| | `plasmaparc` | `/etc/xdg/plasmaparc` (one wheel detent = 1 % = one NJW1195A step) |
| `darwinctl/` | `darwinctl.c` (needs alsa-lib), `darwinctl-restore.service`, `darwinctl.tmpfiles` | DAC filter control from the command line; filters come from the `firmware` branch (`darwin/`) |
| `firefox/` | `firefox-v4l2-fix.c` (LD_PRELOAD shim), `firefox-hiby-rs6` (wrapper), `.desktop`, `.js` (prefs), `-env.conf`, `-plasma-env.sh` | Venus V4L2 hardware decoding in Firefox |
| `system/` | udev rules, tmpfiles, logind and shutdown drop-ins, `nura-swap.service`, `kernel-cmdline.conf`, `modules-initfs`, `99-flashlight.rules` | see `pmos` branch `device-hiby-rs6/APKBUILD` |
| | `kwinrc` | `/etc/xdg/kwinrc` (desktop-only KWin effects off) |
| `spdif/` | meson project: `pcm_rs6_spdif.c` (ALSA PCM plugin `rs6_spdif`, IEC 60958 biphase-mark encoder for the coax output), `ctl_rs6_jack.c` (ALSA control plugin `rs6_jack`: "SPDIF Jack" and "DAC Jack" from the kernel's Output Target), `50-rs6-spdif.conf`, tests | packaged as `rs6-spdif`; see `docs/audio.md` on the `docs` branch |
| `touchboost/` | `rs6-touchboost.c`, `.service` | touch-triggered CPU/GPU boost daemon |
| `vt-lock/` | `rs6-vt-lock.c`, `.service` | locks VT switching once the session is up |
| `rs6-dac-plasma/` | CMake project | Plasma System Settings page, DAC quick setting and a rotate quick setting (KDE Frameworks 6) |

`rs6-dac-plasma` is laid out as CMake expects (`ui/main.qml`, `quicksetting/`, `rotate/`). The pmos package
keeps the same files flat and lays them out in `prepare()`.
