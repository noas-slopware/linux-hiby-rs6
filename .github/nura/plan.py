#!/usr/bin/env python3
"""Decide what to do with each package of the pmos branch.

Every package gets an identity hash (../common/pkgid.py: its directory on pmos plus the pinned
pmbootstrap and pmaports commits) and one of:

  skip     the published repository has this build: built.json next to APKINDEX lists the package
           with this hash, and APKINDEX has it at that version
  restore  an earlier run built it and saved it in the actions cache (key nura-pkg-<name>-<hash>), but
           did not get to publish it (failed or cancelled): the restore job takes it from the cache
  build    neither: the group's job builds it, then saves it in the cache right away

--force builds everything. Versions come from 'pmbootstrap apkbuild_parse', so variables in APKBUILDs
are resolved the way pmbootstrap resolves them.

One-time migration: a repository published before built.json existed has no hashes. A package there is
adopted (skip, and its hash goes into built.json) only if its published version is the APKBUILD's, the
pins are the ones those runs used, and its directory at the pmos commit the site was published from
(index.html names it) is byte for byte the current one. Anything else is built.

Writes GitHub Actions outputs (to $GITHUB_OUTPUT, or stdout):
  build_<group>=true|false     whether the group's job has anything to build
  pkgs_<group>=<json>          [{"name", "key"}] to build in that job, in build order
  restore=<json>               [{"name", "key"}] to take from the actions cache
  any=true|false               whether there is anything to publish
  versions=<json>              {pkgname: version} of every package on the branch
  manifest=<json>              the built.json to publish when every job succeeds
and a summary table to $GITHUB_STEP_SUMMARY when set.
"""

import argparse
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import pkgid  # noqa: E402

# Build groups, one CI job each, in dependency order. A package's fork-dependencies must be in an
# earlier group (or earlier in the same group): qt6-qtbase builds against mesa-dev, the KDE
# packages against qt6-qtbase, plasma-mobile depends on plasma-keyboard, device-hiby-rs6 on the
# kernel, the firmware and rs6-spdif, rs6-dac-plasma on device-hiby-rs6 and plasma-mobile.
GROUPS = {
    "linux": ["linux-postmarketos-qcom-sdm660"],
    "mesa": ["mesa"],
    "base": ["firmware-hiby-rs6", "rs6-spdif", "mobile-config-firefox", "usb-moded-notify", "boot-deploy"],
    "qtbase": ["qt6-qtbase"],
    "device": ["device-hiby-rs6"],
    "kde": ["kiconthemes", "plasma-keyboard", "plasma-mobile", "elisa"],
    "dac": ["rs6-dac-plasma"],
}
# .github/actions/nura-build has one build + cache step pair per package slot
MAX_PER_GROUP = 6

# The pins of every run that published without built.json (ci 18fb663 and 5506710): migration only
LEGACY_PINS = ("7d23010a125ca7386fec4e390d14128b6c24d266", "767b10462fb3f0cb591e2e04c20dd2ed4d6e2568")


def apkbuild_parse(pkgname: str) -> dict:
    r = subprocess.run(["pmbootstrap", "apkbuild_parse", pkgname], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"pmbootstrap apkbuild_parse {pkgname} failed:\n{r.stdout}\n{r.stderr}")
    out = r.stdout
    # Output is "<pkgname>:\n{json}"
    return json.loads(out[out.index("{") :])


def published_index(url: str) -> dict:
    """{pkgname: version} of the published APKINDEX ({} when nothing is published)."""
    data = pkgid.fetch(url)
    if data is None:
        print(f"{url}: 404, nothing published yet", file=sys.stderr)
        return {}
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        text = tar.extractfile("APKINDEX").read().decode()
    versions = {}
    for block in text.split("\n\n"):
        fields = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
        if "P" in fields:
            versions[fields["P"]] = fields["V"]
    return versions


