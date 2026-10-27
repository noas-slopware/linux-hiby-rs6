#!/bin/bash
# SPDX-License-Identifier: MIT
# mksccache-toolchain-rs6.sh: the sccache-dist toolchain archives that let Gorakubu (x86_64) compile
# Rust crates for the RS6. sccache-dist runs a client's compiler from an archive inside bubblewrap.
# Without a mapping it ships the RS6's own AArch64 rustc, which Gorakubu can only run under
# qemu-user, so the RS6's client config points each of its rustup toolchains at one of these archives
# instead (path_override): rustup's x86_64 build of the very same rustc (same commit), with the
# aarch64-unknown-linux-gnu std, plus every library it loads and its ELF interpreter, at /toolchain.
# sccache always passes --target=<client host> to distributed rustc, so it emits AArch64 code.
#
# Run it on Gorakubu after every rustup update on the RS6: for each toolchain the RS6 has (stable,
# nightly) it reads that rustc's version over SSH, installs the matching release or dated nightly
# here, builds the archive and copies it to the RS6, then prints the client config entries.
#   mksccache-toolchain-rs6.sh [ssh-target]   (default irohasakayori@cosmic-princess-kaguya)
#   RS6_SSH_OPTS="-o HostKeyAlias=..."         extra ssh/scp options
#   mksccache-toolchain-rs6.sh --local [stable|nightly]...   (default: both)
#       without the RS6: the archives for rust's current stable release and newest nightly, from the
#       channel manifests (installed here as <version> / nightly-<date>, never touching this host's
#       stable/nightly), left in /var/tmp/rs6-sccache-toolchain/<name>/archive.tar.gz with their
#       versions printed; the RS6 then needs those toolchains (rustup) and the archives copied to
#       ~/.local/share/rs6-sccache/rustc-x86_64-for-aarch64-<name>.tar.gz
set -euo pipefail
LOCAL=; [ "${1:-}" != --local ] || { LOCAL=1; shift; }
RS6=${1:-irohasakayori@cosmic-princess-kaguya}
read -r -a O <<< "${RS6_SSH_OPTS:-}"
W=/var/tmp/rs6-sccache-toolchain
DESTDIR=.local/share/rs6-sccache	# relative to the RS6 user's home

