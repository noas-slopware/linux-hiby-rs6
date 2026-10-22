#!/usr/bin/env bash
# seed-from-local.sh: start the [rs6] repository from packages built locally (the arch branch's
# tools/build-rs6.sh), so the first CI run does not build them again.
#
# Pages is deployed by Actions only, so the packages go through a release: this script uploads them
# with a seed.json (per pkgbase: hash, version, files with pkgname and sha256) as the prerelease
# "arch-seed" and dispatches arch-packages.yml with seed=arch-seed. That run's plan imports every
# pkgbase whose seed hash is the hash of the arch branch's directory (and whose version and split
# packages match its .SRCINFO); the seed jobs check the sha256 sums and run tools/check-armv8.0.py,
# save the packages in the actions cache, and publish puts them on Pages (rs6.db, built.json) and
# on YuruMirror. Pkgbases that do not match (or were not built locally) are built by that run.
#
# Run it once the local build has finished and the arch branch is on GitHub, from a clone of the
# ci branch, with gh logged in as an account that can push to noas-slopware/linux-hiby-rs6:
#
#   git clone -b ci https://github.com/noas-slopware/linux-hiby-rs6 ~/rs6-ci
#   ~/rs6-ci/.github/arch/seed-from-local.sh /var/tmp/rs6-arch-build/repo ~/linux-rs6-pmos/arch
#   gh run list -R noas-slopware/linux-hiby-rs6 -w arch-packages.yml -L 3    # the dispatched run
#   gh run watch -R noas-slopware/linux-hiby-rs6 <run id> --exit-status
#   gh release delete arch-seed -R noas-slopware/linux-hiby-rs6 --cleanup-tag -y   # once it is green
#
#   seed-from-local.sh <dir with *.pkg.tar.zst> <arch dir the packages were built from>
#
# <arch dir> is the directory build-rs6.sh read the PKGBUILDs from: the hashes are computed from it
# (with .github/common/pkgid.py, the code CI uses), and a pkgbase whose directory (or
# tools/makepkg-rs6.conf, tools/pacman-rs6.conf) changed after its packages were built is left out.
# Each hash is also compared with the arch branch on GitHub; the script says which pkgbases CI will
# take from the seed and which it will build. -debug packages are not seeded (they are not in [rs6]
# either). Environment: REPO (default noas-slopware/linux-hiby-rs6), TAG (default arch-seed),
# DRY_RUN=1 to only show what would be seeded, NO_DISPATCH=1 to upload without starting the run.
set -euo pipefail

pkgs=$(realpath "${1:?usage: $0 <dir with *.pkg.tar.zst> <arch dir>}")
src=$(realpath "${2:?usage: $0 <dir with *.pkg.tar.zst> <arch dir>}")
here=$(cd "$(dirname "$0")" && pwd)
REPO=${REPO:-noas-slopware/linux-hiby-rs6}
TAG=${TAG:-arch-seed}
for t in gh git bsdtar python3 sha256sum; do
	command -v "$t" >/dev/null || { echo "needs $t" >&2; exit 1; }
done
gh auth status >/dev/null
[ -f "$src/tools/makepkg-rs6.conf" ] || { echo "$src is not an arch branch checkout (no tools/makepkg-rs6.conf)" >&2; exit 1; }
work=$(mktemp -d "${TMPDIR:-/var/tmp}/rs6-seed.XXXXXX")
echo "work dir: $work"

# the arch branch as it is on GitHub, for the comparison
git -C "$work" init -q branch
git -C "$work/branch" fetch -q --depth 1 "https://github.com/$REPO" arch ||
	{ echo "no arch branch on github.com/$REPO: push it first (CI hashes the branch, not this directory)" >&2; exit 1; }
mkdir "$work/tree"
git -C "$work/branch" archive FETCH_HEAD | tar -x -C "$work/tree"
echo "arch branch on GitHub: $(git -C "$work/branch" rev-parse FETCH_HEAD)"

