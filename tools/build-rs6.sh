#!/bin/bash
# SPDX-License-Identifier: MIT
# build-rs6.sh: build packages of the arch branch for the HiBy RS6 in fresh rs6-builder containers
# (one per package = a clean chroot), check them for post-ARMv8.0+crc+crypto instructions and add them
# to the [rs6] repo. Images come from mkimages-rs6.sh; how the containers split the work is in lib-rs6.sh.
#   build-rs6.sh <arch branch checkout> <package dir>...
# Environment:
#   RS6_REPO   repo dir (default $RS6_WORK/repo; YuruMirror: <mirror root>/rs6/os/aarch64)
#   RS6_WORK   work dir (default /var/tmp/rs6-arch-build): pkg/src caches, ccache, build dirs, logs
#   RS6_ACCEL  how C/C++ gets compiled in the builder (x86_64 hosts):
#                xgcc   (default on x86_64) bens' exact gcc 16.2.1 + binutils 2.47 rebuilt as x86_64
#                       cross tools (mkxtools-rs6.sh) and run natively inside the AArch64 container,
#                       with rustc, clang (mkxtools-rust-rs6.sh) and python, meson, ninja, bison, flex,
#                       m4, zstd, bsdtar, debugedit, xz, gzip, make, bash/sh, coreutils, sed, gawk, grep,
#                       findutils, diffutils, tar, bc, cpio, kmod, file, pahole, faked
#                       (mkxtools-tools-rs6.sh) the same way
#                none   everything under qemu-user (the only mode on an aarch64 host)
#   NOCHECK=1  skip check() (makepkg --nocheck)
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-rs6.sh"

src=$(realpath "${1:?usage: $0 <arch checkout> <package dir>...}"); shift
[ $# -gt 0 ] || { echo "no package given" >&2; exit 1; }
if [ "$HOSTARCH" = aarch64 ]; then ACCEL=${RS6_ACCEL:-none}; else ACCEL=${RS6_ACCEL:-xgcc}; fi
case $ACCEL in
	none) ;;
	xgcc) [ -e "$W/xtools/.stamp" ] || { echo "no cross tools in $W/xtools: run mkxtools-rs6.sh" >&2; exit 1; } ;;
	*) echo "RS6_ACCEL=$ACCEL?" >&2; exit 1 ;;
esac
FETCH_ARGS=(-v "$src:/src:ro")

