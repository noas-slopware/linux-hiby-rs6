#!/bin/bash
# SPDX-License-Identifier: MIT
# mkimage-rs6.sh: build the generic HiBy RS6 Arch Linux Ports image (rs6-boot.img ext4 + rs6-root.img F2FS)
# on an aarch64 host, inside the bens-only build container started with --privileged (loop devices,
# mounts). No personal settings: one user (uid 1000, which plasma-mobile.service starts the session
# as), C.UTF-8, UTC, hostname hiby-rs6, an empty machine-id (made at first boot).
# Login: user archlinux / password archlinux, root password root.
#   [USERNAME=archlinux PASSWORD=archlinux ROOT_PASSWORD=root] mkimage-rs6.sh <outdir> [root image size, default 8G]
# Flash: U-Boot menu -> USB Mass Storage, then on the host
#   tools/flash-nura-ums.sh /dev/sdX rs6-boot.img rs6-root.img   (main branch: name/hole checks + readback)
#   resize.f2fs /dev/sdX<nura_root>                              (grow F2FS to the whole partition)
set -euo pipefail

out=${1:?usage: $0 <outdir> [root size]}
rootsize=${2:-8G}
user=${USERNAME:-archlinux}
PASSWORD=${PASSWORD:-archlinux}
ROOT_PASSWORD=${ROOT_PASSWORD:-root}
export USERNAME="$user" PASSWORD ROOT_PASSWORD
conf=/etc/pacman-rs6.conf	# bens [core], [rs6] (file:///repo), bens [extra]
bens_key=C43E3B9B9CE3F35E97AEF93873556FFF735F691D
PKGS=(base linux-hiby-rs6 linux-hiby-rs6-dtbs mkinitcpio hiby-rs6-device hiby-rs6-firefox
	mesa vulkan-freedreno opencl-mesa
	plasma-mobile plasma-keyboard plasma-settings plasma-nm plasma-pa bluedevil kscreen powerdevil
	xdg-desktop-portal-kde qqc2-breeze-style breeze breeze-icons noto-fonts
	networkmanager openssh tailscale sudo
	firefox mobile-config-firefox elisa dolphin qmlkonsole)
# RS6_IMAGE_PKGS="pkg ..." replaces that list (e.g. a base image to set up over SSH)
[ -z "${RS6_IMAGE_PKGS:-}" ] || read -ra PKGS <<< "$RS6_IMAGE_PKGS"

# x86_64 host (Gorakubu): download the whole package set natively in rs6-fetch (pacman's download
# sandbox), then run this script again inside a privileged rs6-builder (bens AArch64 under qemu-user:
# only pacman, scriptlets and hooks run there, nothing is compiled), which installs from that cache only
if [ "$(uname -m)" = x86_64 ] && [ -z "${RS6_IN_CONTAINER:-}" ]; then
	. "$(dirname "$(realpath "$0")")/lib-rs6.sh"
	mkdir -p "$out"; out=$(realpath "$out")
	fetch_sync
	# (a throwaway root in the throwaway container: the full dependency set, downloaded into the cache)
	fetch_root sh -euc 'r=$(mktemp -d); mkdir -p "$r/db"; cp -r /w/pacdb/sync "$r/db/"
		pacman --config /tools/pacman-rs6.conf --arch aarch64 -r "$r" --dbpath "$r/db" --cachedir /w/pkgcache \
			--gpgdir /w/gnupg --noconfirm -Sw "$@"' sh "${PKGS[@]}"
	exec "$ENGINE" run --rm --privileged "${EMU[@]}" -e RS6_IN_CONTAINER=1 -e PASSWORD -e ROOT_PASSWORD -e USERNAME="$user" -e RS6_IMAGE_PKGS \
		-v "$W/pacdb/sync:/var/lib/pacman/sync:ro" -v "$W/pkgcache:/var/cache/pacman/pkg" -v "$TOOLS:/tools:ro" \
		-v "$out:/out" localhost/rs6-builder /tools/mkimage-rs6.sh /out "$rootsize"
fi
pacstrap_conf=$conf
# in rs6-builder: packages come from the cache only (pacstrap -c), and pacstrap's own -Sy reads the
# sync databases the fetcher made, mounted at /var/lib/pacman/sync; the device gets $conf
if [ -n "${RS6_IN_CONTAINER:-}" ]; then
	pacstrap_conf=$(mktemp)
	sed 's|^Server = .*|Server = file:///var/lib/pacman/sync|' /etc/pacman.conf > "$pacstrap_conf"
fi

