#!/bin/bash
# SPDX-License-Identifier: MIT
# mkxtools-tools-rs6.sh: the build tools around the compilers as native x86_64 programs for the
# rs6-builder container (RS6_ACCEL=xgcc), in $RS6_WORK/xtools/tools next to mkxtools-rs6.sh's gcc and
# binutils (mkxtools-rust-rs6.sh calls it at its end). Each one is Arch Linux's x86_64 package of exactly
# the version bens ships for AArch64 (same PKGBUILD, same source), taken from the Arch repos or, when they
# have moved on, the Arch archive (pacman checks the packager signatures either way):
#   tools     python ninja bison flex m4 zstd libarchive debugedit xz gzip make bash coreutils sed gawk
#             grep findutils diffutils tar bc cpio kmod file pahole fakeroot: their ELF programs in /usr/bin
#             (python: python3.14 and its lib-dynload modules; meson, Mesa's generators, sphinx and every
#             other python script then run natively; bash is /usr/bin/sh too, so makepkg, configure and
#             every shell script run natively, and so do make and the kernel's pahole -J per module;
#             fakeroot: faked) and the plugins and helpers only their own programs load (bash loadables
#             in /usr/lib/bash, gawk extensions in /usr/lib/gawk and /usr/lib/awk, tar's rmt)
#   modules   python-markupsafe python-yaml util-linux-libs libxml2 onetbb: only their python C modules,
#             so the native python can import everything the AArch64 one can
#   ctypes    clang-libs: libclang for the clang bindings (hawkmoth in mesa-docs)
# xtools-activate.sh puts them over bens' AArch64 binaries at the same paths, each only while bens'
# version (and the versions of the libraries it needs) still match. Everything else stays bens': shell
# scripts (gunzip, zcat, yacc, find-debuginfo, fakeroot), the python stdlib and site-packages (.py),
# bison's skeletons, magic.mgc, guile's .go files, the libraries in /usr/lib, and two libraries that are
# preloaded into whatever program comes next, whatever its architecture: libfakeroot.so (xtools/lib has
# the x86_64 one, found through DT_RPATH) and coreutils' libstdbuf.so (stdbuf names it by absolute path,
# so stdbuf's buffering change reaches AArch64 children only; x86_64 ones keep their default buffering
# and ld.so says it ignored the preload). perl stays bens' too: its XS modules (auto/POSIX/POSIX.so) carry no
# architecture in their names, so x86_64 ones cannot sit next to bens' as python's do. x86_64 python
# modules sit next to bens' AArch64 ones (other file names: .cpython-314-x86_64-linux-gnu.so). Their
# libraries are in tools/lib (DT_RPATH, before lib/, which has glibc and libfakeroot.so). Making the x86_64
# programs report what bens' report:
#   librs6-uname.so  first DT_NEEDED of every program: uname() says machine "aarch64", as qemu-user does,
#                    so uname -m (the kernel's SUBARCH, so ARCH=arm64), config.guess, platform.machine(),
#                    sysconfig.get_platform() and meson's build/host machine are aarch64 (a native
#                    build, not a cross build to x86_64)
#   sysconfig        xtools-activate.sh installs bens' _sysconfigdata__linux_aarch64-linux-gnu.py under the
#                    x86_64 name: EXT_SUFFIX, SOABI, CC, CFLAGS, MULTIARCH are the AArch64 python's
#                    (sys.implementation._multiarch itself stays x86_64-linux-gnu, so does the config dir
#                    name in sysconfig.get_makefile_filename(): a symlink to bens' config dir)
# and libclang gets librs6-clang-triple.so: its default target is aarch64-unknown-linux-gnu, as in bens'.
# What still says x86_64: names compiled into bash ($HOSTTYPE, $MACHTYPE, BASH_VERSINFO[5], --version)
# and make ($(MAKE_HOST), --version) as x86_64-pc-linux-gnu (nothing in makepkg or the kernel build reads
# them), /proc/cpuinfo (qemu-user fakes an AArch64 one for its guests only), and long double: coreutils'
# printf, seq, sort -g and numfmt and bash's printf compute in x86's 80-bit format instead of AArch64's
# 128-bit one, which shows from the 20th significant digit on.
# The self-test runs xtools-tools-selftest.sh with bens' tools under qemu and with these and requires
# identical outputs (the .hosttype ones: identical once x86_64-pc-linux-gnu reads aarch64-unknown-linux-gnu).
#   mkxtools-tools-rs6.sh      -> $RS6_WORK/xtools/tools (the builder sees /opt/rs6-xtools/tools), replaced
#                                 only by a set that passed the self-test
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-rs6.sh"
[ "$HOSTARCH" = x86_64 ] || { echo "only for x86_64 hosts" >&2; exit 1; }
[ -e "$W/xtools/.stamp" ] || { echo "run mkxtools-rs6.sh first" >&2; exit 1; }

