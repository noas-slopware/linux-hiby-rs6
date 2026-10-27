#!/bin/bash
# SPDX-License-Identifier: MIT
# mkxtools-rs6.sh: rebuild bens' exact AArch64 toolchain (gcc, binutils, ccache, at whatever versions
# bens' sync db has now) as x86_64 programs, for build-rs6.sh's RS6_ACCEL=xgcc: inside the qemu-user
# builder they replace bens' AArch64 binaries at the same paths and run natively (the kernel runs x86_64 ELF
# directly; only AArch64 ELF goes through binfmt_misc/qemu). Everything else in the container (make,
# cmake, ninja, moc, python, the libraries and headers, gcc's own crt files, libgcc, libstdc++ and
# include dirs) stays bens'. Same source and configure line as bens, so the same code comes out:
# the self-test at the end compiles and links C/C++ (LTO and not, -g) with bens' gcc under qemu and
# with these, and requires byte-identical objects, libraries and executables.
#   mkxtools-rs6.sh            -> $RS6_WORK/xtools (mounted read-only at /opt/rs6-xtools)
# Nothing in here names a version. bens' gcc/binutils/ccache/fakeroot versions come from the sync db;
# the source commit, the patches and their checksums from Arch's PKGBUILD at the tag of bens' version
# (bens builds Arch's binutils PKGBUILD as it is, and Arch's gcc PKGBUILD minus Ada plus one sed, below);
# the steps of its prepare() are replayed (only sed one-liners and patches: anything else stops here);
# gcc's configure flags are those bens' own gcc reports (gcc -v), binutils' those of the PKGBUILD's
# build(). build-rs6.sh reruns this whenever bens' versions move (lib-rs6.sh xtools_use).
# Differences from bens' build that do not change output: host x86_64, C/C++/LTO only (gfortran & co.
# stay bens' AArch64 binaries under qemu), no bootstrap/PGO/LTO of the compiler itself,
# no debuginfod lookups in objdump/readelf. lib/ has Arch's x86_64 glibc with its iconv modules in
# lib/gconv; its libc.so.6 has /usr/lib/gconv (bens' AArch64 modules in the builder) replaced by
# /opt/rs6/gconv, which xtools-activate.sh links to lib/gconv. Two source patches make the cross tools keep native
# path logic: gcc without -DCROSS_DIRECTORY_STRUCTURE (same search dirs, include dirs, tool names as
# a native gcc, C++ headers in /usr/include/c++/<major>; the build system still treats it as a cross) and ld
# with genscripts.sh's NATIVE=yes (same SEARCH_DIRs, ld.so.conf/DT_RUNPATH lookups as a native ld). -march=native is unsupported (the
# host-CPU probe is only built into AArch64-hosted drivers); our packages must not use it anyway.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-rs6.sh"
[ "$HOSTARCH" = x86_64 ] || { echo "only for x86_64 hosts" >&2; exit 1; }
xtools_lock
mkdir -p "$W/xsrc/pkgbuild"

# bens' versions now: the tools are only used while they match (xtools-activate.sh)
fetch_sync > /dev/null
declare -A B
while read -r n v; do B[$n]=$v; done < <(bens_versions)
gccv=${B[gcc]} binv=${B[binutils]} ccachev=${B[ccache]} fakerootv=${B[fakeroot]}
major=${gccv%%.*}
log "bens: gcc $gccv, binutils $binv, ccache $ccachev, fakeroot $fakerootv"

