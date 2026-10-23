#!/bin/sh
# SPDX-License-Identifier: MIT
# xtools-activate.sh: inside an rs6-builder container (as root, after pacman -Su and the build deps),
# put the native x86_64 compilers from mkxtools-rs6.sh and mkxtools-rust-rs6.sh (mounted at
# /opt/rs6-xtools) over bens' AArch64 binaries, at the same paths, the way crossdirect does it:
#   gcc, binutils, ccache   always (bens' exact versions, rebuilt for x86_64)
#   rustc                   if bens' rust is installed: rs6-rustc on rustup's x86_64 rust (same version)
#   clang                   if bens' clang is installed: Arch's x86_64 clang (same version)
#   python ninja bison      Arch's x86_64 packages of bens' versions (mkxtools-tools-rs6.sh), each one
#   flex m4 zstd bsdtar     only while bens' version and those of the libraries it loads still match
#   debugedit xz gzip make  (else it stays AArch64, under qemu); python only if it can also load every
#   bash coreutils sed gawk python C module that bens' python can load here. bash is /usr/bin/sh too:
#   grep findutils diffutils from here on every shell script is native, this one excepted (its shell
#   tar bc cpio kmod file   was loaded before; install unlinks before it writes, so replacing running
#   pahole faked            programs is safe)
# Refuses if bens' gcc/binutils/ccache/fakeroot/rust/clang moved since they were built.
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
# and their libc loads its iconv modules from /opt/rs6/gconv (mkxtools-rs6.sh), not bens' /usr/lib/gconv
mkdir -p /opt/rs6; ln -sfn "$X/lib/gconv" /opt/rs6/gconv
msg="gcc $gcc, binutils $binutils, ccache $ccache"

# (mkxtools-rs6.sh's own self-test runs before mkxtools-rust-rs6.sh has made them)
rust= clang=
[ ! -e "$X/clang.stamp" ] || . "$X/clang.stamp"
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

T=$X/tools
if [ -e "$T/.stamp" ]; then
	. "$T/.python"
	pacman -Q > /tmp/xtools-installed
	q() { sed -n "s/^$1 //p" /tmp/xtools-installed; }
	ok=
	while read -r p v deps; do
		have=$(q "$p"); [ -n "$have" ] || continue
		why=; [ "$have" = "$v" ] || why="$p $have here"
		for d in $deps; do h=$(q "${d%%=*}"); [ -z "$h" ] || [ "$h" = "${d#*=}" ] || why="${why:+$why, }${d%%=*} $h here"; done
		if [ -n "$why" ]; then echo "xtools-activate: $p stays AArch64 ($why, x86_64 $p $v: run mkxtools-tools-rs6.sh)"; continue; fi
		ok="$ok $p"
	done < "$T/.stamp"
	put() { [ ! -d "$T/pkg/$1" ] || (cd "$T/pkg/$1" && find . -type f) | while read -r f; do install -p -m755 "$T/pkg/$1/$f" "/${f#./}"; done; }
	for p in $ok; do [ "$p" = python ] || put "$p"; done
	case " $ok " in *" python "*)
		# every AArch64 module needs its x86_64 twin, unless it cannot be loaded under qemu either
		block=
		for f in $(find "/usr/lib/python$pyv" -name "*.so" ! -name "*-x86_64-linux-gnu.so"); do
			t=${f%-aarch64-linux-gnu.so}-x86_64-linux-gnu.so
			[ "$t" != "$f" ] && { [ -e "$t" ] || [ -e "$T/pkg/python$t" ]; } && continue
			ldd "$f" 2>/dev/null | grep -q "not found" && continue
			block="$block ${f#/usr/lib/python$pyv/}"
		done
		case " $ok " in *" clang-libs "*) ;; *) [ -z "$(q clang-libs)" ] || block="$block libclang";; esac
		if [ -n "$block" ]; then echo "xtools-activate: python stays AArch64, no x86_64 build of:$block"
			ok=$(for p in $ok; do [ "$p" = python ] || printf " %s" "$p"; done)
		else
			put python
			# what bens' python says about itself (EXT_SUFFIX, SOABI, CC, CFLAGS, LIBPL...)
			for f in /usr/lib/python$pyv/_sysconfigdata_*_linux_aarch64-linux-gnu.py; do
				install -p -m644 "$f" "${f%_aarch64-linux-gnu.py}_x86_64-linux-gnu.py"; done
			ln -sfn "config-$pyv-aarch64-linux-gnu" "/usr/lib/python$pyv/config-$pyv-x86_64-linux-gnu"
			msg="$msg, python $(python3 -c 'import platform, sysconfig; print(platform.python_version(), "(" + sysconfig.get_platform(), sysconfig.get_config_var("SOABI") + ")")')"
		fi;;
	esac
	msg="$msg; x86_64 tools:$ok"
fi
echo "xtools-activate: native x86_64 $msg"