TOOL_PKGS=(python ninja bison flex m4 zstd libarchive debugedit xz gzip make bash coreutils sed gawk grep
	findutils diffutils tar bc cpio kmod file pahole fakeroot)
MODULE_PKGS=(python-markupsafe python-yaml util-linux-libs libxml2 onetbb)
CTYPES_PKGS=(clang-libs)

# bens' versions, as the builder resolves them (core, then [rs6], then extra), read natively
bens=$(fetch_root "${PAC[@]}" -Sl | awk '!seen[$2]++ { print $1, $2, $3 }')
mapfile -t ours < <(for p in "${TOOL_PKGS[@]}" "${MODULE_PKGS[@]}" "${CTYPES_PKGS[@]}"; do
	awk -v p="$p" '$2 == p { print $1 "/" $2 }' <<< "$bens"; done)
[ ${#ours[@]} -eq $(( ${#TOOL_PKGS[@]} + ${#MODULE_PKGS[@]} + ${#CTYPES_PKGS[@]} )) ] ||
	{ echo "bens lacks one of ${TOOL_PKGS[*]} ${MODULE_PKGS[*]} ${CTYPES_PKGS[*]}" >&2; exit 1; }
log "bens: $(for p in "${ours[@]}"; do awk -v p="${p#*/}" '$2 == p { printf "%s %s, ", $2, $3 }' <<< "$bens"; done)"
# bens' own packages too: their python files are compared with Arch's below
fetch_pkgs "${ours[@]}" > /dev/null

log "x86_64 packages, $W/xtools/tools (log: $W/logs/mkxtools-tools.log)"
"$ENGINE" run --rm -i --security-opt no-new-privileges -v "$W/xtools:/xt" -v "$W/pkgcache:/pkgcache:ro" \
	-e "OWNER=$(id -u):$(id -g)" -e "TOOL_PKGS=${TOOL_PKGS[*]}" -e "MODULE_PKGS=${MODULE_PKGS[*]}" \
	-e "CTYPES_PKGS=${CTYPES_PKGS[*]}" localhost/rs6-xbuild bash -euo pipefail -c '
	declare -A B
	while read -r _ n v; do B[$n]=$v; done	# bens: name -> version
	# install these Arch x86_64 packages at bens versions: from the repos if they have it, else the archive
	get() {
		local n repo=() urls=()
		for n; do
			[ -n "${B[$n]:-}" ] || { echo "bens has no $n" >&2; return 1; }
			if [ "$(pacman -Sddp --print-format %v "$n" 2>/dev/null)" = "${B[$n]}" ]; then repo+=("$n")
			else urls+=("https://archive.archlinux.org/packages/${n:0:1}/$n/$n-${B[$n]}-x86_64.pkg.tar.zst"); fi
		done
		[ ${#repo[@]} -eq 0 ] || pacman -S --needed --noconfirm "${repo[@]}" > /dev/null
		[ ${#urls[@]} -eq 0 ] || pacman -U --needed --noconfirm "${urls[@]}" > /dev/null
	}
	is_elf() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(head -c4 "$1" | od -An -c | tr -d " ")" = 177ELF ]; }
	pacman -Sy --noconfirm > /dev/null
	get $TOOL_PKGS $MODULE_PKGS $CTYPES_PKGS
	for n in $TOOL_PKGS $MODULE_PKGS $CTYPES_PKGS; do
		[ "$(pacman -Q "$n" | cut -d" " -f2)" = "${B[$n]}" ] || { echo "$n: no x86_64 ${B[$n]}" >&2; exit 1; }
	done

	o=/xt/tools.new
	rm -rf /xt/tools.new
	mkdir -p /xt/tools.new/lib /xt/tools.new/pkg
	pyv=$(python3 -c "import sys; print(\"%d.%d\" % sys.version_info[:2])")
	# tools: ELF programs in /usr/bin, the python lib-dynload modules and the plugins and helpers that only
	# their own programs load; modules: python C modules only. Every other ELF file of a tool must be one
	# that stays bens on purpose (a new one fails here instead of staying AArch64 unnoticed):
	#   /usr/lib/lib*.so*            shared libraries (tools/lib gets the x86_64 ones the programs need)
	#   libstdbuf.so, libfakeroot    preloaded into the next program, whatever its architecture
	#   python config-*-x86_64-*     python.o for embedding builds; that config dir links to the bens one
	for n in $TOOL_PKGS $MODULE_PKGS; do
		case " $MODULE_PKGS " in *" $n "*) mod=1;; *) mod=;; esac
		mkdir -p "$o/pkg/$n"
		pacman -Qlq "$n" | while read -r f; do
			is_elf "$f" || continue
			if [ -n "$mod" ]; then case $f in /usr/lib/python$pyv/*.cpython-*-x86_64-linux-gnu.so) ;; *) continue;; esac
			else case $f in
				/usr/bin/*|/usr/lib/python$pyv/lib-dynload/*.cpython-*-x86_64-linux-gnu.so) ;;
				/usr/lib/bash/*|/usr/lib/gawk/*|/usr/lib/awk/*|/usr/lib/tar/*) ;;
				/usr/lib/lib*.so*|/usr/lib/coreutils/libstdbuf.so|/usr/lib/libfakeroot/*) continue;;
				/usr/lib/python$pyv/config-$pyv-x86_64-linux-gnu/*) continue;;
				*) echo "$n: $f is neither a program nor a plugin of its own programs nor known to stay bens" >&2; exit 1;;
			esac; fi
			install -D -m755 "$f" "$o/pkg/$n$f"
		done
	done
	# libclang for ctypes (clang.cindex loads "libclang.so"); its resource dir is ../lib/clang/<major>
	# next to it, which is bens (same version, the headers are the same on every target)
	l=$(pacman -Qlq clang-libs | grep -m1 "^/usr/lib/libclang\.so\.[0-9]*\.[0-9]*$")
	install -m755 "$l" "$o/lib/${l##*/}"; ln -s "${l##*/}" "$o/lib/libclang.so"; ln -s /usr/lib/clang "$o/lib/clang"
	# libclang reads no config files: its default target comes from libLLVM, which says x86_64. Its first
	# DT_NEEDED, librs6-clang-triple.so, answers aarch64-unknown-linux-gnu for it, as bens libLLVM does
	# (the same symbols and symbol version, found first in the libclang lookup scope)
	v=$(nm -D "$o/lib/${l##*/}" | sed -n "s/.*U _ZN4llvm3sys22getDefaultTargetTripleB5cxx11Ev@\(LLVM_[0-9.]*\)$/\1/p")
	[ -n "$v" ]
	printf "%s {\n global: _ZN4llvm3sys22getDefaultTargetTripleB5cxx11Ev; _ZN4llvm3sys16getProcessTripleB5cxx11Ev;\n local: *;\n};\n" "$v" > /tmp/triple.map
	printf "#include <string>\nnamespace llvm::sys {\nstd::string getDefaultTargetTriple() { return \"aarch64-unknown-linux-gnu\"; }\nstd::string getProcessTriple() { return \"aarch64-unknown-linux-gnu\"; }\n}\n" > /tmp/triple.cpp
	g++ -O2 -fPIC -shared -Wl,-soname,librs6-clang-triple.so -Wl,--version-script=/tmp/triple.map -o "$o/lib/librs6-clang-triple.so" /tmp/triple.cpp
	patchelf --add-needed librs6-clang-triple.so "$o/lib/${l##*/}"
	[ -z "$(find "$o/pkg" -type d -empty)" ] || { echo "no programs in: $(find "$o/pkg" -type d -empty)" >&2; exit 1; }

	# uname() of the native programs says aarch64, like the AArch64 ones under qemu-user
	cat > /tmp/rs6-uname.c <<-"EOF"
	#include <string.h>
	#include <sys/syscall.h>
	#include <sys/utsname.h>
	#include <unistd.h>
	int uname(struct utsname *u)
	{
		long r = syscall(SYS_uname, u);
		if (r == 0) {
			memset(u->machine, 0, sizeof(u->machine));
			strcpy(u->machine, "aarch64");
		}
		return r;
	}
	EOF
	gcc -O2 -fPIC -shared -Wl,-soname,librs6-uname.so -o "$o/lib/librs6-uname.so" /tmp/rs6-uname.c
	# into every program (whatever has an ELF interpreter): coreutils uname -m is the kernel SUBARCH
	find "$o/pkg" -type f | while read -r f; do readelf -lW "$f" | grep -q "Requesting program interpreter" || continue
		patchelf --add-needed librs6-uname.so "$f"
		[ "$(readelf -d "$f" | sed -n "s/.*(NEEDED).*\[\(.*\)\]/\1/p" | head -1)" = librs6-uname.so ] ||
			{ echo "$f: librs6-uname.so is not its first DT_NEEDED" >&2; exit 1; }
	done

	# the libraries they need, at bens versions too; glibc is lib/ (its ld.so is the ELF interpreter;
	# glibc libraries lib/ lacks come from the same glibc build, next to the others in tools/lib)
	glibc=" libc.so.6 libm.so.6 libmvec.so.1 ld-linux-x86-64.so.2 libdl.so.2 libpthread.so.0 librt.so.1 libutil.so.1 libresolv.so.2 libanl.so.1 "
	# (lib/libc.so.6 looks for its iconv modules in /opt/rs6/gconv: mkxtools-rs6.sh)
	for l in libc.so.6 ld-linux-x86-64.so.2 $glibc; do [ ! -e "/xt/lib/$l" ] ||
		cmp -s <(LC_ALL=C sed "s|/usr/lib/gconv|/opt/rs6/gconv|g" "/usr/lib/$l") "/xt/lib/$l" ||
		{ echo "x86_64 glibc moved past xtools/lib ($l): run mkxtools-rs6.sh" >&2; exit 1; }; done
	[ -e /xt/lib/gconv/gconv-modules ] || { echo "no iconv modules in xtools/lib: run mkxtools-rs6.sh" >&2; exit 1; }
	[ -e /xt/lib/libc.so.6 ] && [ -e /xt/lib/ld-linux-x86-64.so.2 ]
	needs() { LD_LIBRARY_PATH=$o/lib ldd "$@" 2>/dev/null | sed -n "s|^\s*\(\S*/\)\?\(\S*\) => \(/\S*\) .*|\2 \3|p" | sort -u; }
	elfs() { find "$@" -type f | while read -r f; do ! is_elf "$f" || echo "$f"; done; }
	for pass in 1 2; do
		mapfile -t libs < <(needs $(elfs "$o") | grep -v "^librs6-\(uname\|clang-triple\).so \| $o/")
		bad=()
		for l in "${libs[@]}"; do case $glibc in *" ${l%% *} "*) continue;; esac
			p=$(pacman -Qoq "${l#* }"); [ "$(pacman -Q "$p" | cut -d" " -f2)" = "${B[$p]:-}" ] || bad+=("$p"); done
		[ ${#bad[@]} -eq 0 ] && break
		[ $pass = 1 ] || { echo "no bens versions of ${bad[*]}" >&2; exit 1; }
		get $(printf "%s\n" "${bad[@]}" | sort -u)
	done
	for l in "${libs[@]}"; do case $glibc in *" ${l%% *} "*) [ ! -e "/xt/lib/${l%% *}" ] || continue;; esac
		cp -L "${l#* }" "$o/lib/${l%% *}"; done
	if needs $(elfs "$o") | grep -q "not found"; then echo "unresolved libraries" >&2; exit 1; fi
	# DT_RPATH (not RUNPATH: it also covers dlopen()ed modules and libfakeroot.so, which makepkg preloads)
	for f in $(elfs "$o"); do patchelf --force-rpath --set-rpath /opt/rs6-xtools/tools/lib:/opt/rs6-xtools/lib "$f"; done

	# the python files the native modules run with are bens: Arch has the same ones, byte for byte (a
	# wheel WHEEL names the architecture, its RECORD lists the C modules and WHEEL: the same apart from those)
	same() { case $1 in *.dist-info/RECORD|*.dist-info/WHEEL)
		cmp -s <(grep -v "\.so,\|/WHEEL," "$1") <(sed "s/x86_64/aarch64/g" "$2" | grep -v "\.so,\|/WHEEL,");; *) cmp -s "$1" "$2";; esac; }
	for n in python $MODULE_PKGS; do
		rm -rf /tmp/bens; mkdir /tmp/bens
		bsdtar -xf "/pkgcache/$n-${B[$n]}-aarch64.pkg.tar.zst" -C /tmp/bens "usr/lib/python$pyv"
		(cd /tmp/bens && find . -type f) | grep -v "/__pycache__/\|aarch64-linux-gnu\|/build-details\.json$" | sort > /tmp/bf
		pacman -Qlq "$n" | grep "^/usr/lib/python$pyv/.*[^/]$" | grep -v "/__pycache__/\|x86_64-linux-gnu\|/build-details\.json$" |
			while read -r f; do [ -L "$f" ] || echo ".$f"; done | sort > /tmp/af
		diff /tmp/bf /tmp/af || { echo "$n: other python files than bens" >&2; exit 1; }
		(cd /tmp/bens && while read -r f; do same "$f" "/${f#./}" || echo "$n: ${f#.} differs from bens"; done < /tmp/bf) | grep . && exit 1
	done

	# stamp: package, version, and the bens packages of the libraries each one loads (activation
	# requires the same versions where they are installed)
	for n in $TOOL_PKGS $MODULE_PKGS $CTYPES_PKGS; do
		case " $CTYPES_PKGS " in *" $n "*) set -- "$o/lib/libclang.so";; *) set -- $(elfs "$o/pkg/$n");; esac
		deps=$(needs "$@" | grep -v "^librs6-\(uname\|clang-triple\).so " | while read -r s p; do case $glibc in *" $s "*) continue;; esac
			q=$(pacman -Qoq "/usr/lib/$s"); [ "$q" = "$n" ] || echo "$q=${B[$q]}"; done | sort -u | tr "\n" " ")
		echo "$n ${B[$n]} $deps"
	done > "$o/.stamp"
	echo "pyv=$pyv" > "$o/.python"
	chown -R "$OWNER" /xt/tools.new
	cat /xt/tools.new/.stamp' <<< "$bens" > "$W/logs/mkxtools-tools.log" 2>&1 ||
	{ tail -30 "$W/logs/mkxtools-tools.log"; exit 1; }

