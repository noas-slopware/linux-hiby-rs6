#!/bin/bash
# SPDX-License-Identifier: MIT
# mkxtools-rs6.sh: rebuild bens' exact AArch64 toolchain (gcc 16.2.1+r23+gd564253eb6c8, binutils 2.47,
# ccache 4.14.1) as x86_64 programs, for build-rs6.sh's RS6_ACCEL=xgcc: inside the qemu-user builder
# they replace bens' AArch64 binaries at the same paths and run natively (the kernel runs x86_64 ELF
# directly; only AArch64 ELF goes through binfmt_misc/qemu). Everything else in the container (make,
# cmake, ninja, moc, python, the libraries and headers, gcc's own crt files, libgcc, libstdc++ and
# include dirs) stays bens'. Same source and configure line as bens, so the same code comes out:
# the self-test at the end compiles and links C/C++ (LTO and not, -g) with bens' gcc under qemu and
# with these, and requires byte-identical objects, libraries and executables.
#   mkxtools-rs6.sh            -> $RS6_WORK/xtools (mounted read-only at /opt/rs6-xtools)
# Differences from bens' build that do not change output: host x86_64, C/C++/LTO only (gfortran & co.
# stay bens' AArch64 binaries under qemu), no bootstrap/PGO/LTO of the compiler itself,
# no debuginfod lookups in objdump/readelf. lib/ has Arch's x86_64 glibc with its iconv modules in
# lib/gconv; its libc.so.6 has /usr/lib/gconv (bens' AArch64 modules in the builder) replaced by
# /opt/rs6/gconv, which xtools-activate.sh links to lib/gconv. Two source patches make the cross tools keep native
# path logic: gcc without -DCROSS_DIRECTORY_STRUCTURE (same search dirs, include dirs, tool names as
# a native gcc, C++ headers in /usr/include/c++/16; the build system still treats it as a cross) and ld with genscripts.sh's NATIVE=yes
# (same SEARCH_DIRs, ld.so.conf/DT_RUNPATH lookups as a native ld). -march=native is unsupported (the
# host-CPU probe is only built into AArch64-hosted drivers); our packages must not use it anyway.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-rs6.sh"
[ "$HOSTARCH" = x86_64 ] || { echo "only for x86_64 hosts" >&2; exit 1; }

GCC_COMMIT=d564253eb6c859e266d3cae18e82fb4db9a88316	# Arch/bens gcc 16.2.1+r23+gd564253eb6c8-1
BINUTILS_TAG=binutils-2_47				# Arch/bens binutils 2.47-4 (6ce87bbc521c)
BINUTILS_COMMIT=6ce87bbc521cf46eaee9a1f7ef61cee2cdfb3e32
ARCH_GCC=https://gitlab.archlinux.org/archlinux/packaging/packages/gcc/-/raw/16.2.1+r23+gd564253eb6c8-1
ARCH_BINUTILS=https://gitlab.archlinux.org/archlinux/packaging/packages/binutils/-/raw/2.47-4
X=$W/xsrc
mkdir -p "$X"

# versions the builder image has; the tools are only used while they match (xtools-activate.sh)
read -r gccv binv ccachev fakerootv < <(builder localhost/rs6-builder sh -c \
	'for p in gcc binutils ccache fakeroot; do pacman -Q $p | cut -d" " -f2; done | tr "\n" " "; echo')
[ "$gccv" = 16.2.1+r23+gd564253eb6c8-1 ] && [ "${binv%-*}" = 2.47 ] ||
	{ echo "bens has gcc $gccv / binutils $binv now: update GCC_COMMIT/BINUTILS_* here" >&2; exit 1; }
log "bens: gcc $gccv, binutils $binv, ccache $ccachev, fakeroot $fakerootv"

