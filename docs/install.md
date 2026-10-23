# Installing Nura on the HiBy RS6 (whole-eMMC layout)

This is the current flow. It replaces the stock Android system with a Nura image
(called Nura here) that owns the whole user area of the eMMC, and puts U-Boot into `boot_a`.

**There is no stock Android left afterwards and no stock slot to go back to.** Recovery is EDL
with HiBy's burn package or with your own full dump. Make that dump first.

Never write: devinfo, frp, keystore, persist, modemst1/2, fsg, sec, ssd, or the
xbl/tz/rpm/hyp/abl chain. Nothing below does.

Paths in this guide: `tools/` is on the `senpai` branch, `patches/` too; `docs/re-tools/` is on this
(`docs`) branch; the device package is on the `pmos` branch; the stock firmware set is on the
`firmware` branch.

## 0. What you need

- A Linux host with: [bkerler/edl](https://github.com/bkerler/edl) (`edl` on PATH; install from a
  shallow clone, the git URL drags in the multi-GB Loaders submodule), `adb`, `sgdisk` (`gptfdisk` on
  Arch, `gdisk` on Debian), `mkswap`, `blkid`, `python3`, polkit (the scripts use `pkexec` through
  `systemd-run --user`), and a writable tmpfs `/dev/shm`.
- The Qualcomm firehose programmer `prog_emmc_ufs_firehose_Sdm660_ddr.elf` from HiBy's official
  1.50 burn package (sha256 `0ac4d153e0b9fae638ebe74ba9fc7b4f46b7baa959b0e24c65e676876d941d5f`).
  It is not in this repository. Point `RS6_LOADER` at it.
- For U-Boot: an aarch64 cross compiler (`aarch64-linux-gnu-`), `mkbootimg`, `xxd`, `gzip`, `make`,
  a C toolchain for the host tools.
- For the image: [pmbootstrap](https://wiki.nura.eco/wiki/Pmbootstrap) 3.x and the `pmos`
  branch of this repository.
- A USB cable and a way into EDL (05c6:9008). From a running stock system: `adb reboot edl`. The
  scripts try that themselves and otherwise ask you to enter EDL by hand and rerun.

## 1. Back up, then check EDL

1. Full read of everything, kept somewhere safe (this is also the input for the `firmware` branch
   if you regenerate it, see `tools/make-firmware-tarball.sh`):
   `edl rl backup/ --loader=$RS6_LOADER --memory=emmc`
2. `RS6_LOADER=... tools/edl-check.sh` (read only: records the loader hash, the GPT and the slot
   flags into `./edl-check-<date>/`).

If anything goes wrong later, the restore path is HiBy's burn package (`rawprogram_unsparse.xml` +
`patch0.xml`) or your backup, written back over EDL.

## 2. Build U-Boot

U-Boot is sdm660-mainline's `release/v2026.10-sdm660` plus the series in `patches/u-boot/`. The
base commit is in `patches/u-boot/README.md`. The boot image parameters for the RS6 are in
`patches/u-boot/extra/sdm660-hiby.sh` (not part of the git series, because upstream's `.gitignore`
hides `.ci/bootimg_params`).

```
git clone -b release/v2026.10-sdm660 https://github.com/sdm660-mainline/u-boot
cd u-boot && git checkout 608a227567373f0274617e8829398fb0c1f1c1a5
git am /path/to/linux-hiby-rs6/patches/u-boot/0*.patch
cp /path/to/linux-hiby-rs6/patches/u-boot/extra/sdm660-hiby.sh .ci/bootimg_params/
make CROSS_COMPILE=aarch64-linux-gnu- O=.output qcom_defconfig qcom-sdm660-phone.config \
     qcom-downstream.config hiby-rs6.config
make CROSS_COMPILE=aarch64-linux-gnu- O=.output -j"$(nproc)"
cp .ci/*.sh .output/ && cp -r .ci/bootimg_params .output/ && cd .output && ./bootimg-all.sh
```

The result is `.output/boot-uboot-sdm660-hiby-rs6.img` (boot image header v1, the RS6 DTB appended,
the load addresses of the stock `boot_a`). U-Boot's boot image carries the cmdline `uboot2nd`; the
stock ABL builds `root=` from the `system_<slot>` entry regardless (see `docs/boot-and-partitions.md`).

## 3. Build the image