# one archive per toolchain name, rebuilt when the commit changes
build_archive() {	# <name> <rustup toolchain> <commit>
	local name=$1 tc=$2 hash=$3 have sysroot d=$W/$1
	rustup toolchain install "$tc" --profile minimal --target aarch64-unknown-linux-gnu >&2
	have=$(rustc +"$tc" -vV | awk '/^commit-hash/{print $2}')
	[ "$have" = "$hash" ] || { echo "$tc is $have, wanted $hash" >&2; exit 1; }
	sysroot=$(rustc +"$tc" --print sysroot)
	if [ "$(cat "$d/stamp" 2>/dev/null)" != "$hash" ]; then
		case $name in
		stable) rm -rf /var/tmp/rs6-sccache-toolchain/stable/root /var/tmp/rs6-sccache-toolchain/stable/archive.tar.gz ;;
		nightly) rm -rf /var/tmp/rs6-sccache-toolchain/nightly/root /var/tmp/rs6-sccache-toolchain/nightly/archive.tar.gz ;;
		esac
		mkdir -p "$d/root/toolchain/bin" "$d/root/toolchain/lib/rustlib"
		cp -a "$sysroot/bin/rustc" "$d/root/toolchain/bin/"
		cp -a "$sysroot"/lib/*.so* "$d/root/toolchain/lib/"
		cp -a "$sysroot/lib/rustlib/aarch64-unknown-linux-gnu" "$d/root/toolchain/lib/rustlib/"
		# the libraries rustc and its shared objects load, at their own paths, and the ELF interpreter
		# (the toolchain's own libraries are already in /toolchain/lib, found through rustc's $ORIGIN rpath)
		{ ldd "$sysroot/bin/rustc"; for f in "$sysroot"/lib/*.so*; do [ -L "$f" ] || ldd "$f" || true; done; } 2>/dev/null |
			awk '/=> \//{print $3} /^\s*\/.*ld-linux/{print $1}' | grep -v "^$sysroot/" | sort -u | while read -r lib; do
				mkdir -p "$d/root$(dirname "$lib")"
				cp -L "$lib" "$d/root$lib"
			done
		mkdir -p "$d/root/lib64" "$d/root/tmp" "$d/root/dev" "$d/root/proc"
		cp -L /lib64/ld-linux-x86-64.so.2 "$d/root/lib64/"
		tar -C "$d/root" --owner=0 --group=0 --numeric-owner -czf "$d/archive.tar.gz" .
		echo "$hash" > "$d/stamp"
	fi
}

if [ -n "$LOCAL" ]; then
	[ $# -gt 0 ] || set -- stable nightly
	for name; do
		case $name in stable | nightly) ;; *) echo "$name: only stable and nightly" >&2; exit 1 ;; esac
		m=$(curl -fsSL "https://static.rust-lang.org/dist/channel-rust-$name.toml")
		date=$(sed -n 's/^date = "\(.*\)"$/\1/p' <<< "$m" | head -1)
		read -r release _ < <(sed -n '/^\[pkg\.rustc\]$/,/^$/s/^version = "\(.*\)"$/\1/p' <<< "$m")
		hash=$(sed -n '/^\[pkg\.rustc\]$/,/^$/s/^git_commit_hash = "\(.*\)"$/\1/p' <<< "$m")
		[ -n "$date" ] && [ -n "$release" ] && [ -n "$hash" ] || { echo "can't read the $name manifest" >&2; exit 1; }
		case $name in stable) tc=$release ;; nightly) tc=nightly-$date ;; esac
		build_archive "$name" "$tc" "$hash"
		echo "$name: $tc, rustc $release, commit $hash: $W/$name/archive.tar.gz"
	done
	exit 0
fi

rhome=$(ssh "${O[@]}" "$RS6" 'echo $HOME')
mapfile -t tcs < <(ssh "${O[@]}" "$RS6" rustup toolchain list | awk '{print $1}' | grep -- '-aarch64-unknown-linux-gnu$')
[ ${#tcs[@]} -gt 0 ] || { echo "no aarch64 rustup toolchains on the RS6" >&2; exit 1; }
ssh "${O[@]}" "$RS6" mkdir -p "$DESTDIR"
entries=()

for rtc in "${tcs[@]}"; do
	name=${rtc%-aarch64-unknown-linux-gnu}
	case $name in
	stable | nightly) ;;
	*) echo "skipping $rtc: only stable and nightly get archives" >&2; continue ;;
	esac
	rustc=$rhome/.rustup/toolchains/$rtc/bin/rustc
	read -r hash date release < <(ssh "${O[@]}" "$RS6" "$rustc" -vV |
		awk '/^commit-hash/{h=$2} /^commit-date/{d=$2} /^release/{r=$2} END{print h, d, r}')
	[ -n "$hash" ] || { echo "can't read $rtc's version" >&2; exit 1; }
	case $name in
	nightly) tc=nightly-$(date -u -d "$date + 1 day" +%F) ;;	# a nightly is published the day after its commit
	stable) tc=$release ;;
	esac
	build_archive "$name" "$tc" "$hash"
	d=$W/$name
	scp -q "${O[@]}" "$d/archive.tar.gz" "$RS6:$DESTDIR/rustc-x86_64-for-aarch64-$name.tar.gz"
	echo "$rtc: $tc ($hash)" >&2
	entries+=("[[dist.toolchains]]
type = \"path_override\"
compiler_executable = \"$rustc\"
archive = \"$rhome/$DESTDIR/rustc-x86_64-for-aarch64-$name.tar.gz\"
archive_compiler_executable = \"/toolchain/bin/rustc\"
")
done

echo "# ~/.config/sccache/config on the RS6: one entry per toolchain"
printf '%s\n' "${entries[@]}"
