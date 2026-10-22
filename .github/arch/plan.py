#!/usr/bin/env python3
"""Decide what to do with each package (pkgbase directory) of the arch branch.

Every pkgbase gets an identity hash (../common/pkgid.py: its directory plus tools/makepkg-rs6.conf
and tools/pacman-rs6.conf) and one of:

  skip     the published repository has this build: built.json next to rs6.db lists the pkgbase
           with this hash, and every file it lists is in the repository (packages.txt)
  restore  an earlier run built (or imported) it and saved it in the actions cache (key
           arch-pkg-<pkgbase>-<hash>) but did not publish it: the restore job takes it from there
  seed     the seed release (--seed, made by seed-from-local.sh) has it, built locally from a
           directory with this same hash, at this version and with every split package: the seed
           job imports it after checking it
  build    none of these: a level job builds it

--force builds everything. The dependency levels come from the .SRCINFO files: a pkgbase is in a later level than
every pkgbase whose packages its build installs (its depends, makedepends and checkdepends, as
makepkg -s installs them, plus their run-time depends when those are ours), and its job only builds
once those are available from this run or published.

Writes plan.json (everything publish.py needs) and GitHub Actions outputs:
  level0 .. level4=<json>   [{"name", "key", "after"}] to build per level ("after": pkgbases of this
                            run it needs)
  restore=<json>, seed=<json>  [{"name", "key"}]
  any=true|false            whether there is anything to publish
"""

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import pkgid  # noqa: E402

LEVELS = 5  # level jobs in arch-packages.yml
DEP_FIELDS = re.compile(r"^(make|check|)depends(_aarch64)?$")


def parse_srcinfo(path: str) -> dict:
    """pkgbase, pkgnames, version; build deps (the pkgbase's depends, makedepends, checkdepends:
    what makepkg -s installs); for every split package its run-time depends and provides (its own
    when it overrides them, else the pkgbase's)."""
    sections, cur = {}, None
    base = None
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        m = re.match(r"^(\t?)(\S+) =(?: (.*))?$", line)
        if not m:
            continue
        indent, key, value = m.group(1), m.group(2), m.group(3) or ""
        if not indent:
            if key == "pkgbase":
                base, cur = value, "@base"
            elif key == "pkgname":
                cur = value
            sections.setdefault(cur, {})
            continue
        sections[cur].setdefault(key, []).append(value)
    g = sections.get("@base", {})
    names = [n for n in sections if n != "@base"]
    version = f"{g['pkgver'][0]}-{g['pkgrel'][0]}"
    if g.get("epoch", [""])[0]:
        version = f"{g['epoch'][0]}:{version}"

    def field(sec: dict, *keys: str) -> list[str]:
        return [v for k in keys for v in sec.get(k, []) if v]

    build = sorted(set(field(g, "depends", "depends_aarch64", "makedepends", "makedepends_aarch64",
                             "checkdepends", "checkdepends_aarch64")))
    runtime, provides = {}, []
    for n in names:
        sec = sections[n]
        dk = ("depends", "depends_aarch64")
        runtime[n] = field(sec if any(k in sec for k in dk) else g, *dk)
        pk = ("provides", "provides_aarch64")
        provides += field(sec if any(k in sec for k in pk) else g, *pk)
    return {"pkgbase": base, "pkgnames": names, "version": version, "build_deps": build,
            "runtime": runtime, "provides": sorted(set(provides))}