def legacy_hashes(pmos: str, site: str, dirs: dict, pmb: str, pmaports: str) -> dict:
    """{pkgname: hash} of each package's directory at the pmos commit the legacy site names."""
    if (pmb, pmaports) != LEGACY_PINS:
        print("migration: pins differ from the legacy runs', adopting nothing", file=sys.stderr)
        return {}
    page = pkgid.fetch(f"{site}/index.html")
    m = re.search(rb"commit <code>([0-9a-f]{40})</code>", page or b"")
    if not m:
        print("migration: published index.html names no pmos commit, adopting nothing", file=sys.stderr)
        return {}
    sha = m.group(1).decode()
    print(f"migration: published site was built from pmos {sha}", file=sys.stderr)
    git = ["git", "-C", pmos]
    if subprocess.run(git + ["cat-file", "-e", f"{sha}^{{commit}}"], capture_output=True).returncode:
        subprocess.run(git + ["fetch", "-q", "--depth", "1", "origin", sha], check=True)
    out = {}
    with tempfile.TemporaryDirectory() as tmp:
        for pkg, rel in dirs.items():
            dest = os.path.join(tmp, pkg)
            os.makedirs(dest)
            archive = subprocess.run(git + ["archive", sha, "--", rel], capture_output=True)
            if archive.returncode:
                continue  # not on the branch at that commit
            with tarfile.open(fileobj=io.BytesIO(archive.stdout)) as tar:
                tar.extractall(dest, filter="tar")
            if os.path.isdir(os.path.join(dest, rel)):
                out[pkg] = pkgid.nura_hash(os.path.join(dest, rel), pmb, pmaports)
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pmos", required=True, help="checkout of the pmos branch")
    ap.add_argument("--site", required=True, help="URL of the published site (has edge/aarch64/)")
    ap.add_argument("--force", action="store_true", help="build everything")
    args = ap.parse_args()
    pmb, pmaports = os.environ["PMB_COMMIT"], os.environ["PMAPORTS_COMMIT"]
    pmos_sha = subprocess.run(["git", "-C", args.pmos, "rev-parse", "HEAD"], capture_output=True,
                              text=True, check=True).stdout.strip()
    run_url = "{}/{}/actions/runs/{}".format(os.environ.get("GITHUB_SERVER_URL", "https://github.com"),
                                            os.environ.get("GITHUB_REPOSITORY", "local"),
                                            os.environ.get("GITHUB_RUN_ID", "0"))

    dirs = {}
    for root, _dirs, files in os.walk(args.pmos):
        if "APKBUILD" in files and "/.git" not in root:
            dirs[os.path.basename(root)] = os.path.relpath(root, args.pmos)
    grouped = {p for pkgs in GROUPS.values() for p in pkgs}
    if set(dirs) != grouped:
        sys.exit(
            "plan.py GROUPS does not match the pmos branch:"
            f" not grouped {sorted(set(dirs) - grouped)}, missing {sorted(grouped - set(dirs))}"
        )
    if max(len(p) for p in GROUPS.values()) > MAX_PER_GROUP:
        sys.exit(f"a group has more than {MAX_PER_GROUP} packages: add slots to nura-build")

    repo = f"{args.site}/edge/aarch64"
    index = published_index(f"{repo}/APKINDEX.tar.gz")
    manifest = pkgid.fetch_json(f"{repo}/built.json")
    legacy = {}
    if manifest is None:
        manifest = {"packages": {}}
        if index:
            legacy = legacy_hashes(args.pmos, args.site, dirs, pmb, pmaports)
    published = manifest.get("packages", {})
    cached = pkgid.cached_keys("nura-pkg-")

    new = {"format": 1, "pins": {"pmbootstrap": pmb, "pmaports": pmaports}, "packages": {}}
    versions, rows, outputs, restore = {}, [], {}, []
    for group, pkgs in GROUPS.items():
        todo = []
        for pkg in pkgs:
            apkbuild = apkbuild_parse(pkg)
            if apkbuild["pkgname"] != pkg:
                sys.exit(f"{pkg}: directory name and pkgname ({apkbuild['pkgname']}) differ")
            version = f"{apkbuild['pkgver']}-r{apkbuild['pkgrel']}"
            versions[pkg] = version
            h = pkgid.nura_hash(os.path.join(args.pmos, dirs[pkg]), pmb, pmaports)
            key = f"nura-pkg-{pkg}-{h}"
            entry = {"hash": h, "version": version, "dir": dirs[pkg], "pmos": pmos_sha, "run": run_url}
            have = published.get(pkg, {})
            if args.force:
                action = "build"
            elif have.get("hash") == h and have.get("version") == version and index.get(pkg) == version:
                action, entry = "skip", have
            elif legacy.get(pkg) == h and index.get(pkg) == version:
                action, entry["via"] = "adopt", "adopted from the site published before built.json"
            elif key in cached:
                action, entry["via"] = "restore", "actions cache"
            else:
                action, entry["via"] = "build", "built"
            if action == "build":
                todo.append({"name": pkg, "key": key})
            elif action == "restore":
                restore.append({"name": pkg, "key": key})
            new["packages"][pkg] = entry
            rows.append((group, pkg, version, index.get(pkg, "-"), h[:12], action))
        outputs[f"build_{group}"] = "true" if todo else "false"
        outputs[f"pkgs_{group}"] = json.dumps(todo)
    outputs["restore"] = json.dumps(restore)
    outputs["any"] = "true" if new["packages"] != published else "false"
    outputs["versions"] = json.dumps(versions, sort_keys=True)
    outputs["manifest"] = json.dumps(new, sort_keys=True)
    pkgid.write_outputs(outputs)

    table = "| job | package | pmos | published | hash | |\n|---|---|---|---|---|---|\n"
    table += "".join(f"| {g} | `{p}` | {v} | {pv} | `{h}` | {a} |\n" for g, p, v, pv, h, a in rows)
    counts = {a: sum(1 for r in rows if r[5] == a) for a in ("skip", "adopt", "restore", "build")}
    pkgid.write_summary("## Build plan\n\n" + ", ".join(f"{n} {a}" for a, n in counts.items() if n)
                        + "\n\n" + table)


if __name__ == "__main__":
    main()
