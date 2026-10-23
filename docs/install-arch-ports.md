# Installing Arch Linux Ports on the HiBy RS6

A minimal [Arch Linux Ports](https://arch.bens.haus) AArch64 system (bens' ARMv8.0 repositories) with
the RS6 kernel and device packages. It uses the same whole-eMMC layout and the same first install as
Nura ([install.md](install.md)), with `arch_*` partitions instead of `nura_*`.

Every package comes from the binary repositories: bens' `[core]` and `[extra]`, and our `[rs6]`
(GitHub Pages and YuruMirror). The image keeps `[rs6]` configured, so `sudo pacman -Syu` updates the
RS6 like any other Arch machine. There is no desktop in the image; install one yourself (Plasma
Mobile below, or anything else: nothing in the device packages needs a particular desktop).

Build recipe: `tools/mkpublic-rs6.sh` on the `arch` branch. It refuses an image whose `[rs6]`
packages or `rs6.db` are not exactly the published ones.

## What is in it

Image `archlinux-hiby-rs6-2026.10.23`, built from the `arch` branch at e5b7a00 and the published
`[rs6]` repository (`hiby-rs6-system` 1-21, `linux-hiby-rs6` 7.2.3-4).

- `base`, `linux-hiby-rs6`, `linux-hiby-rs6-dtbs`, `mkinitcpio`, `firmware-hiby-rs6`
- `hiby-rs6-boot`: extlinux.conf for U-Boot, the initramfs hook, and the unit that grows the root file
  system on first boot
- `hiby-rs6-system`: udev rules, zram swap, firewall (nftables), USB network, shutdown watchdog, touch
  boost, the power key (suspend), and what the hardware needs (`rmtfs`, `tqftpserv`, `qcom-diag`,
  `bootmac`, `swclock-offset`)
- `rs6-mirrorlist`, `networkmanager`, `openssh`, `sudo`, `vim`, `nano`

Enabled at boot, by `hiby-rs6-system`'s preset and systemd's own: NetworkManager, sshd, nftables,
bluetooth, diag-router, rmtfs, tqftpserv, swclock-offset, rs6-touchboost, rs6-vt-lock,
hiby-rs6-growroot-done, systemd-resolved, systemd-timesyncd, systemd-oomd and a getty on tty1.
systemd-networkd and systemd-homed are off (NetworkManager owns the network). No browser, no
Tailscale, nothing personal: host name `hiby-rs6`, `C.UTF-8`, UTC, an empty machine-id (made on
first boot; the Wi-Fi and Bluetooth MAC addresses are derived from it), and SSH host keys made on first
boot too.

## Files

Download them from the [arch-ports-2026.10.23 release](https://github.com/noas-slopware/linux-hiby-rs6/releases/tag/arch-ports-2026.10.23).

| file | what | goes to |
|---|---|---|
| `archlinux-hiby-rs6-2026.10.23-boot.img.zst` | ext4: kernel, initramfs, DTB, extlinux.conf | `arch_boot` |
| `archlinux-hiby-rs6-2026.10.23-root.img.zst` | F2FS, sized to its content; grows to the whole partition on first boot | `arch_root` |
| `archlinux-hiby-rs6-2026.10.23-boot.img.bmap`, `archlinux-hiby-rs6-2026.10.23-root.img.bmap` | block maps: which blocks hold data, with checksums | |
| `archlinux-hiby-rs6-2026.10.23-u-boot.img.zst` | U-Boot for `boot_a` (boot image header v1, RS6 DTB appended, off-mode charging); uncompressed sha256 `cc399617b0ba7cac3f4f745da9c64c5ddfea16beea0bca5821b44cbf15cc68cb` | `boot_a` |
| `*.sha256`, `*.sha512`, `sha256sums` | checksums | |

The RS6 boots U-Boot from `boot_a`, then extlinux from `arch_boot`, with the root on `arch_root`, so
the image is a boot and a root file. There is no Android boot image of the kernel on purpose:
`boot_a` holds U-Boot, and a kernel boot image written there replaces it.

Check, and for EDL unpack:

```
I=archlinux-hiby-rs6-2026.10.23
sha256sum -c sha256sums
unzstd -k $I-u-boot.img.zst $I-boot.img.zst $I-root.img.zst
```

Flashing over USB Mass Storage takes the `.zst` files as they are.

## First install (stock unit, EDL)

Sections 0 and 1 of [install.md](install.md) apply: a full EDL backup first, and the firehose
programmer from HiBy's 1.50 burn package in `RS6_LOADER`. Then, from the root of a checkout of
`senpai` (the default branch), with the unpacked files:

```
export RS6_LOADER=/path/to/prog_emmc_ufs_firehose_Sdm660_ddr.elf
edl w boot_a $I-u-boot.img --loader=$RS6_LOADER
edl setactiveslot a --loader=$RS6_LOADER
RS6_PART_PREFIX=arch tools/repartition-nura.sh $I-boot.img $I-root.img 8
```

Same order and rules as section 4 of [install.md](install.md): `setactiveslot` on the still-stock
table, then the repartition, which writes the table with `arch_boot`, `arch_swap1`, `arch_swap2` and
`arch_root` (`RS6_PART_PREFIX=arch`; the same sectors as the Nura layout), both images and the swap
signatures, reads them back and resets the unit. The repartition only starts from the stock table; a
unit on the Nura layout gets its stock table back from the EDL backup first. The image uses zram for
swap; the two swap partitions stay unused.

## Reinstall or update (already on the arch layout)

The host needs `bmaptool` and `zstd`. Hold volume up at power-on, pick USB Mass Storage in the U-Boot
menu, then on the host:

```
RS6_PART_PREFIX=arch tools/flash-nura-ums.sh /dev/sdX $I-boot.img.zst $I-root.img.zst
```

The script checks the device (size, partition names, no holes in the table), finds the `.bmap` next
to each image, writes only the blocks that hold data with `bmaptool` (decompressing on the fly), then
reads back only those blocks and compares them with the checksums in the `.bmap`. This replaces
everything on `arch_boot` and `arch_root`, including the home directory. To keep a running install
current, `sudo pacman -Syu` is enough; no reflash needed.

## First boot

1. The first boot takes longer: before the root is mounted, the initramfs grows the F2FS root to fill
   `arch_root` (`hiby-rs6-growroot.service`, `resize.f2fs`, asked for by `hiby_rs6.growroot` on the
   kernel command line). Once the root fills the partition, `hiby-rs6-growroot-done.service` records
   it and drops the flag from `extlinux.conf`, so later boots don't touch the root.
2. The panel shows a text login (tty1). There is no on-screen keyboard there, so the first way in is
   SSH over the USB cable: the RS6 is `172.16.42.1` and hands the host an address by DHCP.

   ```
   ssh archlinux@172.16.42.1
   ```

3. User `archlinux`, password `archlinux` (in `wheel`, so `sudo` works with that password). Root's
   password is `root`; root cannot log in over SSH with a password (OpenSSH's default
   `PermitRootLogin prohibit-password`, which Arch keeps).
4. Change both passwords right away, before joining Wi-Fi: SSH is on and the firewall lets it in on
   every interface.

   ```
   passwd
   sudo passwd root
   ```

5. Wi-Fi: `nmtui`, or `nmcli device wifi connect <SSID> --ask`.

SSH is on in this image. To turn it off: `sudo systemctl disable --now sshd`.

A short press of the power key suspends (`hiby-rs6-system`'s logind drop-in); without it systemd's
default would power the RS6 off.

## A desktop

`hiby-rs6-device` brings the audio configuration (`hiby-rs6-audio`: UCM, PipeWire and WirePlumber,
realtime audio threads for the `audio` group, which `archlinux` is in, and Elisa's exclusive,
bit-perfect output) and the S/PDIF output, for any desktop:

```
sudo pacman -S hiby-rs6-device mesa vulkan-freedreno
```

### Plasma Mobile

```
sudo pacman -S hiby-rs6-plasma rs6-dac-plasma plasma-mobile plasma-keyboard plasma-settings plasma-nm \
  plasma-pa bluedevil kscreen powerdevil xdg-desktop-portal-kde qqc2-breeze-style breeze breeze-icons \
  noto-fonts elisa dolphin qmlkonsole
sudo systemctl preset plasma-mobile.service bluetooth.service rtkit-daemon.service
sudo reboot
```

`hiby-rs6-plasma` starts the session on tty1 as uid 1000 (`archlinux`) with `plasma-mobile.service`;
the lock screen asks for that user's password, and powerdevil takes the power key. `rs6-dac-plasma`
is the DAC settings page. `mesa` and `plasma-mobile` come from `[rs6]`, which is listed first. Elisa
is our build (Subsonic source, bit-perfect output).

### Firefox

`sudo pacman -S firefox mobile-config-firefox hiby-rs6-firefox`: hardware video decoding on Venus
through Firefox's own V4L2-DRM path (H.264 and VP9 tested; VP8 and HEVC take the same path), Firefox for Android's user agent (kept in step
with the installed Firefox by a pacman hook) and the RS6's performance defaults.

## Package repositories

`/etc/pacman.conf` lists `[rs6]` first, above `[core]`, so our builds of packages that also exist in
bens' repositories (Mesa, Plasma Mobile and the rest) always win:

```
[rs6]
SigLevel = Never
Include = /etc/pacman.d/rs6-mirrorlist
```

`[rs6]` is unsigned, like arch-mact2. `/etc/pacman.d/rs6-mirrorlist` (package `rs6-mirrorlist`):

```
Server = https://noas-slopware.github.io/linux-hiby-rs6/arch/$arch
Server = https://mirror.funami.tech/linux-hiby-rs6/arch/$arch
```

`[core]` and `[extra]` are bens' ARMv8.0 repositories (`https://arch.bens.haus/repos/$repo/os/$arch`),
signed with bens' key, which the image's keyring has locally signed.

## Checksums

```
f92083b2c6a6a003be5e829b257b7feffecbc802c4414447d0fa722e28381b9b  archlinux-hiby-rs6-2026.10.23-boot.img.zst
1a59d0647c3b4ff2c665fb20390ba05f7b7b3c55d0746a08b302e88a7de585c0  archlinux-hiby-rs6-2026.10.23-root.img.zst
fa200932de08565164f08a258d79740a85cafd3f5e7f59d065d2a52adeb5c229  archlinux-hiby-rs6-2026.10.23-u-boot.img.zst
7a3c05a0500a8b46349fc3a2f7628af7aa2a62aed2395919b298a45d65806460  archlinux-hiby-rs6-2026.10.23-boot.img.bmap
102d4e3dbfb5fcd0fb7ca06c389692f327f90b362377a736b8586a5376f0eaa5  archlinux-hiby-rs6-2026.10.23-root.img.bmap
```
