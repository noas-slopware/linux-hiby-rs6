#!/usr/bin/env python3
"""Decode RS6 stock-kernel ftrace captures (events/gpio + events/spi) into
hm100 / NJW1195A control words and Gowin JTAG instructions.

Usage: decode-trace.py [--base N] [--debugfs-gpio static/debugfs_gpio.txt] trace.txt [...]

The HiBy drivers share TLMM gpio 8/10/11 between three uses:
  JTAG (tdi 8, tdo 9, tms 10, tck 11)            while the FPGA is being loaded
  hm100 control SPI (sdo 8, cs 10, clk 11)       one 16-bit MSB-first word per write
  NJW1195A (data 8, latch 10, clock 11)          same wires, picked by share-spi-select (gpio 13)
jtag-select is gpio 44. The trace only has global gpio numbers, so the
TLMM base is taken from --base or parsed out of the debugfs gpio dump.
"""
import argparse
import re
import sys

LINE = re.compile(r"^\s*(?P<task>.+?)-(?P<pid>\d+)\s+\[(?P<cpu>\d+)\].*?\s(?P<ts>\d+\.\d+):\s(?P<ev>\w+):\s(?P<rest>.*)$")
GPIO = re.compile(r"(\d+)\s+(set|get)\s+(-?\d+)")

SDO, TDO, CS, CLK, SEL, JSEL = 8, 9, 10, 11, 13, 44
NAMES = {8: "sdo/tdi", 9: "tdo", 10: "cs/tms", 11: "clk/tck", 12: "reset", 13: "share-spi-sel", 44: "jtag-sel", 55: "power"}

# Gowin JTAG IR opcodes, as used by hbc3000_jtag_program_ram + openFPGALoader names
IR_NAMES = {0x02: "NOOP", 0x05: "ERASE_SRAM", 0x09: "XFER_DONE", 0x11: "READ_IDCODE", 0x12: "INIT_ADDR",
            0x13: "READ_USERCODE", 0x15: "CONFIG_ENABLE", 0x17: "XFER_WRITE", 0x3A: "CONFIG_DISABLE",
            0x3C: "RELOAD?", 0x41: "STATUS_REGISTER"}

# IEEE 1149.1 TAP state machine: state -> (next if tms=0, next if tms=1)
TAP = {
    "RESET": ("IDLE", "RESET"), "IDLE": ("IDLE", "SELDR"),
    "SELDR": ("CAPDR", "SELIR"), "CAPDR": ("SHDR", "EX1DR"), "SHDR": ("SHDR", "EX1DR"),
    "EX1DR": ("PADR", "UPDR"), "PADR": ("PADR", "EX2DR"), "EX2DR": ("SHDR", "UPDR"), "UPDR": ("IDLE", "SELDR"),
    "SELIR": ("CAPIR", "RESET"), "CAPIR": ("SHIR", "EX1IR"), "SHIR": ("SHIR", "EX1IR"),
    "EX1IR": ("PAIR", "UPIR"), "PAIR": ("PAIR", "EX2IR"), "EX2IR": ("SHIR", "UPIR"), "UPIR": ("IDLE", "SELDR"),
}


def tlmm_base(path):
    # 4.4 debugfs: "GPIOs 0-113, platform/3000000.pinctrl, 3000000.pinctrl:"
    for line in open(path, errors="replace"):
        if "pinctrl" in line and "GPIOs" in line:
            m = re.search(r"GPIOs (\d+)-(\d+)", line)
            if m and int(m.group(2)) - int(m.group(1)) >= 100:
                return int(m.group(1))
    sys.exit(f"no TLMM chip found in {path}, pass --base")


