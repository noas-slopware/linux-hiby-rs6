#!/usr/bin/env python3
"""Decide which packages of the pmos branch need building.

A package needs building when the published repository does not have it at the version of its
APKBUILD (pkgver-rpkgrel), or when --force is given. Versions come from 'pmbootstrap
apkbuild_parse', so variables in APKBUILDs are resolved the way pmbootstrap resolves them.

Writes GitHub Actions outputs (to $GITHUB_OUTPUT, or stdout):
  build_<group>=true|false     whether the group's job has anything to do
  pkgs_<group>=<names>         the packages to build in that job, in build order
  any=true|false
  versions=<json>              {pkgname: version} of every package on the branch
and a summary table to $GITHUB_STEP_SUMMARY when set.
"""

import argparse
import io
import json
import os
import subprocess
import sys
import tarfile
import urllib.error
import urllib.request

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


def apkbuild_parse(pkgname: str) -> dict:
    r = subprocess.run(["pmbootstrap", "apkbuild_parse", pkgname], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"pmbootstrap apkbuild_parse {pkgname} failed:\n{r.stdout}\n{r.stderr}")
    out = r.stdout
    # Output is "<pkgname>:\n{json}"
    return json.loads(out[out.index("{") :])


def published_versions(url: str) -> dict:
    try:
        with urllib.request.urlopen(url, timeout=60) as r:
            data = r.read()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print(f"{url}: 404, nothing published yet", file=sys.stderr)
            return {}
        raise
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        text = tar.extractfile("APKINDEX").read().decode()
    versions = {}
    for block in text.split("\n\n"):
        fields = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
        if "P" in fields:
            versions[fields["P"]] = fields["V"]
    return versions


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pmos", required=True, help="checkout of the pmos branch")
    ap.add_argument("--index", required=True, help="URL of the published APKINDEX.tar.gz")
    ap.add_argument("--force", action="store_true", help="build everything")
    args = ap.parse_args()

    on_branch = set()
    for root, _dirs, files in os.walk(args.pmos):
        if "APKBUILD" in files and "/.git" not in root:
            on_branch.add(os.path.basename(root))
    grouped = {p for pkgs in GROUPS.values() for p in pkgs}
    if on_branch != grouped:
        sys.exit(
            "plan.py GROUPS does not match the pmos branch:"
            f" not grouped {sorted(on_branch - grouped)}, missing {sorted(grouped - on_branch)}"
        )

    published = published_versions(args.index)
    versions = {}
    rows = []
    outputs = {}
    for group, pkgs in GROUPS.items():
        todo = []
        for pkg in pkgs:
            apkbuild = apkbuild_parse(pkg)
            if apkbuild["pkgname"] != pkg:
                sys.exit(f"{pkg}: directory name and pkgname ({apkbuild['pkgname']}) differ")
            version = f"{apkbuild['pkgver']}-r{apkbuild['pkgrel']}"
            versions[pkg] = version
            have = published.get(pkg)
            build = args.force or have != version
            if build:
                todo.append(pkg)
            rows.append((group, pkg, version, have or "-", "build" if build else "up to date"))
        outputs[f"build_{group}"] = "true" if todo else "false"
        outputs[f"pkgs_{group}"] = " ".join(todo)
    outputs["any"] = "true" if any(outputs[f"build_{g}"] == "true" for g in GROUPS) else "false"
    outputs["versions"] = json.dumps(versions, sort_keys=True)

    lines = "".join(f"{k}={v}\n" for k, v in outputs.items())
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(lines)
    else:
        sys.stdout.write(lines)

    table = "| job | package | pmos | published | |\n|---|---|---|---|---|\n"
    table += "".join(f"| {g} | `{p}` | {v} | {h} | {s} |\n" for g, p, v, h, s in rows)
    print(table, file=sys.stderr)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("## Build plan\n\n" + table)


if __name__ == "__main__":
    main()
