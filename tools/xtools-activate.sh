#!/bin/sh
# SPDX-License-Identifier: MIT
# xtools-activate.sh: inside an rs6-builder container (as root, after pacman -Su and the build deps),
# put the native x86_64 compilers from mkxtools-rs6.sh and mkxtools-rust-rs6.sh (mounted at
# /opt/rs6-xtools) over bens' AArch64 binaries, at the same paths, the way crossdirect does it:
#   gcc, binutils, ccache   always (bens' exact versions, rebuilt for x86_64)
#   rustc                   if bens' rust is installed: rs6-rustc on rustup's x86_64 rust (same version)
#   clang                   if bens' clang is installed: Arch's x86_64 clang (same version)
# Refuses if bens' versions moved since they were built.
set -eu
X=/opt/rs6-xtools
. "$X/.stamp"
for p in gcc binutils ccache fakeroot; do
	have=$(pacman -Q "$p" | cut -d' ' -f2)
	eval want=\$$p
	[ "$have" = "$want" ] || { echo "xtools-activate: $p $have here, cross tools are for $want: run mkxtools-rs6.sh" >&2; exit 1; }
done
cd "$X/root"
# -p: ccache keys the compiler on its mtime+size (compiler_check=mtime), keep them stable
find . -type f | while read -r f; do install -p -m755 "$f" "/${f#./}"; done
# their ELF interpreter, /lib64/ld-linux-x86-64.so.2 (= /usr/lib here), is the x86_64 one in lib/
ln -sf "$X/lib/ld-linux-x86-64.so.2" /usr/lib/ld-linux-x86-64.so.2
msg="gcc $gcc, binutils $binutils, ccache $ccache"

. "$X/clang.stamp"
if pacman -Q rust >/dev/null 2>&1; then
	have=$(pacman -Q rust | cut -d' ' -f2)
	[ "$have" = "$rust" ] || { echo "xtools-activate: rust $have here, rs6-rustc is for $rust: run mkxtools-rust-rs6.sh" >&2; exit 1; }
	install -p -m755 "$X/rust/bin/rs6-rustc" /usr/bin/rustc
	msg="$msg, rustc $(rustc -V | cut -d' ' -f2) (host $(rustc -vV | sed -n 's/^host: //p'))"
fi
if pacman -Q clang >/dev/null 2>&1; then
	have=$(pacman -Q clang | cut -d' ' -f2)
	[ "$have" = "$clang" ] || { echo "xtools-activate: clang $have here, the x86_64 clang is $clang: run mkxtools-rust-rs6.sh" >&2; exit 1; }
	cd "$X/clang-root"
	find . -type f | while read -r f; do install -p -m755 "$f" "/${f#./}"; done
	msg="$msg, clang $(clang -dumpversion) (target $(clang -dumpmachine))"
fi
echo "xtools-activate: native x86_64 $msg"
