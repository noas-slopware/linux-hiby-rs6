# pmos

Nura packages for the HiBy RS6: pmaports `device/testing/` plus a patched `main/boot-deploy`.

| package | version | what |
|---|---|---|
| `device-hiby-rs6` | 1-r25 | device package: deviceinfo, kernel cmdline, UCM, PipeWire/WirePlumber config and scripts, udev rules, KWin effects config, `darwinctl`, touch boost, VT lock, Firefox V4L2 shim (subpackages `-systemd`, `-firefox`, `-audio`: PipeWire as the audio backend, `-repo`: this repository and its signing key; recommends Elisa and Dolphin) |
| `firmware-hiby-rs6` | 2.10-r6 | stock firmware 2.10 set (HiBy's own WLAN firmware c2-00708) plus the Xiaomi tulip a530 PFP 0x5ff11a; the source is a GitHub archive of the `firmware` branch |
| `linux-postmarketos-qcom-sdm660` | 7.2.3-r29 | sdm660-mainline `qcom-sdm660-7.2.y` at a pinned commit plus the 94-patch series (same files as `patches/linux` on `main`) and the kernel config |
| `rs6-dac-plasma` | 1.0-r4 | Plasma System Settings page and quick settings for the DAC and screen rotation |
| `rs6-spdif` | 1.0-r0 | coaxial S/PDIF output: ALSA PCM plugin `rs6_spdif` (IEC 60958 encoder) and control plugin `rs6_jack` |
| `mesa` | 26.2.5-r3 | Alpine's Mesa with the freedreno A5xx patches 0101-0106 |
| `elisa` | 26.08.2-r6 | Subsonic source, bit-perfect output, mobile and cover fixes |
| `kiconthemes` | 6.31.0-r1 | KQuickIconProvider size fix |
| `mobile-config-firefox` | 5.5.0-r5 | popup fit and measurement, Firefox for Android (Fenix) look on narrow windows |
| `plasma-keyboard` | 6.8.1-r1 | Korean preedit composition, content-type changes |
| `plasma-mobile` | 6.8.1-r2 | brightness slider watcher, overlays release graphics while hidden |
| `qt6-qtbase` | 6.11.1-r4 | QThreadData/QBindingStatus fix on thread exit (musl) |
| `usb-moded-notify` | 0.4.2-r2 | retry instead of crashing when the notification server fails |
| `main/boot-deploy` | 0.25.0-r1 | extra extlinux entries from `extlinux.d` survive every run (e.g. a known-good kernel to fall back to) |

The RS6 patches inside the upstream packages are also in `patches/<name>/` on `main`; `userspace/` on `main` is
the upstream of the files inside `device-hiby-rs6`, `rs6-dac-plasma` and `rs6-spdif`, kept as plain copies here
so the packages build alone.

The forks follow the pmaports and Alpine aports versions they were built against (the aports in use must have at least
Mesa 26.2.5, Qt 6.11.1, Plasma 6.8.1, KDE Frameworks 6.31.0, Elisa 26.08.2). Where a package already exists in
pmaports or aports, the version here replaces it; keep the whole directory.

## Using it with pmbootstrap

```
git clone https://gitlab.postmarketos.org/postmarketOS/pmaports.git     # or your checkout
cp -r device/testing/* pmaports/device/testing/                          # from this branch
cp -r main/boot-deploy pmaports/main/
pmbootstrap init                                                        # device: hiby-rs6, ui: plasma-mobile
pmbootstrap build linux-postmarketos-qcom-sdm660 firmware-hiby-rs6 rs6-spdif device-hiby-rs6 rs6-dac-plasma
pmbootstrap -y install --split --no-sparse --filesystem ext4 --password <your password>
```

PipeWire is the device's default audio backend (`_pmb_default` in `device-hiby-rs6`, which `pmbootstrap init`
offers and `pmbootstrap install` uses), and `device-hiby-rs6-audio` keeps PulseAudio out, so no `[providers]`
entry is needed any more.
`device-hiby-rs6-repo` adds this repository (GitHub Pages and YuruMirror) to
`/usr/lib/apk/repositories.d/` and its key to `/etc/apk/keys/` and `/usr/lib/apk/keys/`, so an installed RS6 keeps getting
these packages with `apk upgrade`.

The packages that patch upstream projects (`mesa`, `qt6-qtbase`, `kiconthemes`, `elisa`, `plasma-mobile`,
`plasma-keyboard`, `mobile-config-firefox`, `usb-moded-notify`, `boot-deploy`) are built the same way; build them
before `pmbootstrap install` or it uses the stock packages. Mesa for aarch64 was cross-built with
`pmb:cross-native2`. The split images (`hiby-rs6-boot.img`, `hiby-rs6-root.img`) land in the native chroot's
`home/pmos/rootfs/`. Flashing is described in `docs/install.md` on the `docs` branch.
