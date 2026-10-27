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
#                (mkxtools-rs6.sh, xtools-activate.sh), which the kernel runs natively; so are rustc,
#                clang (mkxtools-rust-rs6.sh) and python, ninja, bison, flex, m4, zstd, bsdtar, debugedit,
#                xz, gzip, make, bash (= sh), coreutils, sed, gawk, grep, findutils, diffutils, tar, bc,
#                cpio, kmod, file, pahole, faked (mkxtools-tools-rs6.sh: Arch's x86_64 packages of bens'
#                versions). perl and everything else stay AArch64, under qemu.
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

# bens' current versions, "name version" per package, as the builder resolves them (repo order of
# pacman-rs6.conf: the first repo that has a name wins), read natively from the shared sync dbs
bens_versions() { fetch_root "${PAC[@]}" -Sl | awk '!seen[$2]++ { print $2, $3 }'; }

# run a script in a builder container brought up to date the way build-rs6.sh's builds start
# (pacman -Su, then these packages), everything downloaded natively beforehand:
#   builder_current <pkg>... -- <script> [arg]...
builder_current() {
	local pk=() list pre script
	while [ "$1" != -- ]; do pk+=("$1"); shift; done; shift
	mapfile -t list < <(resolve localhost/rs6-builder "${pk[@]}")
	fetch_pkgs "${list[@]}" > /dev/null
	pre="pacman -Su --noconfirm > /dev/null"
	[ ${#pk[@]} -eq 0 ] || pre="$pre; pacman -S --needed --asdeps --noconfirm ${pk[*]} > /dev/null"
	script=$1; shift
	builder localhost/rs6-builder sh -euc "$pre
$script" sh "$@"
}

# for the x86_64 rs6-xbuild containers (-e "XGET=$XGET", then eval "$XGET"; after pacman -Sy):
#   xget <name>=<version>...   installs Arch's x86_64 packages of exactly these versions, from the
#                              repos when they have them, else from the Arch archive (pacman checks
#                              the packager signatures either way)
XGET='xget() {
	local a n v repo=() urls=()
	for a; do n=${a%%=*} v=${a#*=}
		if [ "$(pacman -Sddp --print-format %v "$n" 2>/dev/null)" = "$v" ]; then repo+=("$n")
		else urls+=("https://archive.archlinux.org/packages/${n:0:1}/$n/$n-$v-x86_64.pkg.tar.zst"); fi
	done
	[ ${#repo[@]} -eq 0 ] || pacman -S --needed --noconfirm "${repo[@]}" > /dev/null
	[ ${#urls[@]} -eq 0 ] || pacman -U --needed --noconfirm "${urls[@]}" > /dev/null
	for a; do [ "$(pacman -Q "${a%%=*}" | cut -d" " -f2)" = "${a#*=}" ] ||
		{ echo "no x86_64 ${a%%=*} ${a#*=}" >&2; return 1; }; done
}'

# $RS6_WORK/xtools (RS6_ACCEL=xgcc) is replaced while no build uses it: a build holds this lock
# shared for as long as its container runs (the container reads ld.so, glibc's iconv modules and the
# libraries from the mount, not only the programs xtools-activate copied), mkxtools-*.sh hold it
# exclusively for their whole run (RS6_XTOOLS_LOCKED: the scripts they call share it)
XLOCK=$W/xtools.lock
xtools_lock() {
	[ -z "${RS6_XTOOLS_LOCKED:-}" ] || return 0
	exec 8> "$XLOCK"
	flock -n 8 || { log "xtools: waiting for the builds that use them"; flock 8; }
	export RS6_XTOOLS_LOCKED=1
}

# what in xtools no longer matches bens' versions in the sync db: the first stage to rerun and why,
#   "gcc|rust|tools <reason>"   (nothing when everything matches; run after fetch_sync)
#   gcc    mkxtools-rs6.sh       gcc, binutils, ccache, fakeroot (it runs the other two after it)
#   rust   mkxtools-rust-rs6.sh  rust, clang (then mkxtools-tools-rs6.sh)
#   tools  mkxtools-tools-rs6.sh python & co. and the libraries they load
xtools_stale() {
	local -A B
	local n v p d want deps
	while read -r n v; do B[$n]=$v; done < <(bens_versions)
	[ -e "$W/xtools/.stamp" ] || { echo "gcc no xtools yet"; return; }
	for p in gcc binutils ccache fakeroot; do
		want=$(sed -n "s/^$p=//p" "$W/xtools/.stamp")
		[ "$want" = "${B[$p]:-}" ] || { echo "gcc $p $want -> ${B[$p]:-none}"; return; }
	done
	for p in rust clang; do
		want=$(sed -n "s/^$p=//p" "$W/xtools/clang.stamp" 2>/dev/null || true)
		[ "$want" = "${B[$p]:-}" ] || { echo "rust $p ${want:-none} -> ${B[$p]:-none}"; return; }
	done
	[ -s "$W/xtools/tools/.stamp" ] || { echo "tools no tools yet"; return; }
	while read -r p v deps; do
		[ "$v" = "${B[$p]:-}" ] || { echo "tools $p $v -> ${B[$p]:-none}"; return; }
		for d in $deps; do [ "${d#*=}" = "${B[${d%%=*}]:-}" ] ||
			{ echo "tools ${d%%=*} ${d#*=} (loaded by $p) -> ${B[${d%%=*}]:-none}"; return; }; done
	done < "$W/xtools/tools/.stamp"
}

# rerun that stage; exit status 3 from a later stage means Arch's x86_64 glibc moved past the one in
# xtools/lib, which only a full run (mkxtools-rs6.sh, new rs6-xbuild image) brings along
xtools_refresh() {
	local rc=0
	case $1 in
		gcc) "$TOOLS/mkxtools-rs6.sh" ;;
		rust) "$TOOLS/mkxtools-rust-rs6.sh" ;;
		tools) "$TOOLS/mkxtools-tools-rs6.sh" ;;
		*) echo "xtools stage $1?" >&2; return 1 ;;
	esac || rc=$?
	[ $rc -eq 3 ] || return $rc
	log "xtools: Arch's x86_64 glibc moved, all of them again"
	"$TOOLS/mkxtools-rs6.sh"
}

# build-rs6.sh, before each RS6_ACCEL=xgcc build: xtools that match the sync db, refreshed here if
# bens moved; returns with fd 8 holding XLOCK shared (close it with "exec 8>&-" after the build)
xtools_use() {
	local i s st
	for i in 1 2 3; do
		s=$(xtools_stale)
		if [ -n "$s" ]; then
			log "xtools: ${s#* } (bens moved): rebuilding from ${s%% *} on"
			xtools_refresh "${s%% *}" || { log "xtools: refresh failed"; return 1; }
		fi
		st=$(stat -c %Y "$W/xtools/.stamp" "$W/xtools/clang.stamp" "$W/xtools/tools/.stamp" 2>/dev/null || true)
		exec 8> "$XLOCK"; flock -s 8
		# a refresh by a parallel build between the check and the lock replaced them: check again
		[ "$st" = "$(stat -c %Y "$W/xtools/.stamp" "$W/xtools/clang.stamp" "$W/xtools/tools/.stamp" 2>/dev/null || true)" ] && return 0
		exec 8>&-
	done
	return 1
}