On the `pmos` branch: copy `device/testing/*` and `main/boot-deploy` into your pmaports checkout (see the
README of that branch), then, in `pmbootstrap init`, pick device `hiby-rs6`. A working `pmbootstrap.cfg` has
`ui = plasma-mobile` and, under `[providers]`, the FULL package name
`postmarketos-base-ui-audio-backend = postmarketos-base-ui-audio-backend-pipewire` (the short
`pipewire` is silently ignored and you get PulseAudio).

```
pmbootstrap build linux-postmarketos-qcom-sdm660 firmware-hiby-rs6 rs6-spdif device-hiby-rs6 rs6-dac-plasma
pmbootstrap -y install --split --no-sparse --filesystem ext4 --password <your password>
```

The two images (`hiby-rs6-boot.img`, `hiby-rs6-root.img`) land in the native chroot's
`home/pmos/rootfs/`. The firmware package fetches its blobs from the `firmware` branch of this
repository, no partition of the stock system is read at boot.

## 4. Flash (EDL, once)

Put the RS6 into EDL (`adb reboot edl` from stock) and, from the root of a checkout of `senpai`:

```
export RS6_LOADER=/path/to/prog_emmc_ufs_firehose_Sdm660_ddr.elf
edl w boot_a boot-uboot-sdm660-hiby-rs6.img --loader=$RS6_LOADER
edl setactiveslot a --loader=$RS6_LOADER
tools/repartition-nura.sh hiby-rs6-boot.img hiby-rs6-root.img 8
```

`edl setactiveslot a` has to run on the still-stock table, so do it before the repartition.
`repartition-nura.sh` (last argument: swap in GiB, 8 = 2 x RAM) rewrites the table as described in
section 6, writes both images and swap signatures, clears `misc`, reads everything back and resets.
Its log and the original GPT go to `./repartition-<date>/`.

Expected first boot: U-Boot text console on the panel (simplefb), then extlinux on `nura_boot`
and the image. Volume up at power-on opens U-Boot's menu (there is no volume-down key except PON
resin).

USB networking comes up as the Nura default: `ssh <user>@172.16.42.1` with the user and
password you chose in `pmbootstrap install`.

## 5. Later updates

- New images without EDL: U-Boot menu (volume up) -> USB Mass Storage, then on the host
  `tools/flash-nura-ums.sh /dev/sdX hiby-rs6-boot.img hiby-rs6-root.img`. It only reads the
  partition table, checks names and holes on the live table, writes `nura_boot` and `nura_root`
  and reads both back.
- New U-Boot from Nura:
  `sudo dd if=boot-uboot-....img of=/dev/disk/by-partlabel/boot_a bs=4096 conv=fsync`, then read
  it back and compare. Keep the previous image around.
- To repartition from a state where the table is already the Nura one, the scripts refuse
  (they expect the stock layout). That is deliberate.
- To run the repartition without EDL (a unit whose U-Boot is already in `boot_a`, USB Mass
  Storage), use `tools/repartition-nura-ums.sh /dev/sdX <boot img> <root img> [swap GiB]`.
- Check the repartition scripts without a device: `docs/re-tools/test-repartition-nura.sh`
  (needs `gpt_main0.bin` from the 1.80 image and `NURA_TOOLS` pointing at `tools/`).

If the screen stays black or it bootloops: ABL does not fall back by itself. A slot marked
successful boots with no retry countdown, and an inactive slot never qualifies for fallback
(`docs/boot-and-partitions.md`, "Slot attributes"). Before the repartition you can go back to stock with
`edl setactiveslot b --loader=$RS6_LOADER`. After it, slot B points at the old stock kernel with
a 1 MiB dummy as its system partition and ABL never leaves it: only EDL gets the unit back.
`edl getactiveslot` fails on this unit (sector-size quirk); read the active slot from the
`edl printgpt` flags (stock showed 0x..77).

## 6. Final layout (whole user area for Nura)

`tools/repartition-nura.sh` (EDL) or `tools/repartition-nura-ums.sh` (U-Boot USB Mass Storage)
repurposes the stock Android entries (system_a/b, vendor_a/b, userdata, 5 slots), adds one entry,
and creates, in the two freed ranges:

