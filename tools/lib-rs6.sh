# SPDX-License-Identifier: MIT
# lib-rs6.sh: shared settings for mkimages-rs6.sh and build-rs6.sh (sourced, not run).
#
# Two kinds of containers:
#   rs6-fetch    native to the host (x86_64: Arch Linux; aarch64: bens), runs as root with
#                --security-opt no-new-privileges so pacman's download sandbox (Landlock + seccomp)
#                works. Every network download happens here: pacman -Sy/-Sw for bens + [rs6] into a
#                shared cache, makepkg --verifysource into SRCDEST, gpg --recv-keys. Also runs
#                check-armv8.0.py (llvm-objdump) and repo-add, natively.
#   rs6-builder  bens AArch64 (ARMv8.0) userland, under qemu-user on x86_64 (QEMU_CPU=cortex-a53:
#                fp asimd aes pmull sha1 sha2 crc32, the RS6's feature set). Its pacman.conf has no
#                reachable servers, so it can only install what rs6-fetch already put in the cache: qemu-user
#                implements neither Landlock (syscalls 444-446) nor seccomp, so a download inside it
#                could not be sandboxed. With RS6_ACCEL=xgcc (build-rs6.sh, x86_64 default) bens' gcc,
#                binutils and ccache inside it are swapped for x86_64 builds of the same versions
#                (mkxtools-rs6.sh, xtools-activate.sh), which the kernel runs natively.
# shellcheck shell=bash

W=${RS6_WORK:-/var/tmp/rs6-arch-build}	# lots of disk; never /tmp (tmpfs)
TOOLS=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
REPO=${RS6_REPO:-$W/repo}		# [rs6] repo dir (YuruMirror: <mirror root>/rs6/os/aarch64)
ENGINE=${ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}
HOSTARCH=$(uname -m)
BENS_KEY=C43E3B9B9CE3F35E97AEF93873556FFF735F691D
BOOTSTRAP=archlinux-bootstrap-2026.09.30-aarch64.tar.zst
BOOTSTRAP_SHA256=7756d5f5e642fa133963cc1cafbacdc6c952667522c80ab33e20a55c43d4070d
QEMU_CPU=${QEMU_CPU:-cortex-a53}
JOBS=${JOBS:-$(nproc)}

if [ "$HOSTARCH" = aarch64 ]; then
	EMU=()
	FETCH_FROM=localhost/rs6-arch-base
else
	# binfmt_misc has qemu-aarch64 without the F flag here, so the interpreter is looked up inside
	# the container: the base image carries /usr/bin/qemu-aarch64-static (Containerfile)
	EMU=(--platform linux/arm64 -e "QEMU_CPU=$QEMU_CPU")
	FETCH_FROM=docker.io/library/archlinux:latest
fi

mkdir -p "$W"/{pacdb/sync,pkgcache,srcdest,ccache,out,logs,makepkg-gnupg} "$REPO"

# pacman for the fetcher: bens + [rs6] (the repo dir mounted at /repo), AArch64 databases.
# RS6_PACMAN_CONF names another pacman.conf in tools/: pacman-rs6-published.conf takes [rs6] from the
# published repository instead (mkpublic-rs6.sh, with its own RS6_WORK)
PACCONF=/tools/${RS6_PACMAN_CONF:-pacman-rs6.conf}
[ -f "$TOOLS/${PACCONF#/tools/}" ] || { echo "no $TOOLS/${PACCONF#/tools/}" >&2; exit 1; }
PAC=(pacman --config "$PACCONF" --arch aarch64 --dbpath /w/pacdb --cachedir /w/pkgcache
     --gpgdir /w/gnupg --noconfirm)

# fetcher as root (pacman), with the full download sandbox
fetch_root() {
	"$ENGINE" run --rm --security-opt no-new-privileges -v "$W:/w" -v "$REPO:/repo" -v "$TOOLS:/tools:ro" \
		"${FETCH_ARGS[@]}" localhost/rs6-fetch "$@"
}
# fetcher as the invoking user (makepkg refuses root; files in SRCDEST stay the user's)
fetch_user() {
	"$ENGINE" run --rm --security-opt no-new-privileges --user "$(id -u):$(id -g)" -e HOME=/tmp \
		-e GNUPGHOME=/w/makepkg-gnupg -v "$W:/w" -v "$REPO:/repo" -v "$TOOLS:/tools:ro" \
		"${FETCH_ARGS[@]}" localhost/rs6-fetch "$@"
}
FETCH_ARGS=()

# refresh the sync databases (bens core/extra + [rs6]); an empty [rs6] db is made on first use
# (parallel builds: one pacman at a time on the shared dbs, cache and repo)
fetch_sync() {
	( flock 9; fetch_root sh -euc '[ -e /repo/rs6.db ] || repo-add -q /repo/rs6.db.tar.zst; "$@" -Sy' sh "${PAC[@]}" ) 9> "$W/pacman.lock"
}

# download exactly these repo/pkgname targets (no dependency resolution: the builder already resolved
# them against its own local db); signatures are checked against /w/gnupg (bens key lsigned)
fetch_pkgs() {
	[ $# -gt 0 ] || return 0
	( flock 9; fetch_root "${PAC[@]}" -Swdd "$@" ) 9> "$W/pacman.lock"
}

# builder run with the shared sync dbs and package cache, both read-only: it installs from what the
# fetcher downloaded and can neither download nor delete anything there (parallel builds share it)
builder() {
	local img=$1; shift
	"$ENGINE" run --rm "${EMU[@]}" -v "$W/pacdb/sync:/var/lib/pacman/sync:ro" \
		-v "$W/pkgcache:/var/cache/pacman/pkg:ro" "${BUILDER_ARGS[@]}" "$img" "$@"
}
BUILDER_ARGS=()

# what pacman -Su + -S --needed <targets> would install in image $1, as repo/pkgname
resolve() {
	local img=$1; shift
	builder "$img" pacman -Sup --needed --noconfirm --print-format '%r/%n' "$@" | grep -v '^::\|^warning:' || true
}

log() { printf '==> %s %s\n' "$(date +%T)" "$*" >&2; }
