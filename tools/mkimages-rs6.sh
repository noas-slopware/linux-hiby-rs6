#!/bin/bash
# SPDX-License-Identifier: MIT
# mkimages-rs6.sh: make the container images build-rs6.sh uses, rootless where the engine allows
# (docker group or rootless podman; no sudo). See lib-rs6.sh for what each image is for.
#   mkimages-rs6.sh [base] [fetch] [builder]      (default: all three, in this order)
#     base     localhost/rs6-arch-base  bens bootstrap 2026.09.30 (+ qemu-aarch64-static on x86_64)
#     fetch    localhost/rs6-fetch      native pacman/makepkg/git/llvm-objdump/repo-add
#     builder  localhost/rs6-builder    bens base-devel + ccache, user "builder" (your uid),
#                                       makepkg-rs6.conf, a pacman.conf without servers
# Re-run "builder" whenever bens moves (build-rs6.sh also upgrades each fresh container first).
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-rs6.sh"

BUILDER_PKGS=(base-devel git python ccache arch-install-scripts f2fs-tools e2fsprogs)	# the last three: mkimage-rs6.sh
steps=("$@"); [ ${#steps[@]} -gt 0 ] || steps=(base fetch builder)

mk_base() {
	local ctx=$W/ctx-base
	mkdir -p "$W/dl" "$ctx"
	if [ ! -e "$W/dl/$BOOTSTRAP" ]; then
		curl -fL -o "$W/dl/$BOOTSTRAP.part" "https://arch.bens.haus/iso/$BOOTSTRAP"
		mv "$W/dl/$BOOTSTRAP.part" "$W/dl/$BOOTSTRAP"
	fi
	echo "$BOOTSTRAP_SHA256  $W/dl/$BOOTSTRAP" | sha256sum -c --quiet
	ln -f "$W/dl/$BOOTSTRAP" "$ctx/bootstrap.tar.zst"
	if [ "$HOSTARCH" = aarch64 ]; then : > "$ctx/qemu-aarch64-static"
	else
		grep -q '^interpreter /usr/bin/qemu-aarch64-static$' /proc/sys/fs/binfmt_misc/qemu-aarch64 ||
			{ echo "binfmt_misc has no qemu-aarch64 -> /usr/bin/qemu-aarch64-static" >&2; exit 1; }
		cp /usr/bin/qemu-aarch64-static "$ctx/"
	fi
	"$ENGINE" build --platform linux/arm64 -f "$TOOLS/Containerfile" -t localhost/rs6-arch-base "$ctx"
}

mk_fetch() {
	# run + commit instead of a Containerfile: pacman's sandbox needs no-new-privileges, which a
	# build step cannot set (the archlinux image works around that with DisableSandboxFilesystem;
	# here it is removed instead)
	local c=rs6-fetch-$$
	"$ENGINE" run --name "$c" --security-opt no-new-privileges -v "$TOOLS:/tools:ro" "$FETCH_FROM" sh -euc '
		sed -i "/^DisableSandbox/d" /etc/pacman.conf
		if [ "$(uname -m)" = aarch64 ]; then	# bens base: bens servers, keyring
			grep -v "^\[rs6\]\|^Server = file:///repo\|^SigLevel = Never" /tools/pacman-rs6.conf > /etc/pacman.conf
			pacman-key --init; pacman-key --populate archlinux
			curl -fsSL https://arch.bens.haus/$1.asc | pacman-key --add -; pacman-key --lsign-key $1
		fi
		pacman -Syu --noconfirm --needed base-devel git llvm python
		rm -rf /var/cache/pacman/pkg/*' sh "$BENS_KEY"
	"$ENGINE" commit "$c" localhost/rs6-fetch >/dev/null
	"$ENGINE" rm "$c" >/dev/null
	# the AArch64 keyring the fetcher checks bens' signatures with (also copied into the builder)
	[ -e "$W/gnupg/pubring.gpg" ] || fetch_root sh -euc '
		pacman-key --gpgdir /w/gnupg --init
		pacman-key --gpgdir /w/gnupg --populate archlinux
		curl -fsSL https://arch.bens.haus/$1.asc | pacman-key --gpgdir /w/gnupg --add -
		pacman-key --gpgdir /w/gnupg --lsign-key $1' sh "$BENS_KEY"
}

mk_builder() {
	local c=rs6-builder-$$ list
	fetch_sync
	mapfile -t list < <(resolve localhost/rs6-arch-base "${BUILDER_PKGS[@]}")
	log "builder: ${#list[@]} packages"
	fetch_pkgs "${list[@]}"
	"$ENGINE" run --name "$c" "${EMU[@]}" -v "$W/pacdb/sync:/var/lib/pacman/sync:ro" \
		-v "$W/pkgcache:/var/cache/pacman/pkg" -v "$W/gnupg:/mnt/gnupg:ro" -v "$TOOLS:/tools:ro" \
		localhost/rs6-arch-base sh -euc '
		uid=$1; shift
		rm -rf /etc/pacman.d/gnupg && cp -a /mnt/gnupg /etc/pacman.d/gnupg
		# no real servers: this container can only install what rs6-fetch put in the cache (libalpm
		# wants a server per repo even for cached packages, so each gets one that cannot be reached)
		sed "s|^Server = .*|Server = file:///rs6-builder-never-downloads/\$repo|" /tools/pacman-rs6.conf > /etc/pacman.conf
		install -m644 /tools/pacman-rs6.conf /etc/pacman-rs6.conf	# mkimage-rs6.sh (native aarch64 hosts)
		pacman -Su --noconfirm --needed "$@"
		grep -q "^CFLAGS=\"-march=armv8-a " /etc/makepkg.conf	# bens baseline unchanged?
		install -m644 /tools/makepkg-rs6.conf /etc/makepkg.conf.d/rs6.conf
		useradd -m -u "$uid" builder
		echo "builder ALL=(root) NOPASSWD: /usr/bin/pacman" > /etc/sudoers.d/builder
		# the flags our builds get, and that bens gcc takes them
		flags=$(su builder -c ". /etc/makepkg.conf; for f in /etc/makepkg.conf.d/*.conf; do . \$f; done; echo \$CFLAGS")
		echo "rs6 CFLAGS: $flags"
		case $flags in "-march=armv8-a+crc+crypto -mtune=cortex-a73.cortex-a53 -O2 "*) ;; *) exit 1;; esac
		echo "int main(void){return 0;}" | gcc $flags -x c - -o /tmp/t && rm /tmp/t
		gcc -v 2>&1 | tail -1' sh "$(id -u)" "${BUILDER_PKGS[@]}"
	"$ENGINE" commit "$c" localhost/rs6-builder >/dev/null
	"$ENGINE" rm "$c" >/dev/null
}

for s in "${steps[@]}"; do
	log "image: $s"
	"mk_$s"
done
