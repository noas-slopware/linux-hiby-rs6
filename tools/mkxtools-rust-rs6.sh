#!/bin/bash
# SPDX-License-Identifier: MIT
# mkxtools-rust-rs6.sh: the rest of the native x86_64 compilers for the rs6-builder container, next to
# mkxtools-rs6.sh's gcc/binutils in $RS6_WORK/xtools (mounted read-only at /opt/rs6-xtools; run it after
# mkxtools-rs6.sh, which calls it at its end). xtools-activate.sh installs them at the normal paths, so every
# compiler a package runs is native, the way pmbootstrap's crossdirect does it:
#   rust/     rustup's official rust toolchain for x86_64 of bens' rust version (sync db) with
#             rust-std for aarch64-unknown-linux-gnu and rust-src; bin/rs6-rustc (rs6-rustc/main.rs,
#             built on its rustc_driver) becomes /usr/bin/rustc: AArch64 by default, x86_64 twins
#             of rlibs and proc macros so proc macros load into the x86_64 compiler
#   x86_64/   link-only Arch x86_64 sysroot (gcc driver, collect2, ld.bfd, crt files, glibc, libgcc)
#             that rs6-rustc links the x86_64 proc-macro twins with
#   clang-root/usr/bin/clang-<major> + {x86_64-pc-linux-gnu-clang,-clang++}.cfg
#             Arch's x86_64 clang package of bens' exact version (sync db), default target
#             aarch64-unknown-linux-gnu
#             through clang's own default config file next to the binary; libraries in lib/
# At its end it runs mkxtools-tools-rs6.sh (the other build tools).
#   mkxtools-rust-rs6.sh
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-rs6.sh"
[ "$HOSTARCH" = x86_64 ] || { echo "only for x86_64 hosts" >&2; exit 1; }
xtools_lock
[ -e "$W/xtools/.stamp" ] || { echo "run mkxtools-rs6.sh first" >&2; exit 1; }
. "$W/xtools/.stamp"	# xglibc: the x86_64 glibc in xtools/lib

