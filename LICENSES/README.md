# Licenses

| path | license | notes |
|---|---|---|
| `patches/linux/` | GPL-2.0-only | Linux. Text in `GPL-2.0-only.txt`. Each patch carries SPDX headers on new files. |
| `patches/u-boot/` | GPL-2.0-only (new files), U-Boot itself is GPL-2.0-or-later | `extra/sdm660-hiby.sh` is a copy of the mkbootimg parameters file in the style of upstream's `.ci/bootimg_params/*.sh` (no header). |
| `patches/<other>/` | the license of the project each patch applies to | see the README in each directory |
| `userspace/darwinctl/darwinctl.c`, `userspace/firefox/firefox-v4l2-fix.c`, `userspace/touchboost/rs6-touchboost.c`, `userspace/vt-lock/rs6-vt-lock.c` | MIT | SPDX header in the file. Text in `MIT.txt`. |
| `userspace/rs6-dac-plasma/` | MIT | SPDX header in the C++, QML and CMake files. The three `*.json` metadata files name MIT in their `KPlugin` block where they have one. |
| `userspace/spdif/` | MIT | SPDX header in the C sources, headers and Python test helpers; `meson.build`, `meson_options.txt`, `50-rs6-spdif.conf` and `test-alsa.conf.in` have none (the `rs6-spdif` package on the `pmos` branch says MIT). |
| `userspace/` other files (units, udev rules, tmpfiles, UCM, PipeWire/WirePlumber configs and scripts, `kwinrc`, Firefox wrapper/desktop/prefs, kernel cmdline, initfs modules) | not stated | no header in these files; the `device-hiby-rs6` package metadata on the `pmos` branch says MIT. |
| `tools/` | not stated | no SPDX header in these files. `tools/ota-patch/` builds AOSP's bsdiff and puffin at build time; their code is downloaded, not included, and stays under its own licenses (see the two AOSP repositories pinned in `build.sh`). |
| `docs` branch | not stated | no license header in the documents or in `docs/re-tools/`. |
| `pmos` branch | per package | each `APKBUILD` has its own `license=` line; the `boot-deploy` patch is under that project's GPL-2.0-or-later. |
| `firmware` branch | vendor files | HiBy's, Qualcomm's and Xiaomi's firmware files, see the README on that branch. |
