#!/usr/bin/env python3
"""Stage the arch part of the site: the package files of [rs6] and built.json.

For every pkgbase on the arch branch: the packages this run built, restored or imported (the
pkgs-<pkgbase> artifacts) if it has them; otherwise the published ones, unchanged, with their
built.json entry (so a package whose build failed stays at its last published build, and its old
hash makes the next run try again). Pkgbases that left the branch are dropped. The repository
database is made afterwards from exactly these files (repo-add in the workflow).

  publish.py --plan plan.json --site <URL> --run-pkgs <dir> --out <dir> --arch-sha <sha>
"""

import argparse
import json
import os
import shutil
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "common"))
import pkgid  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--site", required=True)
    ap.add_argument("--run-pkgs", required=True)
    ap.add_argument("--out", required=True, help="the repository directory to fill (arch/aarch64)")
    ap.add_argument("--arch-sha", required=True)
    args = ap.parse_args()
    with open(args.plan) as f:
        plan = json.load(f)
    run_url = "{}/{}/actions/runs/{}".format(os.environ.get("GITHUB_SERVER_URL", "https://github.com"),
                                            os.environ.get("GITHUB_REPOSITORY", "local"),
                                            os.environ.get("GITHUB_RUN_ID", "0"))
    published = plan["published"].get("packages", {})
    repo = f"{args.site}/arch/aarch64"
    os.makedirs(args.out, exist_ok=True)

    packages, rows = {}, []
    for b, si in sorted(plan["packages"].items()):
        mine = os.path.join(args.run_pkgs, f"pkgs-{b}")
        files = sorted(f for f in os.listdir(mine) if f.endswith(".pkg.tar.zst")) if os.path.isdir(mine) else []
        if files:
            for f in files:
                shutil.copy(os.path.join(mine, f), os.path.join(args.out, f))
            via = {"build": "built", "restore": "actions cache", "seed": "seed release (built locally)"}
            packages[b] = {"hash": si["hash"], "version": si["version"], "files": files,
                           "arch": args.arch_sha, "run": run_url, "via": via.get(si["action"], si["action"])}
            rows.append((b, si["version"], f"new ({packages[b]['via']})"))
            continue
        have = published.get(b)
        if not have:
            rows.append((b, si["version"], "**not published** (no build)"))
            continue
        for f in have["files"]:
            data = pkgid.fetch(f"{repo}/{f}", timeout=300)
            if data is None:
                sys.exit(f"{repo}/{f}: in built.json but not published")
            with open(os.path.join(args.out, f), "wb") as out:
                out.write(data)
        packages[b] = have
        note = "unchanged" if si["action"] == "skip" else f"**kept {have['version']}** ({si['action']} failed)"
        rows.append((b, have["version"], note))
    for b in plan["gone"]:
        rows.append((b, published[b].get("version", "-"), "dropped (not on the branch)"))

    with open(os.path.join(args.out, "built.json"), "w") as f:
        json.dump({"format": 1, "packages": packages}, f, indent=1, sort_keys=True)
        f.write("\n")
    pkgid.write_summary("## Published\n\n| pkgbase | version | |\n|---|---|---|\n"
                        + "".join(f"| `{b}` | {v} | {n} |\n" for b, v, n in rows))


if __name__ == "__main__":
    main()
