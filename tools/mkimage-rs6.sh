#!/bin/bash
# SPDX-License-Identifier: MIT
# mkimage-rs6.sh: build the generic HiBy RS6 Arch Linux Ports image (rs6-boot.img ext4 + rs6-root.img F2FS)
# on an aarch64 host, inside the bens-only build container started with --privileged (loop devices,
# mounts). No personal settings: one user (uid 1000, which plasma-mobile.service starts the session
# as), C.UTF-8, UTC, hostname hiby-rs6, an empty machine-id (made at first boot).
# Login: user archlinux / password archlinux, root password root.
#   [USERNAME=archlinux PASSWORD=archlinux ROOT_PASSWORD=root] mkimage-rs6.sh <outdir> [root image size, default 8G]
# Root image size "fit": the root is built in an 8G scratch image, then copied into an F2FS sized to
# its content plus headroom; hiby-rs6-boot (1-6 and later) grows it to the whole arch_root partition
# in the initramfs at boot.
# Flash: U-Boot menu -> USB Mass Storage, then on the host (senpai branch: name/hole checks + readback)
#   RS6_PART_PREFIX=arch tools/flash-nura-ums.sh /dev/sdX rs6-boot.img rs6-root.img
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
	fetch_root sh -euc 'c=$1; shift; r=$(mktemp -d); mkdir -p "$r/db"; cp -r /w/pacdb/sync "$r/db/"
		pacman --config "$c" --arch aarch64 -r "$r" --dbpath "$r/db" --cachedir /w/pkgcache \
			--gpgdir /w/gnupg --noconfirm -Sw "$@"' sh "$PACCONF" "${PKGS[@]}"
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
[ ! -e "$boot_img" ] && [ ! -e "$root_img" ] && [ ! -e "$out/rs6-root-build.img" ] ||
	{ echo "$out already has images; use a new directory" >&2; exit 1; }
build_img=$root_img
if [ "$rootsize" = fit ]; then build_img=$out/rs6-root-build.img; rootsize=8G; fit=1; fi
truncate -s 1G "$boot_img"	# arch_boot is exactly 1 GiB
truncate -s "$rootsize" "$build_img"
# ext4 with e2fsprogs' defaults: U-Boot reads them (metadata_csum_seed is in its lazy read-only set)
mkfs.ext4 -q -L arch_boot "$boot_img"
f2fs_opts=(-q -l arch_root -O extra_attr,inode_checksum,sb_checksum)
mkfs.f2fs "${f2fs_opts[@]}" "$build_img"

mnt=$(mktemp -d)
mount -o loop "$build_img" "$mnt"
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

# the device's pacman.conf: [rs6] (unsigned, so SigLevel = Never as in arch-mact2) from rs6-mirrorlist, sandbox on (the kernel has
# Landlock); the bens key in the target keyring too (pacstrap -K only populated archlinux)
# [rs6] goes first, above [core], so our packages (mesa and the rest) always win over bens'
awk '/^\[rs6\]/ { skip = 1; next } /^\[/ { if (!done && $0 == "[core]") { print "[rs6]\nSigLevel = Never\nInclude = /etc/pacman.d/rs6-mirrorlist\n"; done = 1 } skip = 0 }
	!skip' "$conf" > "$mnt/etc/pacman.conf"
[ -n "${RS6_IN_CONTAINER:-}" ] ||
	arch-chroot "$mnt" sh -c "curl -fsSL https://arch.bens.haus/$bens_key.asc | pacman-key --add - && pacman-key --lsign-key $bens_key"

cat > "$mnt/etc/fstab" <<'FSTAB'
# HiBy RS6: partitions by GPT name (tools/repartition-nura.sh layout)
PARTLABEL=arch_root	/	f2fs	rw,noatime,lazytime	0 1
PARTLABEL=arch_boot	/boot	ext4	rw,noatime	0 2
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
# blocks freed while building (replaced initramfs, deleted files) become holes in the image files
# (loop discard), so they are not in the .bmap and not written when flashing
fstrim "$mnt/boot"
[ -n "${fit:-}" ] || fstrim "$mnt"
sync
trap - EXIT; umount -R "$mnt"; rmdir "$mnt"

if [ -n "${fit:-}" ]; then
	# root sized to its content: + 20 % + 512 MiB, in whole 2 MiB F2FS segments
	src=$(mktemp -d); dst=$(mktemp -d)
	mount -o loop,ro "$build_img" "$src"
	trap 'umount "$src" "$dst" 2>/dev/null; rmdir "$src" "$dst"' EXIT
	used=$(du -sx --block-size=1M "$src" | cut -f1)
	size=$(( (used + used / 5 + 512 + 1) / 2 * 2 ))
	truncate -s "${size}M" "$root_img"
	mkfs.f2fs "${f2fs_opts[@]}" "$root_img"
	mount -o loop "$root_img" "$dst"
	cp -a --preserve=xattr "$src/." "$dst/"
	# the same tree: names, types, modes, owners, file sizes, link targets, hard links, xattrs
	tree() { (cd "$1" && find . \( -type d -printf '%p d %m %U %G\n' \) -o -printf '%p %y %m %U %G %s %n %l\n' | sort); }
	cmp <(tree "$src") <(tree "$dst") || { echo "copied root differs from the built one" >&2; exit 1; }
	xattrs() { (cd "$1" && getfattr -R -h -d -m - . | awk -v RS= '{ gsub("\n", " "); print }' | sort); }
	cmp <(xattrs "$src") <(xattrs "$dst") || { echo "copied root has different xattrs" >&2; exit 1; }
	echo "root copy: same tree, $(xattrs "$dst" | wc -l) files with xattrs"
	free=$(df --output=avail -B1M "$dst" | tail -n 1)
	[ "$free" -ge 256 ] || { echo "fitted root has only $free MiB free" >&2; exit 1; }
	echo "root: ${used} MiB used, ${size} MiB image, ${free} MiB free"
	fstrim "$dst"
	sync
	trap - EXIT; umount "$src" "$dst"; rmdir "$src" "$dst"
	(cd "$out" && rm rs6-root-build.img)
fi
fsck.ext4 -fn "$boot_img" >/dev/null; fsck.f2fs "$root_img" >/dev/null
(cd "$out" && sha256sum rs6-boot.img rs6-root.img > SHA256SUMS && cat SHA256SUMS)
echo "images: $boot_img $root_img"
