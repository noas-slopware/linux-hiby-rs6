#!/usr/bin/env bash
# Import one pkgbase from the seed release (seed-from-local.sh): download its package files,
# check them against the sha256 sums in seed.json, run the arch branch's tools/check-armv8.0.py on
# them, and put them in <dest dir>. plan.py already checked that the seed's hash, version and split
# packages are the arch branch's.
#
#   import-seed.sh <arch branch checkout> <release tag> <seed.json> <pkgbase> <dest dir>
# Needs GH_TOKEN and the rs6-check image.
set -euo pipefail

src=$(realpath "$1")
tag=$2
seed=$3
pkg=$4
dest=$5
dl=$(mktemp -d)
mkdir -p "$dest"

python3 -I -c 'import json, sys
for f in json.load(open(sys.argv[1]))["packages"][sys.argv[2]]["files"]:
    print(f["sha256"], f["name"])' "$seed" "$pkg" > "$dl/SHA256SUMS"
cat "$dl/SHA256SUMS"
while read -r _sum name; do
	gh release download "$tag" --repo "$GITHUB_REPOSITORY" -p "$name" -D "$dl"
done < "$dl/SHA256SUMS"
(cd "$dl" && sha256sum -c SHA256SUMS)

docker run --rm --security-opt no-new-privileges -v "$dl:/out:ro" -v "$src/tools:/tools:ro" localhost/rs6-check \
	sh -c 'python3 -I /tools/check-armv8.0.py /out/*.pkg.tar.zst' | tail -n 40
while read -r _sum name; do
	cp "$dl/$name" "$dest/"
done < "$dl/SHA256SUMS"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "- \`$pkg\`: imported from the $tag release" >> "$GITHUB_STEP_SUMMARY"
ls -l "$dest"