boot_img=$out/rs6-boot.img
root_img=$out/rs6-root.img
mkdir -p "$out"
[ ! -e "$boot_img" ] && [ ! -e "$root_img" ] || { echo "$out already has images; use a new directory" >&2; exit 1; }
truncate -s 1G "$boot_img"	# nura_boot is exactly 1 GiB
truncate -s "$rootsize" "$root_img"
# ext4 with e2fsprogs' defaults: U-Boot reads them (metadata_csum_seed is in its lazy read-only set)
mkfs.ext4 -q -L nura_boot "$boot_img"
mkfs.f2fs -q -l nura_root -O extra_attr,inode_checksum,sb_checksum "$root_img"

mnt=$(mktemp -d)
mount -o loop "$root_img" "$mnt"
mkdir -p "$mnt/boot"
mount -o loop "$boot_img" "$mnt/boot"
trap 'umount -R "$mnt"; rmdir "$mnt"' EXIT

if [ -n "${RS6_IN_CONTAINER:-}" ]; then
	# binfmt_misc without the F flag: chrooted scriptlets and hooks look for the interpreter in the target
	install -Dm755 /usr/bin/qemu-aarch64-static "$mnt/usr/bin/qemu-aarch64-static"
	pacstrap -c -C "$pacstrap_conf" "$mnt" "${PKGS[@]}"
	# the keyring pacstrap -K would have made, plus the bens key (exported from this container's keyring)
	arch-chroot "$mnt" sh -c 'pacman-key --init && pacman-key --populate archlinux'
	pacman-key --export "$bens_key" > "$mnt/root/bens.asc"
	arch-chroot "$mnt" sh -c "pacman-key --add /root/bens.asc && pacman-key --lsign-key $bens_key"
	(cd "$mnt" && rm root/bens.asc)
else
	pacstrap -K -C "$conf" "$mnt" "${PKGS[@]}"
fi

# the device's pacman.conf: [rs6] from rs6-mirrorlist between [core] and [extra], sandbox on (the kernel has
# Landlock); the bens key in the target keyring too (pacstrap -K only populated archlinux)
sed -e 's|^Server = file:///repo$|Include = /etc/pacman.d/rs6-mirrorlist|' "$conf" > "$mnt/etc/pacman.conf"
[ -n "${RS6_IN_CONTAINER:-}" ] ||
	arch-chroot "$mnt" sh -c "curl -fsSL https://arch.bens.haus/$bens_key.asc | pacman-key --add - && pacman-key --lsign-key $bens_key"

cat > "$mnt/etc/fstab" <<'FSTAB'
# HiBy RS6: partitions by GPT name (tools/repartition-nura.sh layout)
PARTLABEL=nura_root	/	f2fs	rw,noatime,lazytime	0 1
PARTLABEL=nura_boot	/boot	ext4	rw,noatime	0 2
FSTAB
echo hiby-rs6 > "$mnt/etc/hostname"
echo LANG=C.UTF-8 > "$mnt/etc/locale.conf"
ln -sf /usr/share/zoneinfo/UTC "$mnt/etc/localtime"

arch-chroot "$mnt" useradd -m -u 1000 -G wheel,audio "$user"
printf '%s:%s\n%s:%s\n' "$user" "$PASSWORD" root "$ROOT_PASSWORD" | arch-chroot "$mnt" chpasswd
# Arch's own wheel rule, as the wiki sets it up
echo '%wheel ALL=(ALL:ALL) ALL' > "$mnt/etc/sudoers.d/10-wheel"
chmod 440 "$mnt/etc/sudoers.d/10-wheel"

arch-chroot "$mnt" systemctl preset-all
# no machine-id in the image: systemd makes one at first boot (bootmac derives the Wi-Fi/BT MACs from it)
: > "$mnt/etc/machine-id"
(cd "$mnt" && rm -f var/lib/dbus/machine-id)

(cd "$mnt" && rm -f usr/bin/qemu-aarch64-static)
test -s "$mnt/boot/extlinux/extlinux.conf" || { echo "no extlinux.conf: did hiby-rs6-boot's hook run?" >&2; exit 1; }
cat "$mnt/boot/extlinux/extlinux.conf"
sync
trap - EXIT; umount -R "$mnt"; rmdir "$mnt"
fsck.ext4 -fn "$boot_img" >/dev/null; fsck.f2fs "$root_img" >/dev/null
(cd "$out" && sha256sum rs6-boot.img rs6-root.img > SHA256SUMS && cat SHA256SUMS)
echo "images: $boot_img $root_img"