| entry | range | size | use |
|---|---|---|---|
| nura_boot (#48) | 0x034000000 + 1 GiB | 1 GiB | pmOS_boot (extlinux, found by U-Boot in boot_a) |
| nura_swap1 (#49) | to 0x218000000 | 6.56 GiB | swap |
| nura_swap2 (#50) | 0x234000000 + (8 GiB - swap1) | 1.44 GiB | swap |
| system_a (#51) | sector 34 (before the first partition) | 1 MiB | dummy, only for ABL |
| nura_root (#67) | rest of the disk | ~48 GiB | pmOS_root (ext4 grows on first boot) |
| system_b (#68) | sector 17826048 (0x220020000, after storsec) | 1 MiB | dummy, only for ABL |

Swap = 2 x RAM (4 GiB), so 8 GiB. Every other entry keeps its sectors, name, type, UUID and
attributes (the script compares each one before writing).

The table has to satisfy the stock Qualcomm ABL, not just sgdisk (a table that only looked fine
to Linux dropped every boot into fastboot). The rules below are decompiled from the stock ABL;
addresses and evidence are in `docs/boot-and-partitions.md`:

- **system_a and system_b must exist.** ABL builds `root=/dev/mmcblk0pN` from the
  `system_<slot>` entry on every boot (U-Boot's boot.img cmdline has no `root=`) and fails
  the boot ("System partition does not exist") if it is gone. Nura never uses them, so they
  are 1 MiB dummies. Their type GUID must differ from `boot_<slot>`'s, or ABL rejects the slot
  ("does not have valid guids"); the dummies are 8300.
- **No holes.** XBL skips empty entries and hands ABL one handle per remaining entry, so a
  hole shifts every later handle; ABL numbers `mmcblk0pN` and writes slot attributes back
  by handle position, on every boot, so after a hole both point at the wrong entries
  (`docs/boot-and-partitions.md`). On the first attempt everything after a hole went missing (misc, keystore,
  devcfg, frp, vbmeta, nura_root), and bkerler edl stops at a hole too. Never
  `sgdisk -d` without refilling the slot. The stock table holds exactly 68 entries; the
  layout uses all 68, so there is no room for another entry.
- **Backup GPT at the end, where ABL expects it.** ABL rewrites LBA 1-33 and the last 33
  LBAs with fixed geometry (backup entries at TOTAL-33), so the scripts pin the backup array
  there (`sgdisk -k`) and check it.
- **misc must be clean.** U-Boot leaves `bootonce-bootloader` there after `fastboot
  reboot-bootloader`, so the scripts zero misc. ABL itself only acts on `boot-recovery`.

Both scripts share `tools/lib/nura-gpt.sh`: they edit a sparse image of the dumped GPT,
then check the NEW table (sgdisk -v clean, the required names present, no holes, every
Nura/dummy entry at the exact sectors, the ABL rules above, every untouched entry identical)
before writing anything. They dump the old GPT into the output directory first, write backup then
primary GPT, read both back, write swap signatures and both images, clear misc and read
nura_boot (and misc) back. `tools/flash-nura-ums.sh` re-checks names and holes on the
live table before it writes. `docs/re-tools/test-repartition-nura.sh` runs both scripts against
sparse images, no device needed, and puts each result through `docs/re-tools/abl-gpt-check.py`,
an offline model of the stock ABL, and `docs/re-tools/xbl-gpt-check.py`. Passing it is not
enough: only a reboot through ABL proves the table is accepted.

Firmware no longer comes from the partitions: `firmware-hiby-rs6` carries the stock slot B
NON-HLOS `image/` (mba, modem, adsp, cdsp, venus, wlanmdsp, ...), the bluetooth_b patches
(`qca/`), the Adreno zap shader, the hm100 bitstreams/FIR and the Darwin filters, so
msm-firmware-loader and `androidboot.slot_suffix` are gone. The modem/dsp/bluetooth partitions
stay untouched anyway.

## 7. The public image (instead of sections 2 and 3)

Image `20261023-0026`, built from pmos 38b93b8 and the published repository. Download it from the
[nura-2026.10.23 release](https://github.com/noas-slopware/linux-hiby-rs6/releases/tag/nura-2026.10.23).

The public image is built the way Nura builds its official images (bpo,
`build-package-orchestrator/bpo/jobs/build_image.py`): every `pmbootstrap init` default, Plasma Mobile,
systemd, no SSH daemon, the default user and password, and every package installed from the binary
repositories. Our packages come from the linux-hiby-rs6 repository (GitHub Pages and YuruMirror), and
the image keeps both configured, so `apk upgrade` (or Discover) updates the RS6 like any other Nura
device. On top of Plasma Mobile's own app selection, the device package recommends our Elisa (Subsonic
source, bit-perfect output) and Dolphin. Build recipe: `re/tools/build-public-image.sh`.

### Files

| file | what | goes to |
|---|---|---|
| `20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6-bootpart.img.xz` | `pmOS_boot` (ext2): kernel, initramfs, DTB, extlinux.conf | `nura_boot` |
| `20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6.img.xz` | `pmOS_root` (ext4), grows to the whole partition on first boot | `nura_root` |
| `20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6-u-boot.img.xz` | U-Boot for `boot_a` (boot image header v1, RS6 DTB appended, off-mode charging); uncompressed sha256 `cc399617b0ba7cac3f4f745da9c64c5ddfea16beea0bca5821b44cbf15cc68cb` | `boot_a` |
| `*.sha256`, `*.sha512`, `sha256sums` | checksums | |

Names follow Nura's images (`<date>-<distro>-<channel>-<ui>-<ui version>-<device>`). The RS6 boots
U-Boot from `boot_a`, then extlinux from `nura_boot`, so the image is split into a boot and a root
file, like Nura's images for other bootpart devices (`-bootpart.img`). There is no `-boot.img`
(Android boot image) on purpose: on the RS6 `boot_a` holds U-Boot, and a kernel boot image
written there replaces it.

Check and unpack:

```
sha256sum -c sha256sums
unxz -k 20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6-bootpart.img.xz 20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6.img.xz
```

The flashing scripts take the unpacked `.img` files.

### First install (stock unit, EDL)

Everything in sections 0 and 1 applies: full EDL backup first, the firehose programmer from HiBy's
1.50 burn package in `RS6_LOADER`. Then, from the root of a checkout of `senpai`:

```
export RS6_LOADER=/path/to/prog_emmc_ufs_firehose_Sdm660_ddr.elf
unxz -k 20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6-u-boot.img.xz
edl w boot_a 20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6-u-boot.img --loader=$RS6_LOADER
edl setactiveslot a --loader=$RS6_LOADER
tools/repartition-nura.sh 20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6-bootpart.img 20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6.img 8
```

Same order and rules as section 4: `setactiveslot` on the still-stock table, then the repartition,
which writes both images, reads them back and resets the unit.

### Reinstall or update (already on the Nura layout)

Hold volume up at power-on, pick USB Mass Storage in the U-Boot menu, then on the host:

```
tools/flash-nura-ums.sh /dev/sdX 20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6-bootpart.img 20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6.img
```

This replaces everything on `nura_boot` and `nura_root`, including the user's home directory. To
keep a running install current, `sudo apk upgrade -a` or Discover is enough; no reflash needed.

### First boot

1. The first boot takes longer: the root file system grows to fill `nura_root`.
2. Plasma Mobile asks for the PIN. The default user is `user`, the PIN (password) is `147147`, the
   same as every pre-built Nura image.
3. Plasma Mobile's setup wizard opens once (time zone, Wi-Fi, navigation). It does not change
   the password.
4. Change the password right away: open the terminal (QMLKonsole) and run `passwd`. The PIN on the
   lock screen is that password.

SSH is off, as in every pre-built Nura image. To turn it on: `sudo systemctl enable --now sshd`
(the sudo password is the PIN). Over USB it is then `ssh user@172.16.42.1`.

### Package repositories

The image comes with the linux-hiby-rs6 repository configured by `device-hiby-rs6-repo`:

- `/usr/lib/apk/repositories.d/90-linux-hiby-rs6.list`:
  `https://noas-slopware.github.io/linux-hiby-rs6/main` and
  `https://mirror.funami.tech/linux-hiby-rs6/nura/main`
- `/usr/lib/apk/keys/linux-hiby-rs6-6ad9f9de.rsa.pub`, the repository's signing key. The package also
  owns `/etc/apk/keys/linux-hiby-rs6-6ad9f9de.rsa.pub`; apk reads both directories.

`/etc/apk/repositories` keeps Nura's and Alpine's mirrors as in every Nura image. Where a package
exists in both, apk takes the higher version, which is ours for the patched packages (kernel,
Mesa, Qt, Plasma Mobile and the rest in the `pmos` branch README).

### Checksums

```
98a7541a06c22e2c0cf8cbd1fb08eb345d64418df3843cd02f09804bc542f293  20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6-bootpart.img.xz
8766e1190176092809c6aff2d149e105e225f800b9d9d42e8aef9cf7537605b5  20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6.img.xz
6b68dd5c0b715045d6cfc588cfd91942de418ddffccad31faf03aeb5d43d81e9  20261023-0026-Nura-edge-plasma-mobile-6-hiby-rs6-u-boot.img.xz
```
