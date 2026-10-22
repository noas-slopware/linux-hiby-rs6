#!/usr/bin/env python3
"""APKINDEX helpers for the CI.

  apkindex.py files <APKINDEX.tar.gz>
      print the file name of every package in the index (<name>-<version>.apk)
  apkindex.py prune <APKINDEX.tar.gz> <versions.json>
      print the files that do not belong in the published repository: packages whose origin is
      not on the pmos branch any more, or is there at another version than the APKBUILD's
"""

import json
import sys
import tarfile


def entries(path: str) -> list[dict]:
    with tarfile.open(path) as tar:
        text = tar.extractfile("APKINDEX").read().decode()
    out = []
    for block in text.split("\n\n"):
        fields = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
        if "P" in fields:
            out.append(fields)
    return out


def main() -> None:
    cmd, index = sys.argv[1], sys.argv[2]
    if cmd == "files":
        for e in entries(index):
            print(f"{e['P']}-{e['V']}.apk")
    elif cmd == "prune":
        with open(sys.argv[3]) as f:
            versions = json.load(f)
        for e in entries(index):
            origin = e.get("o", e["P"])
            if versions.get(origin) != e["V"]:
                print(f"{e['P']}-{e['V']}.apk")
    else:
        sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    main()
