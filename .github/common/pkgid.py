#!/usr/bin/env python3
"""Package identity for the CI: which build of a package is which, and where finished builds are kept.

A package's identity is a sha256 over everything its build is made from that lives in this repository:
every file of its own directory (APKBUILD or PKGBUILD plus all local sources: path, executable bit and
content; symlinks by target), plus the pinned inputs of the distribution:

  nura  the pmbootstrap and pmaports commits (PMB_COMMIT, PMAPORTS_COMMIT of nura-packages.yml)
  arch  tools/makepkg-rs6.conf and tools/pacman-rs6.conf of the arch branch (our compiler flags and the
        bens-only repository list), without comment and blank lines

A pkgrel bump or any change to a source file changes the hash, so the package is built again; the same
hash means the same inputs, so a build that exists is never repeated. Changing RECIPE rebuilds everything.

Command line:
  pkgid.py hash nura <package dir> <pmbootstrap commit> <pmaports commit>
  pkgid.py hash arch <arch branch checkout> <pkgbase>
"""

import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

RECIPE = "linux-hiby-rs6 package identity 1"
ARCH_CONFS = ("tools/makepkg-rs6.conf", "tools/pacman-rs6.conf")


def _sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_lines(root: str) -> list[str]:
    """One line per file below root (sorted by path; .git skipped)."""
    if not os.path.isdir(root):
        raise FileNotFoundError(root)
    lines = []
    for dirpath, dirnames, filenames in os.walk(root):
        keep = []
        for d in dirnames:
            p = os.path.join(dirpath, d)
            if d == ".git":
                continue
            if os.path.islink(p):  # os.walk does not descend into it: record the link itself
                lines.append((os.path.relpath(p, root), f"l {os.readlink(p)}"))
            else:
                keep.append(d)
        dirnames[:] = keep
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, root)
            if os.path.islink(p):
                lines.append((rel, f"l {os.readlink(p)}"))
            else:
                mode = "x" if os.stat(p).st_mode & 0o100 else "-"
                lines.append((rel, f"f {mode} {_sha256_file(p)}"))
    return [f"{rel} {what}" for rel, what in sorted(lines)]


def conf_digest(path: str) -> str:
    """sha256 of a shell-style config file without comment and blank lines."""
    with open(path, encoding="utf-8") as f:
        kept = [line.rstrip() for line in f if line.strip() and not line.lstrip().startswith("#")]
    return hashlib.sha256(("\n".join(kept) + "\n").encode()).hexdigest()


def digest(pkgdir: str, inputs: dict[str, str]) -> str:
    text = [RECIPE]
    text += [f"input {k}={inputs[k]}" for k in sorted(inputs)]
    text += [f"file {line}" for line in tree_lines(pkgdir)]
    return hashlib.sha256(("\n".join(text) + "\n").encode()).hexdigest()


def nura_hash(pkgdir: str, pmb_commit: str, pmaports_commit: str) -> str:
    return digest(pkgdir, {"pmbootstrap": pmb_commit, "pmaports": pmaports_commit})


def arch_hash(checkout: str, pkgbase: str) -> str:
    inputs = {conf: conf_digest(os.path.join(checkout, conf)) for conf in ARCH_CONFS}
    return digest(os.path.join(checkout, pkgbase), inputs)


# --- helpers shared by the plan scripts ---------------------------------------------------------


def fetch(url: str, timeout: int = 60) -> bytes | None:
    """GET url; None on 404. GitHub Pages answers 5xx now and then (a 503 failed a publish):
    retry those and dropped connections, 15/45/120 s apart, before giving up."""
    for wait in (15, 45, 120, None):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if e.code < 500 or wait is None:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if wait is None:
                raise
        print(f"{url}: retrying in {wait} s", file=sys.stderr)
        time.sleep(wait)


def fetch_json(url: str):
    data = fetch(url)
    return None if data is None else json.loads(data)


def cached_keys(prefix: str) -> set[str]:
    """Keys of the actions caches of this repository whose key starts with prefix and that a run on
    this ref can restore (this ref's own and the default branch's). Needs actions: read. Without
    GITHUB_TOKEN (local runs) nothing is cached."""
    token = os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GITHUB_REPOSITORY")
    if not token or not repo:
        print("no GITHUB_TOKEN/GITHUB_REPOSITORY: not looking at the actions cache", file=sys.stderr)
        return set()
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    keys, page = set(), 1
    while True:
        q = urllib.parse.urlencode({"key": prefix, "per_page": 100, "page": page})
        req = urllib.request.Request(
            f"{api}/repos/{repo}/actions/caches?{q}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
        )
        with urllib.request.urlopen(req, timeout=60) as r:
            data = json.load(r)
        caches = data.get("actions_caches", [])
        refs = {os.environ.get("GITHUB_REF", ""), f"refs/heads/{os.environ.get('DEFAULT_BRANCH', 'senpai')}"}
        keys |= {c["key"] for c in caches if c.get("ref") in refs}
        if len(caches) < 100:
            return keys
        page += 1


def write_outputs(outputs: dict[str, str]) -> None:
    lines = "".join(f"{k}={v}\n" for k, v in outputs.items())
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(lines)
    else:
        sys.stdout.write(lines)


def write_summary(text: str) -> None:
    print(text, file=sys.stderr)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(text + "\n")


def main() -> None:
    args = sys.argv[1:]
    if len(args) == 5 and args[:2] == ["hash", "nura"]:
        print(nura_hash(args[2], args[3], args[4]))
    elif len(args) == 4 and args[:2] == ["hash", "arch"]:
        print(arch_hash(args[2], args[3]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