# Arch's PKGBUILDs at those tags (Arch tags spell an epoch's ":" as "-"), read without running them:
# the simple assignments and source/sha256sums arrays are evaluated in a throwaway container; the
# result, rs6.parsed, has "git <url> <commit>", "file <name> <sha256>", "sed <expr> <path>",
# "patch <-Npn> <name>" (prepare(), in order) and "configure <flags>" (build()'s configure call)
fetch_user bash -euo pipefail -c '
	for a; do
		n=${a%%=*} v=${a#*=} t=${a#*=}; t=${t/:/-}; d=/w/xsrc/pkgbuild/$n-$t
		[ -s "$d/rs6.parsed" ] && continue
		rm -rf "/w/xsrc/pkgbuild/$n-$t.part"; mkdir -p "/w/xsrc/pkgbuild/$n-$t.part"; cd "/w/xsrc/pkgbuild/$n-$t.part"
		raw=https://gitlab.archlinux.org/archlinux/packaging/packages/$n/-/raw/$t
		curl -fsSL -o PKGBUILD "$raw/PKGBUILD"
		(	epoch= pkgver= pkgrel= _commit=
			eval "$(grep -E "^(epoch|pkgver|pkgrel|_commit|_tag)=[A-Za-z0-9_.+-]*$" PKGBUILD)"
			[ "${epoch:+$epoch:}$pkgver-$pkgrel" = "$v" ] || { echo "$n PKGBUILD at $t is ${epoch:+$epoch:}$pkgver-$pkgrel" >&2; exit 1; }
			eval "$(sed -n "/^source=(/,/)/p" PKGBUILD)"; eval "$(sed -n "/^sha256sums=(/,/)/p" PKGBUILD)"
			[ ${#source[@]} = ${#sha256sums[@]} ]
			srcdir_name=
			for i in "${!source[@]}"; do
				s=${source[$i]}; name=; case $s in *::*) name=${s%%::*}; s=${s#*::};; esac
				case $s in
					git+*"#commit="*) u=${s#git+}; c=${u#*#commit=}; u=${u%%#*}; [ -n "$name" ] || { name=${u##*/}; name=${name%.git}; }
						srcdir_name=$name; echo "git $u $c $name";;
					*://*) echo "$n: source $s?" >&2; exit 1;;
					*) curl -fsSL -o "$s" "$raw/$s"; echo "${sha256sums[$i]}  $s" | sha256sum -c --quiet; echo "file $s ${sha256sums[$i]}";;
				esac
			done
			[ -n "$srcdir_name" ] || { echo "$n: no git source" >&2; exit 1; }
			sed -n "/^prepare() {$/,/^}$/p" PKGBUILD | sed "1d;\$d" | while IFS= read -r l; do
				l=$(printf "%s" "$l" | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")
				case $l in
					""|"#"*) ;;
					"[[ ! -d $srcdir_name ]] && ln -s "*) ;;		# makepkg source dir names
					"cd $srcdir_name"|"mkdir -p "*) ;;			# the steps run in the source tree
					"patch -Np"[01]" < "*) f=${l#*< }; f=${f//\"/}; f=${f##*/}; echo "patch ${l:6:4} $f";;
					*) if printf "%s\n" "$l" | grep -qE "^sed -i '"'"'[^'"'"']*'"'"' [A-Za-z0-9_./+-]+$"; then echo "sed ${l#sed -i }"
					   else echo "$n: prepare() has a step this script cannot replay: $l" >&2; exit 1; fi;;
				esac
			done
			# configure flags of build()'"'"'s configure call (gcc: bens'"'"' gcc -v instead, see below)
			f=$(sed -n "/^build() {$/,/^}$/p" PKGBUILD | sed -n "/\/configure \\\\$/,/[^\\\\]$/p" | sed "1d;s/\\\\$//" | tr -s " \n" "  ")
			echo "configure $f"
		) > rs6.parsed
		cd /; mv "/w/xsrc/pkgbuild/$n-$t.part" "$d"
	done' sh "gcc=$gccv" "binutils=$binv"
P=$W/xsrc/pkgbuild
pg=$P/gcc-${gccv/:/-}/rs6.parsed pb=$P/binutils-${binv/:/-}/rs6.parsed
read -r _ gcc_url gcc_commit _ < <(grep "^git " "$pg")
read -r _ bin_url bin_commit _ < <(grep "^git " "$pb")
# the version names its commit (…+g<12 hex>)
case $gccv in *+g"${gcc_commit:0:12}"-*) ;; *) echo "gcc $gccv is not commit $gcc_commit" >&2; exit 1;; esac
read -r -a bin_flags < <(sed -n "s/^configure //p" "$pb")
# no PGO/LTO of binutils itself (output unchanged), no debuginfod client (no lookups from objdump/readelf)
bin_flags=($(printf "%s\n" "${bin_flags[@]}" | grep -v -e "^--enable-pgo-build=" -e "^--with-debuginfod$") --without-debuginfod)
printf "%s\n" "${bin_flags[@]}" | grep -qvE "^--[a-z0-9-]+(=[A-Za-z0-9_.,:/+-]*)?$" &&
	{ echo "binutils configure flags: $(printf "%s\n" "${bin_flags[@]}" | grep -vE "^--[a-z0-9-]+(=[A-Za-z0-9_.,:/+-]*)?$")?" >&2; exit 1; }