build_one() {
	local pkg=$1 t0 t1 deps keys list f n
	local log=$W/logs/$pkg-$(date +%Y%m%d-%H%M%S).log
	[ -e "$src/$pkg/PKGBUILD" ] || { echo "$src/$pkg/PKGBUILD missing" >&2; return 1; }
	t0=$(date +%s)
	log "$pkg: sync, sources ($log)"
	fetch_sync >> "$log" 2>&1

	# .SRCINFO with CARCH=aarch64, read natively; deps = makepkg -s's set (all split packages)
	local srcinfo
	srcinfo=$(fetch_user sh -euc 'sed "s/^CARCH=.*/CARCH=\"aarch64\"/;s/^CHOST=.*/CHOST=\"aarch64-unknown-linux-gnu\"/" \
		/etc/makepkg.conf > /tmp/makepkg.conf; cp -r "/src/$1" /tmp/p && cd /tmp/p && makepkg --config /tmp/makepkg.conf --printsrcinfo' sh "$pkg")
	# what makepkg -s installs: the pkgbase section only (a split package's own depends are not build deps)
	mapfile -t deps < <(sed -n '/^pkgname = /q; s/^\t\(make\|check\|\)depends\(_aarch64\|\) = //p' <<< "$srcinfo" | sort -u)
	mapfile -t keys < <(sed -n 's/^\tvalidpgpkeys = //p' <<< "$srcinfo" | sort -u)

	# PGP keys for the source signatures, by full fingerprint, then all sources into SRCDEST
	fetch_user sh -euc 'mkdir -p -m700 /w/makepkg-gnupg
		for k; do gpg -q --list-keys "$k" >/dev/null 2>&1 && continue
			gpg -q --keyserver hkps://keyserver.ubuntu.com --recv-keys "$k" ||
			gpg -q --keyserver hkps://keys.openpgp.org --recv-keys "$k"; done' sh "${keys[@]}" >> "$log" 2>&1
	fetch_user sh -euc 'sed "s/^CARCH=.*/CARCH=\"aarch64\"/" /etc/makepkg.conf > /tmp/makepkg.conf
		cp -r "/src/$1" /tmp/p && cd /tmp/p && SRCDEST=/w/srcdest makepkg --config /tmp/makepkg.conf --verifysource' \
		sh "$pkg" >> "$log" 2>&1

	# upgrades + missing deps as the fresh container sees them, downloaded natively
	mapfile -t list < <(resolve localhost/rs6-builder "${deps[@]}")
	log "$pkg: ${#deps[@]} deps, ${#list[@]} packages to install"
	fetch_pkgs "${list[@]}" >> "$log" 2>&1
	t1=$(date +%s)

	# a fresh output dir per run (nothing to delete); the build dir is cleaned by makepkg --cleanbuild
	local out=$W/out/$pkg-$(date +%Y%m%d-%H%M%S) bdir=$W/build/$pkg
	mkdir -p "$out" "$bdir"
	BUILDER_ARGS=(-v "$src/$pkg:/pkg:ro" -v "$out:/out" -v "$bdir:/build" -v "$W/srcdest:/srcdest"
		-v "$W/ccache:/ccache" -v "$W/makepkg-gnupg:/gnupg" -e "ACCEL=$ACCEL" -e "NOCHECK=${NOCHECK:-}")
	[ "$ACCEL" != xgcc ] || BUILDER_ARGS+=(-v "$W/xtools:/opt/rs6-xtools:ro" -v "$TOOLS/xtools-activate.sh:/usr/local/bin/xtools-activate:ro")
	log "$pkg: build (accel $ACCEL)"
	# ccache: the 5 GiB default held less than the kernel plus Mesa, and makepkg's freshly extracted
	# sources are always newer than the compile start, which kept ccache out of direct mode
	builder localhost/rs6-builder sh -euc '
		pacman -Su --noconfirm
		echo "rs6-timing: deps $(date +%s)"
		[ $# -eq 0 ] || pacman -S --needed --asdeps --noconfirm "$@"	# what makepkg -s would install
		[ "$ACCEL" != xgcc ] || xtools-activate
		chown builder /build
		echo "rs6-timing: makepkg $(date +%s)"
		su builder -c "cp -r /pkg /home/builder/p && cd /home/builder/p && \
			GNUPGHOME=/gnupg SRCDEST=/srcdest PKGDEST=/out BUILDDIR=/build CCACHE_DIR=/ccache CCACHE_BASEDIR=/build \
			CCACHE_MAXSIZE=30G CCACHE_SLOPPINESS=include_file_mtime,include_file_ctime,time_macros \
			makepkg -s --noconfirm --cleanbuild ${NOCHECK:+--nocheck}"
		echo "rs6-timing: done $(date +%s)"' sh "${deps[@]}" >> "$log" 2>&1 || {
		log "$pkg: build failed, see $log"; return 1; }
	local t2 td tm; t2=$(date +%s)
	td=$(sed -n 's/^rs6-timing: deps //p' "$log" | tail -1); tm=$(sed -n 's/^rs6-timing: makepkg //p' "$log" | tail -1)
	log "$pkg: built in $((t2 - t1))s (upgrade $((td - t1))s, deps $((tm - td))s, makepkg $((t2 - tm))s; prep $((t1 - t0))s)"
	# rs6-rustc's x86_64 proc-macro twins live in .rs6-host dirs of the build tree only
	if fetch_root sh -c 'for f in /w/out/"$1"/*.pkg.tar.zst; do bsdtar -tf "$f" | grep -q "\.rs6-host" && echo "$f"; done' \
		sh "${out#$W/out/}" | grep .; then log "$pkg: .rs6-host files in the package, not added"; return 1; fi
	log "$pkg: ARMv8.0+crc+crypto check"
	fetch_root sh -c 'python3 -I /tools/check-armv8.0.py /w/out/"$1"/*.pkg.tar.zst' sh "${out#$W/out/}" 2>&1 | tee -a "$log" | tail -n 20 >&2 ||
		{ log "$pkg: post-ARMv8.0 instructions, not added to the repo"; return 1; }

	# into [rs6]: ":" -> "." (GitHub release assets cannot carry the epoch colon; pacman uses %FILENAME%).
	# -debug packages stay in $RS6_WORK/out/<pkg> (Arch keeps them out of the main repos too)
	( flock 9; fetch_root sh -euc 'for f in /w/out/$1/*.pkg.tar.zst; do case $f in *-debug-*) continue;; esac
			n=$(basename "$f" | tr : .); cp "$f" "/repo/$n"; repo-add -q -R /repo/rs6.db.tar.zst "/repo/$n"
			# a rebuild keeps its file name: the copy in the package cache becomes this one too, or
			# pacman rejects the old cached file as corrupted against the new checksum
			cp "$f" "/w/pkgcache/$(basename "$f")"; done' \
		sh "${out#$W/out/}" >> "$log" 2>&1 ) 9> "$W/pacman.lock"
	log "$pkg: in $REPO, $(( $(date +%s) - t0 ))s total"
}

for p; do build_one "$p"; done
