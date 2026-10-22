# Audio: the hm100 FPGA DAC, the analog chain, S/PDIF, DSD and the Darwin filters

How the RS6 plays sound: the HiBy hm100 FPGA DAC and its control protocol, the analog chain and the
stock driver's settings, the stock playback path from the HAL to the FPGA, the coaxial S/PDIF output and
native DSD (stock and mainline), and the stock Darwin FIR filter files.

## Contents

- [Sources and conventions](#sources-and-conventions)
- [The hm100 FPGA](#the-hm100-fpga): part, pins, bitstreams, SRAM load, control words, rate words, init
  and power, FIR filters and R2R calibration
- [The analog chain and the stock driver settings](#the-analog-chain-and-the-stock-driver-settings):
  actors, rails, output targets, power sequences, delays, volume, settings sysfs, dangerous attributes
- [The stock playback path](#the-stock-playback-path): capture caveats, stream setup, rates and clocking,
  the traced PO sequence, the other outputs, who writes what, a minimal driver sequence
- [Coax S/PDIF and native DSD](#coax-spdif-and-native-dsd): stock S/PDIF and DSD, the coax stream
  format, the mainline design, review fixes, the `rs6-spdif` package, how to check, open items, patches
- [Darwin filters](#darwin-filters): provenance, how stock lists and selects them, `darwinctl` on Nura

## Sources and conventions

Stock facts come from HiBy's firmware 1.80. Nothing was run on the device for these notes.

- Kernel: the stock GPL kernel 4.4.153, kallsyms via vmlinux-to-elf, static disassembly passes
  (2026-10-20, including a second pass on control words and calibration). The hm100, analog-chain, S/PDIF
  and DSD parts were read from the slot A kernel; the playback-path part from the slot B kernel
  `bootb/Image` (#16), the running firmware. Where both are cited, slot A is #15. The sequencing code is
  the same in both (see [The stock playback path](#the-stock-playback-path)); the addresses differ, so each
  address below is from the slot of the part it is in unless it is labelled.
- Addresses are kernel virtual addresses (`Image` offset = VA - 0xffffff8008080000). HAL addresses are ELF
  vaddrs.
- Device tree: the stock DTB #96 (`dtb96.dts`, appended to the stock boot image). The slot B appended DTB
  #96 is identical.
- HAL and apps: the closed `vendor_b` HAL `lib64/hw/audio.primary.sdm660.so` (Ghidra 12.1 with its
  `.gnu_debugdata` MiniDebugInfo symbols), `system_b` apps and framework. The closed HAL is only the
  source of facts, not reproduced.
- Captures: offline captures taken with `docs/re-tools/run-capture.sh` and decoded with
  `docs/re-tools/decode-trace.py`. The capture files named below (`play_44100_16.txt`, `out_*.txt`,
  `traces/*`) are not published.
- Darwin filters: the EDL dump and a copy of `/data/vendor/misc` from a running stock unit (see
  [Darwin filters](#darwin-filters)).

Evidence tags: **confirmed** = seen in a capture (trace, dmesg, tinymix, getprop), **static** = read from
a binary or config, **inferred** = reasoned from static facts, not observed, **guess** = plausible,
nothing in the evidence decides it, **open** = not settled. For the mainline port, "on the unit" and "by
ear" mean tested on an RS6 running it.

## The hm100 FPGA

The hm100 is HiBy's "Darwin" DAC: an FPGA that takes I2S from the SoC and drives an R2R DAC. Everything in
this part is static unless tagged.

### Part

Gowin GW1N(R)-9, IDCODE 0x1100581B (openFPGALoader masks the top nibble, so it reports GW1NR-9).
`hm100_set_id_code` (0xffffff8008cee0b4) accepts 0x1100581B and 0x0900281B; only 0x1100581B selects the
GW1N-9 GPO name tables. The firmware set carries a GW1N-9C variant of each bitstream as well, which the
mainline driver picks by IDCODE.

### Pins

| TLMM gpio | JTAG | control SPI | NJW1195A |
|---|---|---|---|
| 8 | TDI | SDO | DATA |
| 9 | TDO | | |
| 10 | TMS | CS (active low) | LATCH |
| 11 | TCK | CLK (sample on rising) | CLOCK |
| 12 | `hm100,reset-gpio`: run/stop (RUN), see below | | |
| 13 | | share-spi-select (1 = NJW1195A) | |
| 44 | jtag-select | | |
| 55 | FPGA power | | |

- The DT has `hm100,jtag-io-as-spi-io`, so `hm100_probe` (0xffffff8008cef86c) reuses TDI/TCK/TMS as
  SDO/CLK/CS.
- gpio 12 is driven by `hm100_start` (high) and `hm100_stop` (low), around every rate change and at stream
  start. It is not the configuration reset.
- gpio 13: `hm100_share_spi_lock` (0xffffff8008ceefc0) takes the SPI mutex and sets it to 1 before
  NJW1195A writes; `hm100_share_spi_unlock` sets 0.
- gpio 44: `hm100_jtag_io_func_select(0)` before JTAG programming, `(1)` after it in
  `hm100_program_by_hw_param`. `hm100_program` leaves it at 0 on success. In the captures it is only ever
  set to 0 (10 events, one per bitstream load, never `set 1`), idle debugfs shows `out 0`, and every
  control and NJW write in every trace happens with gpio44 = 0 (confirmed). Only
  `hm100_program_by_hw_param`, the DSD design-switch path, sets 1 after a load. Whether the control port
  also works at 1 is open: no capture shows control writes at that level.
- Power: there is no `hm100,power-regulator` in the DT, so `hm100_power_enable` drives `hm100,power-gpio`
  (55).

During the bitstream data phase gpio 8/11 are muxed to `blsp_spi3` (`spi@c177000`, 10 MHz, DT node
`hiby,hbc3000_ram`) and TMS is held low.

### Bitstreams

`FS_data` (PCM design) and `FS_dsd_data` (DSD design) in the kernel's .data. Each: 4-byte header `GW1N`,
22 x 0xFF, `A5 C3` sync, `06 00 00 00 11 00 58 1B`, ...; 1737 pages x 256 bytes (444672 bytes). Extract
them with `tools/extract-hm100-blobs.py`.

The DSD design is only used when `dsd_mode` is "mdsd": `hiby_snd_hw_params` then calls
`hm100_program_by_hw_param(1)`, while the default "dsd" mode keeps the PCM design and only switches reg 0
to mode 2 (see [Stream setup in the kernel](#stream-setup-in-the-kernel)). `hm100_program_by_hw_param`
reprograms only when the requested design differs from `hm100_fw_version`, so the design is swapped at a
PCM/DSD change only in "mdsd" mode.

### SRAM load

`hbc3000_jtag_program_ram`:

1. TAP reset; IR 0x11 READ_IDCODE, accept GW1N-1 / GW1N-4 / GW1N-9(C) ids.
2. IR 0x13 READ_USERCODE; skip programming if it matches the expected id.
3. Reset; IR 0x3C x2; 0x15 CONFIG_ENABLE; 0x05 ERASE_SRAM x2; 0x3A CONFIG_DISABLE.
4. 0x15; 0x17 XFER_WRITE; TMS 1,0,0 to Shift-DR; stream the pages over SPI; TMS 1,1,0.
5. 0x3A; 0x02 NOOP; reset; 0x13 verify USERCODE. 0x41 STATUS is only read on failure.

This differs from openFPGALoader's writeSRAM (no 0x12 INIT_ADDR, no 0x09, no 0x0A/0x08 checksum). The
load takes about 464 ms (confirmed, BAL trace).

### Control words

#### Framing (`hm100_spi_write_lock_or_unlock.constprop.10` 0xffffff8008ceeb6c)

CLK low, CS low, then 16 x (CLK low, SDO = bit 15, shift left, CLK high), then CS high (CLK is left high).
MSB first, data changes while CLK is low. Write only: no read path, no R/W flag, no address auto-increment.
The constprop dropped the lock argument; the "lock" is the `g_hm100` mutex taken by callers, not an
on-wire lock/unlock word.

#### Frame layout (`hm100_set_reg_data_unlock` 0xffffff8008ceec38)

`frame = (reg << 10) | (data & 0x3ff)`: bits 15:10 register (6 bits), bits 9:0 data. Register 0 has
opcode 0, so its 16-bit frame equals the data word. `hm100_set_reg_data` (0xffffff8008ceeee8) wraps it in
the mutex.

#### Register map

| reg | frame | writer | meaning |
|---|---|---|---|
| 0x00 | `0x0000 \| word` | `hm100_set_samplerate` 0xffffff8008cef520 | rate / format, see [Rate words](#rate-words) |
| 0x01 | `0x0400 \| v` | `hm100_set_gpo`, `hm100_enable_init` | GPO group 0 (10 pins) |
| 0x02 | `0x0800 \| v` | `hm100_set_gpo`, `hm100_enable_init` | GPO group 1 (10 pins) |
| 0x03 | `0x0c00 \| v` | several | control, shadow `spi_reg_power` (bss 0xffffff800a695628, starts 0) |
| 0x10 | `0x4000 \| m` | `hm100_set_module_coef` 0xffffff8008ceec5c | coefficient module select |
| 0x11 | `0x4400 \| a` | `hm100_set_module_coef` | start address in the module |
| 0x12 | `0x4800 \| b` | `hm100_set_module_coef` | one data byte (bits 7:0) |
| 0x13 | `0x4c00` | `hm100_set_module_coef` (raw frame) | commit / end of block |

Reg 3 bits (shadow, the whole 10-bit value is rewritten each time):

| bit | name | writer |
|---|---|---|
| 0 | never set | |
| 1 | load_flash | `hm100_enable_init`, `load_flash_set`: set, 2 ms, clear |
| 2 | erase_flash | `erase_flash_set`: set, 140 ms, clear (never touch) |
| 3 | sar_bypass (disables R2R correction) | `sar_bypass_set`: stop, write, start |
| 4 | osr_bypass (NOS) | `hm100_osr_bypass_set_by_vendor` 0xffffff8008cf012c |
| 5 | never set | |
| 8:6 | input_select | `input_select_set` |
| 9 | power_down | `power_down_set`; cleared by `hm100_enable_init` |

#### Coefficient block (`hm100_set_module_coef(module, addr, buf, n)`)

`0x10 module`, `0x11 addr`, then per 32-bit word four `0x12` frames, bytes 31:24, 23:16, 15:8, 7:0, then
raw `0x4c00`. Modules used: 0 = live SAR (R2R) coefficients, 1 = write-back target (see
[FIR filters and R2R calibration](#fir-filters-and-r2r-calibration)), 2 = FIR (256 taps at addr 0).
`coef_input` accepts modules 0..5.

#### GPO

`hm100_set_gpo(name, val)` (0xffffff8008cefdf0) looks the name up in group 0, then group 1, sets or clears bit i of that group's 16-bit shadow
(`hm100_gpio_group0_val` 0xffffff800a695734, `group1_val` 0xffffff800a695738) as `val << i` (no masking),
and writes the whole shadow to reg 1 or reg 2. Unknown names are ignored.

| bit | reg 1 (group 0) | reg 2 (group 1) |
|---|---|---|
| 0 | IOB17B | IOR11B |
| 1 | IOB27A | IOR11A |
| 2 | IOB27B (bal_amp_en) | IOR5A |
| 3 | IOB29A (po_amp_en) | IOT42A |
| 4 | IOB29B (hp_mute) | IOT37B |
| 5 | IOB35A (iv_mute) | IOT37A |
| 6 | IOB35B (pcm_dsd_sel) | IOT32A |
| 7 | IOB39A (lpf_pwr_en) | IOT22B |
| 8 | IOB39B | IOT22A |
| 9 | IOR12A | IOT12B |

GW1N-1 tables also exist (group 0 IOB6B, IOB10A, IOB10B, IOB11A, IOB11B; group 1 IOR6C, IOR6B, IOR6A,
IOR5A, IOT17A) but are not used on the RS6. Only group-0 names are used by the RS6 DT.

### Rate words

`hm100_set_samplerate` (0xffffff8008cef520) picks one of two tables from `spdif_enabled` (set by
`hm100_set_spdif_mode` while the Spdif output is active, see
[S/PDIF in the stock kernel](#spdif-in-the-stock-kernel)): `spdif_table` (8 entries at
0xffffff8009226a58, mode 1) if set, else `dsd_i2s_table_hm100` (14 entries, mode 0 if
32000 <= rate <= 768000, else mode 2). It then stores the rate, drops RUN (`hm100_stop`, gpio 12 low) and
writes reg 0. It does not restart; `hm100_start` comes from trigger or `hm100_enable_init`.

Table entries are 8 bytes: u32 rate, u8 f0, u8 f1, u8 f2, pad. Frame build (one frame, reg 0):

`data = (f0 << 9) | ((f1 & 3) << 7) | ((f2 & 0xf) << 3) | mode`, masked to 10 bits.

- bit 9 = f0 = clock family (0 = 44.1k / 45.1584 MHz, 1 = 48k / 49.152 MHz)
- bits 8:7 = f1, bits 6:3 = f2 (rate-dependent dividers or oversampling selects, meaning open), bit 2 = 0
- mode bits 1:0: 0 = PCM, 1 = S/PDIF, 2 = DSD

The lookup is linear and stops at the last entry, so an unknown rate gets the last entry's word: on the
S/PDIF table **any rate not in the table gets the 384000 word 0x0229**. The PCM/DSD table does the same
with the mode bits taken from the requested rate: an unknown rate in 32k..768k gets mode 0, one above gets
mode 2.

`dsd_i2s_table_hm100` ("word" is `f2 << 16 | f1 << 8 | f0`, a little-endian read of bytes 4..6):

| rate | word | reg 0 frame |
|---|---|---|
| 44100 | 0x40200 | 0x0120 |
| 48000 | 0x40201 | 0x0320 |
| 88200 | 0x20100 | 0x0090 |
| 96000 | 0x20101 | 0x0290 |
| 176400 | 0x10000 | 0x0008 |
| 192000 | 0x10001 | 0x0208 |
| 352800 | 0x00100 | 0x0080 |
| 384000 | 0x00101 | 0x0280 |
| 705600 | 0x50000 | 0x0028 |
| 768000 | 0x50001 | 0x0228 |
| DSD 2822400 (DSD64) | 0x20000 | 0x0012 |
| DSD 5644800 (DSD128) | 0x10000 | 0x000a |
| DSD 11289600 (DSD256) | 0x00000 | 0x0002 |
| DSD 22579200 (DSD512) | 0x50100 | 0x00aa |

`spdif_table`:

| rate | f0 | f1 | f2 | reg 0 frame |
|---|---|---|---|---|
| 44100 | 0 | 0 | 2 | 0x0011 |
| 48000 | 1 | 0 | 2 | 0x0211 |
| 88200 | 0 | 0 | 1 | 0x0009 |
| 96000 | 1 | 0 | 1 | 0x0209 |
| 176400 | 0 | 0 | 0 | 0x0001 |
| 192000 | 1 | 0 | 0 | 0x0201 |
| 352800 | 0 | 0 | 5 | 0x0029 |
| 384000 | 1 | 0 | 5 | 0x0229 |

Confirmed on the wire: 0x0120 at 44.1k and 0x0320 at 48k (`play_44100_16.txt` line 72, dmesg
"samplerate:44100 0x0120"; `play_48000_16` the same lines), and the S/PDIF words 0x0011 at 44.1k and
0x0009, 0x0001, 0x0201 in the HiBy Music runs.

The DSD rate families use the same f2 values as S/PDIF: DSD64 f2 = 2 (like S/PDIF 44.1k), DSD128 f2 = 1
(88.2k), DSD256 f2 = 0 (176.4k). **Inferred**: BCLK is the same in both (5.6448 / 11.2896 / 22.5792 MHz);
the modes differ in what the FPGA does with the data line.

### Init sequence and power

`hm100_enable_init` (0xffffff8008cef648):

1. reg 3 with bit 9 cleared
2. reg 1, reg 2 from the GPO shadows
3. `hm100_set_samplerate(hm100_sample_rate)` (stop, reg 0)
4. `hm100_start`
5. reg 3 bit 1 set, udelay 2000, cleared (load_flash pulse)
6. module 2 from `hm100_fir_coef_custom` (256 words), done twice
7. `hm100_stop`

Probe (`hm100_probe`) runs `hm100_enable`, `hm100_stop`, `hm100_set_samplerate(44100)`, `hm100_disable`.

| fn | addr | does |
|---|---|---|
| `hm100_power_enable(g, on)` | 0xffffff8008cee6c4 | regulator if `hm100,power-regulator`, else power-gpio (TLMM55) = on. The RS6 uses the gpio |
| `hm100_enable` | 0xffffff8008cef714 | if `!hm100_enabled`: `hm100_program` (power on, 50 ms, up to 3 tries of jtag-select = 0 + `hbc3000_program_ram`; on failure jtag-select = 1, power off, 1 s, power on, 50 ms). Then `hm100_enable_init` if loaded |
| `hm100_disable` | 0xffffff8008cef4e0 | power off, `hm100_enabled = 0` |
| `hm100_start` / `hm100_stop` | 0xffffff8008cef214 / 0xffffff8008cef410 | reset-gpio TLMM12 = 1 / 0 |
| `hm100_done` | 0xffffff8008ceff68 | `hm100_stop` |
| `hm100_suspend` | 0xffffff8008cee150 | (cancel program work if no `jtag-spi-mode`), power off, `hm100_enabled = 0`, SDO / CLK / CS low |
| `hm100_resume` | 0xffffff8008cee26c | CS (TLMM10) high; without `jtag-spi-mode` also power on and queue reprogram after 500 jiffies. The RS6 has `jtag-spi-mode`, so nothing is reloaded until the next `hm100_enable` |
| `hm100_poweroff` | 0xffffff8008cee114 | power off (shutdown hook) |
| `sound_platform_suspend` | 0xffffff8008cf2474 | `flush_delayed_work(switch_work)` |
| `sound_platform_resume` | 0xffffff8008cf216c | printk only |

### FIR filters and R2R calibration

- A `.flt` file is 1024 bytes = 256 x int32 FIR taps, loaded into FPGA module 2 with
  `hm100_set_module_coef(2, 0, buf, 256)` (x2) by `hm100_filter_path_set_by_vendor`.
- `hm100_fir_coef_default`: 4 KB in the kernel = 4 filters x 256 taps. Probe copies filter 0 into
  `hm100_fir_coef_custom`, which `hm100_enable_init` reloads on every power-up.
- `hm100_set_filter_coef` (0xffffff8008ceed6c) loads filter idx 0..3 straight from the default table
  (module 2 only, once). It rejects an index above 3 and does not touch the custom buffer, so the next
  `hm100_enable_init` (every output power-on) reverts to the custom/default buffer.
- NOS = `osr_bypass` (reg 3 bit 4); `sar_bypass` (reg 3 bit 3) disables the R2R correction.

SAR / R2R calibration (`hm100_sar_coef_data`, bss 0xffffff800a695630, 256 B):

- Layout: 64 x u32, entries 0..31 = left (module 0, addr 0), 32..63 = right (module 0, addr 0x200).
- Filled by `hm100_probe` (loop at 0xffffff8008cefc2c) with ideal binary weights:
  `buf[i] = buf[32 + i] = 0x80000000 >> i`, i = 0..31. Nothing reads it from a file or from the FPGA.
- Per-unit calibration lives in the FPGA's internal flash. Every `hm100_enable_init` pulses reg 3 bit 1,
  the same bit `load_flash_set(1)` pulses, so the FPGA reloads its stored coefficients into module 0 by
  itself at each power-up (meaning of the bit: guess from the sysfs name; the pulse itself is static). The
  kernel never sends the buffer during normal operation.
- Host paths that touch it (all sysfs, all userspace-driven):
  - `coef_input "1 addr data"`: stores `data` at `buf[(addr & 0x3f) + 32 * ((addr >> 9) & 1)]` and writes
    it live to module 0.
  - `load_flash 0`: resets the buffer to ideal weights and writes both halves to module 0.
  - `write_back`: writes both halves to module 1 (guess: flash staging, used after `erase_flash`).
- Guess at the factory flow: `calib_process start` / other (unmute / mute the active output), tune
  module 0 through `coef_input`, then `erase_flash`, `write_back`.
- For a mainline driver: leave the buffer alone and keep the reg 3 bit 1 pulse in init.

The attributes that reach the flash are in [Dangerous attributes](#dangerous-attributes).

## The analog chain and the stock driver settings

The machine glue around the FPGA: rails, mutes, output targets, the NJW1195A volume chip and the
`sa_sound_setting` sysfs interface. Everything here is static unless tagged.

### Actors

| what | where | notes |
|---|---|---|
| machine glue (`hiby,sound-plat`) | `sound_platform_probe` 0xffffff8008cf2cec | state in `g_sound_platform` (heap, 0x1a0 B) |
| ASoC hooks | `hiby_snd_startup/hw_params/trigger/shutdown` 0xffffff8008cf3c60 / cf3cc0 / cf3b80 / cf3ecc | called from sdm660-common `msm_mi2s_snd_*` |
| FPGA driver (`hiby,hm100`) | `hm100_probe` 0xffffff8008cef86c | see [The hm100 FPGA](#the-hm100-fpga) |
| volume chip (`njw,njw1195a`) | `njw1195a_spi_write` 0xffffff8008c661d8 | bit-banged on the FPGA's control pins |
| settings sysfs | `sa_sound_setting_probe` 0xffffff8008cf1180 | dispatches through the `setting_function` table |

### sound-plat DT lines and rail helpers

SoC gpios are requested by `gpio_request_from_of` (0xffffff8008cf2c64) and driven output-low at probe.
String values are FPGA GPO names, passed to `hm100_set_gpo` (`hbc3000_request_from_of` 0xffffff8008cf2890
just stores the string).

| prop | value | struct off | used by |
|---|---|---|---|
| `audio_dc_dc_en` | TLMM 28 | 0x150 | `hiby_dac_power` |
| `dac_pwr_en` | TLMM 40 | 0x154 | `hiby_dac_power` |
| `lpf_pwr_en` | GPO IOB39A | 0x158 | `hiby_lpf_power` |
| `vol_pwr_en` | TLMM 15 | 0x160 | `hiby_volume_power` (NJW1195A supply, guess) |
| `po_pwr_en` | pm660 GPIO 13 (phandle 0x224 = `pm660-gpio`; global gpio 1023) | 0x164 | `hiby_po_amp_power` |
| `po_amp_en` | GPO IOB29A | 0x168 | `hiby_po_amp_power` |
| `bal_amp_en` | GPO IOB27B | 0x170 | `hiby_bal_po_amp_power` |
| `pcm_dsd_sel` | GPO IOB35B | 0x178 | `hiby_snd_hw_params` (1 = DSD) |
| `lpf_sel` | TLMM 34 | 0x180 | `hiby_lpf_sel` |
| `po_bal_po_sel` | TLMM 29 | 0x184 | `hiby_headphone_balance_select` (1 = balance) |
| `iv_mute` | GPO IOB35A | 0x188 | `hiby_iv_mute` (1 = mute) |
| `lpf_mute` | TLMM 61 | 0x190 | mute helpers |
| `line_mute` | TLMM 76 | 0x194 | mute helpers |
| `hp_mute` | GPO IOB29B | 0x198 | `hiby_po_mute` (1 = mute) |

| helper | addr | action |
|---|---|---|
| `hiby_dac_power(on)` | 0xffffff8008cf34b4 | TLMM28 = on, 10 ms, TLMM40 = on |
| `hiby_lpf_power(on)` | 0xffffff8008cf2208 | GPO IOB39A = on |
| `hiby_lpf_sel(v)` | 0xffffff8008cf2120 | TLMM34 = v |
| `hiby_volume_power(on)` | 0xffffff8008cf20f0 | TLMM15 = on |
| `hiby_po_amp_power(on)` | 0xffffff8008cf30c0 | pm660 GPIO13 = on, 10 ms, GPO IOB29A = on |
| `hiby_bal_po_amp_power(on)` | 0xffffff8008cf21bc | GPO IOB27B = on |
| `hiby_iv_mute(m)` | 0xffffff8008cf27d8 | GPO IOB35A = m |
| `hiby_po_mute(m)` | 0xffffff8008cf2750 | m=1: TLMM61 = 0, IOB29B = 1. m=0: IOB29B = 0, TLMM61 = 0 |
| `hiby_lo_mute(m)` | 0xffffff8008cf2654 | m=1: TLMM76 = 1, TLMM61 = 1. m=0: TLMM61 = 0, TLMM76 = 1 |
| `hiby_bal_lo_mute(m)` | 0xffffff8008cf25c8 | m=1: TLMM76 = 1, TLMM61 = 1. m=0: TLMM61 = 0, TLMM76 = 0 |
| `hiby_headphone_balance_select(s)` | 0xffffff8008cf26d8 | TLMM29 = (s == "balance") |
| `hiby_delay(n)` | 0xffffff8008cf258c | n x udelay(1000), busy wait |

`lo_mute(0)` leaves TLMM76 high while `bal_lo_mute(0)` drives it low, and in the traces TLMM76 is high in
LO and low in BAL-LO. So TLMM76 (`line_mute`) behaves more like an LO / BAL-LO selector than a mute
(inferred). TLMM61 (`lpf_mute`) never goes high on PO/BAL.

### Output targets

`Output Select` mixer (`output_select_put` 0xffffff8008ce8ad0, texts in `output_select_text`): None,
Lineout, Headset, Balance, Spdif, Coax, Iis, BalanceLo. `hiby_output_switch` (0xffffff8008cf3a04) maps by
strcmp: Lineout = 1 (LO), Headset = 2 (PO), Balance = 3 (BAL), Spdif = 4, BalanceLo = 7 (BAL-LO).

- Anything else (None, Coax, Iis) keeps the old target and queues `switch_work` after 500 jiffies (HZ =
  100, so 5 s), which runs `hiby_target_poweroff(current)` and sets the target to 0
  (`switch_work_schedule` 0xffffff8008cf365c). Confirmed: `out_Iis.txt`, power-off 4.6 s after play.
- For a valid target: the same as the current one does nothing; otherwise `hiby_target_poweroff(old)`
  then `hiby_target_poweron(new)`, all under `hiby_target_mutex`.
- Every power-off ends in `hm100_disable`, which cuts FPGA power. So every output change power-cycles the
  amps and the FPGA and reprograms it (`hm100_enable` reloads the PCM bitstream because `hm100_enabled`
  was cleared). Confirmed in the `out_*` traces.

### Power-on, mute and power-off per target

`hiby_target_poweron` (0xffffff8008cf36f0). Always first: `only_after_poweron_umute = 1`,
`hm100_fw_version = 0` (PCM design assumed). Always last: `current_target_on = target`, `sp+0x134 = 1`
(unmute pending).

| step | BAL (3) | PO (2) | BAL-LO (7) | LO (1) | Spdif (4) |
|---|---|---|---|---|---|
| 1 | po_mute(1) | po_mute(1) | bal_lo_mute(1) | lo_mute(1) | bal_po_amp(0) |
| 2 | dac_power(1) | dac_power(1) | dac_power(1) | lpf_sel(1) | po_amp(0) |
| 3 | hm100_enable | hm100_enable | hm100_enable | dac_power(1) | volume_power(0) |
| 4 | 10 ms | 10 ms | 10 ms | hm100_enable | lpf_sel(0) |
| 5 | lpf_power(1) | lpf_power(1) | lpf_power(1) | 10 ms | lpf_power(0) |
| 6 | 10 ms | 10 ms | 10 ms | lpf_power(1) | dac_power(0) |
| 7 | lpf_sel(1) | lpf_sel(1) | lpf_sel(0) | 10 ms | hm100_enable |
| 8 | 50 ms | 10 ms | volume_power(0) | volume_power(0) | |
| 9 | volume_power(1) | volume_power(1) | po_amp(0) | po_amp(0) | |
| 10 | po_amp(1) | po_amp(1) | bal_po_amp(0) | bal_po_amp(0) | |
| 11 | 10 ms | 10 ms | | lpf_sel(0) | |
| 12 | bal_po_amp(1) | bal_po_amp(0) | | | |
| 13 | 50 ms | 10 ms | | | |
| 14 | `lrch_volume_imm_set(3, L, R, 1)` | `lrch_volume_imm_set(2, L, R, 1)` | | | |
| 15 | NJW 0x2840, 0x2850 | NJW 0x2840, 0x0050 | | | |
| 16 | balance_select("balance") | balance_select("headphone") | | | |

The NJW writes in step 15 are wrapped in `hm100_share_spi_lock/unlock` (share-spi-select TLMM13 = 1).
Spdif powers the whole analog chain down and keeps only the FPGA up (see
[S/PDIF in the stock kernel](#spdif-in-the-stock-kernel)).

Mute / unmute (`hiby_target_poweron_mute` 0xffffff8008cf32c4, `_umute` 0xffffff8008cf2b44):

| target | mute | unmute |
|---|---|---|
| BAL (3) | IOB35A = 1, TLMM76 = 0, TLMM61 = 0, IOB29B = 1 | IOB35A = 0, IOB29B = 0, TLMM61 = 0, TLMM76 = 0 |
| PO (2) | IOB35A = 1, po_mute(1) | IOB35A = 0, po_mute(0) |
| BAL-LO (7) | IOB35A = 1 | IOB35A = 0, bal_lo_mute(0) |
| LO (1) | IOB35A = 1 | IOB35A = 0, lo_mute(0) |
| Spdif (4) | nothing | nothing |

Power-off (`hiby_target_poweroff` 0xffffff8008cf3504), ends with `current_target_on = 0`:

| PO / BAL (2, 3) | BAL-LO (7) | LO (1) | Spdif (4) |
|---|---|---|---|
| po_mute(1), 10 ms | bal_lo_mute(1), 100 ms | lo_mute(1), 10 ms | bal_po_amp(0) |
| bal_po_amp(0) | same chain as left | same chain as left | po_amp(0) |
| po_amp(0) | | | volume_power(0) |
| volume_power(0) | | | lpf_power(0) |
| lpf_sel(0) | | | dac_power(0) |
| lpf_power(0) | | | hm100_disable |
| hm100_disable | | | |
| dac_power(0) | | | |
| po_mute(0) | bal_lo_mute(0) | lo_mute(0) | |

### Delays

All delays in the sequences are hardcoded `hiby_delay()` / udelay calls. Names like `po_poweron_before`
are not DT properties: they are module statics listed in `power_delay_array` (0xffffff8009226e70),
writable through the `delay_val` attribute, with these defaults (ms, guess on unit):

| name | default | name | default |
|---|---|---|---|
| lo_poweron_before/after | 200 / 200 | po_poweron_before/after | 300 / 300 |
| lo_poweroff_before/after | 200 / 1000 | po_poweroff_before/after | 200 / 1000 |
| bal_lo_poweron_before/after | 300 / 300 | bal_poweron_before/after | 300 / 300 |
| bal_lo_poweroff_before/after | 200 / 1000 | bal_poweroff_before/after | 200 / 1000 |

No load of these variables (0xffffff800a3044a0..0x4dc) exists in the driver text
(0xffffff8008cec400..0xffffff8008cf4000), so they have no effect. `unmute_delay_ms` / `mute_delay_ms`
(`sp+0x120` / `+0x124`) are zeroed in probe and never written, so trigger work runs immediately.

### Volume

Who sets it:

- HAL: `adev_set_master_volume` 0x242f8 sets level = (int)(v x 100 + 0.5), clamped to 0..100, and writes
  **Plat Left**, then **Plat Right** (static). That is the only writer. The caller is AudioFlinger master
  volume (inferred: services.vdex has 19 MasterVolume strings, and HiBy Music sets no Plat control
  directly).
- Kernel: `Plat Left Playback Volume` (`plat_lch_vol_put` -> `hiby_lch_vol_put`, 0xffffff8008cf3990, slot
  B 0xffffff8008cf3ca4) only stores `left_level` (clamped 0..100). `Plat Right Playback Volume`
  (`hiby_rch_vol_put` 0xffffff8008cf39b8, slot B 0xffffff8008cf3ccc) stores `right_level` and calls
  `lrch_volume_imm_set(current_target_on, left, right, 0)`. Write Left first.
- Boot defaults (.data): `left_level = right_level = 90`, `plat_dsd_compensate = 6`; `plat_pregain` and
  `plat_vol_gain` start at 0 in bss until the init rc writes the properties.
- **Readback is fake:** both Plat controls use `plat_dummy_get` (slot B 0xffffff8008ce8040, `return 0`), so
  tinymix always shows 0. A script that saves and restores them, like `device.sh vol()`, writes volume 0.

`lrch_volume_imm_set(target, l, r, now)` 0xffffff8008cf28d0:

- Acts only for target 2 (PO) and 3 (BAL): LO and BAL-LO have no NJW volume.
- `base = plat_pregain`; `+ 5 * plat_vol_gain` unless the target is 1 or 7; `+ 5 * plat_dsd_compensate`
  when `output_format == 1` (DSD).
- Balance `b = plat_vol_lrbalance`: b < 0 gives L += -5b, b > 0 gives R += 5b.
- `L = njw1195a_volume_db[l] + offL`, clamp to [-955, 315], `code = 255 - (L + 955) / 5`; the same for R.
  Units are 0.1 dB, so one code step is 0.5 dB and code 255 is the floor (guess on the dB meaning).
  Example: level 90 with gain middle gives -110, code 0x56. The traced code 0x8e is level 39 with gain
  middle (confirmed words, `out_Balance`).
- `now = 1`: share-SPI lock, NJW words `codeL<<8 | 0x00`, `codeL<<8 | 0x10`, `codeR<<8 | 0x20`,
  `codeR<<8 | 0x30`, unlock. `now = 0`: queue `volume_work` (0xffffff8008cf2a44), which steps
  `current_left/right_level` by 1 per jiffy (10 ms) toward `left/right_level`, writing each step to the
  NJW.
- `njw1195a_volume_db` (0xffffff8009226ff8, `blobs/njw1195a_volume_db.bin`): 102 x int32, index = level
  0..100: -960, -880, -830, ... -280, then 0.5 dB steps to 0 at index 100 and 101.

NJW1195A (`njw1195a_*`, DT `njw,njw1195a`):

- Pins: `njw1195a,spi-sdo` TLMM8, `spi-clk` TLMM11, `spi-cs` TLMM10 (latch), `spi-share` present (struct
  +0x2c / +0x28 / +0x24, `njw1195a_probe` 0xffffff8008c65de8).
- `njw1195a_spi_write(w)` 0xffffff8008c661d8: CLK 0, LATCH 1 then 0, then 16 x (CLK 0, DATA = bit15,
  shift, CLK 1), CLK 0, LATCH 1. MSB first, latched on LATCH rising. It does not touch share-spi-select;
  callers must hold `hm100_share_spi_lock` (TLMM13 = 1).
- Word: bits 15:8 data, bits 7:4 select, bits 3:0 = 0. Selects used: 0x0..0x3 volume, 0x4 / 0x5 input
  select. Reading 0x0..0x3 as volume ch1..4 and the low nibble as chip address 0 matches the datasheet
  layout as remembered, not checked (guess).
- `njw1195a_set_volume(l, r)` 0xffffff8008c664a0: clamp to [-955, 95], `code = 255 - (v + 955) / 5`,
  stores L in +0x1c, R in +0x18, then `njw1195a_spi_write_both` 0xffffff8008c663f8 writes `L<<8 | 0x00`,
  `L<<8 | 0x20`, `R<<8 | 0x10`, `R<<8 | 0x30` with 5 us gaps. The channel-to-select mapping differs from
  `lrch_volume_imm_set` (L on 0x00/0x10 there). Not called by the sound-plat paths found.
- `njw1195a_set_mute(1)` 0xffffff8008c66574: 0xff00, 0xff20, 0xff10, 0xff30.
- Input select: `njw1195a_intput_select` 0x2840/0x2850; `_po(tube)` 0x6040/0x6050 else 0x2040/0x2050;
  `_bal_po(tube)` 0x7040/0x7050 else 0x2840/0x2850. No caller found for the tube variants.

### Settings sysfs

`sa_sound_setting` attrs (`sa_sound_setting_attributes` 0xffffff800a303cd0, all 0644). String attrs
strncmp against a list, strcpy into a `*_str` buffer, then call slot N of the table registered by
`sa_sound_setting_register(setting_function)` (slot A table at 0xffffff800a304140, slot B at
0xffffff800a3041a8). Slot B inserts `mute_enable` at slot 3, so its slot numbers from 3 on are one higher
than slot A's. NULL slots (slot A 11..15 and 17..23) only store the string. `sa_sound_setting_probe`
strcpys the defaults gain "low", lo_gain "high", bal_po_lo "bal_po", timbre "monitor". The last column is
what the stock image writes and the live value on the unit (see [Who writes what](#who-writes-what)).

| attr | store fn (slot A) | accepted input | slot A / B: handler | hardware effect | written by stock |
|---|---|---|---|---|---|
| lrbalance | `set_lrbalance` 0xffffff8008cf2010 | `%d` | 0 / 0: `plat_set_lrbalance` | `plat_vol_lrbalance` = v, volume update (0.5 dB per unit on one side) | yes, 0 |
| pregain | `set_pregain` 0xffffff8008cf1f94 | `%d` | 1 / 1: `plat_set_pregain` | `plat_pregain` = v (0.1 dB units), volume update | rc trigger exists; prop unset on this unit |
| gain | `set_gain` 0xffffff8008cf1a9c | low / middle / high | 2 / 2: `plat_set_gain` | `plat_vol_gain` = -24 / -12 / 0 (x5: -12 / -6 / 0 dB), volume update, PO/BAL only | yes, middle |
| mute_enable | `set_mute_enable` (slot B only) | any string | - / 3: NULL | none, stores the string | no |
| lo_gain | `set_lo_gain` 0xffffff8008cf1850 | low / middle / high | 3 / 4: `plat_set_lo_gain`, stub (`ret`) | none | no rc trigger (prop `vendor.audio.hw.lo_gain=high`); the `high` read back is the probe default |
| digital_filter | `set_digital_filter` 0xffffff8008cf1108 | any string | 4 / 5: `plat_set_digital_filter` 0xffffff8008cf2418 | index in `digital_fileter` -> `hm100_set_fir_coef(i)`: module 2 gets built-in filter 0..3, lost at the next power-up | yes, sharp_roll_off |
| dsd_digital_filter | `set_dsd_digital_filter` 0xffffff8008cf1090 | any string | 5 / 6: stub | none | |
| timbre | `set_timbre` 0xffffff8008cf19c0 | default / monitor / warm / tube | 6 / 7: stub | none | yes |
| dsd_compensate | `set_dsd_compensate` 0xffffff8008cf1f14 | `%d` | 7 / 8: `plat_set_dsd_compensate` | `plat_dsd_compensate` = v, +0.5 dB per unit on DSD (`.data` default 6, so +3 dB), volume update | yes, 0 |
| bal_po_lo_switch | `set_bal_po_lo_switch` 0xffffff8008cf17a4 | bal_po / bal_lo | 8 / 9: stub | none | yes |
| mqa_source | `set_mqa_source` 0xffffff8008cf1914 | yes / no | 9 / 10: stub | none | "no" at every boot (`on boot` sets both mqa props to no) |
| turbo | `set_turbo` 0xffffff8008cf16f8 | on / off | 10 / 11: stub | none | yes |
| power_p_pplus | `set_power_p_pplus_switch` | power_p / power_pplus | 11 / 12: NULL | none | **no** (prop exists: power_p; no rc trigger) |
| balpo_po_a_ab | `set_balpo_po_a_ab_switch` | zoom_a / zoom_ab | 12 / 13: NULL | none | **no** (prop exists: zoom_ab; no rc trigger) |
| balpo_po_t_n | `set_balpo_po_t_n_switch` | transistor_t / transistor_n | 13 / 14: NULL | none | **no** (prop exists: transistor_t; no rc trigger) |
| digital_output_type | `set_diftal_output_type` | spidf/iis / analog | 14 / 15: NULL | none | **no** |
| amp_eneble | `set_amp_enable_type` | on / off | 15 / 16: NULL | none | **no** |
| vendor_func | `set_vendor_function` 0xffffff8008cf0f28 | raw buffer | 16 / 17: `plat_set_vendor_func` 0xffffff8008cf22d0 | NOS (reg 3 bit 4), .flt to module 2, DSD bitstream choice; see below | yes, last value `dsd_mode mdsd`; Settings also sends `nos_enable on/off`, `filter_path <f>` |
| dac_type | `set_dac_type_function` | ignored, returns 0 | none (show: slot 18 / 19, NULL) | none, see [Dangerous attributes](#dangerous-attributes) | **no**; `init.qcom.sh` only reads it into `ro.vendor.hiby.dac_type` (empty) |
| dsd_filter | `set_dsd_filter` | dsd_low / dsd_middle / dsd_high | 19 / 20: NULL | none | no |
| lo_output_select | `set_lo_output_type` | line_out / pre_out | 20 / 21: NULL | none | no |
| play_next | `set_play_next_value` | any string | 21 / 22: NULL | none | no |
| led_work_state | `set_led_work_state_type` | led_off / led_on | 22 / 23: NULL | none | no |
| on_boot_completed | `set_on_boot_completed` (write only) | any string | 23 / 24: NULL | none | no |

Never write `dac_type`: it hangs the writer (see [Dangerous attributes](#dangerous-attributes)).

`digital_fileter` (0xffffff8009226e20): sharp_roll_off, slow_roll_off, short_delay_sharp_roll_off,
short_delay_slow_roll_off, super_sharp_roll_off, super_slow_roll_off, low_dispersion_short_delay.
`hm100_set_filter_coef` rejects an index above 3, so only the first four do anything (see
[FIR filters and R2R calibration](#fir-filters-and-r2r-calibration)).

`plat_set_vendor_func`: `sscanf("%s %s", key, val)`:

- `nos_enable on|off` -> `hm100_osr_bypass_set_by_vendor(1|0)` (reg 3 bit 4)
- `filter_path <file>` -> `hm100_filter_path_set_by_vendor` (1024-byte `.flt` into module 2, twice)
- `dsd_mode dsd|mdsd` -> `current_dsd_mode` (default "dsd")

Stock Settings sends all three through the property `vendor.audio.hw.vendor_func` (see
[Darwin filters](#darwin-filters) for `filter_path` and `dsd_mode`).

sound-plat attrs (`sys_hiby_platform_group` 0xffffff80092271b8, write only):

| attr | fn | input | effect |
|---|---|---|---|
| delay_val | `sys_set_delay_val` 0xffffff8008cf24b0 | `%s %d` | sets a `power_delay_array` var (prefix strncmp); unused |
| mute_port | `sys_set_mute_val` 0xffffff8008cf33bc | `%s %d`, name lineout / headset / balance / balance_lo | v != 0: `hiby_target_poweron_mute(1/2/3/7)`, else `_umute` |

hm100 attrs (`hm100_attributes` 0xffffff800a22a1e8):

| attr | mode | store | input | effect |
|---|---|---|---|---|
| osr_bypass | 0644 | `osr_bypass_set` 0xffffff8008cf0170 | `%d` | reg 3 bit 4 = !!v (NOS), written only on change |
| sar_bypass | 0644 | `sar_bypass_set` 0xffffff8008cef444 | `%d` | on change: reg 3 bit 3 = !!v, stop, write, start |
| input_select | 0644 | `input_select_set` 0xffffff8008cef7b4 | `%d` | on change: reg 3 bits 8:6 = v; if v != 0 and rate % 48000 != 0, `hm100_set_samplerate(rate)`; stop, write reg 3, start |
| power_down | 0644 | `power_down_set` 0xffffff8008ceef34 | `%d` | reg 3 bit 9 = !!v, on change |
| filter_path | 0200 | `filter_path_set` 0xffffff8008cf00bc | `%s` path | read 1024 B into `hm100_fir_coef_custom`, load module 2 twice |
| coef_input | 0200 | `coef_input_set` 0xffffff8008ceee3c | `%x %x %x` module addr data | module > 5 ignored; module 1: cache in `hm100_sar_coef_data` and write to module **0**; others written as given (1 word) |
| coef_load | 0200 | `coef_load_set` 0xffffff8008ceedcc | `%x %x` module idx | module 2..5 -> `hm100_set_filter_coef`, which only acts for module 2, idx 0..3 |
| calib_process | 0200 | `calib_process_set` 0xffffff8008cee2e8 | `%s` | `hiby_plat_calib_process`: "start" -> `hiby_target_poweron_umute(target)`, anything else -> `_mute` |
| firmware_load | 0200 | `firmware_load_set` 0xffffff8008cee348 | `%s` path | file = u16 checksum, u32 length, bitstream; needs len/256 <= 1737; overwrites `FS_chksum` / `FS_data` in RAM, no reprogram |
| erase_flash | 0644 | `erase_flash_set` | `%d` | **never touch**: reg 3 bit 2 high for 140 ms |
| load_flash | 0644 | `load_flash_set` | `%d` | **never touch** (manual use): 1 = reg 3 bit 1 pulse 2 ms; 0 = reset `hm100_sar_coef_data` to ideal weights and write it to module 0 |
| write_back | 0644 | `write_back_set` | any | **never touch**: writes `hm100_sar_coef_data` to module 1 (guess: flash staging) |

The `_get` handlers print the reg 3 shadow bits (`erase_flash_get` and `write_back_get` both read bit 2).

### Dangerous attributes

- **`dac_type` (both slots): never write it.** On the live unit (fw 1.80, 2026-10-20)
  `echo 0 > sa_sound_setting/dac_type` wedged the device and blanked the display until a forced restart;
  its value read back empty beforehand.
  - `set_dac_type_function` (#15 0xffffff8008cf0f68, #16 0xffffff8008cf1228) does
    `printk("%s %s\n", __func__, buf); return 0;` with no other effect and no valid values (static).
  - A sysfs store that returns 0 makes `write(2)` return 0 for a non-empty buffer. mksh's `echo` (Android
    root shell) retries short writes in a loop, so `echo 0 > dac_type` spins forever, and every spin prints
    a line on `console=ttyHSL0,115200` (cmdline), with tracing on as well in the sweep. The endless loop,
    the console flood, and through them the stall and blank display are inferred. The sweep log stops
    right after "== dac_type".
  - The show handler calls `setting_function[18]` (#15) or `[19]` (#16). Both are NULL, so a read returns
    0 bytes, which is why the value read back empty.
  - Nothing in stock writes it; any write from a shell hangs it.
- **Unbounded `strcpy` in every string store.** `set_mute_enable`, `set_on_boot_completed`,
  `set_play_next_value`, `set_*_filter`, `set_gain`, `set_turbo` and the rest copy `buf` with `strcpy`.
  - The destinations are 16-byte bss buffers (32 B for the two filter names; `mqa_source_str` has 4 B).
  - The ones that accept any string (`mute_enable`, `on_boot_completed`, `play_next`) accept anything up
    to PAGE_SIZE-1 (4095 bytes). So do the prefix-checked ones (`on...`, `yes...`) once the prefix matches.
  - About 336 bytes from `mute_str`, or 32 from `turbo_str`, overwrite the `g_sound_platform` pointer
    (0xffffff800a695ca8). The next audio operation then oopses (static layout; crash inferred).
  - Even `echo yes > mqa_source` writes "yes\n\0" (5 bytes) into a 4-byte buffer and clobbers a byte of
    `pregain`.
  - Keep writes short. Never write these from untrusted input.
- **FPGA flash: never touch `erase_flash`, `load_flash`, `write_back`.** They hit the FPGA's internal
  flash (reg 3 bits 1 / 2 and module 1). `load_flash 0` also overwrites the live per-unit R2R calibration
  with ideal weights until the next power-up.
- **`firmware_load <file>`** overwrites `FS_data` in RAM. The next output switch programs whatever was
  loaded, which can leave the DAC dead until reboot (static).
- **`coef_input`** writes module 0 live: it corrupts the calibration until the next power-up.
  **`sar_bypass 1`** turns off the R2R correction.
- **`input_select` != 0** moves the FPGA input away from I2S: silence. **`power_down 1`** powers down the
  FPGA core until the next output power-on.
- **`calib_process start`** and **`mute_port <out> 0`** unmute the amps outside the stream: pops.
- **`Output Select`** (mixer): every change power-cycles and reloads the FPGA and the amps (pop risk).
  None, Coax and Iis cut power 5 s later.
- Harmless: `filter_path` (returns 1024 on success, errno on failure); `delay_val` (no effect); the store
  of every other attr returns `count` (all checked in #16).

## The stock playback path

From the HAL to the FPGA on the running firmware (slot B, #16 addresses), with the PO (3.5 mm headphone)
output first. Slot A and slot B sequencing code is the same: call order and immediates match for
`hiby_snd_*`, `hiby_target_*`, `lrch_volume_imm_set`, `hm100_enable*`, `hm100_program`,
`hm100_set_samplerate`, `hiby_output_switch` and `output_select_put`. Only the `sa_sound_setting` table
moved (see [Settings sysfs](#settings-sysfs)).

### Capture caveats

- The `out_*`, `play_*` and `set_*` traces of the 1219 capture are byte-identical copies of the auto1 run
  (38/38 files `cmp` equal). There is one set of PO evidence, not two.
- Every `app_*` capture (HiBy Music, 1219 run) ran with `Output Select = Spdif`, because getprop has
  `vendor.audio.hiby.hw.output=spdif`. Its reg0 frames come from `spdif_table`: 0x0009 = 88.2k,
  0x0001 = 176.4k, 0x0201 = 192k. Those captures show the HAL's S/PDIF branch, not PO, and the native-DSD
  path of the stock kernel was read from code, not seen on a wire.
- PO evidence = the auto1 tinyplay runs (kernel path only, HAL bypassed) plus the settings sweep, which ran
  with target PO and has full kernel logs (`traces/set_amp_eneble_0.dmesg`).
- `docs/re-tools/decode-trace.py` drops the **first** control frame of a trace when CS is already low at
  the first event: `out_Lineout.txt` lines 21-71 hold a 0x04b8 frame that is not in the decode. The first
  reg3 frame after a JTAG load also decodes as "18 bits 0x00c10". That is reg3 = 0x010; CS and CLK are not
  idle-high yet when it starts.
- Live hm100 state before the RE: `osr_bypass = 1`, NOS on (user setting), so every traced reg3 carries
  bit 4.

### Stream setup in the kernel

The SEC_MI2S_RX BE link (`msm_mi2s_be_dai_links` 0xffffff800921da28, entry 2): cpu `msm-dai-q6-mi2s.1`,
codec `soc:hiby,hm100-codec` / `hm100-codec-dai`, be_id 0x29, **no `be_hw_params_fixup`**, ops
`msm_mi2s_be_ops` 0xffffff800a2280b8 = {startup, shutdown, hw_params, -, -, trigger}. Without a fixup the
BE params are the FE params, so `hiby_snd_hw_params` reads the real FE rate and format. Slot A addresses
in this list, slot B where labelled.

1. **startup**: `msm_mi2s_snd_startup` (0xffffff8008ce7808, slot B 0xffffff8008ce7ac8) enables the bit
   clock and sets the DAI format from the master flag (see [Rates, clocking and the MI2S
   link](#rates-clocking-and-the-mi2s-link)), then `hiby_snd_startup`: `hiby_snd_on = 1`,
   `hm100_set_spdif_mode(current_target_on == 4)`.
2. **hw_params**: `msm_mi2s_snd_hw_params` 0xffffff8008ce5628 calls `hiby_snd_hw_params` (slot B
   0xffffff8008cf3fd4) and returns 0. Playback only. `rate = params_rate`, `fmt` = the first set bit of
   the format mask.
   - **PCM** (fmt != 0x31):
     1. `first_dsd_play = 1`
     2. `hm100_program_by_hw_param(0)`: reprograms the PCM design only if `hm100_fw_version != 0`
     3. if the previous stream was DSD and `plat_dsd_compensate != 0`: `lrch_volume_imm_set(target, L, R, 0)`
     4. `output_format = 0`, `hm100_set_gpo(IOB35B, 0)` (`pcm_dsd_sel` low); there is no S/PDIF-specific
        GPO write
     5. `hm100_set_samplerate(rate)` (stops the FPGA, writes reg 0)

     Confirmed for 44.1k: `set_amp_eneble_0.dmesg` lines 19-26 "inner_hw_params format:2
     samplerate:44100" (format 2 = S16_LE).
   - **DSD** (fmt == 0x31 = 49 = `DSD_U16_LE`, checked against `snd_pcm_format_names`):
     1. `current_dsd_mode` "mdsd": `hm100_program_by_hw_param(1)` (loads `FS_dsd_data`);
        "dsd" (default): `hm100_program_by_hw_param(0)` (keeps the PCM design); other: no reprogram
     2. if the previous stream was PCM and `plat_dsd_compensate != 0`: volume update
     3. `output_format = 1`
     4. only while `first_dsd_play == 0`, before any stream since boot (a PCM stream sets it):
        `hm100_set_samplerate(44100)`, `hm100_start`, about 1 ms, `hm100_stop`
     5. `hm100_set_gpo(IOB35B, 1)`
     6. `hm100_set_samplerate(rate << 5)`: the ALSA rate is the DSD bit rate / 32, so DSD64 arrives as 88200
        frames/s (static on the HAL side, see [Native DSD in stock](#native-dsd-in-stock))
3. **trigger** (`hiby_snd_trigger` 0xffffff8008cf3b80, returns -1 if `hiby_snd_on == 0`):
   - START / PAUSE_RELEASE / RESUME (cmd 1, 4, 6): `hm100_start` (reset-gpio TLMM12 high), queue
     `unmute_work` with delay 0. `unmute_work_schedule` 0xffffff8008cf2c1c cancels mute work and, if
     `sp+0x134`, calls `hiby_target_poweron_umute(current_target_on)`.
   - STOP (cmd 0): queue `mute_work` with delay 0: `hiby_target_poweron_mute(current_target_on)`,
     `sp+0x134 = 1`. The FPGA is **not** stopped; it stays running until the next `hm100_set_samplerate`.
   - PAUSE_PUSH, SUSPEND: nothing.
4. **shutdown**: `hiby_snd_shutdown` clears `hiby_snd_on`; `msm_mi2s_snd_shutdown` drops the clock.

`hm100_program_by_hw_param(design)` 0xffffff8008cf2254: if `design != hm100_fw_version`: jtag-select
(TLMM44) = 0, program `FS_dsd_data` (design 1) or `FS_data` (0), jtag-select = 1, `hm100_enable_init`
(about half a second in all), then `hm100_fw_version = design`. `hiby_target_poweron` resets the
remembered design to 0.

### Rates, clocking and the MI2S link

Rate handling for the 44.1k family on PO:

| stage | 44.1k track | 48k track | evidence |
|---|---|---|---|
| App to HAL | AudioTrack at the file rate; HiBy Music's engine (`libhibyservice.so`) is an AudioTrack client | same | static |
| HAL stream intake | `$pcm_open` 0x5c410 diverts every card-0 non-mmap open into the HiBy software mixer (`hmixer_stream_open`); accepts 32k..768k PCM and DSD64..512 | same | static |
| HAL software resampling | none by default. `PP_resample` exists, driven by `enable_force_rate`/`sample_rate` (`sa_set_fixed_samplerate*` 0x66d50/0x66d98, exported, no caller inside the HAL). **Caveat:** the HAL has an optional DSP unit (off by default, internal target only); with it on, the PCM and reg0 rate may differ from the track. Not documented here | same | static |
| HAL output PCM (DSP unit off) | `output_proxy_set_type` 0x5e560: `pcm_open(card 0, device 13, PCM_OUT, cfg)`. Device 13 is MultiMedia5 (low-latency FE; `audio_platform_info.xml` id 13, `/proc/asound/pcm` "00-13"; the one open hw_params block in the app captures is the 4th of 21 in glob order, which is `pcm13p`). cfg = 2 ch, **rate 44100**, **S16_LE**, period 512 x 8 (`op_pcm_param` 0xe74fc) | rate 48000, period 512 x 8 | static. The branch mapping is confirmed: the app hw_params periods (88.2k: 1024/8192, 176.4k and 192k: 2048/16384) fit only the S/PDIF branch's `rate<<1` table lookup, so `DAT_000fb868 == 1` is S/PDIF, 2 is USB and 0 is the internal DAC |
| HAL sample packing | `output_proxy_callback` 0x5d438: float to int32 with clamp, then `s = s>>16 \| s<<16` and `pcm_write(frames*8 bytes)`. Each 32-bit sample goes out as two 16-bit words, high then low, so one audio frame = **two** S16 stereo PCM frames | same | static |
| `SEC_MI2S_RX SampleRate` / `Format` | never set by the HAL: the strings are absent, and the backend cfg names `INT0_MI2S_RX`. They stay at the boot default KHZ_48 / S16_LE (tinymix lines 2942/2950 in both static dumps) | same | confirmed |
| what those enums do | only feed `msm_mi2s_set_sclk` 0xffffff8008ce30b8 (rate x 2 x 16 = 1.536 MHz), which programs the **EBIT** clock id, see below | same | static + confirmed |
| `hiby_snd_hw_params` 0xffffff8008cf3fd4 | rate 44100, format 2 (S16_LE). The SEC_MI2S BE has no fixup, so the FE params pass through | 48000 | confirmed |
| hm100 reg0 | `hm100_stop` (gpio12=0), frame **0x0120** | **0x0320** | confirmed, see [Rate words](#rate-words) |
| FPGA clock family | bit 9 = 0: **45.1584 MHz** | bit 9 = 1: **49.152 MHz** | static meaning of f0, values confirmed |
| q6 ASM/ADM/AFE | all forced to 384000 (`hiby_fixed_samplerate` 0xffffff8008ce9f5c), so the ADSP sees one rate end to end and never converts | same | confirmed: dmesg "bit_width = 16 ... ws_src = 0x0 sample_rate = 384000", "afe_get_cal_hw_delay: Unable to find delay for sample rate 384000" |

**Clocking: the SoC is the I2S slave, and the FPGA is the clock master.**

- Confirmed: the AFE I2S config goes out with `ws_src = 0x0` (external).
- Static:
  - `msm_asoc_machine_probe` (slot A 0xffffff8008ce6180, slot B 0xffffff8008ce6440) reads
    `qcom,msm-mi2s-master` (u32[4]) into `mi2s_intf_conf[i].msm_is_mi2s_master` and
    `qcom,msm-mi2s-ext-mclk` into `.msm_is_ext_mclk` (absent on the RS6, so no MCLK). The DT says master:
    `qcom,msm-mi2s-master = <1 1 1 1>`, in dtb96 of both slots.
  - But the probe overwrites all four flags with 0 right after parsing them (`str wzr` at
    0xffffff8008ce6858..64 in slot B, before "qcom,audio-routing"; slot A has the same code at
    0xffffff8008ce6598). This is a HiBy patch. A reading of the DT alone takes the SoC for the bit/frame
    clock master; on the running firmware it is not.
  - The SEC link uses the global `msm_mi2s_snd_startup`. It picks CBM_CFM plus the **EBIT** clock id when
    `mi2s_intf_conf[1].msm_is_mi2s_master == 0`; with the flag set it would keep fmt = `CBS_CFS`
    (0x4000) and the IBIT clock. `msm_dai_q6_mi2s_set_fmt` 0xffffff8008c73b80 sets the external
    `ws_src` only for `CBM_CFM`.
- So the FPGA drives BCLK and WS from its 45.1584 / 49.152 MHz crystals.
- That is how 44.1k works over a "384 kHz" port: 384000 is a dummy rate that keeps the ADSP from
  resampling, and the real frame rate is whatever reg0 selects.
- **Inferred wire format:** 16-bit slots, words L_hi, L_lo, R_hi, R_lo over two WS periods, BCLK = 64 x
  Fs (2.8224 MHz at 44.1k; 49.152 MHz at 768k, which equals the crystal and so explains the 768k cap). Not
  observed on the wire. The tinyplay runs fed plain 16-bit silence, so they prove nothing about the audio
  content.

MI2S and q6 details (SEC_MI2S on the internal-codec card `qcom,sdm660-asoc-snd`; slot A unless labelled):

- **Bit clock**: `msm_mi2s_set_sclk` (0xffffff8008ce7638, slot B 0xffffff8008ce30b8) sets `mi2s_clk[1]` =
  {clk_id, freq = `mi2s_rx_cfg[1].sample_rate` x 2 x w}, w = 32 for S24_LE / S32_LE / S24_3LE else 16, via
  `afe_set_lpass_clock_v2`. The clk_id is 0x102 (SEC_MI2S IBIT) in the master case and the EBIT id on the
  running firmware. `mi2s_rx_cfg[1]` defaults to 48000 / S16_LE / 2 ch (1.536 MHz) and only changes through
  the `SEC_MI2S_RX SampleRate` (8k, 16k, 32k, 44.1k, 48k, 96k, 192k) and `SEC_MI2S_RX Format` (S16_LE,
  S24_LE, S24_3LE, S32_LE) controls. No 88.2k / 176.4k entries. The BE SampleRate enum only feeds this
  bit-clock computation.
- **AFE port pinned to 384 kHz**: `hiby_fixed_samplerate` (0xffffff8008ce9c9c, slot B 0xffffff8008ce9f5c)
  returns 384000. It replaces the rate in `msm_dai_q6_mi2s_hw_params` (+0x1d0, i2s port config),
  `msm_dai_q6_mi2s_prepare` (+0xbc, `afe_port_start`), `msm_pcm_routing_hw_params` (+0x54),
  `msm_pcm_prepare` (compress media format) and `msm_pcm_playback_app_type_cfg_ctl_put`.
- **Formats**: the FE offers S16_LE, S24_LE, S32_LE, S24_3LE and **DSD_U16_LE**, rates 8000..768000.
  `msm_pcm_prepare` maps every format except S32/S24 to a 16-bit ASM stream and declares plain linear PCM
  at `hiby_fixed_samplerate()` = 384000; the DSD-specific ASM media format block is called only from the
  compress-offload driver. The q6 dai accepts S16_LE, SPECIAL and DSD_U16_LE as 16-bit and S24_LE /
  S24_3LE as 24-bit and starts the AFE at 384000, so the AFE is 16-bit stereo at 384000 whatever the real
  rate. DSD is selected by format `DSD_U16_LE` plus `rate << 5`, and by `dsd_mode` for the bitstream
  choice.
- **Topology**: which ADM topology the stock path used depends on ACDB data that was not decoded
  (**open**). Mainline uses NULL topologies on the ASM stream (`ASM_NULL_POPP_TOPOLOGY` 0x10C68) and the
  COPP (`NULL_COPP_TOPOLOGY` 0x10312).

### The PO sequence, traced

GPO bits in reg1 (shadow `hm100_gpio_group0_val`) are in the [GPO](#gpo)
table. `hm100_set_gpo` (slot B 0xffffff8008cf00b0) rewrites the whole reg1 every call, even when nothing
changed (static; the trace shows the repeat frames). Every reg1 write is a 16-bit control frame on gpio
8/10/11. TLMM 13 = 1 only around NJW1195A words.

#### Power-on PO: `Output Select` = Headset, `hiby_target_poweron(2)` (slot B 0xffffff8008cf3a04)

Static, the PO column of [Power-on, mute and power-off per
target](#power-on-mute-and-power-off-per-target). PO power-on was never traced. The shared steps are
confirmed in `out_Balance.txt` (BAL power-on, same chain), with the measured gaps in the right column.

| # | action | pins / frames | BAL trace check |
|---|---|---|---|
| 1 | `hiby_po_mute(1)` | TLMM61=0, then reg1 \|= IOB29B (0x030 from 0x020) | 61=0 then 0x0430 at +80 us |
| 2 | `hiby_dac_power(1)` | TLMM28=1, 10 ms, TLMM40=1 | 10.0 ms |
| 3 | `hm100_enable` | TLMM55=1, 50 ms, TLMM44=0, JTAG IDCODE/USERCODE, SRAM load over blsp_spi3 (444672 B, ~464 ms), then `hm100_enable_init`: reg3 0x000 (0x010 with NOS), reg1 shadow, reg2 0x000, gpio12=0, reg0 rate, gpio12=1, reg3 \|= 0x002, 2 ms, reg3 &= ~0x002, module 2 gets filter 0 x2 (0x4002, 0x4400, 1024 x 0x48xx, 0x4c00), gpio12=0 | 50.0 ms; load 0.46 s; init ~140 ms. The coef bytes equal `hm100_fir_coef_default` filter 0 (big-endian words), sent twice: confirmed |
| 4 | 10 ms; `hiby_lpf_power(1)` | reg1 \|= IOB39A (0x0b0) | confirmed |
| 5 | 10 ms; `hiby_lpf_sel(1)` | TLMM34=1 | confirmed |
| 6 | **10 ms** (BAL: 50 ms); `hiby_volume_power(1)` | TLMM15=1 | BAL 50 ms |
| 7 | `hiby_po_amp_power(1)` | pm660 GPIO13 (global 1023, `hiby,po_pwr_en`)=1, 10 ms, reg1 \|= IOB29A (0x0b8) | 10.1 ms |
| 8 | 10 ms; `hiby_bal_po_amp_power(0)` | reg1 IOB27B=0 (0x0b8 rewritten) | BAL sets 1 instead (0x0bc), then waits 50 ms |
| 9 | 10 ms; `lrch_volume_imm_set(2, L, R, 1)` | TLMM13=1, NJW `cL<<8\|0x00`, `cL<<8\|0x10`, `cR<<8\|0x20`, `cR<<8\|0x30`, TLMM13=0 | confirmed (0x8e00..0x8e30) |
| 10 | NJW input select | TLMM13=1, **0x2840, 0x0050**, TLMM13=0 (BAL: 0x2840, 0x2850) | BAL words confirmed |
| 11 | `hiby_headphone_balance_select("headphone")` | TLMM29=0 | BAL sets 29=1 |
| 12 | `current_target_on = 2`, unmute pending | | |

#### Play: hw_params, then trigger START (confirmed, `play_44100_16.txt`, `set_amp_eneble_0.dmesg`)

1. startup: EBIT clock "rate 1411200" (here the sweep had set KHZ_44P1), `hiby_snd_startup`:
   `hm100_set_spdif_mode disable`.
2. hw_params: `hm100_program_by_hw_param(0)` (no-op while the PCM design is loaded), reg1 IOB35B=0 (0x0b8
   frame, raw lines 21-71, missed by the decoder), `hm100_stop` gpio12=0 (line 72), reg0 0x0120.
3. prepare: AFE port start at 384000.
4. START (~33 ms later in the trace): gpio12=1 (line 124), then `unmute_work`: IOB35A=0 -> reg1 0x098,
   `po_mute(0)`: IOB29B=0 -> reg1 **0x088**, TLMM61=0 (line 227). PO steady state: reg1 = 0x088
   (po_amp_en + lpf_pwr_en).

#### Stop: trigger STOP (confirmed, `play_44100_16` at 2343264.748)

`mute_work`: IOB35A=1 -> 0x0a8, then `po_mute(1)`: TLMM61=0, IOB29B=1 -> 0x0b8. gpio12 **stays high**
until the next hw_params. A rate change therefore always runs muted: stream close, STOP mute, hw_params
(stop, reg0), START, unmute.

#### Power-off PO: `hiby_target_poweroff(2)` (slot B 0xffffff8008cf3818; confirmed, `out_Lineout.txt` raw lines 20-282)

TLMM61=0 (l.20), reg1 0x0b8 IOB29B=1 (l.21-71), 10 ms, reg1 0x0b8 IOB27B=0 (l.73-122), pm660 GPIO13=0
(l.123), 10 ms, reg1 0x0b0 IOB29A=0, TLMM15=0 (l.175), TLMM34=0 (l.176), reg1 0x030 IOB39A=0, TLMM55=0
(l.228), TLMM28=0 (l.229), 10 ms, TLMM40=0 (l.230), reg1 0x020 IOB29B=0, TLMM61=0 (l.282).

### The other outputs

Static, confirmed in the `out_*` traces:

| | PO (2) | BAL (3) | LO (1) | BAL-LO (7) |
|---|---|---|---|---|
| pre-mute | TLMM61=0, IOB29B=1 | same | TLMM76=1, TLMM61=1 | TLMM76=1, TLMM61=1 |
| lpf_sel (TLMM34) | 1 | 1 | 1 during power-up, then 0 | 0 |
| delay after lpf_sel(1) | 10 ms | 50 ms | none (no wait before lpf_sel(0)) | n/a (lpf_sel(0), no wait) |
| vol_pwr (TLMM15) | 1 | 1 | 0 | 0 |
| po_pwr (pm660 13) + IOB29A | on | on | off | off |
| IOB27B bal_amp_en | 0 | 1 (+50 ms) | 0 | 0 |
| NJW volume | yes | yes | none | none |
| NJW in-select | 0x2840, 0x0050 | 0x2840, 0x2850 | none | none |
| TLMM29 po_bal_po_sel | 0 | 1 | untouched | untouched |
| reg1 playing / muted | 0x088 / 0x0b8 | 0x08c / 0x0bc | 0x080 / 0x0a0 | 0x080 / 0x0a0 |
| unmute pins | IOB35A=0, IOB29B=0, TLMM61=0 | + TLMM76=0 | IOB35A=0, TLMM61=0, TLMM76 stays 1 | IOB35A=0, TLMM61=0, TLMM76=0 |
| power-off extra delay | 10 ms | 10 ms | 10 ms | 100 ms |

### Who writes what

Nobody writes sysfs or runs tinymix directly. Searched: every partition, the HiByMusic dex and native
libs, and Settings/services.

- `sa_sound_setting` attrs: nothing in the kernel or the HAL writes them. The only writer is init:
  `vendor/etc/init/hw/init.hiby.audio.rc` turns `vendor.audio.hiby.hw.*` property changes into sysfs
  writes. Settings and `services.vdex` set the properties when they restore user settings at boot, and
  when the user changes them (static; boot timing inferred). Playback start writes no attr. Which attr is
  written, with the live values, is in the [Settings sysfs](#settings-sysfs) table.
- HiBy Music (`classes*.dex`, `libhibyservice.so`) plays through AudioTrack and reads and sets
  `vendor.audio.hiby.hw.*` properties (digital_output_type, iisspdif, lrbalance, play_next). Its only
  `/sys` reads are cpufreq/thermal/net.
- Settings and `services.vdex` set `vendor.audio.hiby.hw.*`, `vendor.audio.hw.vendor_func` and
  `vendor.audio.hiby.hw.darwin.filter_path`. init (`init.hiby.audio.rc`) turns the first two into sysfs
  writes. The HAL reads `darwin.filter_path` at PCM open and hands it to its own DSP unit
  (`hmixer_get_dsp_hdr()->set("darwin_filter_path")`); no sysfs write was found (static).
- `audiomonitor` (root, started from that rc) only touches `vendor.audio.hiby.hw.audio_stop_timeout` and
  `sample_quality`.
- The HAL sets mixer controls: `Output Select`, `SEC_MI2S_RX Channels`, the MultiMedia5 routing
  (mixer_paths `headphones`/`balance`/`line`/`balancelo`/`spdif`/`iis` and `low-latency-playback`),
  `Plat Left/Right`, and a **"Mute Output"** control that the kernel does not have (the string is not in
  `Image`): `hal_primary_output_mute` sets it for DSD streams only, before `pcm_close`, and it is a no-op
  (static). The HAL also sets `vendor.audio.hiby.hw.sample_rate` / `sample_quality`, which drive the LED
  rc.

So on the RS6, `amp_eneble`, `balpo_po_a_ab` (Class A/AB) and `power_p_pplus` do nothing in hardware, and
the RS6 stock image never writes them. They are leftovers from other HiBy models: the RS6 kernel and DT
are built on the shared HiBy SDM660 BSP, which still carries `r8-sound-plat`, `r8_gpio_sound_switch`,
`r8_gpio_switch` and `n9-*` pinctrl groups (`dtb96.dts` L10316-L10479). The RS6's own `hiby,sound-plat`
node points at the `r8-sound-plat` group (gpio29/40/55/76), so the R8 naming is the BSP's, not a sign that
R8 code paths are live here. The attrs match other SDM660 Android 9 DAPs: Turbo is the HiBy R8's mode
(store.hiby.com R8 page), and Class A/AB (`balpo_po_a_ab`), P/P+ (`power_p_pplus`) and Transistor/Nutube
timbre (`balpo_po_t_n`) are the Cayin N8ii's switches (en.cayin.cn N8ii features page; HiFi Oasis lists it
as Snapdragon 660 + Android 9). The `n9-*` groups are probably a Cayin codename; no public "Cayin N9"
product turned up. The sweep traces for these attrs show only unrelated stream start/stop frames, hundreds
of ms after the write (confirmed).

### Minimal PO sequence for a driver

For PO, 44.1k and 48k family PCM.

Clocking and data path:

1. Make the SoC MI2S (SEC, gpio24-27) the **clock consumer**: codec is bitclock and frame master, q6afe
   EBIT, AFE `ws_src` external. Confirmed on stock, despite the `<1 1 1 1>` in the DT.
2. Keep the ADSP from resampling. Run ASM, ADM and AFE at one fixed nominal rate (stock uses 384000,
   16-bit, 2 ch) and keep the real rate only in hw_params for the codec. Confirmed on stock; the mainline
   recipe is inferred.
3. Feed 32-bit samples as two S16 words, high word first, so one audio frame = 2 S16 stereo frames. This
   is what stock does (static). That the FPGA needs it is inferred. Verify on hardware with a non-silent
   tone before relying on it (open).

Probe:

4. Request outputs low: TLMM 8, 10, 11, 12, 13, 15, 28, 29, 34, 40, 44, 55, 61, 76 and pm660 GPIO13.
5. Load `FS_data` (and `FS_dsd_data`) with `request_firmware`.
6. The GPO shadow starts at IOB35A | IOB29B (muted). The reg3 shadow starts at 0, so NOS is off.

PO power-on, in order (static, timing confirmed on the BAL twin):

7. TLMM61=0; set IOB29B in the shadow.
8. TLMM28=1, 10 ms, TLMM40=1.
9. TLMM55=1, 50 ms, TLMM44=0, then the JTAG/SPI [SRAM load](#sram-load). Check
   USERCODE. **Leave TLMM44=0.** Drive TLMM10 (CS) and TLMM11 (CLK) high before the first control frame.
10. Init the FPGA:
    1. reg3=0x000, reg1=shadow, reg2=0x000.
    2. gpio12=0, reg0=rate frame, gpio12=1.
    3. reg3=0x002, 2 ms, reg3=0x000.
    4. Module 2 gets filter 0: 0x4002, 0x4400, 1024 byte frames 0x48xx (each 32-bit word MSB first),
       0x4c00. Send it twice.
    5. gpio12=0.
11. 10 ms, IOB39A=1 (write reg1).
12. 10 ms, TLMM34=1.
13. 10 ms, TLMM15=1.
14. pm660 GPIO13=1, 10 ms, IOB29A=1.
15. 10 ms, IOB27B=0.
16. 10 ms, TLMM13=1, NJW L/R volume words (see [Volume](#volume)), TLMM13=0.
17. TLMM13=1, NJW 0x2840, 0x0050, TLMM13=0.
18. TLMM29=0.

hw_params (rate R):

19. IOB35B=0, gpio12=0, reg0 = the PCM frame of R from [Rate words](#rate-words). The 44.1k/48k values
    (0x0120, 0x0320) are confirmed, the rest are table values.

trigger START:

20. gpio12=1, then IOB35A=0, IOB29B=0, TLMM61=0 (reg1 0x098, then 0x088). Confirmed.

trigger STOP:

21. IOB35A=1, TLMM61=0, IOB29B=1 (reg1 0x0a8, then 0x0b8). Leave gpio12 high. Confirmed.

Volume:

22. On a level change, write the four NJW words under TLMM13=1. Ramp them if you want stock's
    anti-zipper behaviour (1 code per 10 ms).

PO power-off (confirmed):

23. TLMM61=0, IOB29B=1, 10 ms, IOB27B=0.
24. pm660 GPIO13=0, 10 ms, IOB29A=0.
25. TLMM15=0, TLMM34=0, IOB39A=0.
26. TLMM55=0.
27. TLMM28=0, 10 ms, TLMM40=0.
28. IOB29B=0, TLMM61=0.

Do not expose `dac_type`-style no-op attrs. Bound every string copy.

### Open items of the playback path

- The I2S wire framing (16-bit slots, hi/lo word order, WS period). Needs a scope or a tone test.
- Who turns on the HAL resampler (`enable_force_rate`), and whether HiBy Music's own "Fixed SampleRate"
  defaults on.
- The PCM rate the HAL opens on PO above 192k. The `op_pcm_param` table allows up to 768k for the internal
  path, but no PO capture exists.
- DSD on PO through the stock HAL was not captured: the tinyalsa format id 5 mapping and the
  `dsd_mode mdsd` reloads are read statically only (see [Native DSD in stock](#native-dsd-in-stock)).

## Coax S/PDIF and native DSD

Two outputs of the hm100 that stock firmware 1.80 drives in ways a generic PCM driver does not: the
coaxial S/PDIF pin and native DSD to the internal DAC. Stock facts come from the GPL kernel in detail and
the closed HAL only as the source of a fact; the mainline facts are the kernel series on `main` and the
`rs6-spdif` package on `pmos`.

### Status and summary

- Verified by ear on the unit: native DSD64, DSD128 and DSD256 on the analog outputs. A clip with sound in
  the left channel only confirmed the channel order.
- Not recorded as verified on the unit: DSD512, PCM 768k, the coax S/PDIF output through `rs6-spdif`, and
  the [Review fixes](#review-fixes) (they are in the kernel the unit runs, but were not tested on their
  own).
- The stock S/PDIF and DSD paths were not measured on stock hardware pins (see [Capture
  caveats](#capture-caveats)).

Summary:

- **Coax is the stock fallback route, not a user action.** With nothing plugged in, AudioPolicy routes to
  SPEAKER, the HAL maps it to the `spdif` snd device, and the mixer path sets `Output Select = Spdif` (see
  [What selects S/PDIF in stock](#what-selects-spdif-in-stock)).
- **Kernel S/PDIF is one flag and one table** (`spdif_enabled`, `spdif_table`), which also forces reg0
  mode 1. **The FPGA does not encode S/PDIF, the HAL does**: in mode 1 the FPGA only forwards its serial
  data line to the S/PDIF pad.
- **Stock native DSD is raw DSD bits as 16-bit PCM over the normal MI2S path**, both channels
  bit-interleaved; the ADSP never learns it is DSD.
- **How the signal reaches the USB-C connector is not in the software.**
- **Mainline does both**: nothing plugged in resolves to the Spdif target, a read-only `Output Target`
  control tells userspace where a stream goes, DSD_U32_LE/BE at DSD rate/32 plays natively, and the
  `rs6-spdif` package provides the encoder.

### S/PDIF in the stock kernel

The table and the frame build are in [Rate words](#rate-words). `hm100_set_spdif_mode`
(0xffffff8008ceff1c) stores the flag `spdif_enabled`. It is written only by `hm100_set_spdif_mode`, which
is called only by `hiby_snd_startup` with `current_target_on == 4`, and read only in
`hm100_set_samplerate`. The older `hbc3000` FPGA driver has its own copy of all this; the RS6 binds
`hiby,hm100`, so that copy is dead here. Consequences (static):

- The flag is latched **per stream open** (`hiby_snd_startup`, called from `msm_mi2s_snd_startup`), not at
  output switch. `Output Select = Spdif` must be set before the PCM opens.
- The flag is not reset on stream end or power-off. `hm100_enable_init` calls `hm100_set_samplerate` with
  the stale flag, so the post-load init frame is 0x0001 in one capture (flag left set) and 0x0120 in
  another (flag 0). Harmless, since hw_params rewrites reg0.
- `hiby_snd_hw_params` does not look at the flag: a PCM stream takes the PCM branch of [Stream setup in
  the kernel](#stream-setup-in-the-kernel), with no S/PDIF-specific GPO write. Confirmed: at play, reg1
  0x0420 (IOB35B already 0), reg0 0x0011, RUN high.
- STOP and START do no mute or unmute for target 4.

What the Spdif target (4) powers: the Spdif column of [Power-on, mute and power-off per
target](#power-on-mute-and-power-off-per-target). Power-off is the same chain ending in `hm100_disable`
(confirmed in the captures: gpio 1023, 15, 34, 55, 28, 40 all low afterwards). So Spdif powers the FPGA
(TLMM55, bitstream, init) and nothing else: **the DAC rails (TLMM28 audio_dc_dc_en, TLMM40 dac_pwr_en)
stay off**, the LPF, volume supply and both amps stay off, and the reg1 mute bits stay as the previous
target left them. The AFE clocks come from the FPGA oscillators, not from the DAC rails (inferred from the
netlist). The HiBy Music runs ran start to finish with the rails off; there is no error in the kernel
logs, but also no audio proof from them.

### What selects S/PDIF in stock

The kernel only reports jacks: `sa_sound_switch` polls the four jack GPIOs every 200 ms, debounces 4 reads
and sets switch-class states (`balance`, `balance_lo`, `h2w`, `lineout`; with DT `report_only_one` only
the first plugged jack in DT order reports). `hiby_output_switch` is reached only from the `Output Select`
mixer put. No kernel code picks Spdif for "no jack". The chain (static):

1. **Framework.** `WiredAccessoryManager` has no `spdif`/`iis` kernel switch to observe, so BIT_SPDIF is
   never set. With nothing plugged in, AudioPolicy falls back to `AUDIO_DEVICE_OUT_SPEAKER` (**inferred**:
   standard Android behaviour; the HAL mapping below only makes sense for that device).
2. **HAL `platform_get_output_snd_device`** maps SPEAKER to snd device 11, named "spdif" in the HAL's table
   (8 "line", 9 "balance", 10 "balancelo", 12 "iis", 13 "headphones", 2 "speaker"). `out_set_parameters`
   also handles wired names (Lineout, Balance, BalanceLo, Spdif, Iis); that path is not exercised on the
   RS6.
3. **HAL `enable_snd_device`** calls `output_proxy_spdif(snd_device == 11)`, which switches the HAL's own
   mixer target, then applies the mixer path.
4. **`mixer_paths.xml`, path `spdif`**: `SEC_MI2S_RX Channels = Two`, WCD controls that are no-ops on this
   card, and **`Output Select = Spdif`**. `headphones` sets `Headset`, `line` `Lineout`, `balance`
   `Balance`, `balancelo` `BalanceLo`, `iis` `Iis`; the `speaker` path has no `Output Select`. No path sets
   `Coax`.
5. **Kernel**: `output_select_put` -> `hiby_output_switch("Spdif")` -> `hiby_target_poweroff(old)` +
   `hiby_target_poweron(4)`. When the HAL puts the stream in standby, `Output Select` returns to None and
   the switch work powers the FPGA down 5 s later.

Not on the path: HiBy Music (it steers its own format conversion by device type, never the mixer),
Settings "Multifunction Output" and `vendor.audio.hiby.hw.output` (stored, never consumed by routing), and
adapter auto-detection (none exists, see the next section).

Rates seen in the HiBy Music runs (confirmed, all with `Output Select = Spdif`):

| track | reg0 | meaning |
|---|---|---|
| PCM 88.2k | 0x0009 | S/PDIF 88.2k |
| PCM 176.4k | 0x0009 then 0x0001 | 88.2k, then 176.4k (engine reopened once) |
| PCM 352.8k / 384k | 0x0001 / 0x0201 | resampled by the engine to 176.4k / 192k |
| DSD64 | 0x0001 | DoP at 176.4k |
| DSD128 | 0x0009 | converted to PCM at 88.2k |

### How the S/PDIF signal reaches the USB-C connector

- **No mux GPIO.** The stock DT's `dp_ctrl` node names TLMM76 and TLMM21 as DisplayPort aux pins, but the
  stock kernel has no DP driver (`# CONFIG_FB_MSM_MDSS_DP_PANEL is not set`; the only `mdss_dp` symbols are
  clock tables and a PLL table). Those pins are the HiBy `line_mute` and balance_lo jack detect, so there
  is no conflict.
- **No Type-C, PD or accessory code for it.** The Type-C logic is the PM660 SMB2 and `qpnp-pdphy`. The
  HAL's USB branch is for USB-audio-class devices. Nothing in kernel, HAL, Settings, HiBy Music or
  services detects the coax adapter. **Inferred**: the cable is passive and the output is on whenever the
  FPGA runs in mode 1.
- **Which FPGA pin.** Netlist decode of the PCM bitstream: **IOT42B** forwards the data line only in reg0
  mode 1; DSD forwarding is IOR24A/IOR17B in mode 2. IOT42B is not one of the [GPO](#gpo)
  pins. Inferred from the bitstream, not from a schematic.
- **Which USB-C pin.** Unknown. D+/D- belong to the USB PHY, so SBU1/SBU2 or a repurposed CC-adjacent pin
  are the candidates (**guess**). The software gives no hint.

In stock the signal exists whenever the FPGA is powered, in mode 1, with RUN high. STOP leaves RUN high
until the next hw_params, so within a session the pad stays active between tracks. In mode 0 the pad
should be quiet (inferred from the netlist).

### Native DSD in stock

Kernel side: the DSD branch of [Stream setup in the kernel](#stream-setup-in-the-kernel), the DSD words
in [Rate words](#rate-words) (the userspace convention is `rate << 5` of the ALSA rate), and the q6 path
in [Rates, clocking and the MI2S link](#rates-clocking-and-the-mi2s-link).

- Settings' "DSD filter" list is `mdsd` ("Darwin Default") / `dsd` ("Darwin 1"), and the live unit's
  last `vendor_func` value was `dsd_mode mdsd`, so **stock's normal DSD path is the separate DSD
  bitstream**, reloaded at every PCM/DSD change. The "dsd" alternative keeps the PCM design and only
  selects reg0 mode 2. What the DSD bitstream does differently is **open** (its netlist was not analysed).
- Volume: `dsd_compensate` adds `5 * plat_dsd_compensate` (0.1 dB units) to the NJW volume on DSD. The
  `.data` default is 6 (+3 dB); the stock init wrote the user value, 0 on the unit.

HAL side (static):

- `$pcm_open` diverts the stream into the HiBy software mixer (see the rate table in [Rates, clocking and
  the MI2S link](#rates-clocking-and-the-mi2s-link)). Tinyalsa format 5 means DSD; the `rate` field is
  then the DSD bit rate (2822400 / 5644800 / 11289600 / 22579200) and frames are 8 bytes:
  `[L0 R0 L1 R1 L2 R2 L3 R3]`, one byte per channel, oldest first.
- `output_proxy_set_type` opens card 0, device 13 (MultiMedia5), 2 ch, tinyalsa format 5 which maps to
  ALSA DSD_U16_LE (49), rate = `dsd_rate >> 5` (DSD64 = 88200). Eight bytes are two 4-byte DSD_U16 frames,
  so the true frame rate on the wire is 2x the declared one (DSD64: 176400 frames/s, BCLK 5.6448 MHz, the
  same bit clock as `spdif_table` 44.1k).
- **Data transform** (`output_proxy_callback`, DSD branch): for each byte pair `(b0, b1)` it writes
  `out0 = even(b0 & 15) | odd(b1 & 15)` and `out1 = even(b0 >> 4) | odd(b1 >> 4)`, where `even(n)` spreads
  the 4 bits of n to bit positions 0, 2, 4, 6 and `odd(n)` to 1, 3, 5, 7. This is a Morton interleave of
  the two channel bytes: b0 on the even bits, b1 on the odd ones. Tables: odd
  `00 02 08 0a 20 22 28 2a 80 82 88 8a a0 a2 a8 aa`, even
  `00 01 04 05 10 11 14 15 40 41 44 45 50 51 54 55`. No half-word swap in this branch (unlike PCM and
  S/PDIF). b0/b2 belong to the first (left) channel and b0 is older than b2 (read off the DoP builder in
  the same function).
- DSD64 over the S/PDIF output is DoP (marker byte alternating 0x05/0xFA); DSD128 and above reached the
  stock captures only as PCM converted by the player engine.

### The coax stream format

The encoder contract: what the data on the I2S line must be for the FPGA to put valid S/PDIF on its pad in
reg0 mode 1. Read from the stock HAL (`spdif_core_process_data`, the nibble table built by
`spdif_core_init`, the preamble bytes, and `output_proxy_callback`'s half swap) and cross-checked: a
transliteration of the HAL code and an encoder written from the IEC 60958 spec agree bit for bit on random
input across odd chunk sizes and block boundaries. The FPGA adds nothing: **the stream carries
biphase-mark cells, 128 x fs of them per second**.

| item | contract |
|---|---|
| FE format | **S32_LE, 2 channels, interleaved, rate = 2 x fs.** fs is one of 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, so the FE runs at 88200 .. 768000. S16_LE at 4 x fs (fs up to 192000) carries the same words, each as two S16 samples, bits 31:16 first |
| frame | one IEC 60958 frame = 16 bytes = four S32 samples in this order: L.w0, L.w1, R.w0, R.w1. The ALSA channel pair is a transport pair: FE "left" carries w0 and "right" w1 of one subframe |
| audio | `a` = 24-bit two's complement sample. 16-bit audio sits in a[23:8]; a 32-bit input loses bits 7:0 |
| w0 | `pre << 24 \| bmc(a[3:0]) << 16 \| bmc(a[7:4]) << 8 \| bmc(a[11:8])` |
| w1 | `bmc(a[15:12]) << 24 \| bmc(a[19:16]) << 16 \| bmc(a[23:20]) << 8 \| bmc(VUCP)` |
| bmc(n) | 8 cells for 4 data bits, LSB of the nibble first, MSB of the byte = first cell. The level flips at the start of each bit cell pair, and again mid-pair for a 1. The input level is the last cell of the byte before, across words, subframes, FE frames and periods: one continuous line. Table (index `2n + prev`): `cc 33 b3 4c d3 2c ac 53 cb 34 b4 4b d4 2b ab 54 cd 32 b2 4d d2 2d ad 52 ca 35 b5 4a d5 2a aa 55` |
| preamble | after a 0 cell: B = 0xE8, M = 0xE2, W = 0xE4; after a 1 cell the inverses 0x17, 0x1D, 0x1B. B on the left subframe of frame 0 of every 192-frame block, M on every other left subframe, W on every right subframe |
| VUCP | nibble bit 0 = V, 1 = U, 2 = C, 3 = P. V = U = 0; P makes parity over slots 4 to 31 even |
| channel status | **Stock sends none: C = 0 in every subframe.** The HAL computes channel-status bytes (sampling-frequency codes) but nothing reads them. A real block (consumer, PCM, rate, word length) is the encoder's choice; the kernel never looks at the data |

How the words travel on mainline: the FE is S32 on a DAI with `qcom,s32-as-s16-pairs`, so the q6asm-dai
ack hook rotates each sample by 16 in place (`ror32(w, 16)`, the HAL's own half swap) and the DSP sees
16-bit stereo, high half first. ASM, ADM and AFE run 16-bit stereo at the fixed 384000 with NULL
topologies; the FPGA clocks I2S with BCLK = 128 x fs, 16-bit slots, MSB first, and forwards the data line
to its S/PDIF pin. The declared FE rate equals the true FE frame rate. (Stock declared fs while writing 4
S16 frames per audio frame, 4x off, which only worked because tinyalsa wrote blocking.)

Test vectors (S32 samples as the encoder writes them, stream start, previous level 0):

```
silence:            f0: e8cccccc cccccccc e4cccccc cccccccc   f1: e2cccccc cccccccc e4cccccc cccccccc
L = 0x123456,       f0: e8d4b4cb 532cb332 e4aaaaaa aaaaaacc
R = -1 (24 bit)     f1: e2d4b4cb 532cb332 e4aaaaaa aaaaaacc
```

DoP is the encoder's business: DSD64 = DoP at fs 176400 (FE 352800), DSD128 = fs 352800 (FE 705600), as
stock (`(dsd >> 5) << 1`). There is no DoP DSD256, since `spdif_table` has no 705.6k entry.

### Mainline: targets and the resolved target

Targets are stock's: OFF (T_NONE), LO 1, PO 2, BAL 3, **Spdif 4**, BAL-LO 7. `hm100_resolved()` is the
`Output` control if set, else the plugged jack, else **Spdif (nothing plugged in)**, as stock. Every stream
therefore gets a real target in hw_params and the FPGA, which is the I2S clock provider, always runs for
an open stream. The former "clocks only" target (T_CLK) is gone for that reason.

Each stream carries one flag, `spdif` (stock `spdif_enabled`), latched in `hm100_startup` from the
resolved target: what the stream **contains**. The target is where it **goes**.

Power chains are stock's; power-off drops the rails before the FPGA. No mute or unmute work for Spdif.
`hm100_enable_init` writes the 0x0120 init frame on every power-up, Spdif included.

reg0 per stream (`stream_word`):

| stream | reg0 |
|---|---|
| `spdif` latched, linear FE format, `rate x frame bytes / 16` in `spdif_table` | the `spdif_table` word (mode 1), e.g. S32 at 88200 -> fs 44100 -> 0x0011 |
| `spdif` latched, no table entry (a plain stream at 44.1k/48k, or S16 below 176.4k) | the PCM word of the FE rate (mode 0): clocks at the stream's own rate, S/PDIF pin quiet. Stock would run off the table to 0x0229, many times too fast |
| not latched | the PCM word of the FE rate |
| native DSD FE format | never a `spdif_table` word; `fe_frame_bytes` returns 0 for DSD formats |

The kernel takes a stream as S/PDIF cells exactly when it got a `spdif_table` word. The word follows the
**stream**, not the target, as in stock. This is what makes the switches below safe.

| from | event | to | what runs |
|---|---|---|---|
| OFF | stream opens, Auto, nothing plugged | Spdif | startup latches `spdif = 1`; hw_params powers target 4, IOB35B low, RUN low, spdif word; RUN at START |
| OFF | stream opens, jack or forced Output | that target | `spdif = 0`, PCM word |
| target | unplug (Auto), no stream | OFF after 5 s | the stock power-off; the next stream powers Spdif |
| target | unplug or Output -> Auto with nothing plugged, stream open | Spdif now | mute, `poweroff(t)`, `poweron(4)`, restart with the stream's PCM word (mode 0, pin quiet); userspace reopens through the encoder and the new stream latches `spdif = 1` |
| Spdif | jack plugged or Output forced, stream open | that target now | mute, `poweroff(4)`, `poweron(t)` (rails, then FPGA load), restart with the stream's **spdif word**. The analog output is not unmuted while the stream carries S/PDIF cells (full-scale noise otherwise); it opens once userspace reopens a PCM stream |
| Spdif | stream closed | OFF after Idle Power Off Seconds | `hm100_idle_work`; with 0 it stays up |
| any | stream opens while a power-off or a switch is pending | resolved target | hw_params switches itself; the pending work leaves it alone |

Cost: a plug or unplug with a stream open reloads the FPGA (about 0.6 s with no clocks, the PCM pauses).

### Mainline: the Output Target control

The userspace interface of the hm100 driver:

- `Output`: `Auto, Lineout, Headset, Balance, BalanceLo, Spdif` (Spdif appended, so saved indices keep
  their meaning). Stock's enum also has `Coax` (5) and `Iis` (6); no code path exists for them.
- `Output Target` (read-only, volatile, the same names without Auto): `hm100_resolved()`, the target a
  stream opened now runs on. It reads Spdif through an idle power-off. A value event follows every switch
  (jack change in Auto, Output change).
- Rule for encoders and UCM: read `Output Target` before opening; on an event, close and reopen (Spdif:
  through the encoder, S32_LE at 2 x fs; anything else: plain PCM). The kernel keeps the wrong kind of data
  off each output during the gap, but the new output is silent until the reopen.
- A **plain** S32 stream at 88.2k to 768k opened while the target is Spdif is indistinguishable from
  encoder output at fs = rate / 2: it gets the mode 1 word and puts non-BMC words on the coax pin.
  Receivers find no preambles and stay unlocked. This is why userspace must read the control first.
- Boot window: the first debounced jack result lands about 1 s after probe. With a jack plugged at boot,
  `Output Target` reads Spdif until then, and a stream opened in that window latches `spdif` and stays
  muted on the jack's output after the switch. The event that follows is real; the reopen it triggers
  fixes it.

### Native DSD in mainline

Format: DSD_U32_LE and DSD_U32_BE at DSD rate / 32.

| DSD | FE rate (frames/s) | reg0 | BCLK | 16-bit stereo frames/s at the AFE |
|---|---|---|---|---|
| DSD64 | 88200 | 0x0012 | 5.6448 MHz | 176400 |
| DSD128 | 176400 | 0x000a | 11.2896 MHz | 352800 |
| DSD256 | 352800 | 0x0002 | 22.5792 MHz | 705600 |
| DSD512 | 705600 | 0x00aa | 45.1584 MHz | 1411200 (not verified) |

Stereo only, offered only on a `qcom,s32-as-s16-pairs` FE (the RS6's MultiMedia1) that also has
`qcom,fixed-rate`; no new DT property. Why not stock's DSD_U16_LE at DSD/32: PipeWire counts DSD rates in
bytes per channel per second with a floor of 352800 (DSD64), so stock's tuple (88200 x 2 bytes) is below
its floor and would never play DSD64; MPD tries DSD_U8, then host-endian DSD_U32, then DSD_U16. DSD_U8 is
not offered (its rates exceed the FE's 768000). A DSD_U32 stereo frame is 8 bytes, the HAL's frame, and
the declared rate equals the true FE frame rate. With both U32 variants neither player converts
endianness.

Data path:

1. The player writes DSD_U32 frames at DSD/32 into MultiMedia1.
2. `q6asm_dai_ack` converts each period in place, before it is queued: per frame, the L and R 32-bit
   words (MSB = oldest bit, so byte 3 is the oldest), then four 16-bit words, oldest bytes first, each
   `even(L byte) | odd(R byte)`. On the wire (MSB first) a word is `R7 L7 R6 L6 ... R0 L0`. DSD silence
   (0x69) becomes 0x3cc3. This is exactly what the stock HAL sent. An offline check ran the HAL's table
   code and the kernel function on 4800 random frames, for both U32 byte orders: byte-identical.
3. ASM: linear PCM, 16 bit, 2 ch, `ASM_NULL_POPP_TOPOLOGY`, media format at the fixed 384000.
   `q6asm_dai_hw_params` refuses DSD on an FE without `qcom,fixed-rate`, since the DSP would resample.
4. ADM: `NULL_COPP_TOPOLOGY`, opened at the BE rate after `sm8250_be_hw_params_fixup` (384000, S16, 2 ch).
5. AFE SEC_MI2S_RX: 16 bit, 384000 nominal, external BCLK and WS from the FPGA.
6. hm100 (`hm100_hw_params` -> `hm100_stream_setup`): FE format via `fe_format()`, DSD rate = FE rate x
   32, which must give a mode-2 word or the stream is refused. Then, as stock: design for `DSD Mode`,
   volume update if the stream kind changed and `DSD Compensate` is not 0, the first-DSD kick if no stream
   has played since the module loaded (reg0 0x0120, RUN high, 1 ms, RUN low), IOB35B high, RUN low, reg0 =
   DSD word. START raises RUN as for PCM.

The channel assignment (b0 = left, oldest bit in bit 7) was **inferred** from the HAL; a left-only clip
played on the unit confirmed the channel order, so the kernel sends what stock sent and the order is right.

hm100 state:

- Controls: `DSD Mode` (`mdsd`, `dsd`; default `mdsd`, as the stock Settings wrote at boot) and
  `DSD Compensate` (-254..254, default 6, stock's `.data` value, +3 dB on DSD). Both apply from the next
  stream or volume write. `mdsd` loads `hiby/rs6/hm100-dsd.bin` (`hm100-dsd-gw1n9c.bin` for the GW1N-9C
  part, picked by IDCODE; extract with `tools/extract-hm100-blobs.py`); `dsd` keeps the PCM design and
  selects mode 2.
- `hm100_program_design()` is stock's `hm100_program_by_hw_param`: it reloads only when the other design is
  in SRAM. A failed load fails the stream and marks the design unknown (stock ignored the error).
- Every PCM stream goes back through the same helper: PCM design, IOB35B low, `stream_word()`.
- An output switch under an open DSD stream brings the DSD design back before RUN goes high.
- A DSD stream on Spdif (nothing plugged in): mode 2, analog side down, S/PDIF pin quiet.
- With the default `DSD Compensate` of 6 a DSD stream plays 3 dB louder than PCM at the same wheel level;
  the stock unit's own setting was 0.

Bit-exactness through the DSP: stock DSD went through the plain linear-PCM ASM/ADM/AFE path with no DSD
flag anywhere. Mainline does the same with less in the way: ASM, COPP and AFE all at 384000 (no rate
conversion), 16 bit throughout (no width conversion), NULL topologies (no soft volume, EQ or dither;
mainline sends no ACDB calibration), 2 in and 2 out at unity. Any gain, dither or requantization in the DSP
would flip the newest bits of every word and turn DSD into loud broadband noise. DSD64, DSD128 and DSD256
were verified by ear on the unit, which is consistent with unchanged words (**inferred**; no pattern
capture at the I2S pins was made). DSD256 means a true 705.6k frames/s against a declared 384000 AFE rate;
DSD512 (1.41M) and PCM 768k (1.536M) are the same order or higher and are not verified.

### Review fixes

Behaviour of `hiby-hm100.c` and `q6asm-dai.c` after the audio review. None of this is recorded as
verified on the unit.

- **DSD pause, suspend and start.** On PAUSE_PUSH and SUSPEND the AFE port, still clocked, sends 0x0000
  words, and at START, RESUME and PAUSE_RELEASE it does until the stream's data arrives. For PCM that is
  the zero level. For DSD every bit 0 is the most negative level (DSD silence is 0x69, 0x3cc3
  interleaved): a DC step at the output. Stock never hit this because its HAL stopped streams and never
  paused them (its trigger ignores PAUSE_PUSH and SUSPEND). Now DSD is muted on PAUSE_PUSH, SUSPEND and
  STOP (PCM keeps stock's behaviour), and its unmute waits `dsd_unmute_ms` (module parameter, default 50,
  writable at runtime) from the latest START, RESUME or PAUSE_RELEASE. 50 ms is a margin; the ASM-to-AFE
  start latency was never measured. The mute work runs on the high-priority workqueue because it races
  the DSP draining the last words. The mute and unmute works no longer cancel each other, and a DSD mute
  queues the unmute again itself, so an unmute always lands after the mute, at any `dsd_unmute_ms`
  including 0. Residual: on an xrun the mute must land within the tail still held by ADM and AFE, or a DC
  pulse of a few ms reaches the output.
- **Design reload (PCM <-> DSD) is muted first.** The reload takes about 0.6 s with the rails, the NJW and
  the amps powered, and the FPGA pins carrying iv_mute, hp_mute, po_amp_en, bal_amp_en and lpf_pwr_en are
  unconfigured meanwhile. Before the JTAG select goes low the driver now mutes synchronously, asserts the
  SoC-side LO and BAL-LO mutes (TLMM61 `lpf_mute`, TLMM76 `line_mute`; the only mutes that hold while the
  FPGA has no design) and waits 10 ms. The output opens only in the unmute work of a started stream.
  Gowin's GW1N schematic manual (UG284) says all GPIOs are high-impedance with weak pull-ups during
  configuration, so the mute pins should float high (muted) and the amp enables float enabled; an external
  pull-down on the board would change that (board side unknown).
- **`fe_frame_bytes`** returned 8 for DSD_U32 stereo (ALSA counts the DSD formats as linear). It now
  returns 0 for DSD explicitly (`fe_is_dsd()`).
- **Rates are negotiated in q6asm-dai.** On the RS6 FE, DSD is offered only at 88200, 176400, 352800 and
  705600, and PCM only at the DAC's rates (44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384, 705.6, 768 kHz);
  other rates go through plughw resampling. The matching rate checks in hm100 are now debug-level.
- **A failed FPGA load leaves the target off** and fails the stream (before, the target was marked on and
  every later hw_params retried up to three times with 1 s power cycles). While the failure stands,
  hw_params fail at once with -EIO; the next stream open clears it and retries once.

### The rs6-spdif package, UCM and WirePlumber

Package `device/testing/rs6-spdif` (postmarketOS, `pmos` branch), built with meson, MIT. It installs two
ALSA plugins and `50-rs6-spdif.conf` into `alsa.conf.d`.

**`rs6_spdif` (PCM plugin).** Applications open it at the audio rate fs: S16_LE, S24_LE or S32_LE, stereo,
any access type, fs one of the eight rates of [The coax stream format](#the-coax-stream-format). It opens
the card's playback PCM at S32_LE, 2 channels, 2 x fs (period 960 frames = 480 audio frames, 8 periods)
and writes four BMC words per audio frame (`iec958.c`, the contract of that section). No resampling,
dither or volume; S32 input loses bits 7:0.

- Because the kernel latches the S/PDIF flag at open, the plugin opens the card PCM only while
  `Output Target` reads Spdif, re-reads it after the open, and closes the card PCM as soon as the target
  changes.
- While **detached** (target elsewhere, or the device busy) it keeps time on CLOCK_MONOTONIC, discards the
  data and retries every 100 ms, so neither `aplay` nor PipeWire sees an error. The card PCM is opened at
  the first data, not when an application only probes the configuration.
- Config: `card` (default `HiByRS6`), `device`, `slave`, `ctl`, and `channel_status`: `consumer` (default;
  ALSA's IEC958 default block with the IEC 60958-3 sampling-frequency and word-length codes, including the
  extension codes for 352.8k and 384k) or `stock` (V = U = C = 0, like the stock HAL).

**`rs6_jack` (control plugin).** Two read-only boolean controls derived from `Output Target`: `SPDIF Jack`
on while the target is Spdif, `DAC Jack` on for anything else. UCM points `JackCTL` of both devices at
them, so PipeWire treats the two sinks like a headphone jack pair: it offers the one that can play and
makes it the default. Every `Output Target` event becomes a value event on both controls.

**Tests** (`meson test`): the encoder against the vectors of [The coax stream
format](#the-coax-stream-format), against the HAL transliteration and against a spec encoder (Python), the
plugin end to end through alsa-lib, and a target test that needs a sound card.

UCM (`device-hiby-rs6`, `ucm-HiFi.conf`, `ucm-card.conf`):

- The card file's `FixedBootSequence` sets `SEC_MI2S_RX Audio Mixer MultiMedia1`, the card's only route.
  The verb does not switch it off again (that made PCM opens outside the verb fail with "no backend DAIs
  enabled").
- Two devices on the one playback PCM, one usable at a time:
  - `Headphones` (priority 200): `hw:${CardId},0`, mixer element `Headphone`, jack `DAC Jack`.
  - `SPDIF` (priority 100): `rs6_spdif:${CardId}`, jack `SPDIF Jack`, no hardware volume (the analog side
    is off). UCM resolves PCMs in its own ALSA configuration, so the profile declares the `rs6_spdif` PCM
    in `LibraryConfig`; `rs6_jack` comes from the system configuration.
- UCM never sets `Output`, or every profile activation would overwrite the user's choice. `Auto` follows
  the jacks; the DAC page can pin one.

WirePlumber (`wireplumber-rs6.conf`, `wireplumber-output-handover.lua`):

- `api.alsa.ignore-dB = true` and `api.acp.disable-pro-audio = true` on the card. The only hardware volume
  is the NJW1195A's 100 steps; with a dB scale ACP would apply the remainder in software to every sample.
- `api.alsa.headroom = 1024` on the coax sink (matched by `~.*rs6_spdif:.*`): the card PCM behind it moves
  its position once per 960-frame period and the plugin cannot flag itself as a batch device. The coax
  sink is bit-perfect at 100 % volume; below that PipeWire scales in software.
- `output-handover.lua`: the two sinks share the card PCM. When a jack change moves the target, the
  `rs6_jack` controls mark the old sink's route unavailable; the script suspends a sink of this card at
  once when it goes idle with no available route, instead of after the 5 s idle suspend that would block
  the new sink. (The coax sink releases the PCM itself the moment the target moves.)

### How to check S/PDIF and DSD

Card id `HiByRS6` (see `aplay -l`).

**Target and coax.** With nothing plugged in and `Output` = Auto,
`amixer -c HiByRS6 cget name='Output Target'` reads Spdif. `aplay -D rs6_spdif:HiByRS6 file.wav` (any of
the eight rates) logs "target 4 on" and advances the card PCM's position at 2 x fs; a coax DAC or S/PDIF
analyzer on the cable checks lock, rate and bit-exactness. Plug headphones during coax playback: no burst,
the analog output stays muted until the stream reopens.

**Native DSD** (headphones plugged in first: with nothing plugged in the stream goes to Spdif and is
silent).

- While playing, `/proc/asound/card*/pcm0p/sub0/hw_params` shows `format: DSD_U32_LE` (MPD) or
  `DSD_U32_BE` (PipeWire) and `rate: 88200` for DSD64. The first DSD stream after PCM logs the
  `hm100-dsd.bin` load.
- PipeWire: `pw-cli enum-params <sink node> EnumFormat | grep -i -A2 dsd`, then
  `pw-dsdplay --target <sink node> file.dsf` (`pw-cat --dsd`; nothing else may be playing). MPD: an `alsa`
  output with `device "hw:CARD=HiByRS6,DEV=0"`, `dop "no"`, `mixer_type "none"`, with PipeWire released
  from the device; volume stays on the DAC's `Headphone`.
- Listen for the right pitch and speed and both channels on the right sides; broadband noise means the
  words are being changed. Repeat with `amixer -c HiByRS6 cset name='DSD Mode' dsd`. Set `DSD Compensate`
  to 0 before comparing levels with PCM.

**Review fixes.** A raw DSD64 silence stream is 0x69 bytes:
`python3 -c "import sys; sys.stdout.buffer.write(b'\x69' * (88200 * 8 * 30))" > dsd64-silence.raw`.

- Pause DC check: force the output (`amixer -c HiByRS6 cset name='Output' Headset`), play with
  `aplay -i -D hw:CARD=HiByRS6,DEV=0 -t raw -f DSD_U32_LE -c 2 -r 88200 dsd64-silence.raw` and read DC
  volts (tip and ring to sleeve) before, during and after a pause (space) and across a suspend: near 0 V
  throughout. A PCM zero stream is the control. Set `Output` back to Auto afterwards.
- Start window: compare a thump at stream start with `dsd_unmute_ms` set to 0 and to 50
  (`/sys/module/snd_soc_hiby_hm100/parameters/dsd_unmute_ms`).
- Design reload: PCM track, DSD file, PCM again, with no thump and no unmute before the stream starts.
- Rate negotiation: `aplay ... -f DSD_U32_LE -r 96000 dsd64-silence.raw` warns "rate is not accurate
  (requested = 96000Hz, got = 88200Hz)" and plays, with no "rate not supported" line in `dmesg`.
- Failed load: make the requested design file unavailable and play DSD (the open fails with one "load
  failed" line), then PCM (works).
- Regression: PCM on every output at 44.1k and 48k, idle power-off, suspend while playing.

### Open items of S/PDIF and DSD

1. The USB-C pin that carries S/PDIF, and the adapter wiring (needs a schematic or a probe).
2. Whether the S/PDIF pad is quiet in modes 0 and 2 (the netlist says the data line reaches IOT42B only in
   mode 1), and whether mode 0 runs with the DAC rails off (stock never ran that).
3. The coax output through `rs6-spdif`: no receiver result is recorded for lock, rates (352.8k and 384k
   need an FE of 705.6k and 768k), bit-exactness, and whether receivers accept the default consumer
   channel status or need the `stock` all-zero one.
4. DSD512 and PCM 768k, and whether the q6 path sustains a true 1.41M / 1.536M frames/s with the AFE
   declared at 384000. DSD256 (705.6k) plays on the unit.
5. The [Review fixes](#review-fixes) on the unit: the ASM-to-AFE start latency behind the 50 ms default,
   whether the high-priority mute beats the DSP drain on xrun, pause and STOP, whether the mute work runs
   before system suspend, and the board-level pulls on the FPGA mute and amp-enable nets during a design
   load.
6. What the DSD bitstream (`mdsd`) does that the PCM design's mode 2 does not, and which `DSD Mode` the
   by-ear listens used (not recorded).
7. The JTAG-select level after a design load is 1, as stock (see [Pins](#pins)); no capture shows control
   writes at that level. The first-DSD kick never ran on a pin in the stock captures.
8. The stock ACDB topology for the SEC_MI2S / MultiMedia5 path, and whether the ADM matrix mixer is
   lossless on arbitrary 16-bit words at unity (structurally a copy; a pattern capture at the I2S pins
   would settle it).
9. `Output Target` reads Spdif for about 1 s after probe when a jack is plugged at boot (see
   [Mainline: the Output Target control](#mainline-the-output-target-control)). Seeding the jack state with
   a synchronous read in probe would close the window.

### Kernel patches

All in the 94-patch series on `main` (`patches/linux/`). `rs6-spdif` is the `pmos` branch package.

| patch | change |
|---|---|
| 0031 | hm100 FPGA DAC driver: load, rate words, power sequencing, jack follow, controls |
| 0032 | q6asm-dai: `qcom,fixed-rate` and `qcom,s32-as-s16-pairs` (S32 as two 16-bit words, high first) |
| 0033 | sm8250: codec-clocked secondary MI2S, AFE fixed at 384 kHz |
| 0060, 0061, 0062 | native DSD_U32_LE/BE on the s32-as-s16-pairs FE: binding, in-place interleave, DT note |
| 0063 | q6asm-dai offers DSD at the DSD rates only ([Review fixes](#review-fixes)) |
| 0064 | Spdif target; Auto with nothing plugged resolves to it; per-stream `spdif` flag and `spdif_table` words |
| 0065 | read-only `Output Target` control and its events |
| 0066 | a failed FPGA load leaves the target off |
| 0067 | native DSD in hm100: `DSD Mode`, `DSD Compensate`, design reload with mute, first-DSD kick, `fe_is_dsd` |
| 0068 | DSD muted across pause, suspend and restart; `dsd_unmute_ms` |
| 0073 | comment fix for the DSD mute/unmute ordering |
| 0074, 0075 | q6asm-dai offers PCM at the DAC's rates only; the matching hm100 rate check logs at debug level |

## Darwin filters

The stock Darwin FIR filter presets: where they come from, how stock lists and selects them, and how
`darwinctl` uses them on Nura. The filters themselves ship in the `firmware` branch (`darwin/`). How the
kernel loads a `.flt` is in [FIR filters and R2R calibration](#fir-filters-and-r2r-calibration).

Offline RE of HiBy's stock firmware 1.80 (the EDL dump zip, sha256
`34b6a8826eda215e36551807608923bd6fe40cc329e403b65ef9fcb610480d59`) and a copy of `/data/vendor/misc` from
a running stock unit. Method: `system_a.bin` of the dump is a raw ext4 (reassembled 3 GiB image sha256
`f63403422f5f8e72e041a54994f59b8df7f3a42f7fcf123b0479e5b53abebb46`), `debugfs rdump /system`, `unzip` on
the APK, androguard 4 for dex disassembly and `resources.arsc` / binary XML. No jadx/apktool/aapt was
available, so the code facts below come from dalvik bytecode (class and method names are quoted so they
can be found again).

### Provenance

All assets live in one APK:

- `/system/priv-app/Settings/Settings.apk` (sha256
  `f0429f2543f5141ee4ed07bff3607f9bd83a5752217068d1b6904a22a7fc9820`), package `com.android.settings`
- inside the APK: `assets/*.flt` (1024 bytes each) plus `assets/filter.json` (sha256
  `d9975f8125da3a39176797b1654186f47469ca7077e4231ba7aa15b935e004c1`)

`1.flt`, `2.flt`, `3.flt` in `/data/vendor/misc` are byte-identical to `assets/1.flt`, `assets/2.flt`,
`assets/3.flt` of that same APK. The capture does not only contain 1/2/3: it holds 11 `.flt`, exactly the
11 entries of `filter.json` (all dated 2026-08-06 02:34, `system:system`, mode 0777), and every one
matches the APK asset of the same name.

`1.flt` and `2.flt` are the same bytes, so "Darwin Default" and "Darwin 1" run the identical FIR (they
differ only in the DSD filter, see [How stock exposes them](#how-stock-exposes-them)).
`nyquist-60-slow-rolloff-normal.flt` and `nyquist-30-slow-rolloff-minphase.flt` are also identical to each
other (neither is used by the UI).

sha256 of every .flt (APK asset; "dev" = also present in the captured /data/vendor/misc with the same hash):

| file | sha256 | in filter.json | dev |
|---|---|---|---|
| 1.flt | 60c4b0c2248f902eb0c83308b27d6ae4d83f68ad79b08525ce6ae48c45e20edc | yes | yes |
| 2.flt | 60c4b0c2248f902eb0c83308b27d6ae4d83f68ad79b08525ce6ae48c45e20edc | yes | yes |
| 3.flt | 75e8835dc43e613d764fb91be80781e76401399d1e0c0146a7146a8a2dad16f0 | yes | yes |
| raised-cosine-254-rolloff-normal.flt | e1d16f959fd3a52da976e36e40a3647a44d3b322ccfcd35b8d96c6dc9bfc4315 | yes | yes |
| raised-cosine-254-rolloff-square.flt | 6d1a2097289cf911afec2339f75d9624ad8b43bd0653e317df4a6d55a63de214 | yes | yes |
| raised-cosine-254-rolloff-999-square.flt | f37d829d433b888a1f2809457705bd95833f6ab829fe299b5a41f07553dbc7f4 | yes | yes |
| raised-cosine-254-fast-rolloff-normal.flt | 1edfd4aedd6ceb283edb0bd8aa5dc4678a6d775046f1054be93eed36b333c902 | yes | yes |
| raised-cosine-254-fast-rolloff-square.flt | d7b0c6aa1efc4ad45c8db8816bfc01b37f9daaf06b3435ecbd627846ddc7756c | yes | yes |
| raised-cosine-254-slow-rolloff-normal.flt | 5e447caa6d45de2cf50ab223bf670eec4e8e65ebfec297dcaa2d50a7785ee168 | yes | yes |
| raised-cosine-254-slow-rolloff-square.flt | d1ad37eb4549f251a25d4ac41ade087a20d4fca6035f1da9c25807344fdd2b67 | yes | yes |
| nyquist-30-rolloff-minphase.flt | e007a7e57301066d98b122ad7dd051ef909f483a78b51952a3bbe07adb66bf09 | yes | yes |
| 4.flt | d244f6aa0570e96c7747d14ff570f2ea9f88adc7efd798737dfcd12db5ffb2cd | no | no |
| bass-boost.flt | 3733bdb277c9ca57d15fe922dd0680c6383a8cd1255893df085ebaba30c0c183 | no | no |
| inverse-sinc-lowpass-254-min-phase.flt | 329a29fc5584bc6c788284ab9b5de8dd32d63bd3c8f717fb6cba58d55aacd27d | no | no |
| inverse-sinc-lowpass-254-normal.flt | 92adb306f53c66f3f0e344681cd3c64dda7eec00c218909cfc3595114bcfd9a2 | no | no |
| nyquist-30-slow-rolloff-minphase.flt | df607f8cd15b8cb5cef9b638c740b563d448d218e45438d9049dea75c1665eba | no | no |
| nyquist-60-rolloff-nonnegative.flt | 06f5180211f63566fecbb24d34bedd2cf0ced1294685efdd453e21d478ed8a12 | no | no |
| nyquist-60-rolloff-normal.flt | 1ea3c25132fd11bc808e504463683f35951827012a9ca142d2695d6dae0b734d | no | no |
| nyquist-60-slow-rolloff-normal.flt | df607f8cd15b8cb5cef9b638c740b563d448d218e45438d9049dea75c1665eba | no | no |
| nyquist-62-fast-rolloff-nonnegative.flt | 8d9069c43dc5f7b146e803a22dc4741ddac6000297d46f005dbf1e86f749bee0 | no | no |
| nyquist-62-fast-rolloff-normal.flt | eb86584fff4c3a8f28d4fede13f826b75cab09fb11c27521adc7d5e1325b428c | no | no |
| nyquist-62-slow-rolloff-nonnegative.flt | 9ea45079577a608512eeef0ea2908197652c74398ea26bf04db0ccb3cd465ae2 | no | no |

The 11 "no" rows are APK assets that stock never lists and never copies (the copy loop is driven only by
`filter.json`).

File format sanity (little-endian int32 x256): symmetric linear-phase kernels peak at tap 127 (e.g.
`1.flt` peak 930712756, sum 2147509284, about 2^31, so DC gain about 1.0 in Q31);
`nyquist-30-rolloff-minphase.flt` peaks at tap 2 (minimum phase, sum 2173219488).

### How stock exposes them

Screens and labels:

- Settings > Audio > "Darwin Controller" (`com.android.settings.audio.DarwinSettings`,
  `res/xml/darwin_settings.xml`, title `string/darwin_settings`). It holds the row `key=darwin_filter`,
  title `@string/fir_rolloff` (0x7f12066c), summary shows the current selection. Tapping fires intent
  `android.settings.DARWIN_FILTER`, which resolves to `com.android.settings.audio.FilterActivity`
  (manifest; its label is also `fir_rolloff`).
- `fir_rolloff` per language (the only localised strings involved; there is no `ko` entry, Korean falls
  back to default English):
  - default / en: "Low-pass antialiasing filter setting"
  - ja: "アンチエイリアスフィルタ"
  - zh-rCN: "数字滤波器模式"; zh-rTW and zh-rHK: "數字濾波器模式" (all = "Digital filter mode")
- `darwin_settings`: en "Darwin Controller", ja "Darwinコントローラー", zh-rCN "Darwin 控制器",
  zh-rTW/zh-rHK "Darwin 控製器".
- Sibling rows on that screen (not covered here): a `dsd_filter` ListPreference (`dsd_filter_title`
  "DSD Filter" / zh "DSD 滤波器"), NOS, bass boost, a harmonic controller and tuning presets.
- The per-filter names are not in resources. They are hard-coded English `title` strings in
  `assets/filter.json` ("Darwin Default", "Darwin 1" ... "Darwin 10"), identical in every locale.

The list in `FilterActivity`: a `ListView`; each row is a CheckBox (checked = current selection, text =
title) plus an ImageView (frequency-response plot) plus a TextView. The order is the order of
`filter.json`, filtered to entries whose file exists in `/data/vendor/misc/`. Row i uses icon array
`mDigitalFilterIconArr[i]` = `darwin_default, darwin_1 ... darwin_10` (drawables in
`res/drawable-xxhdpi-v4/`, 1120x380 magnitude-response plots; the plot is tied to list position, not to
the file name). If the user supplied their own `/sdcard/filter/filter.json` (Settings.Global
`isFromUserCopyInSdCard` = "yes"), the plots are hidden and the title text is shown instead. There is no
"off" / "none" / bypass entry. (`darwin_none.png` is a blank grid image and is not in the icon array.)

| # | stock label (filter.json `title`) | file | icon drawable | filter.json `desc` (never displayed, see [Metadata](#metadata)) |
|---|---|---|---|---|
| 1 (default) | Darwin Default | 1.flt | darwin_default | "" |
| 2 | Darwin 1 | 2.flt (same bytes as 1.flt) | darwin_1 | "" |
| 3 | Darwin 2 | 3.flt | darwin_2 | "" |
| 4 | Darwin 3 | raised-cosine-254-rolloff-normal.flt | darwin_3 | Darwin 4 - Raised-Cosine Rolloff Normal |
| 5 | Darwin 4 | raised-cosine-254-rolloff-square.flt | darwin_4 | Darwin 5 - Raised-Cosine Rolloff Square |
| 6 | Darwin 5 | raised-cosine-254-rolloff-999-square.flt | darwin_5 | Darwin 6 - Raised-Cosine Rolloff 0.999 Square |
| 7 | Darwin 6 | raised-cosine-254-fast-rolloff-normal.flt | darwin_6 | Darwin 7 - Raised-Cosine Rolloff 0.01 Square |
| 8 | Darwin 7 | raised-cosine-254-fast-rolloff-square.flt | darwin_7 | Darwin 8 - Raised-Cosine Rolloff 0.01 Square |
| 9 | Darwin 8 | raised-cosine-254-slow-rolloff-normal.flt | darwin_8 | Darwin 9 - Raised-Cosine Rolloff 0.5 Square |
| 10 | Darwin 9 | raised-cosine-254-slow-rolloff-square.flt | darwin_9 | Darwin 10 - Raised-Cosine Rolloff 0.5 Square |
| 11 | Darwin 10 | nyquist-30-rolloff-minphase.flt | darwin_10 | Darwin 18 - Nyquist 30 Rolloff Min Phase |

The `desc` numbering is off by one from `title` and partly copy-pasted (both fast entries say "0.01
Square", both slow ones "0.5 Square"), so treat the file names, not the descs, as authoritative.

Preset tuning profiles (`res/raw/darwin_presets.json`, key `digital_filter`) reference these titles
("Darwin Default" for QDC Anole V14, FIDUE Artemis, Softears RS10; "Darwin 1" for UM MASON FuSang;
"Darwin 10" for UM MEST MKII and DUNU ZEN PRO; "Darwin 8" for DITA Dream XLS) and apply them through the
same path as a selection.

What selecting one does: `FilterActivity$1.onItemClick(pos)` calls `setDigitalFilter(valueList[pos])`,
where the value is the full path `/data/vendor/misc/<file>.flt`. `setDigitalFilter` does three things:

1. `Settings.Global.putString(resolver, "vendor.audio.hw.vendor_funcfilter_path ", "<path>")` (the key
   really has a trailing space; this is the persisted selection that the UI reads back).
2. `SystemProperties.set("vendor.audio.hw.vendor_func", "filter_path <path>")`
3. `SystemProperties.set("vendor.audio.hiby.hw.darwin.filter_path", "filter_path <path>")`

(`DarwinSettings.setDigitalFilter` does 1 and 2 only, not 3.) The adapter then refreshes the checkbox.
Example value: `filter_path /data/vendor/misc/raised-cosine-254-rolloff-normal.flt`. Step 2 reaches the
kernel's `vendor_func` (see [Settings sysfs](#settings-sysfs)); step 3 goes to the HAL's DSP unit (see
[Who writes what](#who-writes-what)).

Default and first-run population:

- Default = first list entry (`valueList[0]` = `/data/vendor/misc/1.flt`, "Darwin Default").
  `FilterActivity.initSelectValue` reads Global `vendor.audio.hw.vendor_funcfilter_path `; if null it
  falls back to Global `vendor.audio.hw.vendor_func` (stripping `filter_path `); if still null, or the
  stored path is not in the list, it applies entry 0 via `setDigitalFilter`.
  `DarwinSettings.resetDarwinDefaultValue` also resets to entry 0 (and the DSD filter to `mdsd`).
- Population (`DarwinSettings.initDigitalFilterData`, run in `onCreate` of the Darwin Controller screen):
  `copyRawToFile()` copies every asset named in `filter.json` into `<filesDir>/filter/`;
  `startCheckFileAndCopy()` takes `/sdcard/filter/filter.json` if the user made one, else copies the APK
  `assets/filter.json` to `<filesDir>/filter_sd/filter.json`; then `copyFile`/`copyFiletoSystem` does a
  plain FileChannel copy of each listed .flt into `/data/vendor/misc/` (creating the dir if absent). This
  explains the 2026-08-06 02:34 timestamps on all 11 files. `initShowData` adds a list row only if the
  file exists in `/data/vendor/misc/` afterwards.
- Fallback if the title list is empty: resource arrays `digital_filter_list_preference` /
  `digital_filter_value_list_preference` (0x7f030061 / 0x7f030064), an ES9038-style set with no files:
  Sharp Roll-off (`sharp_roll_off`), Slow Roll-off, Short Delay Sharp Roll-off, Short Delay Slow Roll-off,
  Super Sharp Roll-off, Super Slow Roll-off, Low Dispersion Short Delay. Not reached on a normal RS6 since
  `filter.json` is bundled.
- Separate DSD filter list (`array/dsd_filter_title` = "Darwin Default" / "Darwin 1", values `mdsd` /
  `dsd`; set via property `vendor.audio.hw.vendor_func` = `dsd_mode <mdsd|dsd>` and Global `dsd_filter`).
  Its two titles share names with the first two PCM filters (presets set both from one `digital_filter`
  name: "Darwin Default" -> `mdsd`, "Darwin 1" -> `dsd`), but it is a different control. Other
  `vendor_func` verbs seen: `nos_enable on|off`.

### Metadata

- Grouping: all 11 sit under the single "Darwin Controller" screen, row "Low-pass antialiasing filter
  setting" (zh "Digital filter mode"). No further grouping or headings.
- The only metadata in `filter.json` is `title`, `desc`, `path`. The code (`FilterActivity.initShowData`,
  `DarwinSettings.initShowData` / `copyRawToFile` / `copyFile`) reads only `title` and `path`; `desc` is
  never shown. `path` is `/mnt/sdcard/filter/<file>`, only its basename is used (the target is always
  `/data/vendor/misc/<basename>`).
- Visual metadata: one magnitude-response PNG per list position (`darwin_default`, `darwin_1` to
  `darwin_10`).
- Filename vocabulary (names and desc): raised-cosine with 254 taps; `fast` / `slow` rolloff (desc says
  0.01 / 0.5); `normal` vs `square`; `rolloff-999-square` (0.999); `nyquist-30-...-minphase` =
  minimum-phase.

### On Nura

- `firmware-hiby-rs6` installs stock's `filter.json` (unchanged) and the 11 `.flt` it lists to
  `/usr/share/hiby-rs6/darwin/`, extracted from a stock dump by `tools/make-firmware-tarball.sh`
  (Settings.apk in system_b). The 11 unlisted assets are not shipped: stock never offered them. `1.flt`
  (Darwin Default) and `2.flt` equal the kernel's built-in set 0 (sharp_roll_off), `3.flt` equals set 1,
  so the boot default already matches stock.
- The hm100 driver's "Digital Filter" has a last item "custom" (kernel series): the FIR Custom set, which a
  FIR Custom write selects. Stock's indices 0-6 keep their meaning.
- `darwinctl` (`userspace/darwinctl` on the main branch):
  - `darwinctl` / `darwinctl status`: active filter and NOS.
  - `darwinctl list [--porcelain]`: built-in filters, then Darwin filters in filter.json order with stock
    titles (works without the DAC too).
  - `darwinctl set <filter>`: a built-in name (`sharp_roll_off`, `slow-roll-off`, ...), a Darwin title or
    file name (`"Darwin 3"`, `darwin-10`, `raised-cosine-254-rolloff-normal`), a `.flt` path, or `custom`
    (the last Darwin filter again).
  - `darwinctl nos on|off`.
  - `darwinctl restore`: run by `darwinctl-restore.service` at sound.target after alsa-restore.
  - Own filters: `~/.local/share/hiby-rs6/darwin/*.flt`, optionally with a filter.json in stock's format
    (like stock's `/sdcard/filter`); they come first.
  - State: `/var/lib/hiby-rs6/darwin/{filter.flt,name}` (group audio, setgid). alsactl keeps the Digital
    Filter index across reboots, darwinctl the custom taps.
- RS6 DAC settings page: "Digital filter" lists the built-ins plus "Darwin filter"; with that one active, a
  "Darwin filter" combo lists the stock Darwin filters; "Load a Darwin filter file" takes any .flt. All of
  it goes through darwinctl, so it is kept for the next boot. The quick setting shows the active Darwin
  filter's name.

### Open item

- `vendor.audio.hiby.hw.darwin.filter_path` is set only by `FilterActivity.setDigitalFilter`; the HAL-side
  consumer is closed code and was not examined for these notes beyond the `darwin_filter_path` hand-off in
  [Who writes what](#who-writes-what).