# .PKGINFO of every package file
: > "$work/pkginfo.tsv"
shopt -s nullglob
for f in "$pkgs"/*.pkg.tar.zst; do
	info=$(bsdtar -xOf "$f" .PKGINFO)
	field() { sed -n "s/^$1 = //p" <<< "$info" | head -n 1; }
	printf '%s\t%s\t%s\t%s\n' "$(field pkgbase)" "$(field pkgname)" "$(field pkgver)" "$f" >> "$work/pkginfo.tsv"
done
[ -s "$work/pkginfo.tsv" ] || { echo "no *.pkg.tar.zst in $pkgs" >&2; exit 1; }

mkdir "$work/upload"
python3 -I - "$here/../common" "$src" "$work/tree" "$work/pkginfo.tsv" "$work/upload" "${SEED_IGNORE_MTIME:-}" <<'EOF'
import hashlib, json, os, sys
common, src, tree, tsv, upload, ignore_mtime = sys.argv[1:]
sys.path.insert(0, common)
import pkgid

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

bases = {}
for line in open(tsv):
    base, name, ver, path = line.rstrip("\n").split("\t")
    if name == f"{base}-debug":
        continue
    bases.setdefault(base, []).append((name, ver, path))

seed, rows = {}, []
for base, files in sorted(bases.items()):
    pkgdir = os.path.join(src, base)
    if not os.path.isfile(os.path.join(pkgdir, "PKGBUILD")):
        rows.append((base, "-", "left out: no PKGBUILD in the arch dir"))
        continue
    versions = {v for _, v, _ in files}
    if len(versions) != 1:
        rows.append((base, " ".join(sorted(versions)), "left out: more than one version in the repo dir"))
        continue
    inputs = [os.path.join(r, f) for r, _, fs in os.walk(pkgdir) for f in fs]
    inputs += [os.path.join(src, c) for c in pkgid.ARCH_CONFS]
    newest = max(os.lstat(p).st_mtime for p in inputs)
    built = min(os.stat(p).st_mtime for _, _, p in files)
    if newest > built and not ignore_mtime:
        rows.append((base, versions.pop(), "left out: its sources changed after the build (SEED_IGNORE_MTIME=1 overrides)"))
        continue
    h = pkgid.arch_hash(src, base)
    try:
        on_branch = pkgid.arch_hash(tree, base)
    except FileNotFoundError:
        on_branch = None
    entry = {"hash": h, "version": versions.pop(), "files": []}
    for name, _, path in sorted(files):
        fn = os.path.basename(path).replace(":", ".")
        os.symlink(path, os.path.join(upload, fn))
        entry["files"].append({"name": fn, "pkgname": name, "sha256": sha256(path), "size": os.path.getsize(path)})
    seed[base] = entry
    rows.append((base, entry["version"], "seeded" if on_branch == h else
                 "uploaded, but the arch branch on GitHub differs: CI will build it"))

with open(os.path.join(upload, "seed.json"), "w") as f:
    json.dump({"format": 1, "packages": seed}, f, indent=1, sort_keys=True)
w = max(len(b) for b, _, _ in rows)
for b, v, what in rows:
    print(f"{b:<{w}}  {v:<16}  {what}")
if not seed:
    sys.exit("nothing to seed")
EOF

n=$(find "$work/upload" -name '*.pkg.tar.zst' | wc -l)
if [ -n "${DRY_RUN:-}" ]; then
	echo "dry run: would upload $n packages ($(du -shL "$work/upload" | cut -f1)) and $work/upload/seed.json"
	exit 0
fi
echo "uploading $n packages ($(du -shL "$work/upload" | cut -f1)) as the $TAG release of $REPO"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
	gh release delete "$TAG" -R "$REPO" --cleanup-tag -y
fi
gh release create "$TAG" -R "$REPO" --prerelease --latest=false --target ci --title "Arch seed (locally built packages)" \
	--notes "Locally built [rs6] packages for arch-packages.yml to import (.github/arch/seed-from-local.sh). Not a release; delete it once the import run is green."
gh release upload "$TAG" -R "$REPO" "$work/upload"/*
if [ -n "${NO_DISPATCH:-}" ]; then
	echo "uploaded; start the import with: gh workflow run arch-packages.yml -R $REPO --ref ci -f seed=$TAG"
	exit 0
fi
gh workflow run arch-packages.yml -R "$REPO" --ref ci -f seed="$TAG"
echo "dispatched arch-packages.yml with seed=$TAG; find the run with:"
echo "  gh run list -R $REPO -w arch-packages.yml -L 3"