# self-test: bens' tools (qemu) vs these (still tools.new, mounted where builds see tools/; they become
# tools/ only once it passes), same inputs, identical outputs required. The test needs a few
# packages in the builder (meson, mako, clang for the bindings, bc, pahole), resolved and downloaded like a
# build's deps
log "self-test: bens' tools (qemu) vs x86_64 (log: $W/logs/xtools-tools-selftest.log)"
TEST_PKGS=(meson ninja python-mako python-yaml python-markupsafe clang bison flex bc pahole)
mapfile -t list < <(resolve localhost/rs6-builder "${TEST_PKGS[@]}")
fetch_pkgs "${list[@]}" > /dev/null
mkdir -p "$W/xtools/tools"	# the mount point (an empty tools/ activates nothing)
BUILDER_ARGS=(-v "$W/xtools:/opt/rs6-xtools:ro" -v "$W/xtools/tools.new:/opt/rs6-xtools/tools:ro"
	-v "$TOOLS/xtools-activate.sh:/usr/local/bin/xtools-activate:ro"
	-v "$TOOLS/xtools-tools-selftest.sh:/usr/local/bin/xtools-tools-selftest:ro")
builder localhost/rs6-builder sh -euc 'pacman -S --needed --asdeps --noconfirm "$@" > /dev/null
	xtools-tools-selftest /tmp/qemu; xtools-activate; xtools-tools-selftest /tmp/x
	cd /tmp/qemu; rc=0
	for f in *; do
		# the host names compiled into bash and make are the one expected difference
		case $f in *.hosttype) sed "s/x86_64-pc-linux-gnu/aarch64-unknown-linux-gnu/g; s/x86_64/aarch64/g" "/tmp/x/$f" |
			cmp -s - "$f" && { cmp -s "$f" "/tmp/x/$f" || echo "known delta: $f: $(paste -sd"|" "/tmp/x/$f")"; continue; };; esac
		cmp -s "$f" "/tmp/x/$f" && continue; rc=1; echo "DIFFERS: $f"
		case $f in *.txt|*.json|*.c|*.h|*.ninja|*.hosttype) diff "$f" "/tmp/x/$f" | head -20;; esac; done
	echo "$(ls | wc -l) outputs compared"; exit $rc' sh "${TEST_PKGS[@]}" > "$W/logs/xtools-tools-selftest.log" 2>&1 ||
	{ grep -v "^ " "$W/logs/xtools-tools-selftest.log" | tail -40; echo "self-test FAILED: outputs differ (tools.new not used)" >&2; exit 1; }
grep "^xtools-activate\|^known delta\|outputs compared" "$W/logs/xtools-tools-selftest.log" >&2
# into place by renames (a build running now keeps what it activated; same versions at the same paths)
"$ENGINE" run --rm --user "$(id -u):$(id -g)" -v "$W/xtools:/xt" localhost/rs6-xbuild sh -euc \
	'rm -rf /xt/tools.old; mv /xt/tools /xt/tools.old; mv /xt/tools.new /xt/tools; rm -rf /xt/tools.old'
log "tools ready: $(cut -d' ' -f1,2 "$W/xtools/tools/.stamp" | tr '\n' ' ')"
