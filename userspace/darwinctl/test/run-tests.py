#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
darwinctl against the emulated hm100 (hm100-emu.py + ctl_hm100emu.so, through alsa-lib):
every command, the KCM's contract (list --porcelain, set <path>, set custom; byte for byte the
same as the previous darwinctl), status --json, and monitor's events, including changes from
other clients (amixer) and the jack detection, and the card going away.

  run-tests.py <build dir> <dir with stock Settings' filter.json + .flt files>

The build dir has darwinctl, darwinctl-old (the previous version, for the contract) and
libasound_module_ctl_hm100emu.so (run.sh builds them). Prints a transcript and PASS/FAIL lines;
exits 1 if anything failed.
"""
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import zlib

B = os.path.abspath(sys.argv[1])
STOCK = os.path.abspath(sys.argv[2])
HERE = os.path.dirname(os.path.abspath(__file__))
RUN = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
SOCK = os.path.join(RUN, "hm100emu-test-%d.sock" % os.getpid())   # sun_path is short
W = tempfile.mkdtemp(prefix="darwinctl-test-")
failed = 0


def check(ok, what):
    global failed
    print(("PASS " if ok else "FAIL ") + what, flush=True)
    failed += not ok


def conf(name, extra):
    path = os.path.join(W, name)
    with open(os.path.join(HERE, name + ".in")) as f:
        text = f.read()
    with open(path, "w") as f:
        f.write(text.replace("@LIB@", os.path.join(B, "libasound_module_ctl_hm100emu.so"))
                .replace("@SOCKET@", SOCK))
    return path


CONF = conf("hm100emu.conf", None)
HWCONF = conf("hm100emu-hw.conf", None)
STATE = os.path.join(W, "state")
os.mkdir(STATE)
ENV = dict(os.environ, ALSA_CONFIG_PATH="/usr/share/alsa/alsa.conf:" + CONF, DARWINCTL_CTL="hm100emu",
           DARWINCTL_PRESETS=STOCK, DARWINCTL_STATE=STATE, LC_ALL="C")
# hw:N is the emulator, no DARWINCTL_CTL: the card scan, and the previous darwinctl
HWENV = dict(ENV, ALSA_CONFIG_PATH="/usr/share/alsa/alsa.conf:%s:%s" % (CONF, HWCONF))
del HWENV["DARWINCTL_CTL"]

emu = None


def start_emu(*args):
    global emu
    emu = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "hm100-emu.py"), SOCK, *args],
                           stdout=subprocess.PIPE, stderr=open(os.path.join(W, "emu.log"), "a"), text=True)
    assert emu.stdout.readline().strip() == "ready"


def stop_emu():
    emu.terminate()
    emu.wait()


def emu_req(line):
    import socket
    s = socket.socket(socket.AF_UNIX)
    s.connect(SOCK)
    s.sendall(line.encode() + b"\n")
    reply = s.makefile().readline().strip()
    s.close()
    return reply


def dc(*args, env=None, bin="darwinctl", show=True):
    p = subprocess.run([os.path.join(B, bin), *args], env=env or ENV, capture_output=True, text=True,
                       timeout=10)
    if show:
        print("$ %s %s  [exit %d]" % (bin, " ".join(args), p.returncode))
        for line in (p.stdout + p.stderr).splitlines():
            print("  " + line)
    return p


def amixer(*args):
    return subprocess.run(["amixer", "-D", "hm100emu", *args], env=ENV, capture_output=True, text=True,
                          timeout=10)


def state():
    p = dc("status", "--json", show=False)
    return json.loads(p.stdout)


def csum(path):
    with open(path, "rb") as f:
        return "%08x" % (sum(f.read()) & 0xffffffff)


class Monitor:
    def __init__(self, env=None):
        self.p = subprocess.Popen([os.path.join(B, "darwinctl"), "monitor"], env=env or ENV,
                                  stdout=subprocess.PIPE, text=True, bufsize=1)
        self.lines = 0

    def next(self, timeout=3):
        """the next line, or None after timeout seconds without one"""
        r, _, _ = select.select([self.p.stdout], [], [], timeout)
        if not r:
            return None
        line = self.p.stdout.readline()
        if not line:
            return None
        self.lines += 1
        return json.loads(line)

    def until(self, pred, what):
        """lines until pred(state) holds; the state, and how many lines that took"""
        n = 0
        while True:
            s = self.next()
            if s is None:
                check(False, "monitor: " + what + " (no line)")
                return None, n
            n += 1
            if pred(s):
                return s, n

    def quiet(self, timeout=0.5):
        return self.next(timeout) is None


try:
    start_emu("--jack", "balance")

    # ---- the commands ----
    p = dc("status")
    check(p.returncode == 0 and p.stdout.splitlines()[:2] == ["filter: sharp_roll_off",
                                                               "NOS: on (the filter is bypassed)"],
          "status: the first two lines as before")
    check("output: Auto, now 4.4 mm balanced" in p.stdout and "gain: Middle" in p.stdout and
          "pregain: 0.0 dB" in p.stdout and "balance: center" in p.stdout and
          "idle power off: 60 s" in p.stdout and "DSD filter: Darwin Default (mdsd)" in p.stdout and
          "DSD compensate: +3.0 dB" in p.stdout, "status: the driver defaults")
    s = state()
    check(s["available"] and s["nos"] is True and s["output"]["name"] == "Auto" and
          s["target"]["name"] == "Balance" and s["gain"]["index"] == 1 and s["filter"]["index"] == 0 and
          s["pregain"] == {"value": 0, "min": -955, "max": 315, "db": 0.0} and
          s["balance"]["max"] == 254 and s["idle_off"]["value"] == 60 and s["dsd_mode"]["name"] == "mdsd" and
          s["dsd_compensate"]["db"] == 3.0 and s["custom_index"] == 7 and len(s["filters"]) == 8 and
          len(s["outputs"]) == 6 and s["outputs"][5]["label"] == "S/PDIF" and len(s["targets"]) == 5 and
          len(s["darwin_filters"]) == 11 and s["darwin_filters"][3]["title"] == "Darwin 3" and
          s["darwin"] is None, "status --json: schema and defaults")

    dc("nos")
    check(dc("nos", "off").returncode == 0 and dc("nos").stdout == "off\n", "nos off, read back")
    dc("output")
    for arg, want in (("balance", "Balance"), ("3.5 mm line out", "Lineout"), ("2", "Headset"),
                      ("Spdif", "Spdif"), ("auto", "Auto")):
        dc("output", arg)
        check(state()["output"]["name"] == want, "output %s -> %s" % (arg, want))
    check(dc("output", "nowhere").returncode == 1, "output: unknown name fails")
    dc("target")
    check(dc("target").stdout.splitlines()[2].startswith("* Balance"), "target: Auto on the 4.4 mm jack")
    r = amixer("cset", "name=Output Target", "0")
    check(r.returncode != 0 and "Operation not permitted" in r.stderr,
          "Output Target is read-only (amixer cset: %s)" % r.stderr.strip().splitlines()[-1:])
    dc("gain")
    dc("gain", "high")
    check(dc("gain").stdout.splitlines()[2] == "* High", "gain high")
    for arg, want in (("-3.5", -35), ("+31.5 dB", 315), ("-95,5dB", -955), ("0", 0), ("1.26", 13)):
        dc("pregain", arg)
        check(state()["pregain"]["value"] == want, "pregain %s -> %d tenths" % (arg, want))
    check(dc("pregain", "+32").returncode == 1 and dc("pregain", "loud").returncode == 1,
          "pregain: out of range and not a number fail")
    dc("pregain", "-2")
    check(dc("pregain").stdout == "-2.0 dB\n", "pregain read back")
    for arg, want, text in (("L1.5", -3, "L +1.5 dB"), ("R2", 4, "R +2.0 dB"), ("-0.5", -1, "L +0.5 dB"),
                            ("right 127", 254, "R +127.0 dB"), ("center", 0, "center")):
        dc("balance", arg)
        check(state()["balance"]["value"] == want and dc("balance", show=False).stdout == text + "\n",
              "balance %s -> %d (%s)" % (arg, want, text))
    check(dc("balance", "L200").returncode == 1 and dc("balance", "L-1").returncode == 1,
          "balance: too far and L with a sign fail")
    for arg, want in (("30", 30), ("never", 0), ("3600s", 3600)):
        dc("idle-off", arg)
        check(state()["idle_off"]["value"] == want, "idle-off %s -> %d" % (arg, want))
    check(dc("idle-off", "3601").returncode == 1, "idle-off: out of range fails")
    dc("idle-off", "60")
    dc("dsd-mode")
    dc("dsd-mode", "Darwin 1")
    check(state()["dsd_mode"]["name"] == "dsd", "dsd-mode by stock label")
    dc("dsd-mode", "mdsd")
    dc("dsd-compensate", "-1.5")
    check(state()["dsd_compensate"]["value"] == -3, "dsd-compensate -1.5 dB -> -3")
    dc("dsd-compensate", "+3")
    dc("filter")
    dc("filter", "Slow roll off")
    check(state()["filter"]["name"] == "slow_roll_off", "filter by label")
    check(dc("filter", "Darwin 3").returncode == 1, "filter: a Darwin filter is not a built-in one")
    dc("darwin")
    dc("darwin", "Darwin 3")
    s = state()
    want = csum(os.path.join(STOCK, "raised-cosine-254-rolloff-normal.flt"))
    check(s["filter"]["darwin"] and s["filter"]["label"] == "Darwin 3" and s["darwin"]["index"] == 3 and
          s["darwin"]["active"] and json.loads(emu_req("dump")[3:])["FIR Custom"] == want,
          "darwin 'Darwin 3': custom, the right taps (%s)" % want)
    dc("darwin")
    dc("filter", "sharp_roll_off")
    s = state()
    check(not s["filter"]["darwin"] and s["darwin"]["title"] == "Darwin 3" and not s["darwin"]["active"],
          "a built-in filter: the Darwin filter stays known, not active")
    dc("filter", "custom")
    check(state()["filter"]["label"] == "Darwin 3", "filter custom: Darwin 3 again")
    copy = os.path.join(W, "my filter.flt")
    shutil.copy(os.path.join(STOCK, "nyquist-30-rolloff-minphase.flt"), copy)
    dc("darwin", copy)
    s = state()
    check(s["filter"]["label"] == "my filter" and s["darwin"]["index"] == -1 and s["darwin"]["path"] is None
          and json.loads(emu_req("dump")[3:])["FIR Custom"] == csum(copy), "darwin <file>: a loaded file")
    bad = os.path.join(W, "bad.flt")
    with open(bad, "wb") as f:
        f.write(os.urandom(1000))
    check(dc("darwin", bad).returncode == 1 and state()["filter"]["label"] == "my filter",
          "darwin <1000-byte file> fails, nothing changes")
    check(dc("darwin", "no-such-filter").returncode == 1, "darwin: unknown name fails")

    # ---- the KCM's contract: the previous darwinctl's output, byte for byte ----
    dc("set", "darwin-10", env=HWENV)
    for args in (("list",), ("list", "--porcelain")):
        new, old = dc(*args, env=HWENV, show=False), dc(*args, env=HWENV, bin="darwinctl-old", show=False)
        check((new.returncode, new.stdout) == (old.returncode, old.stdout),
              "%s: the same as the previous darwinctl (hw: card scan)" % " ".join(args))
    new, old = dc("status", env=HWENV, show=False), dc("status", env=HWENV, bin="darwinctl-old", show=False)
    check(new.stdout.splitlines()[:2] == old.stdout.splitlines(), "status: starts with the previous lines")
    print(dc("list", "--porcelain", env=HWENV, show=False).stdout)
    for args in (("set", os.path.join(STOCK, "raised-cosine-254-rolloff-normal.flt")), ("set", "custom"),
                 ("set", "slow_roll_off"), ("set", "custom"), ("nos", "on"), ("set", "Darwin 1")):
        dc(*args, env=HWENV)
        a = dc("list", "--porcelain", env=HWENV, show=False).stdout
        b = dc("list", "--porcelain", env=HWENV, bin="darwinctl-old", show=False).stdout
        check(a == b, "after set %s: list --porcelain as before" % args[1])

    # ---- monitor ----
    m = Monitor()
    s0 = m.next()
    check(s0 is not None and s0["available"] and s0["filter"]["label"] == "Darwin 1", "monitor: the state first")
    check(m.quiet(), "monitor: then nothing while nothing changes")
    dc("output", "headset")
    s, n = m.until(lambda s: s["output"]["name"] == "Headset", "output headset")
    check(s and s["target"]["name"] == "Headset" and m.quiet(),
          "output headset: one line with Output and Output Target (%d line)" % n)
    dc("output", "auto")
    s, n = m.until(lambda s: s["output"]["name"] == "Auto", "output auto")
    check(s and s["target"]["name"] == "Balance", "output auto: back on the 4.4 mm jack")
    emu_req("jack lineout")     # the jack detection: someone plugged into the line out
    s, n = m.until(lambda s: s["target"]["name"] == "Lineout", "jack: line out")
    check(s and s["output"]["name"] == "Auto" and m.quiet(), "external: jack switch -> Output Target event")
    emu_req("jack none")
    s, n = m.until(lambda s: s["target"]["name"] == "Spdif", "jack: nothing plugged")
    check(s is not None, "external: nothing plugged -> S/PDIF")
    r = amixer("cset", "name=Gain", "Low")
    s, n = m.until(lambda s: s["gain"]["name"] == "Low", "amixer gain")
    check(r.returncode == 0 and s is not None, "external: amixer cset Gain -> event")
    amixer("cset", "name=Headphone Playback Volume", "30,30")
    check(m.quiet(), "the playback volume (not darwinctl's) prints nothing")
    amixer("cset", "name=Gain", "Low")
    check(m.quiet(), "a write without a change prints nothing (no event, as the driver)")
    for args, pred in ((("pregain", "-6.5"), lambda s: s["pregain"]["value"] == -65),
                       (("balance", "R1"), lambda s: s["balance"]["value"] == 2),
                       (("idle-off", "120"), lambda s: s["idle_off"]["value"] == 120),
                       (("nos", "off"), lambda s: s["nos"] is False),
                       (("dsd-mode", "dsd"), lambda s: s["dsd_mode"]["index"] == 1),
                       (("dsd-compensate", "0"), lambda s: s["dsd_compensate"]["value"] == 0),
                       (("filter", "super_slow_roll_off"), lambda s: s["filter"]["index"] == 5)):
        dc(*args, show=False)
        s, n = m.until(pred, " ".join(args))
        check(s is not None, "monitor: %s" % " ".join(args))
    dc("darwin", "Darwin 7", show=False)
    s, n = m.until(lambda s: s["filter"]["darwin"] and s["filter"]["label"] == "Darwin 7", "darwin 7")
    check(s is not None and s["darwin"]["index"] == 7 and m.quiet(),
          "monitor: a Darwin filter (%d lines to the final state)" % n)
    dc("darwin", "Darwin 2", show=False)
    s, n = m.until(lambda s: s["filter"]["label"] == "Darwin 2", "darwin 2")
    check(s is not None and m.quiet(), "monitor: Darwin filter to Darwin filter (FIR TLV event only)")
    stop_emu()
    s = m.next()
    check(s == {"available": False}, "the card goes away: {\"available\":false}")
    m.p.wait(timeout=5)
    check(m.p.returncode == 1, "monitor on a named ctl device ends then (no hotplug to wait for)")

    # ---- reboot: alsactl restored custom, the driver has its default taps; restore loads ours ----
    start_emu("--jack", "headset")
    amixer("cset", "name=Digital Filter", "custom")
    dc("restore")
    want = csum(os.path.join(STOCK, "3.flt"))
    check(json.loads(emu_req("dump")[3:])["FIR Custom"] == want and state()["filter"]["label"] == "Darwin 2",
          "restore: the saved Darwin filter's taps are back (%s)" % want)
    stop_emu()
    check(dc("restore").returncode == 0 and dc("status").returncode == 1 and
          dc("status", "--json").stdout == '{"available":false}\n', "no card: restore 0, status 1")
finally:
    if emu and emu.poll() is None:
        stop_emu()
    try:
        os.unlink(SOCK)
    except FileNotFoundError:
        pass
    print("emulator log: %s/emu.log" % W)

print("%d failed" % failed if failed else "all passed")
sys.exit(1 if failed else 0)
