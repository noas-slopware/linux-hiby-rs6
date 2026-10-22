#!/usr/bin/env bash
# Build the given packages for aarch64, one 'pmbootstrap build' each, in the given order, and copy
# what was built to <out dir>. --no-depends: every fork a package needs must already be in the local
# repository (seed.sh); if one is missing or outdated, pmbootstrap stops instead of quietly building
# it here as well.
#
#   build.sh <out dir> <pkgname>...
set -euo pipefail

: "${NURA_WORK:?}"
out=$1
shift
repo=$NURA_WORK/packages/edge/aarch64
force=()
[ "${NURA_FORCE:-false}" = true ] && force=(--force)

marker=$(mktemp)
touch "$marker"
for pkg in "$@"; do
	echo "::group::pmbootstrap build $pkg"
	start=$(date +%s)
	pmbootstrap -y --details-to-stdout build --no-depends --arch aarch64 "${force[@]}" "$pkg"
	echo "::endgroup::"
	echo "$pkg built in $(( ($(date +%s) - start) / 60 )) min"
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		echo "- \`$pkg\`: $(( ($(date +%s) - start) / 60 )) min" >> "$GITHUB_STEP_SUMMARY"
	fi
done

mkdir -p "$out"
find "$repo" -maxdepth 1 -name '*.apk' -newer "$marker" -exec cp '{}' "$out/" ';'
rm -f "$marker"
ls -l "$out"