# sources (fetcher: native, sandboxed pacman not needed, plain curl/git as the user)
fetch_user sh -euc '
	cd /w/xsrc
	[ -e gcc-$1.tar.gz ] || curl -fsSL -o gcc-$1.tar.gz.part https://codeload.github.com/gcc-mirror/gcc/tar.gz/$1 && \
		{ [ ! -e gcc-$1.tar.gz.part ] || mv gcc-$1.tar.gz.part gcc-$1.tar.gz; }
	[ -d binutils-gdb ] || git clone -q --depth 1 --branch $2 https://forge.sourceware.org/binutils-gdb/binutils-gdb-mirror binutils-gdb
	[ "$(git -C binutils-gdb rev-parse HEAD)" = $3 ]
	for f in tune_branch_prediction_cost.patch gcc-ada-repro.patch; do [ -e $f ] || curl -fsSL -o $f $4/$f; done
	[ -e gold-warn-unsupported.patch ] || curl -fsSL -o gold-warn-unsupported.patch $5/gold-warn-unsupported.patch
	echo "1773f5137f08ac1f48f0f7297e324d5d868d55201c03068670ee4602babdef2f  gcc-ada-repro.patch" | sha256sum -c --quiet
	echo "838e14d4ef76079107a5373316598025915eaf747a10522ec9f8842125ca9a8e  tune_branch_prediction_cost.patch" | sha256sum -c --quiet
	echo "2d430b66f84a19c154725ec535280c493be1d34f1a90f95208dce02fecd0e4e4  gold-warn-unsupported.patch" | sha256sum -c --quiet
	' sh "$GCC_COMMIT" "$BINUTILS_TAG" "$BINUTILS_COMMIT" "$ARCH_GCC" "$ARCH_BINUTILS"

# x86_64 build image: rs6-fetch + gcc's/binutils' build deps + Arch's x86_64 ccache and fakeroot (same
# versions as bens': libfakeroot.so must also be preloadable into the x86_64 strip/objcopy that makepkg
# runs under fakeroot, and it talks to bens' AArch64 faked over SysV IPC, same LP64 message layout)
if ! "$ENGINE" image inspect localhost/rs6-xbuild >/dev/null 2>&1; then
	c=rs6-xbuild-$$
	"$ENGINE" run --name "$c" --security-opt no-new-privileges localhost/rs6-fetch \
		pacman -Syu --noconfirm --needed gmp mpfr libmpc libisl zstd zlib jansson patchelf ccache
	"$ENGINE" commit "$c" localhost/rs6-xbuild >/dev/null; "$ENGINE" rm "$c" >/dev/null
fi
"$ENGINE" run --rm localhost/rs6-xbuild sh -c '[ "$(pacman -Q ccache fakeroot | cut -d" " -f2 | tr "\n" " ")" = "$1 $2 " ]' \
	sh "$ccachev" "$fakerootv" || { echo "x86_64 Arch ccache/fakeroot differ from bens' $ccachev/$fakerootv" >&2; exit 1; }

# bens glibc + kernel headers as the build sysroot for gcc's configure checks of the target libc
fetch_sync; fetch_pkgs core/glibc core/linux-api-headers >/dev/null
mapfile -t sysroot_pkgs < <(builder localhost/rs6-builder pacman -Q glibc linux-api-headers |
	while read -r n v; do echo "$n-$v-aarch64.pkg.tar.zst"; done)

if [ -e "$W/xbuild/stage/.done" ] && [ "$(cat "$W/xbuild/.for" 2>/dev/null)" = "$gccv $binv" ]; then
	log "binutils + gcc already built for $gccv / $binv"
