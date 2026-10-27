#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""
hm100-emu: the hm100 driver's mixer controls (snd-soc-hiby-hm100, patches 0031, 0065, 0067) as a
small daemon, so that darwinctl and its users run on a PC against the real alsa-lib control path:
ctl_hm100emu.so (an ALSA external control plugin) connects every client to this one daemon, which
holds the state and sends the control events to every subscribed client, as the ALSA core does.

The put semantics follow hiby-hm100.c: range checks (-EINVAL), no change -> 0 and no event,
"Output Target" read-only (-EPERM) and volatile, "FIR Custom" a TLV bytes control (no value
read/write; a TLV write of type, length 1024 and the taps selects "custom" and notifies "Digital
Filter" if that changed, the core sends a TLV event for "FIR Custom"), an Output change runs the
switch work, which notifies "Output Target". The defaults are the driver's probe values.

  hm100-emu.py <socket> [--jack none|balance|balancelo|headset|lineout]

Line protocol (one request per line, one reply line "ok ..." or "err <errno>"):
  list                       -> "ctl <i> <type> <access> <count> <min> <max> <items> <name>" lines,
                                "item <i> <k> <name>" lines, then "ok"
  get <i>                    -> "ok <v> [<v>]"
  put <i> <v> [<v>]          -> "ok <changed>"
  tlvw <i> <hex>             -> "ok <changed>"   (the whole container: type, length, data)
  tlvr <i> <bytes>           -> "ok <hex>"
  subscribe                  -> this connection gets "event <i> <mask>" lines from now on
  jack <name>                -> the jack detection settles on that jack (an external change)
  dump                       -> "ok <json>"
"""
import errno
import json
import os
import selectors
import socket
import struct
import sys

# alsa/control.h
T_BOOLEAN, T_INTEGER, T_ENUMERATED, T_BYTES = 1, 2, 3, 4
A_READ, A_WRITE, A_VOLATILE = 1 << 0, 1 << 1, 1 << 2
A_TLV_READ, A_TLV_WRITE, A_TLV_CALLBACK = 1 << 4, 1 << 5, 1 << 28
M_VALUE, M_INFO, M_TLV = 1 << 0, 1 << 1, 1 << 3
RW = A_READ | A_WRITE

# driver targets (T_*) and the Output items (output_texts / output_target)
T_NONE, T_LO, T_PO, T_BAL, T_SPDIF, T_BALLO = 0, 1, 2, 3, 4, 7
OUTPUT_TEXTS = ["Auto", "Lineout", "Headset", "Balance", "BalanceLo", "Spdif"]
OUTPUT_TARGET = [0, T_LO, T_PO, T_BAL, T_BALLO, T_SPDIF]
FILTER_TEXTS = ["sharp_roll_off", "slow_roll_off", "short_delay_sharp_roll_off",
                "short_delay_slow_roll_off", "super_sharp_roll_off", "super_slow_roll_off",
                "low_dispersion_short_delay", "custom"]
FIR_CUSTOM = len(FILTER_TEXTS) - 1
JACKS = {"none": T_NONE, "balance": T_BAL, "balancelo": T_BALLO, "headset": T_PO, "lineout": T_LO}

# hm100_controls[], in the driver's order: name, type, access, count, min, max, items
CONTROLS = [
    # the driver's also has its dB scale as a TLV (not here: darwinctl leaves the volume to PipeWire)
    ("Headphone Playback Volume", T_INTEGER, RW, 2, 0, 100, None),
    ("Pregain", T_INTEGER, RW, 1, -955, 315, None),
    ("Idle Power Off Seconds", T_INTEGER, RW, 1, 0, 3600, None),
    ("LR Balance", T_INTEGER, RW, 1, -254, 254, None),
    ("Gain", T_ENUMERATED, RW, 1, 0, 0, ["Low", "Middle", "High"]),
    ("Output", T_ENUMERATED, RW, 1, 0, 0, OUTPUT_TEXTS),
    ("Output Target", T_ENUMERATED, A_READ | A_VOLATILE, 1, 0, 0, OUTPUT_TEXTS[1:]),
    ("Digital Filter", T_ENUMERATED, RW, 1, 0, 0, FILTER_TEXTS),
    ("FIR Custom", T_BYTES, A_TLV_READ | A_TLV_WRITE | A_TLV_CALLBACK, 8 + 1024, 0, 0, None),
    ("NOS Switch", T_BOOLEAN, RW, 1, 0, 1, None),
    ("DSD Compensate", T_INTEGER, RW, 1, -254, 254, None),
    ("DSD Mode", T_ENUMERATED, RW, 1, 0, 0, ["mdsd", "dsd"]),
]
IDX = {c[0]: i for i, c in enumerate(CONTROLS)}


class Hm100:
    def __init__(self, jack):
        # hm100_probe defaults
        self.left = self.right = 45
        self.pregain = 0
        self.idle_off = 60
        self.lrbalance = 0
        self.gain = 1
        self.output = 0                 # Auto
        self.jack_target = JACKS[jack]
        self.fir_idx = 0
        self.fir_custom = bytes(1024)
        self.nos = True                 # reg3 = REG3_OSR_BYPASS
        self.dsd_comp = 6
        self.dsd_mode = 0
        self.notify = None              # (index, mask) -> send to subscribers

    def resolved(self):
        t = self.output or self.jack_target
        return t if t != T_NONE else T_SPDIF

    def get(self, i):
        name = CONTROLS[i][0]
        if name == "Headphone Playback Volume":
            return [self.left, self.right]
        if name == "Output":
            return [OUTPUT_TARGET.index(self.output)]
        if name == "Output Target":
            return [OUTPUT_TARGET.index(self.resolved()) - 1]
        if name == "Digital Filter":
            return [self.fir_idx]
        if name == "NOS Switch":
            return [int(self.nos)]
        if name == "FIR Custom":
            raise OSError(errno.EPERM, "no read access")
        attr = {"Pregain": "pregain", "Idle Power Off Seconds": "idle_off", "LR Balance": "lrbalance",
                "Gain": "gain", "DSD Compensate": "dsd_comp", "DSD Mode": "dsd_mode"}[name]
        return [getattr(self, attr)]

    def put(self, i, vals):
        name, typ, access, count, lo, hi, items = CONTROLS[i]
        if not access & A_WRITE:
            raise OSError(errno.EPERM, "read-only")
        if len(vals) != count:
            raise OSError(errno.EINVAL, "count")
        if typ == T_ENUMERATED and not all(0 <= v < len(items) for v in vals):
            raise OSError(errno.EINVAL, "item")
        if typ == T_INTEGER and not all(lo <= v <= hi for v in vals):
            raise OSError(errno.EINVAL, "range")
        v = vals[0]
        if name == "Headphone Playback Volume":
            changed = [self.left, self.right] != vals
            self.left, self.right = vals
        elif name == "Output":
            changed = OUTPUT_TARGET[v] != self.output
            self.output = OUTPUT_TARGET[v]
        elif name == "Digital Filter":
            changed = v != self.fir_idx
            self.fir_idx = v
        elif name == "NOS Switch":
            changed = bool(v) != self.nos
            self.nos = bool(v)
        else:
            attr = {"Pregain": "pregain", "Idle Power Off Seconds": "idle_off", "LR Balance": "lrbalance",
                    "Gain": "gain", "DSD Compensate": "dsd_comp", "DSD Mode": "dsd_mode"}[name]
            changed = getattr(self, attr) != v
            setattr(self, attr, v)
        if changed:
            self.notify(i, M_VALUE)     # snd_ctl_elem_write: put returned 1
            if name == "Output":        # schedule_work(&h->switch_work): notifies the target
                self.notify(IDX["Output Target"], M_VALUE)
        return int(changed)

    def tlv_write(self, i, data):
        if CONTROLS[i][0] != "FIR Custom":
            raise OSError(errno.ENXIO, "no TLV write")
        if len(data) < 8 + 1024:
            raise OSError(errno.EINVAL, "short")
        _, length = struct.unpack_from("<II", data)
        if length != 1024:
            raise OSError(errno.EINVAL, "length")
        self.fir_custom = data[8:8 + 1024]
        reselected = self.fir_idx != FIR_CUSTOM
        self.fir_idx = FIR_CUSTOM
        if reselected:
            self.notify(IDX["Digital Filter"], M_VALUE)
        self.notify(i, M_TLV)           # call_tlv_handler: the callback returned 1
        return 1

    def tlv_read(self, i, size):
        if CONTROLS[i][0] != "FIR Custom":
            raise OSError(errno.ENXIO, "no TLV read")
        if size < 8 + 1024:
            raise OSError(errno.EINVAL, "short")
        return struct.pack("<II", 0, 1024) + self.fir_custom

    def jack(self, name):
        """hm100_jack_work after the detect GPIOs settled: Auto follows, Output Target event"""
        t = JACKS[name]
        if t != self.jack_target:
            self.jack_target = t
            if not self.output:
                self.notify(IDX["Output Target"], M_VALUE)

    def dump(self):
        return {CONTROLS[i][0]: (self.get(i) if CONTROLS[i][3] < 8 else
                                 "%08x" % (sum(self.fir_custom) & 0xffffffff))
                for i in range(len(CONTROLS))} | {"jack_target": self.jack_target}


def main():
    path = sys.argv[1]
    jack = sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == "--jack" else "none"
    dev = Hm100(jack)
    sel = selectors.DefaultSelector()
    subscribers = set()
    bufs = {}

    def notify(i, mask):
        for s in list(subscribers):
            try:
                s.sendall(b"event %d %d\n" % (i, mask))
            except OSError:
                subscribers.discard(s)
        log("event %s %d" % (CONTROLS[i][0], mask))

    dev.notify = notify
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(16)
    sel.register(srv, selectors.EVENT_READ)
    print("ready", flush=True)          # for whoever started it: the socket accepts now

    def reply(s, line):
        s.sendall(line.encode() + b"\n")

    def handle(s, line):
        words = line.split()
        if not words:
            return
        cmd, args = words[0], words[1:]
        try:
            if cmd == "list":
                for i, (name, typ, access, count, lo, hi, items) in enumerate(CONTROLS):
                    reply(s, "ctl %d %d %d %d %d %d %d %s" % (i, typ, access, count, lo, hi,
                                                              len(items or []), name))
                    for k, item in enumerate(items or []):
                        reply(s, "item %d %d %s" % (i, k, item))
                reply(s, "ok")
            elif cmd == "get":
                reply(s, "ok " + " ".join(map(str, dev.get(int(args[0])))))
            elif cmd == "put":
                i = int(args[0])
                r = dev.put(i, [int(v) for v in args[1:]])
                log("put %s %s -> %d" % (CONTROLS[i][0], args[1:], r))
                reply(s, "ok %d" % r)
            elif cmd == "tlvw":
                i = int(args[0])
                r = dev.tlv_write(i, bytes.fromhex(args[1]))
                log("tlv write %s, %d bytes, sum %08x" % (CONTROLS[i][0], len(args[1]) // 2,
                                                         sum(dev.fir_custom) & 0xffffffff))
                reply(s, "ok %d" % r)
            elif cmd == "tlvr":
                reply(s, "ok " + dev.tlv_read(int(args[0]), int(args[1])).hex())
            elif cmd == "subscribe":
                subscribers.add(s)
                reply(s, "ok")
            elif cmd == "jack":
                dev.jack(args[0])
                log("jack %s" % args[0])
                reply(s, "ok")
            elif cmd == "dump":
                reply(s, "ok " + json.dumps(dev.dump()))
            else:
                reply(s, "err %d" % errno.EINVAL)
        except OSError as e:
            reply(s, "err %d" % e.errno)
        except (ValueError, IndexError, KeyError):
            reply(s, "err %d" % errno.EINVAL)

    while True:
        for key, _ in sel.select():
            s = key.fileobj
            if s is srv:
                c, _ = srv.accept()
                sel.register(c, selectors.EVENT_READ)
                bufs[c] = b""
                continue
            try:
                data = s.recv(65536)
            except OSError:
                data = b""
            if not data:
                sel.unregister(s)
                subscribers.discard(s)
                bufs.pop(s, None)
                s.close()
                continue
            bufs[s] += data
            while b"\n" in bufs[s]:
                line, bufs[s] = bufs[s].split(b"\n", 1)
                handle(s, line.decode())


def log(msg):
    print("hm100-emu: " + msg, file=sys.stderr, flush=True)


if __name__ == "__main__":
    main()
