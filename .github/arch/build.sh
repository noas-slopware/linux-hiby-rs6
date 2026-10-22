#!/usr/bin/env bash
# Build one package of the arch branch in a fresh rs6-builder container (= a clean chroot), the way
# the arch branch's tools/build-rs6.sh does on a build host: pacman -Syu, the pkgbase's depends,
# makedepends and checkdepends from bens + [rs6], the sources' PGP keys by full fingerprint, then
# makepkg --cleanbuild as user builder with tools/makepkg-rs6.conf's flags. Natively, so pacman's
# download sandbox works and the container downloads itself (no separate fetcher).
# Then tools/check-armv8.0.py on every package file, and the non-debug packages, with ":" -> "." in
# their file names (as build-rs6.sh adds them to [rs6]), go to <dest dir>.
#
#   build.sh <arch branch checkout> <pkgbase> <dest dir>
set -euo pipefail

: "${ARCH_WORK:?}"
src=$(realpath "$1")
pkg=$2
dest=$3
[ -f "$src/$pkg/PKGBUILD" ] || { echo "$src/$pkg/PKGBUILD missing" >&2; exit 1; }
out=$(mktemp -d "$ARCH_WORK/out-$pkg.XXXXXX")
mkdir -p "$dest"

# what makepkg -s would install: depends, makedepends, checkdepends of the pkgbase (not the
# run-time depends of split packages: those are installed when the package is, not to build it)
srcinfo=$out.SRCINFO
docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$src/$pkg:/pkg:ro" localhost/rs6-builder \
	bash -euc 'cp -r /pkg /tmp/p && cd /tmp/p && makepkg --printsrcinfo' > "$srcinfo"
deps=$(awk '/^pkgname = /{exit} /^\t(makedepends|checkdepends|depends)(_aarch64)? = /{sub(/^\t[a-z_0-9]+ = /, ""); print}' "$srcinfo" | sort -u)
keys=$(sed -n 's/^\tvalidpgpkeys = //p' "$srcinfo" | sort -u)
echo "deps: $(echo $deps)"

start=$(date +%s)
echo "::group::makepkg $pkg"
docker run --rm --security-opt no-new-privileges -v "$src/$pkg:/pkg:ro" -v "$ARCH_WORK/repo:/repo:ro" \
	-v "$out:/out" -e DEPS="$deps" -e KEYS="$keys" localhost/rs6-builder bash -euo pipefail -c '
	set -f	# DEPS: one dependency per line, split on purpose; no globbing
	pacman -Syu --noconfirm
	[ -z "$DEPS" ] || pacman -S --needed --asdeps --noconfirm $DEPS
	runuser -u builder -- env HOME=/home/builder KEYS="$KEYS" bash -euc "for k in \$KEYS; do
		gpg -q --keyserver hkps://keyserver.ubuntu.com --recv-keys \"\$k\" ||
		gpg -q --keyserver hkps://keys.openpgp.org --recv-keys \"\$k\"; done"
	runuser -u builder -- env HOME=/home/builder bash -euc "cp -r /pkg ~/p && cd ~/p && PKGDEST=/out makepkg --noconfirm --cleanbuild"'
echo "::endgroup::"
echo "$pkg built in $(( ($(date +%s) - start) / 60 )) min"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "- \`$pkg\`: built in $(( ($(date +%s) - start) / 60 )) min" >> "$GITHUB_STEP_SUMMARY"
ls -l "$out"

echo "::group::check-armv8.0.py $pkg"
docker run --rm --security-opt no-new-privileges -v "$out:/out:ro" -v "$src/tools:/tools:ro" localhost/rs6-check \
	sh -c 'python3 -I /tools/check-armv8.0.py /out/*.pkg.tar.zst' | tee "$out.check" | tail -n 40
echo "::endgroup::"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "  $(tail -n 1 "$out.check")" >> "$GITHUB_STEP_SUMMARY"

for f in "$out"/*.pkg.tar.zst; do
	case $(basename "$f") in *-debug-*) continue ;; esac
	cp "$f" "$dest/$(basename "$f" | tr : .)"
done
ls -l "$dest"
