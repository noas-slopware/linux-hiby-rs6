#!/bin/sh
# darwinctl against the emulated hm100 on a PC: builds darwinctl, the previous darwinctl (for the
# KCM's contract) and the ALSA control plugin, then runs run-tests.py.
# Usage: run.sh <build dir> <dir with stock Settings' filter.json + .flt files (firmware branch, darwin/)>
set -e
T=$(cd "$(dirname "$0")" && pwd); B=$(mkdir -p "$1" && cd "$1" && pwd); S=$(cd "$2" && pwd)
# the darwinctl before status --json and monitor (a8143bd)
OLD=a8143bdc6aa1cc3b3ac00ecbd022d98d6fadee59
CC=${CC:-cc}
$CC -O2 -g -Wall -Wextra -o "$B/darwinctl" "$T/../darwinctl.c" -lasound
git -C "$T" show "$OLD:userspace/darwinctl/darwinctl.c" > "$B/darwinctl-old.c"
$CC -O2 -g -o "$B/darwinctl-old" "$B/darwinctl-old.c" -lasound
$CC -O2 -g -Wall -Wextra -DPIC -shared -fPIC -o "$B/libasound_module_ctl_hm100emu.so" "$T/ctl_hm100emu.c" -lasound
exec python3 -I "$T/run-tests.py" "$B" "$S"
