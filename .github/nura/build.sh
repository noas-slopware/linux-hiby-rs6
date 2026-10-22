#!/usr/bin/env bash
# Build one package for aarch64 with 'pmbootstrap build', and copy what it built (the package and its
# subpackages) to <out dir> (this job's artifact) and to $NURA_PKGCACHE/<pkgname>/ (what the next
# step saves in the actions cache under the package's hash). Always --force: plan.py decided that
# this build is needed, also when the local repository already has the same version (a source
# changed without a pkgrel bump). --no-depends: every fork a package
# needs must already be in the local repository (seed.sh); if one is missing or outdated, pmbootstrap
# stops instead of quietly building it here as well.
#
#   build.sh <out dir> <pkgname>
set -euo pipefail

: "${NURA_WORK:?}" "${NURA_PKGCACHE:?}"
out=$1
pkg=$2
repo=$NURA_WORK/packages/edge/aarch64

marker=$(mktemp)
touch "$marker"
echo "::group::pmbootstrap build $pkg"
start=$(date +%s)
pmbootstrap -y --details-to-stdout build --no-depends --force --arch aarch64 "$pkg"
echo "::endgroup::"
echo "$pkg built in $(( ($(date +%s) - start) / 60 )) min"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
	echo "- \`$pkg\`: $(( ($(date +%s) - start) / 60 )) min" >> "$GITHUB_STEP_SUMMARY"
fi

mkdir -p "$out" "$NURA_PKGCACHE/$pkg"
find "$repo" -maxdepth 1 -name '*.apk' -newer "$marker" -exec cp '{}' "$out/" ';' \
	-exec cp '{}' "$NURA_PKGCACHE/$pkg/" ';'
if ! compgen -G "$NURA_PKGCACHE/$pkg/*.apk" >/dev/null; then
	echo "$pkg: pmbootstrap built nothing" >&2
	exit 1
fi
ls -l "$NURA_PKGCACHE/$pkg"