printf "%s\n" "${bin_flags[@]}" | grep -qx -- --prefix=/usr || { echo "binutils: no configure flags found in its PKGBUILD" >&2; exit 1; }
log "Arch: gcc $gcc_commit, binutils $bin_commit; prepare: $(grep -c "^\(sed\|patch\) " "$pg") + $(grep -c "^\(sed\|patch\) " "$pb") steps"

# bens' gcc itself, current (pacman -Su as in a build): its configure line and multilib directory
mapfile -t probe < <(builder_current -- 'pacman -Q gcc binutils | tr "\n" " "; echo
	gcc -v 2>&1 | sed -n "s/^Configured with: //p"; gcc -print-multi-os-directory')
[ "${probe[0]}" = "gcc $gccv binutils $binv " ] || { echo "builder has ${probe[0]}, the sync db gcc $gccv binutils $binv" >&2; exit 1; }
# bens' configure flags minus the languages, bootstrap and its LTO build config (ours: C, C++, LTO, no bootstrap)
read -r -a gcc_flags <<< "${probe[1]}"
gcc_flags=($(printf "%s\n" "${gcc_flags[@]:1}" | grep -v -e "^--enable-languages=" -e "^--enable-bootstrap$" -e "^--with-build-config="))
printf "%s\n" "${gcc_flags[@]}" | grep -qvE "^--[a-z0-9-]+(=[A-Za-z0-9_.,:/+-]*)?$" &&
	{ echo "bens gcc configure flags: $(printf "%s\n" "${gcc_flags[@]}" | grep -vE "^--[a-z0-9-]+(=[A-Za-z0-9_.,:/+-]*)?$")?" >&2; exit 1; }
# bens' libraries are in /usr/lib (its specs say "lp64:../lib"): the one change bens makes to Arch's prepare()
[ "${probe[2]}" = ../lib ] || { echo "bens gcc -print-multi-os-directory: ${probe[2]}, not ../lib" >&2; exit 1; }

# sources at those commits (fetcher: native, plain git as the user)
fetch_user sh -euc '
	while [ $# -gt 0 ]; do [ -d "/w/xsrc/$1" ] || {
		rm -rf "/w/xsrc/$1.part"; git init -q "/w/xsrc/$1.part"; git -C "/w/xsrc/$1.part" fetch -q --depth 1 "$2" "$3"
		git -C "/w/xsrc/$1.part" -c advice.detachedHead=false checkout -q FETCH_HEAD; mv "/w/xsrc/$1.part" "/w/xsrc/$1"; }
		[ "$(git -C "/w/xsrc/$1" rev-parse HEAD)" = "$3" ]; shift 3; done' \
	sh "gcc-$gcc_commit" "$gcc_url" "$gcc_commit" "binutils-$bin_commit" "$bin_url" "$bin_commit"

# x86_64 build image: rs6-fetch + gcc's/binutils' build deps + Arch's x86_64 ccache and fakeroot of bens'
# versions (libfakeroot.so must also be preloadable into the x86_64 strip/objcopy that makepkg runs under
# fakeroot, and it talks to bens' AArch64 faked over SysV IPC, same LP64 message layout). Brought up to
# date on every run: its glibc and libraries become xtools/lib
c=rs6-xbuild-$$
"$ENGINE" image inspect localhost/rs6-xbuild > /dev/null 2>&1 && from=localhost/rs6-xbuild || from=localhost/rs6-fetch
"$ENGINE" run --name "$c" --security-opt no-new-privileges -e "XGET=$XGET" "$from" bash -euo pipefail -c '
	eval "$XGET"
	pacman -Syu --noconfirm --needed gmp mpfr libmpc libisl zstd zlib jansson patchelf git > /dev/null
	xget "ccache=$1" "fakeroot=$2"
	rm -rf /var/cache/pacman/pkg/*' sh "$ccachev" "$fakerootv"
"$ENGINE" commit "$c" localhost/rs6-xbuild > /dev/null; "$ENGINE" rm "$c" > /dev/null
xglibc=$("$ENGINE" run --rm localhost/rs6-xbuild pacman -Q glibc | cut -d" " -f2)

# bens glibc + kernel headers as the build sysroot for gcc's configure checks of the target libc
fetch_pkgs core/glibc core/linux-api-headers > /dev/null
sysroot_pkgs=("glibc-${B[glibc]}-aarch64.pkg.tar.zst" "linux-api-headers-${B[linux-api-headers]}-aarch64.pkg.tar.zst")

# the compiler build is reused while everything it is made from is the same
key=$({ echo "rev 2 gcc $gccv $gcc_commit binutils $binv $bin_commit"; cat "$pg" "$pb"; printf "%s\n" "${gcc_flags[@]}"
	"$ENGINE" run --rm localhost/rs6-xbuild pacman -Q gmp mpfr libmpc libisl zstd zlib jansson; } | sha256sum | cut -d" " -f1)
if [ -e "$W/xbuild/stage/.done" ] && [ "$(cat "$W/xbuild/.for" 2>/dev/null)" = "$key" ]; then
	log "binutils + gcc already built for $gccv / $binv"
else
log "building binutils + gcc (log: $W/logs/mkxtools.log)"
"$ENGINE" run --rm -v "$W:/w" localhost/rs6-xbuild sh -c 'rm -rf /w/xbuild && mkdir /w/xbuild && chown "$1" /w/xbuild' sh "$(id -u):$(id -g)"
echo "$key" > "$W/xbuild/.for"
"$ENGINE" run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$W/xbuild:/xb" -v "$W/xsrc:/xsrc:ro" \
	-v "$W/pkgcache:/pkgcache:ro" -e "GCC_FLAGS=${gcc_flags[*]}" -e "BIN_FLAGS=${bin_flags[*]}" localhost/rs6-xbuild bash -euc '
	J=$(nproc); gsrc=$1 bsrc=$2 gp=$3 bp=$4; shift 4
	mkdir -p /xb/sysroot
	for p; do bsdtar -xf /pkgcache/$p -C /xb/sysroot; done
	# Arch prepare(), replayed: its seds and patches, in order, in the source tree
	replay() {
		local k rest a b
		while read -r k rest; do case $k in
			sed) eval "sed -i $rest";;
			patch) read -r a b <<< "$rest"; patch "$a" < "${2%/*}/$b";;
		esac; done < "$2"
	}

	# binutils: Arch/bens configure line; host != target
	cp -a "/xsrc/$bsrc" /xb/binutils-src && cd /xb/binutils-src
	replay binutils "/xsrc/$bp"
	sed -i "s/^    if \[ \"x\${host}\" = \"x\${target}\" \] ; then/    if [ \"x\${host}\" = \"x\${target}\" ] || [ -n \"\${RS6_NATIVE_LD}\" ] ; then/" ld/genscripts.sh
	grep -q RS6_NATIVE_LD ld/genscripts.sh
	# at run time the libraries come from /opt/rs6-xtools/lib (DT_RPATH, searched before anything else;
	# the AArch64 /usr/lib of the builder comes later). Absent here, so the build uses this image libs.
	export LDFLAGS="-Wl,-rpath,/opt/rs6-xtools/lib -Wl,--disable-new-dtags"
	mkdir /xb/b-binutils && cd /xb/b-binutils
	/xb/binutils-src/configure --target=aarch64-unknown-linux-gnu $BIN_FLAGS > /xb/binutils-configure.log
	RS6_NATIVE_LD=1 make -s -j$J tooldir=/usr > /xb/binutils-make.log 2>&1
	make -s DESTDIR=/xb/stage tooldir=/usr install > /dev/null 2>&1

	# gcc: bens configure line (Arch minus ada), C/C++/LTO, no CROSS_DIRECTORY_STRUCTURE
	cp -a "/xsrc/$gsrc" /xb/gcc-src && cd /xb/gcc-src
	replay gcc "/xsrc/$gp"
	# what bens adds for AArch64 (its specs say "lp64:../lib"): libraries in /usr/lib, not lib64
	sed -i "/mabi.lp64=/s/lib64/lib/" gcc/config/aarch64/t-aarch64-linux
	grep -qF "mabi.lp64=../lib\$(call" gcc/config/aarch64/t-aarch64-linux
	sed -i "s/^    CROSS=\"-DCROSS_DIRECTORY_STRUCTURE\"$/    CROSS=/" gcc/configure
	grep -q "^    CROSS=$" gcc/configure
	# and the C++ include dirs where a native gcc has them (/usr/include/c++/<major>, not under the target alias)
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
		--enable-languages=c,c++,lto --with-build-sysroot=/xb/sysroot $GCC_FLAGS > /xb/gcc-configure.log
	make -s -j$J all-gcc all-lto-plugin all-c++tools > /xb/gcc-make.log 2>&1
	make -s DESTDIR=/xb/stage install-gcc install-lto-plugin install-c++tools > /dev/null 2>&1
	touch /xb/stage/.done
	' sh "gcc-$gcc_commit" "binutils-$bin_commit" "pkgbuild/gcc-${gccv/:/-}/rs6.parsed" "pkgbuild/binutils-${binv/:/-}/rs6.parsed" \
	"${sysroot_pkgs[@]}" > "$W/logs/mkxtools.log" 2>&1 ||
	{ tail -30 "$W/logs/mkxtools.log"; tail -30 "$W"/xbuild/*-make.log; exit 1; }
fi

# assemble /opt/rs6-xtools: root/ mirrors the paths the tools take in the builder; lib/ is a private
# x86_64 glibc + the libraries they need (ld.so path and DT_RPATH point there, never at the
# container's AArch64 /usr/lib)
log "assembling $W/xtools"
"$ENGINE" run --rm -v "$W:/w" localhost/rs6-xbuild sh -c 'rm -rf /w/xtools.new && mkdir /w/xtools.new && chown "$1" /w/xtools.new' sh "$(id -u):$(id -g)"
"$ENGINE" run --rm --user "$(id -u):$(id -g)" -v "$W/xbuild:/xb:ro" -v "$W/xtools.new:/xt" localhost/rs6-xbuild bash -euc '
	s=/xb/stage/usr; t=aarch64-unknown-linux-gnu; g=usr/lib/gcc/$t/$1
	r=/xt/root; mkdir -p $r/usr/bin $r/$g $r/usr/lib/bfd-plugins /xt/lib
	for d in gcc g++ c++ cpp gcc-ar gcc-nm gcc-ranlib; do
		install -m755 $s/bin/$t-$d $r/usr/bin/$d; ln -f $r/usr/bin/$d $r/usr/bin/$t-$d; done
	ln -f $r/usr/bin/gcc $r/usr/bin/$t-gcc-$1
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
	' sh "$major"
printf 'gcc=%s\nbinutils=%s\nccache=%s\nfakeroot=%s\nxglibc=%s\n' "$gccv" "$binv" "$ccachev" "$fakerootv" "$xglibc" > "$W/xtools.new/.stamp"

# self-test: bens gcc under qemu (brought up to date first) vs these, same inputs, byte-identical
# outputs required; still as xtools.new, mounted where the builds see xtools
log "self-test: bens gcc (qemu) vs xtools"
BUILDER_ARGS=(-v "$W/xtools.new:/opt/rs6-xtools:ro" -v "$TOOLS/xtools-activate.sh:/usr/local/bin/xtools-activate:ro"
	-v "$TOOLS/xtools-selftest.sh:/usr/local/bin/xtools-selftest:ro")
builder_current -- 'xtools-selftest /tmp/native; xtools-activate; xtools-selftest /tmp/x
	cd /tmp/native; rc=0
	for f in *; do cmp -s "$f" "/tmp/x/$f" && continue; rc=1; echo "DIFFERS: $f"
		case $f in *.txt|*.s) diff "$f" "/tmp/x/$f" | head -20;; esac; done
	echo "$(ls | wc -l) outputs compared"; exit $rc' > "$W/logs/xtools-selftest.log" 2>&1 ||
	{ grep -v "^ " "$W/logs/xtools-selftest.log" | tail -40; echo "self-test FAILED: outputs differ (xtools.new not used)" >&2; exit 1; }
BUILDER_ARGS=()
tail -1 "$W/logs/xtools-selftest.log"
# into place (no build runs: xtools_lock); rust/, clang and tools/ are made again on top of it below
"$ENGINE" run --rm -v "$W:/w" localhost/rs6-xbuild sh -euc 'rm -rf /w/xtools.old; [ ! -e /w/xtools ] || mv /w/xtools /w/xtools.old
	mv /w/xtools.new /w/xtools; rm -rf /w/xtools.old'
log "xtools ready: $(tr '\n' ' ' < "$W/xtools/.stamp")"

# rustc, clang and the x86_64 link sysroot for proc macros
"$TOOLS/mkxtools-rust-rs6.sh"
