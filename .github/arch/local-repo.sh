#!/usr/bin/env bash
# Make $ARCH_WORK/repo, the [rs6] repository the build containers see at /repo: the published
# database (rs6.db from $ARCH_SITE/arch/aarch64, if there is one) with this run's packages added
# (dirs of *.pkg.tar.zst, e.g. the downloaded pkgs-<pkgbase> artifacts). Only this run's package
# files are in /repo; pacman fetches the published ones from Pages, the second [rs6] server.
#
#   local-repo.sh [dir with this run's packages]
set -euo pipefail

: "${ARCH_WORK:?}" "${ARCH_SITE:?}"
run_pkgs=${1:-}
repo=$ARCH_WORK/repo
mkdir -p "$repo"
dl=$(mktemp -d)
if curl -fsSL --retry 3 -o "$dl/rs6.db.tar.zst" "$ARCH_SITE/arch/aarch64/rs6.db.tar.zst" &&
	curl -fsSL --retry 3 -o "$dl/rs6.files.tar.zst" "$ARCH_SITE/arch/aarch64/rs6.files.tar.zst"; then
	mv "$dl/rs6.db.tar.zst" "$dl/rs6.files.tar.zst" "$repo/"
	echo "local repo: the published database"
else
	echo "local repo: nothing published at $ARCH_SITE/arch/aarch64 yet"
fi
new=()
if [ -n "$run_pkgs" ] && [ -d "$run_pkgs" ]; then
	while IFS= read -r -d '' f; do
		cp "$f" "$repo/"
		new+=("$(basename "$f")")
	done < <(find "$run_pkgs" -name '*.pkg.tar.zst' -print0)
fi
echo "local repo: ${#new[@]} packages from this run"
"$(dirname "$0")/repo-db.sh" "$repo" "${new[@]}"
chmod -R a+rX "$repo"
ls -l "$repo"