else
log "building binutils + gcc (log: $W/logs/mkxtools.log)"
rm -rf "$W/xbuild"; mkdir -p "$W/xbuild"; echo "$gccv $binv" > "$W/xbuild/.for"
"$ENGINE" run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$W/xbuild:/xb" -v "$X:/xsrc:ro" \
	-v "$W/pkgcache:/pkgcache:ro" localhost/rs6-xbuild bash -euc '
	J=$(nproc); gcc=$1; shift
	mkdir -p /xb/sysroot
	for p; do bsdtar -xf /pkgcache/$p -C /xb/sysroot; done

	# binutils: Arch/bens configure line; host != target
	cp -a /xsrc/binutils-gdb /xb/binutils-src && cd /xb/binutils-src
	sed -i "/^development=/s/true/false/" bfd/development.sh
	patch -Np1 < /xsrc/gold-warn-unsupported.patch
	sed -i "s/^    if \[ \"x\${host}\" = \"x\${target}\" \] ; then/    if [ \"x\${host}\" = \"x\${target}\" ] || [ -n \"\${RS6_NATIVE_LD}\" ] ; then/" ld/genscripts.sh
	grep -q RS6_NATIVE_LD ld/genscripts.sh
	# at run time the libraries come from /opt/rs6-xtools/lib (DT_RPATH, searched before anything else;
	# the AArch64 /usr/lib of the builder comes later). Absent here, so the build uses this image libs.
	export LDFLAGS="-Wl,-rpath,/opt/rs6-xtools/lib -Wl,--disable-new-dtags"
	mkdir /xb/b-binutils && cd /xb/b-binutils
	/xb/binutils-src/configure --target=aarch64-unknown-linux-gnu \
		--prefix=/usr --sysconfdir=/etc --with-lib-path=/usr/lib:/usr/local/lib \
		--with-bugurl=https://gitlab.archlinux.org/archlinux/packaging/packages/binutils/-/issues \
		--enable-cet --enable-colored-disassembly --enable-default-execstack=no \
		--enable-deterministic-archives --enable-gold --enable-jansson --enable-ld=default \
		--enable-new-dtags --enable-plugins --enable-relro --enable-shared \
		--enable-targets=x86_64-pep,bpf-unknown-none --enable-threads \
		--disable-gdb --disable-gdbserver --disable-libdecnumber --disable-readline --disable-sim \
		--disable-werror --disable-gprofng --with-pic --with-system-zlib > /xb/binutils-configure.log
	RS6_NATIVE_LD=1 make -s -j$J tooldir=/usr > /xb/binutils-make.log 2>&1
	make -s DESTDIR=/xb/stage tooldir=/usr install > /dev/null 2>&1

	# gcc: Arch/bens configure line (bens: Arch minus ada), C/C++/LTO, no CROSS_DIRECTORY_STRUCTURE
	mkdir /xb/gcc-src && tar -xzf /xsrc/gcc-$gcc.tar.gz -C /xb/gcc-src --strip-components=1 && cd /xb/gcc-src
	sed -i "/m64=/s/lib64/lib/" gcc/config/i386/t-linux64
	# what bens does for AArch64 (its specs say "lp64:../lib"): libraries in /usr/lib, not lib64
	sed -i "/mabi.lp64=/s/lib64/lib/" gcc/config/aarch64/t-aarch64-linux
	grep -qF "mabi.lp64=../lib\$(call" gcc/config/aarch64/t-aarch64-linux
	patch -Np0 < /xsrc/gcc-ada-repro.patch
	patch -Np1 < /xsrc/tune_branch_prediction_cost.patch
	sed -i "s/^    CROSS=\"-DCROSS_DIRECTORY_STRUCTURE\"$/    CROSS=/" gcc/configure
	grep -q "^    CROSS=$" gcc/configure
	# and the C++ include dirs where a native gcc has them (/usr/include/c++/16, not under the target alias)
	sed -i -e '"'"'s|^       libstdcxx_incdir="$target_alias/$libstdcxx_incdir"$|       :|'"'"' \
		-e '"'"'s|^       libcxx_incdir="$target_alias/$libcxx_incdir"$|       :|'"'"' gcc/configure
	[ "$(grep -c '"'"'_incdir="$target_alias/'"'"' gcc/configure)" = 0 ]
	mkdir /xb/b-gcc && cd /xb/b-gcc
	# only the target-prefixed names: stage/usr/bin also has plain as/ld for AArch64
	export LD_LIBRARY_PATH=/xb/stage/usr/x86_64-pc-linux-gnu/aarch64-unknown-linux-gnu/lib:/xb/stage/usr/lib	# cross libbfd/libopcodes live in the former
	mkdir /xb/tbin && ln -s /xb/stage/usr/bin/aarch64-unknown-linux-gnu-* /xb/tbin/
	export PATH=/xb/tbin:$PATH
	CFLAGS="-O2 -pipe" CXXFLAGS="-O2 -pipe" /xb/gcc-src/configure \
		--build=x86_64-pc-linux-gnu --host=x86_64-pc-linux-gnu --target=aarch64-unknown-linux-gnu \
		--enable-languages=c,c++,lto --with-build-sysroot=/xb/sysroot \
		--prefix=/usr --libdir=/usr/lib --libexecdir=/usr/lib --mandir=/usr/share/man --infodir=/usr/share/info \
		--with-bugurl=https://gitlab.archlinux.org/archlinux/packaging/packages/gcc/-/issues \
		--with-gcc-major-version-only --with-linker-hash-style=gnu --with-system-zlib --enable-cet=auto \
		--enable-checking=release --enable-clocale=gnu --enable-default-pie --enable-default-ssp \
		--enable-gnu-indirect-function --enable-gnu-unique-object --enable-libstdcxx-backtrace \
		--enable-link-serialization=1 --enable-linker-build-id --enable-lto --enable-multilib \
		--enable-plugin --enable-shared --enable-threads=posix --disable-fixincludes --disable-libssp \
		--disable-libstdcxx-pch --disable-werror > /xb/gcc-configure.log
	make -s -j$J all-gcc all-lto-plugin all-c++tools > /xb/gcc-make.log 2>&1
	make -s DESTDIR=/xb/stage install-gcc install-lto-plugin install-c++tools > /dev/null 2>&1
	touch /xb/stage/.done
	' sh "$GCC_COMMIT" "${sysroot_pkgs[@]}" > "$W/logs/mkxtools.log" 2>&1 ||
	{ tail -30 "$W/logs/mkxtools.log"; tail -30 "$W"/xbuild/*-make.log; exit 1; }
fi

# assemble /opt/rs6-xtools: root/ mirrors the paths the tools take in the builder; lib/ is a private
# x86_64 glibc + the libraries they need (ld.so path and DT_RPATH point there, never at the
# container's AArch64 /usr/lib)
log "assembling $W/xtools"
rm -rf "$W/xtools.new"; mkdir -p "$W/xtools.new"
"$ENGINE" run --rm --user "$(id -u):$(id -g)" -v "$W/xbuild:/xb:ro" -v "$W/xtools.new:/xt" localhost/rs6-xbuild bash -euc '
	s=/xb/stage/usr; t=aarch64-unknown-linux-gnu; g=usr/lib/gcc/$t/16
	r=/xt/root; mkdir -p $r/usr/bin $r/$g $r/usr/lib/bfd-plugins /xt/lib
	for d in gcc g++ c++ cpp gcc-ar gcc-nm gcc-ranlib; do
		install -m755 $s/bin/$t-$d $r/usr/bin/$d; ln -f $r/usr/bin/$d $r/usr/bin/$t-$d; done
	ln -f $r/usr/bin/gcc $r/usr/bin/$t-gcc-16
	for f in cc1 cc1plus collect2 lto1 lto-wrapper g++-mapper-server liblto_plugin.so; do
		install -m755 /xb/stage/$g/$f $r/$g/$f; done
	for b in addr2line ar as c++filt elfedit ld ld.bfd ld.gold nm objcopy objdump ranlib readelf size strings strip; do
		install -m755 $s/bin/$t-$b $r/usr/bin/$b; ln -f $r/usr/bin/$b $r/usr/bin/$t-$b; done
	install -m755 $s/lib/bfd-plugins/libdep.so $r/usr/lib/bfd-plugins/libdep.so
	install -m755 /usr/bin/ccache $r/usr/bin/ccache
	# found through the DT_RPATH before LD_LIBRARY_PATH=/usr/lib/libfakeroot (AArch64) when fakeroot
	# preloads "libfakeroot.so" into one of these
	cp -L /usr/lib/libfakeroot/libfakeroot.so /xt/lib/libfakeroot.so
	# private runtime: everything these need, from this x86_64 Arch image
	export LD_LIBRARY_PATH=/xb/stage/usr/x86_64-pc-linux-gnu/aarch64-unknown-linux-gnu/lib:/xb/stage/usr/lib	# cross libbfd/libopcodes live in the former
	if find $r -type f -exec ldd {} \; 2>/dev/null | grep "not found"; then echo "unresolved libraries" >&2; exit 1; fi
	for f in $(find $r -type f); do ldd $f 2>/dev/null | sed -n "s/.*=> \(\/[^ ]*\) .*/\1/p;s/^\s*\(\/[^ ]*ld-linux[^ ]*\) .*/\1/p"; done |
		sort -u | while read -r l; do cp -L "$l" /xt/lib/; done
	# glibc dlopen()s the iconv modules of every charset it has no built-in converter for (ISO-8859-1,
	# EUC-KR...) from /usr/lib/gconv, which in the builder holds AArch64 ones: iconv_open() would fail
	# in every x86_64 program (gcc -finput-charset, guile in make, tar, python embedding iconv). Its own
	# modules go to lib/gconv, and this libc looks for them in /opt/rs6/gconv instead, the same length
	# as /usr/lib/gconv so only those bytes change (xtools-activate.sh links /opt/rs6/gconv to lib/gconv)
	cp -a /usr/lib/gconv /xt/lib/gconv
	[ ! -e /xt/lib/gconv/gconv-modules.cache ]	# would name /usr/lib/gconv; the config files do not
	[ "$(LC_ALL=C grep -c -a /opt/rs6/gconv /xt/lib/libc.so.6)" = 0 ]
	LC_ALL=C sed -i "s|/usr/lib/gconv|/opt/rs6/gconv|g" /xt/lib/libc.so.6
	[ "$(strings -a /xt/lib/libc.so.6 | grep -c "^/opt/rs6/gconv")" = 2 ] && ! LC_ALL=C grep -q -a /usr/lib/gconv /xt/lib/libc.so.6
	[ "$(stat -c %s /xt/lib/libc.so.6)" = "$(stat -c %s -L /usr/lib/libc.so.6)" ]
	# gcc/binutils got their DT_RPATH at link time; Arch'"'"'s ccache gets it here (only --set-rpath:
	# patchelf 0.19 breaks the gcc driver when it also moves PT_INTERP). The interpreter stays
	# /lib64/ld-linux-x86-64.so.2, which xtools-activate.sh points at lib/ (no AArch64 file has that name).
	patchelf --force-rpath --set-rpath /opt/rs6-xtools/lib $r/usr/bin/ccache
	for f in $(find $r -type f); do
		readelf -d $f | grep -q "(RPATH).*/opt/rs6-xtools/lib" || { echo "$f: no DT_RPATH /opt/rs6-xtools/lib" >&2; exit 1; }
	done
	'
printf 'gcc=%s\nbinutils=%s\nccache=%s\nfakeroot=%s\n' "$gccv" "$binv" "$ccachev" "$fakerootv" > "$W/xtools.new/.stamp"
rm -rf "$W/xtools"; mv "$W/xtools.new" "$W/xtools"

# self-test: bens gcc under qemu vs these, same inputs, byte-identical outputs required
log "self-test: bens gcc (qemu) vs xtools"
BUILDER_ARGS=(-v "$W/xtools:/opt/rs6-xtools:ro" -v "$TOOLS/xtools-activate.sh:/usr/local/bin/xtools-activate:ro"
	-v "$TOOLS/xtools-selftest.sh:/usr/local/bin/xtools-selftest:ro")
builder localhost/rs6-builder sh -euc 'xtools-selftest /tmp/native; xtools-activate; xtools-selftest /tmp/x
	cd /tmp/native; rc=0
	for f in *; do cmp -s "$f" "/tmp/x/$f" && continue; rc=1; echo "DIFFERS: $f"
		case $f in *.txt|*.s) diff "$f" "/tmp/x/$f" | head -20;; esac; done
	echo "$(ls | wc -l) outputs compared"; exit $rc' > "$W/logs/xtools-selftest.log" 2>&1 ||
	{ grep -v "^ " "$W/logs/xtools-selftest.log" | tail -40; echo "self-test FAILED: outputs differ" >&2; exit 1; }
tail -1 "$W/logs/xtools-selftest.log"
log "xtools ready: $(cat "$W/xtools/.stamp" | tr '\n' ' ')"

# rustc, clang and the x86_64 link sysroot for proc macros
"$TOOLS/mkxtools-rust-rs6.sh"
