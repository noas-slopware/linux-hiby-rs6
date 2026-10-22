#!/usr/bin/env bash
# Add package files to the [rs6] database in <repo dir> with bens' repo-add (in rs6-arch-base),
# creating it if needed, and make sure rs6.db and rs6.files exist. repo-add given no packages
# writes nothing at all, but pacman needs a database even for an empty repository: an empty
# archive is one.
#
#   repo-db.sh <repo dir> [package file name in <repo dir>]...
set -euo pipefail

repo=$(realpath "$1")
shift
if [ $# -gt 0 ]; then
	docker run --rm --user "$(id -u):$(id -g)" -v "$repo:/repo" -w /repo localhost/rs6-arch-base \
		repo-add -q rs6.db.tar.zst "$@"
fi
for db in rs6.db rs6.files; do
	[ -e "$repo/$db.tar.zst" ] || tar --zstd -cf "$repo/$db.tar.zst" -T /dev/null
	[ -e "$repo/$db" ] || ln -s "$db.tar.zst" "$repo/$db"
done
