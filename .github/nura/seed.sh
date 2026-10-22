#!/usr/bin/env bash
# Fill pmbootstrap's local repository (work/packages/edge/aarch64) with the published packages and
# the ones earlier jobs of this run built, then index it. pmbootstrap compares the APKBUILD versions
# with this index, so packages that are already built are not built again, and the build chroots
# install our forks (not Alpine's) as build dependencies.
#
# The published repository is <site>/main/aarch64 (upstream's layout: pmbootstrap and apk read
# <base>/main/<arch>/APKINDEX.tar.gz); a site from before that layout has it at <site>/edge/aarch64.
#
#   seed.sh <published site URL> [dir with apks from this run]
set -euo pipefail

: "${NURA_WORK:?}"
site=$1
run_apks=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
repo=$NURA_WORK/packages/edge/aarch64
tmp=$(mktemp -d)
mkdir -p "$tmp/apks"

url=$site/main
curl -fsSL --retry 3 -o "$tmp/APKINDEX.tar.gz" "$url/aarch64/APKINDEX.tar.gz" || url=$site/edge
if curl -fsSL --retry 3 -o "$tmp/APKINDEX.tar.gz" "$url/aarch64/APKINDEX.tar.gz"; then
	python3 -I "$here/apkindex.py" files "$tmp/APKINDEX.tar.gz" > "$tmp/files"
	echo "seed: $(wc -l < "$tmp/files") published packages"
	# shellcheck disable=SC2016
	xargs -P 8 -I '{}' curl -fsSL --retry 3 -o "$tmp/apks/{}" "$url/aarch64/{}" < "$tmp/files"
else
	echo "seed: nothing published at $site yet"
fi
if [ -n "$run_apks" ] && [ -d "$run_apks" ]; then
	n=$(find "$run_apks" -name '*.apk' | wc -l)
	echo "seed: $n packages from this run"
	find "$run_apks" -name '*.apk' -exec cp '{}' "$tmp/apks/" ';'
fi

sudo mkdir -p "$repo"
if compgen -G "$tmp/apks/*.apk" >/dev/null; then
	sudo cp "$tmp/apks/"*.apk "$repo/"
	sudo chown -R 12345:12345 "$NURA_WORK/packages"
	pmbootstrap -y --details-to-stdout index
fi
sudo chown -R 12345:12345 "$NURA_WORK/packages"
rm -rf "$tmp"
ls -l "$repo"
