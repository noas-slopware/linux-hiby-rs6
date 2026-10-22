#!/usr/bin/env python3
"""The GitHub Pages site is shared by two workflows, and every Pages deployment replaces the whole
site. Each workflow owns one part and carries the other part over from the live site unchanged:

  nura  everything outside arch/: index.html, the apk signing key, main/   (nura-packages.yml)
  arch  arch/                                                              (arch-packages.yml)

Each part lists its files in <part dir>/files.txt (main/files.txt, arch/files.txt; paths relative to
the site root), which is what the other workflow downloads by. Sites from before the main/ layout
had the nura part's list at edge/files.txt, or none (edge/aarch64/packages.txt is read then).
Both publish jobs share one concurrency group, so a deployment never drops what the other one just
published.

  site.py list <site dir> <part>               write the part's files.txt
  site.py fetch <site URL> <part> <site dir>   download the live part into <site dir>
"""

import os
import re
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

LISTS = {"nura": "main/files.txt", "arch": "arch/files.txt"}
OLD_LISTS = {"nura": ["edge/files.txt"], "arch": []}


def in_part(rel: str, part: str) -> bool:
    is_arch = rel == "arch" or rel.startswith("arch/")
    return is_arch if part == "arch" else not is_arch


def get(url: str) -> bytes | None:
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if attempt == 3:
                raise
        except (urllib.error.URLError, TimeoutError):
            if attempt == 3:
                raise
        time.sleep(5 * (attempt + 1))
    return None


def list_part(site: str, part: str) -> None:
    out = os.path.join(site, LISTS[part])
    files = []
    for root, _dirs, names in os.walk(site):
        for n in names:
            rel = os.path.relpath(os.path.join(root, n), site)
            if in_part(rel, part) and rel != LISTS[part]:
                files.append(rel)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        f.write("".join(f"{r}\n" for r in sorted(files)))
    print(f"{LISTS[part]}: {len(files)} files")


def legacy_nura(url: str) -> list[str] | None:
    """The nura part as published before files.txt existed."""
    pkgs = get(f"{url}/edge/aarch64/packages.txt")
    if pkgs is None:
        return None
    page = get(f"{url}/index.html") or b""
    keys = sorted(set(re.findall(rb'href="([^"/]+\.pub)"', page)))
    files = ["index.html", "edge/aarch64/APKINDEX.tar.gz", "edge/aarch64/packages.txt"]
    files += [k.decode() for k in keys]
    files += [f"edge/aarch64/{line}" for line in pkgs.decode().split()]
    return files


def fetch_part(url: str, part: str, site: str) -> None:
    files = None
    for name in [LISTS[part]] + OLD_LISTS[part]:
        listing = get(f"{url}/{name}")
        if listing is not None:
            files = [line for line in listing.decode().splitlines() if line] + [name]
            break
    if files is not None:
        pass
    elif part == "nura":
        files = legacy_nura(url)
    else:
        files = None
    if files is None:
        print(f"{url}: no {part} part published, nothing to carry over")
        return
    for rel in files:
        if not in_part(rel, part) or rel.startswith("/") or ".." in rel.split("/"):
            sys.exit(f"{LISTS[part]}: refusing {rel!r}")

    def one(rel: str) -> int:
        data = get(f"{url}/{rel}")
        if data is None:
            sys.exit(f"{url}/{rel}: listed but missing")
        dest = os.path.join(site, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(data)
        return len(data)

    with ThreadPoolExecutor(8) as ex:
        size = sum(ex.map(one, files))
    print(f"carried over the {part} part: {len(files)} files, {size / 1e6:.1f} MB")


def main() -> None:
    a = sys.argv[1:]
    if len(a) == 3 and a[0] == "list" and a[2] in LISTS:
        list_part(a[1], a[2])
    elif len(a) == 4 and a[0] == "fetch" and a[2] in LISTS:
        fetch_part(a[1].rstrip("/"), a[2], a[3])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
