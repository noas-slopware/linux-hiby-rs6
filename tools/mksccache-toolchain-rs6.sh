#!/bin/bash
# SPDX-License-Identifier: MIT
# mksccache-toolchain-rs6.sh: the sccache-dist toolchain archive that lets Gorakubu (x86_64) compile
# Rust crates for the RS6. sccache-dist runs a client's compiler from an archive inside bubblewrap,
# and Gorakubu can't run the RS6's AArch64 rustc, so the RS6's client config points its rustc at this
# archive instead (path_override): rustup's x86_64 build of the very same nightly, with the
# aarch64-unknown-linux-gnu std, plus every library it loads and its ELF interpreter, at /toolchain.
# sccache always passes --target=<client host> to distributed rustc, so it emits AArch64 code.
#
# Run it on Gorakubu after every rustup update on the RS6: it reads the RS6's rustc version over SSH,
# installs the matching dated nightly here, builds the archive and copies it to the RS6.
#   mksccache-toolchain-rs6.sh [ssh-target]   (default irohasakayori@cosmic-princess-kaguya)
#   RS6_SSH_OPTS="-o HostKeyAlias=..."         extra ssh/scp options
set -euo pipefail
RS6=${1:-irohasakayori@cosmic-princess-kaguya}
read -r -a O <<< "${RS6_SSH_OPTS:-}"
W=/var/tmp/rs6-sccache-toolchain
DEST=.local/share/rs6-sccache/rustc-x86_64-for-aarch64.tar.gz	# relative to the RS6 user's home

read -r hash date < <(ssh "${O[@]}" "$RS6" rustc -vV | awk '/^commit-hash/{h=$2} /^commit-date/{d=$2} END{print h, d}')
[ -n "$hash" ] && [ -n "$date" ] || { echo "can't read the RS6's rustc version" >&2; exit 1; }
# a nightly is published the day after its commit
tc=nightly-$(date -u -d "$date + 1 day" +%F)
rustup toolchain install "$tc" --profile minimal --target aarch64-unknown-linux-gnu >&2
have=$(rustc +"$tc" -vV | awk '/^commit-hash/{print $2}')
[ "$have" = "$hash" ] || { echo "$tc is $have, the RS6 runs $hash" >&2; exit 1; }
sysroot=$(rustc +"$tc" --print sysroot)

stamp=$W/stamp
if [ "$(cat "$stamp" 2>/dev/null)" != "$hash" ]; then
	rm -rf /var/tmp/rs6-sccache-toolchain/root /var/tmp/rs6-sccache-toolchain/archive.tar.gz
	mkdir -p "$W/root/toolchain/bin" "$W/root/toolchain/lib/rustlib"
	cp -a "$sysroot/bin/rustc" "$W/root/toolchain/bin/"
	cp -a "$sysroot"/lib/*.so* "$W/root/toolchain/lib/"
	cp -a "$sysroot/lib/rustlib/aarch64-unknown-linux-gnu" "$W/root/toolchain/lib/rustlib/"
	# the libraries rustc and its shared objects load, at their own paths, and the ELF interpreter
	# (the toolchain's own libraries are already in /toolchain/lib, found through rustc's $ORIGIN rpath)
	{ ldd "$sysroot/bin/rustc"; for f in "$sysroot"/lib/*.so*; do [ -L "$f" ] || ldd "$f" || true; done; } 2>/dev/null |
		awk '/=> \//{print $3} /^\s*\/.*ld-linux/{print $1}' | grep -v "^$sysroot/" | sort -u | while read -r lib; do
			mkdir -p "$W/root$(dirname "$lib")"
			cp -L "$lib" "$W/root$lib"
		done
	mkdir -p "$W/root/lib64" "$W/root/tmp" "$W/root/dev" "$W/root/proc"
	cp -L /lib64/ld-linux-x86-64.so.2 "$W/root/lib64/"
	tar -C "$W/root" --owner=0 --group=0 --numeric-owner -czf "$W/archive.tar.gz" .
	echo "$hash" > "$stamp"
fi

ssh "${O[@]}" "$RS6" mkdir -p "$(dirname "$DEST")"
scp -q "${O[@]}" "$W/archive.tar.gz" "$RS6:$DEST"
echo "toolchain $tc ($hash) at $RS6:~/$DEST"