class Decoder:
    def __init__(self, base, out):
        self.base, self.out = base, out
        self.lvl = {}
        self.spi_bits = None  # list while cs is low
        self.tap, self.shift, self.dr_bits = "RESET", [], 0
        self.tdo_bits = []

    def emit(self, ts, msg):
        self.out.write(f"{ts:>14}  {msg}\n")

    def target(self):
        return "njw1195a" if self.lvl.get(SEL) == 1 else "hm100"

    def jtag_mode(self):
        return self.lvl.get(JSEL) == 1

    def on_set(self, ts, g, v):
        prev = self.lvl.get(g)
        self.lvl[g] = v
        if g not in (SDO, CS, CLK):
            if prev != v:
                self.emit(ts, f"gpio {g} ({NAMES.get(g, '?')}) = {v}")
            return
        # SPI view: frame = cs low .. cs high, sample sdo on clk rising edge
        if g == CS and prev == 1 and v == 0:
            self.spi_bits = []
        elif g == CS and prev == 0 and v == 1 and self.spi_bits is not None:
            bits = self.spi_bits
            self.spi_bits = None
            if bits and not self.jtag_mode():
                word = int("".join(map(str, bits)), 2)
                desc = self.describe(word, len(bits))
                self.emit(ts, f"SPI {self.target():8} {len(bits):2} bits 0x{word:0{(len(bits) + 3) // 4}x}  {desc}")
        if g == CLK and prev == 0 and v == 1:
            if self.spi_bits is not None:
                self.spi_bits.append(self.lvl.get(SDO, 0))
            self.tck(ts)

    def tck(self, ts):
        # JTAG view: on TCK rising edge, sample TMS (cs) and TDI (sdo), advance TAP
        tms, tdi = self.lvl.get(CS, 0), self.lvl.get(SDO, 0)
        st = self.tap
        if st in ("SHIR", "SHDR"):
            self.shift.append(tdi)
            self.tdo_bits.append(self.lvl.get(TDO, 0))
        nxt = TAP[st][tms]
        if st == "SHIR" and nxt == "EX1IR":
            ir = sum(b << i for i, b in enumerate(self.shift))  # LSB first
            self.emit(ts, f"JTAG IR 0x{ir:02x} {IR_NAMES.get(ir, '?')} ({len(self.shift)} bits)")
        if st == "SHDR" and nxt == "EX1DR":
            n = len(self.shift)
            if n <= 64:
                tdo = sum(b << i for i, b in enumerate(self.tdo_bits))
                self.emit(ts, f"JTAG DR {n} bits tdi=0x{sum(b << i for i, b in enumerate(self.shift)):x} tdo=0x{tdo:x}")
            else:
                self.emit(ts, f"JTAG DR {n} bits (data stream)")
        if nxt in ("CAPIR", "CAPDR"):
            self.shift, self.tdo_bits = [], []
        if nxt == "RESET" and st != "RESET":
            self.emit(ts, "JTAG TAP reset")
        self.tap = nxt

    def describe(self, word, n):
        if n != 16:
            return ""
        if self.target() == "njw1195a":
            data, sel, chip = word >> 8, (word >> 4) & 0xF, word & 0xF
            what = {0: "vol1A", 1: "vol1B", 2: "vol2A", 3: "vol2B", 4: "inselA", 5: "inselB"}.get(sel, f"sel{sel}")
            if sel <= 3:
                db = "mute" if data == 0 else f"{31.5 - (data - 1) * 0.5:+.1f} dB"
                return f"chip{chip} {what} = 0x{data:02x} ({db})"
            return f"chip{chip} {what} = 0x{data:02x}"
        # hm100 frame: (reg << 10) | data[9:0] (docs/hm100-protocol.md)
        if word == 0x4C00:
            return "coef commit"
        reg, data = word >> 10, word & 0x3FF
        if reg == 0:
            mode = {0: "pcm", 1: "spdif", 2: "dsd"}.get(data & 0x3, f"mode{data & 0x3}")
            return f"reg0 RATE data=0x{data:03x} ({mode}, f0={data >> 9} f1={(data >> 7) & 3} f2={(data >> 3) & 0xF})"
        if reg == 3:
            bits = [n for b, n in ((1, "load_flash"), (2, "erase_flash!"), (3, "sar_bypass"), (4, "osr_bypass"), (9, "power_down")) if data >> b & 1]
            return f"reg3 CTRL data=0x{data:03x} input_select={(data >> 6) & 7} {' '.join(bits)}"
        name = {1: "GPO1", 2: "GPO2", 0x10: "COEF_MODULE", 0x11: "COEF_ADDR", 0x12: "COEF_BYTE", 0x13: "COEF_13"}.get(reg, "?")
        return f"reg{reg:#x} {name} data=0x{data:03x}"

    def feed(self, path):
        for raw in open(path, errors="replace"):
            m = LINE.match(raw)
            if not m:
                continue
            ev, rest, ts = m["ev"], m["rest"], m["ts"]
            if ev == "gpio_value":
                g = GPIO.match(rest)
                if not g:
                    continue
                num, kind, val = int(g[1]) - self.base, g[2], int(g[3])
                if kind == "set":
                    self.on_set(ts, num, 1 if val else 0)
                elif num == TDO:
                    self.lvl[TDO] = 1 if val else 0
            elif ev == "tracing_mark_write":
                self.emit(ts, f"--- {rest.strip()}")
            elif ev.startswith("spi_"):
                self.emit(ts, f"{ev} {rest.strip()}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", type=int)
    ap.add_argument("--debugfs-gpio")
    ap.add_argument("traces", nargs="+")
    a = ap.parse_args()
    base = a.base if a.base is not None else tlmm_base(a.debugfs_gpio) if a.debugfs_gpio else 0
    for t in a.traces:
        print(f"===== {t} (tlmm base {base})")
        Decoder(base, sys.stdout).feed(t)


if __name__ == "__main__":
    main()