# bens' versions now (sync db): rustup toolchain = rust's upstream version (no epoch, no pkgrel)
fetch_sync > /dev/null
declare -A B
while read -r n v; do B[$n]=$v; done < <(bens_versions)
rustv=${B[rust]} clangv=${B[clang]}
RUST_VERSION=${rustv#*:}; RUST_VERSION=${RUST_VERSION%-*}
log "bens: rust $rustv, clang $clangv (clang-libs ${B[clang-libs]}, llvm-libs ${B[llvm-libs]})"

# rustup (Arch's package) in the x86_64 build image; RUSTUP_HOME in $W/rustup
mkdir -p "$W/rustup"
tc=$W/rustup/rustup/toolchains/$RUST_VERSION-x86_64-unknown-linux-gnu
if [ ! -x "$tc/bin/rustc" ]; then
	log "rustup: rust $RUST_VERSION (x86_64, + aarch64-unknown-linux-gnu std, rust-src, rustc-dev)"
	"$ENGINE" run --rm --security-opt no-new-privileges -v "$W/rustup:/r" -e RUSTUP_HOME=/r/rustup \
		-e CARGO_HOME=/r/cargo localhost/rs6-xbuild sh -euc '
		pacman -Sy --noconfirm --needed rustup >/dev/null
		rustup toolchain install "$1" --profile minimal --component rustc-dev,rust-src \
			--target aarch64-unknown-linux-gnu
		chown -R "$2" /r' sh "$RUST_VERSION" "$(id -u):$(id -g)"
fi

X=$W/xtools
# reruns (under xtools_lock, no build running): the toolchain is copied again when bens' rust moved,
# rs6-rustc and the x86_64 sysroot are installed over the old ones, clang-root/clang-lib are made anew
if [ "$(cat "$X/rust/.copied" 2>/dev/null)" != "$RUST_VERSION" ]; then
	log "copying the toolchain to $X/rust"
	# the toolchain minus rustc-dev (only needed to build rs6-rustc), its sources and rustup's docs
	"$ENGINE" run --rm -v "$X:/xt" localhost/rs6-xbuild sh -c 'rm -rf /xt/rust && mkdir /xt/rust && chown "$1" /xt/rust' sh "$(id -u):$(id -g)"
	(cd "$tc" && find . \( -path ./lib/rustlib/rustc-src -o -path ./share/doc \) -prune -o \( -type f -o -type l \) -print |
		grep -vxF -f <(sed -n 's|^file:|./|p' lib/rustlib/manifest-rustc-dev-x86_64-unknown-linux-gnu) |
		cpio -pdm --quiet "$X/rust")
	echo "$RUST_VERSION" > "$X/rust/.copied"
fi

"$ENGINE" run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$tc:/tc:ro" -v "$X:/xt" \
	-v "$TOOLS/rs6-rustc:/src:ro" localhost/rs6-xbuild bash -euc '
	# rs6-rustc: on the full toolchain (rustc-dev), installed into the stripped copy
	RUSTC_BOOTSTRAP=1 /tc/bin/rustc --edition 2024 -O -C debuginfo=0 /src/main.rs -o /tmp/rs6-rustc \
		-L native=/tc/lib -C link-arg=-Wl,--disable-new-dtags \
		-C link-arg=-Wl,-rpath,/opt/rs6-xtools/rust/lib:/opt/rs6-xtools/lib
	install -m755 /tmp/rs6-rustc /xt/rust/bin/rs6-rustc
	# the toolchain libraries find each other and the private x86_64 runtime, never the container'"'"'s
	# AArch64 /usr/lib (RPATH, not RUNPATH: RUNPATH would hide the executable'"'"'s)
	for f in /xt/rust/lib/*.so* /xt/rust/bin/rustc /xt/rust/bin/rustdoc /xt/rust/lib/rustlib/x86_64-unknown-linux-gnu/bin/* \
		/xt/rust/lib/rustlib/x86_64-unknown-linux-gnu/bin/gcc-ld/*; do
		[ -d "$f" ] && continue
		[ -L "$f" ] || [ "$(head -c4 "$f" | od -An -c | tr -d " ")" != "177ELF" ] || patchelf --force-rpath --set-rpath /opt/rs6-xtools/rust/lib:/opt/rs6-xtools/lib "$f"
	done
	for f in /xt/rust/bin/rs6-rustc /xt/rust/lib/*.so* /xt/rust/lib/rustlib/x86_64-unknown-linux-gnu/bin/rust-lld; do ldd "$f"; done 2>/dev/null |
		sed -n "s/.*=> \(\/usr\/lib\/[^ ]*\) .*/\1/p" | sort -u | while read -r l; do
		[ -e "/xt/lib/${l##*/}" ] || cp -L "$l" /xt/lib/; done
	# glibc'"'"'s compat stubs (rustc links them by name), same glibc as lib/libc.so.6
	for l in libdl.so.2 librt.so.1 libpthread.so.0 libutil.so.1; do cp -L /usr/lib/$l /xt/lib/; done

	# x86_64 link-only sysroot for the proc-macro twins (its tools run on its own usr/lib)
	r=/xt/x86_64; g=usr/lib/gcc/x86_64-pc-linux-gnu/$(gcc -dumpversion); bfd=$(cd /usr/lib && echo libbfd-*.so)
	[ -e "/usr/lib/$bfd" ] && [ -d "/$g" ]
	mkdir -p $r/usr/bin $r/$g
	install -m755 /usr/bin/gcc $r/usr/bin/gcc
	install -m755 /usr/bin/ld.bfd $r/usr/bin/ld
	for f in collect2 lto-wrapper liblto_plugin.so crtbegin.o crtbeginS.o crtbeginT.o crtend.o crtendS.o \
		libgcc.a libgcc_eh.a libgcc_s.so libgcc_s_asneeded.so; do cp -a /$g/$f $r/$g/; done
	for f in crt1.o Scrt1.o rcrt1.o crti.o crtn.o libc.so libc.so.6 libc_nonshared.a ld-linux-x86-64.so.2 \
		libm.so libm.so.6 libmvec.so.1 libpthread.so.0 libpthread.a libdl.so.2 libdl.a librt.so.1 librt.a \
		libutil.so.1 libutil.a libgcc_s.so.1 $bfd libctf.so.0 libjansson.so.4 libz.so.1 \
		libzstd.so.1 libsframe.so.3; do cp -L /usr/lib/$f $r/usr/lib/; done
	ln -sfn lib $r/usr/lib64
	for f in $r/usr/bin/gcc $r/usr/bin/ld $r/$g/collect2 $r/$g/lto-wrapper $r/usr/lib/$bfd \
		$r/usr/lib/libctf.so.0; do
		patchelf --force-rpath --set-rpath /opt/rs6-xtools/x86_64/usr/lib "$f"; done
	'

# clang: Arch's x86_64 packages (clang, clang-libs, llvm-libs) of exactly bens' versions (repos, else the
# Arch archive; pacman checks the signatures), installed into a throwaway rs6-xbuild container (root,
# for pacman's download sandbox)
log "clang $clangv (x86_64)"
rc=0
"$ENGINE" run --rm --security-opt no-new-privileges -v "$X:/xt" -e "XGET=$XGET" localhost/rs6-xbuild bash -euc '
	eval "$XGET"
	pacman -Sy --noconfirm > /dev/null
	xget "clang=$1" "clang-libs=$4" "llvm-libs=$5"
	v=$(pacman -Q clang | cut -d" " -f2); m=clang-${v%%.*}
	# installing clang must not have moved glibc past lib/ (rs6-xbuild glibc): exit 3, all of xtools again
	[ "$(pacman -Q glibc | cut -d" " -f2)" = "$2" ] || { echo "clang pulled glibc $(pacman -Q glibc), lib/ has $2" >&2; exit 3; }
	rm -rf /xt/clang-root /xt/clang-lib
	mkdir -p /xt/clang-root/usr/bin
	install -m755 /usr/bin/$m /xt/clang-root/usr/bin/$m
	# glibc (same version) comes from lib/, everything else Arch x86_64 clang needs from clang-lib/
	patchelf --force-rpath --set-rpath /opt/rs6-xtools/clang-lib:/opt/rs6-xtools/lib /xt/clang-root/usr/bin/$m
	mkdir -p /xt/clang-lib
	ldd /usr/bin/$m | sed -n "s/.*=> \(\/[^ ]*\) .*/\1/p" | grep -v -E "/(libc|libm|libdl|librt|libpthread)\.so|ld-linux" |
		while read -r l; do cp -L "$l" /xt/clang-lib/; done
	for f in /xt/clang-lib/*; do patchelf --force-rpath --set-rpath /opt/rs6-xtools/clang-lib:/opt/rs6-xtools/lib "$f"; done
	# clang reads <triple>-<driver>.cfg next to its binary when no --target is given
	for d in clang clang++; do printf -- "--target=aarch64-unknown-linux-gnu\n" > /xt/clang-root/usr/bin/x86_64-pc-linux-gnu-$d.cfg; done
	echo "clang=$v" > /xt/clang.stamp
	chown -R "$3" /xt/clang-root /xt/clang-lib /xt/clang.stamp' sh "$clangv" "$xglibc" "$(id -u):$(id -g)" \
	"${B[clang-libs]}" "${B[llvm-libs]}" || rc=$?
[ $rc -eq 0 ] || exit $rc
printf 'rust=%s\n' "$rustv" >> "$X/clang.stamp"
log "rust + clang ready: $(tr '\n' ' ' < "$X/clang.stamp")"

# python, make, bash, coreutils, pahole and the other build tools (mkxtools-tools-rs6.sh)
"$TOOLS/mkxtools-tools-rs6.sh"