def bare(dep: str) -> str:
    return re.split(r"[<>=]", dep, maxsplit=1)[0]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", required=True, help="checkout of the arch branch")
    ap.add_argument("--srcinfo", required=True, help="dir with <pkgbase>.SRCINFO (CARCH=aarch64)")
    ap.add_argument("--site", required=True, help="URL of the published site (has arch/aarch64/)")
    ap.add_argument("--seed", default="", help="seed.json of the seed release")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--out", required=True, help="plan.json to write")
    args = ap.parse_args()

    bases = sorted(d for d in os.listdir(args.arch)
                   if os.path.isfile(os.path.join(args.arch, d, "PKGBUILD")))
    info = {}
    for b in bases:
        si = parse_srcinfo(os.path.join(args.srcinfo, f"{b}.SRCINFO"))
        if si["pkgbase"] != b:
            sys.exit(f"{b}: directory name and pkgbase ({si['pkgbase']}) differ")
        si["hash"] = pkgid.arch_hash(args.arch, b)
        si["key"] = f"arch-pkg-{b}-{si['hash']}"
        info[b] = si

    # dependency levels: a pkgbase needs every pkgbase whose package it installs to build, i.e. its
    # build deps and, since installing one of our packages pulls in its run-time depends, theirs
    producer, runtime = {}, {}
    for b, si in info.items():
        for n in si["pkgnames"] + [bare(p) for p in si["provides"]]:
            producer.setdefault(n, b)
        runtime.update(si["runtime"])
    for b, si in info.items():
        needs, todo, seen = set(), [bare(d) for d in si["build_deps"]], set()
        while todo:
            n = todo.pop()
            if n in seen or n not in producer:
                continue
            seen.add(n)
            needs.add(producer[n])
            todo += [bare(d) for d in runtime.get(n, [])]
        si["needs"] = sorted(needs - {b})
    level = {}

    def lvl(b: str, stack: tuple = ()) -> int:
        if b in stack:
            sys.exit(f"dependency cycle: {' -> '.join(stack + (b,))}")
        if b not in level:
            level[b] = 1 + max((lvl(d, stack + (b,)) for d in info[b]["needs"]), default=-1)
        return level[b]

    for b in bases:
        info[b]["level"] = lvl(b)
    if max(level.values(), default=0) >= LEVELS:
        sys.exit(f"more than {LEVELS} dependency levels: add level jobs to arch-packages.yml")

    repo = f"{args.site}/arch/aarch64"
    manifest = pkgid.fetch_json(f"{repo}/built.json") or {"packages": {}}
    published = manifest.get("packages", {})
    listing = pkgid.fetch(f"{repo}/packages.txt")
    in_repo = set(listing.decode().split()) if listing else set()
    cached = pkgid.cached_keys("arch-pkg-")
    seed = {}
    if args.seed:
        with open(args.seed) as f:
            seed = json.load(f).get("packages", {})

    rows = []
    for b in bases:
        si = info[b]
        have = published.get(b, {})
        s = seed.get(b)
        seed_ok, why = False, ""
        if s:
            seed_names = sorted(f["pkgname"] for f in s.get("files", []))
            if s.get("hash") != si["hash"]:
                why = "seed: other hash"
            elif s.get("version") != si["version"]:
                why = f"seed: version {s.get('version')}"
            elif seed_names != sorted(si["pkgnames"]):
                why = f"seed: packages {seed_names}"
            else:
                seed_ok = True
        if args.force:
            action = "build"
        elif have.get("hash") == si["hash"] and have.get("files") and set(have["files"]) <= in_repo:
            action = "skip"
        elif si["key"] in cached:
            action = "restore"
        elif seed_ok:
            action = "seed"
        else:
            action = "build"
        si["action"] = action
        rows.append((si["level"], b, si["version"], have.get("version", "-"), si["hash"][:12], action, why))

    outputs = {}
    for n in range(LEVELS):
        outputs[f"level{n}"] = json.dumps([
            {"name": b, "key": info[b]["key"],
             "after": [d for d in info[b]["needs"] if info[d]["action"] != "skip"]}
            for b in bases if info[b]["level"] == n and info[b]["action"] == "build"])
    for a in ("restore", "seed"):
        outputs[a] = json.dumps([{"name": b, "key": info[b]["key"]} for b in bases if info[b]["action"] == a])
    gone = sorted(set(published) - set(bases))
    outputs["any"] = "true" if gone or any(si["action"] != "skip" for si in info.values()) else "false"
    with open(args.out, "w") as f:
        json.dump({"packages": info, "published": manifest, "gone": gone}, f, indent=1, sort_keys=True)
    pkgid.write_outputs(outputs)

    table = "| level | pkgbase | arch | published | hash | | |\n|---|---|---|---|---|---|---|\n"
    table += "".join(f"| {lv} | `{b}` | {v} | {pv} | `{h}` | {a} | {w} |\n"
                     for lv, b, v, pv, h, a, w in sorted(rows))
    counts = {a: sum(1 for r in rows if r[5] == a) for a in ("skip", "restore", "seed", "build")}
    pkgid.write_summary("## Build plan\n\n" + ", ".join(f"{n} {a}" for a, n in counts.items() if n)
                        + (f"; dropping {', '.join(gone)}" if gone else "") + "\n\n" + table)


if __name__ == "__main__":
    main()
