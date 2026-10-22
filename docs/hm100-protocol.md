# hm100 (HiBy "Darwin" FPGA) protocol notes

Source: stock RS6 1.80 kernel (4.4.153, kallsyms via vmlinux-to-elf), the stock DTB #96 (`dtb96.dts`, appended to the stock boot image), static disassembly passes
(2026-10-20) incl. a second one on control words / calibration. Status per item: **confirmed** (seen in a live trace), **static** (read from the
binary only), **open**. Machine-driver sequencing, settings and MI2S are in `sa-sound.md`.

## Part
Gowin GW1N(R)-9, IDCODE 0x1100581B (openFPGALoader masks the top nibble → GW1NR-9). Static.
`hm100_set_id_code` (0xffffff8008cee0b4) accepts 0x1100581B and 0x0900281B; only 0x1100581B selects
the GW1N-9 GPO name tables. Static.

## Pins (TLMM)
| gpio | JTAG | control SPI | NJW1195A |
|---|---|---|---|
| 8 | TDI | SDO | DATA |
| 9 | TDO | | |
| 10 | TMS | CS (active low) | LATCH |
| 11 | TCK | CLK (sample on rising) | CLOCK |
| 12 | `hm100,reset-gpio`: run/stop, see below | | |
| 13 | | share-spi-select (1 = NJW1195A) | |
| 44 | jtag-select | | |
| 55 | FPGA power | | |

- DT has `hm100,jtag-io-as-spi-io`, so `hm100_probe` (0xffffff8008cef86c) reuses TDI/TCK/TMS as
  SDO/CLK/CS. Static.
- gpio 12 is driven by `hm100_start` (high) and `hm100_stop` (low), around every rate change and at
  stream start; it is not the configuration reset. Static. (Earlier table said just "reset".)
- gpio 13: `hm100_share_spi_lock` (0xffffff8008ceefc0) takes the SPI mutex and sets it to 1 before NJW1195A
  writes; `hm100_share_spi_unlock` sets 0. Static (was "open: verify polarity").
- gpio 44: `hm100_jtag_io_func_select(0)` before JTAG programming, `(1)` after it in
  `hm100_program_by_hw_param`. `hm100_program` leaves it at 0 on success. Which level the control
  port needs: open.
- Power: no `hm100,power-regulator` in DT, so `hm100_power_enable` drives `hm100,power-gpio` (55). Static.

During the bitstream data phase gpio 8/11 are muxed to `blsp_spi3` (`spi@c177000`, 10 MHz,
DT node `hiby,hbc3000_ram`) and TMS is held low. Static.

## Bitstreams
`FS_data` (PCM design) and `FS_dsd_data` (DSD design) in the kernel's .data.
Each: 4-byte header `GW1N`, 22 × 0xFF, `A5 C3` sync, `06 00 00 00 11 00 58 1B`, …;
1737 pages × 256 bytes. Extract with `tools/extract-hm100-blobs.py`. Static.
The DSD design is only used when `dsd_mode` is "mdsd": `hiby_snd_hw_params` calls
`hm100_program_by_hw_param(1)` then, while the default "dsd" mode keeps the PCM design and only
switches reg 0 to mode 2. `hm100_program_by_hw_param` reprograms only when the requested design differs
from `hm100_fw_version`. Static. (Earlier text said the design is swapped on every PCM↔DSD change;
that is only true in "mdsd" mode.)

## SRAM load (`hbc3000_jtag_program_ram`), static
1. TAP reset; IR 0x11 READ_IDCODE, accept GW1N-1 / GW1N-4 / GW1N-9(C) ids
2. IR 0x13 READ_USERCODE; skip programming if it matches the expected id
3. reset; IR 0x3C ×2; 0x15 CONFIG_ENABLE; 0x05 ERASE_SRAM ×2; 0x3A CONFIG_DISABLE
4. 0x15; 0x17 XFER_WRITE; TMS 1,0,0 → Shift-DR; stream the pages over SPI; TMS 1,1,0
5. 0x3A; 0x02 NOOP; reset; 0x13 verify USERCODE. 0x41 STATUS only read on failure.
Differs from openFPGALoader's writeSRAM (no 0x12 INIT_ADDR, no 0x09, no 0x0A/0x08 checksum).

## Control words
All static.

### Framing (`hm100_spi_write_lock_or_unlock.constprop.10` 0xffffff8008ceeb6c)
CLK low, CS low, then 16 × (CLK low, SDO = bit 15, shift left, CLK high), then CS high (CLK is left
high). MSB first, data changes while CLK is low. Write only: no read path, no R/W flag, no address
auto-increment. The constprop dropped the lock argument; the "lock" is the `g_hm100` mutex taken by
callers, not an on-wire lock/unlock word.

### Frame layout (`hm100_set_reg_data_unlock` 0xffffff8008ceec38)
`frame = (reg << 10) | (data & 0x3ff)`: bits 15:10 register (6 bits), bits 9:0 data.
`hm100_set_reg_data` (0xffffff8008ceeee8) wraps it in the mutex.

### Register map
| reg | frame | writer | meaning |
|---|---|---|---|
| 0x00 | `0x0000 \| word` | `hm100_set_samplerate` 0xffffff8008cef520 | rate / format, see below |
| 0x01 | `0x0400 \| v` | `hm100_set_gpo`, `hm100_enable_init` | GPO group 0 (10 pins) |
| 0x02 | `0x0800 \| v` | `hm100_set_gpo`, `hm100_enable_init` | GPO group 1 (10 pins) |
| 0x03 | `0x0c00 \| v` | several | control, shadow `spi_reg_power` (bss 0xffffff800a695628, starts 0) |
| 0x10 | `0x4000 \| m` | `hm100_set_module_coef` 0xffffff8008ceec5c | coefficient module select |
| 0x11 | `0x4400 \| a` | `hm100_set_module_coef` | start address in the module |
| 0x12 | `0x4800 \| b` | `hm100_set_module_coef` | one data byte (bits 7:0) |
| 0x13 | `0x4c00` | `hm100_set_module_coef` (raw frame) | commit / end of block |

Reg 3 bits (shadow, whole 10-bit value rewritten each time):
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

### Coefficient block (`hm100_set_module_coef(module, addr, buf, n)`)
`0x10 module`, `0x11 addr`, then per 32-bit word four `0x12` frames, bytes 31:24, 23:16, 15:8, 7:0,
then raw `0x4c00`. Modules used: 0 = live SAR (R2R) coefficients, 1 = write-back target (see Filters),
2 = FIR (256 taps at addr 0). `coef_input` accepts modules 0..5.

### GPO (`hm100_set_gpo(name, val)` 0xffffff8008cefdf0)
Looks the name up in group 0, then group 1, sets or clears bit i of that group's 16-bit shadow
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
IOR5A, IOT17A) but are not used on RS6. Only group-0 names are used by the RS6 DT.

### Sample-rate word (`hm100_set_samplerate`, table `dsd_i2s_table_hm100`), static
Table entries are 8 bytes: u32 rate, u8 f0, u8 f1, u8 f2, pad. The "word" column below is
`f2 << 16 | f1 << 8 | f0` (a little-endian read of bytes 4..6), as in the first pass; the actual frame
is in the next table.

| rate | word | | rate | word |
|---|---|---|---|---|
| 44100 | 0x40200 | | 705600 | 0x50000 |
| 48000 | 0x40201 | | 768000 | 0x50001 |
| 88200 | 0x20100 | | DSD 2822400 | 0x20000 |
| 96000 | 0x20101 | | DSD 5644800 | 0x10000 |
| 176400 | 0x10000 | | DSD 11289600 | 0x00000 |
| 192000 | 0x10001 | | DSD 22579200 | 0x50100 |
| 352800 | 0x00100 | | | |
| 384000 | 0x00101 | | | |

Frame build (one frame, reg 0):
`data = (f0 << 9) | ((f1 & 3) << 7) | ((f2 & 0xf) << 3) | mode`, masked to 10 bits.
- bit 9 = f0 = clock family (0 = 44.1k / 45.1584 MHz, 1 = 48k / 49.152 MHz)
- bits 8:7 = f1, bits 6:3 = f2 (rate-dependent dividers or oversampling selects, meaning open), bit 2 = 0
- mode bits 1:0: 0 = PCM (32000 ≤ rate ≤ 768000), 2 = DSD (any other rate), 1 = S/PDIF
- S/PDIF (`spdif_enabled`, set by `hm100_set_spdif_mode` when the Spdif output is active) uses the
  separate 8-entry `spdif_table` (0xffffff8009226a58) instead.
- Lookup is linear; an unknown rate falls through to the last entry.
- Sequence: `hm100_stop` (gpio 12 low), write reg 0. It does not restart; `hm100_start` comes from
  trigger or `hm100_enable_init`.

| rate | frame | | rate | frame | | S/PDIF rate | frame |
|---|---|---|---|---|---|---|---|
| 44100 | 0x0120 | | 705600 | 0x0028 | | 44100 | 0x0011 |
| 48000 | 0x0320 | | 768000 | 0x0228 | | 48000 | 0x0211 |
| 88200 | 0x0090 | | DSD 2822400 | 0x0012 | | 88200 | 0x0009 |
| 96000 | 0x0290 | | DSD 5644800 | 0x000a | | 96000 | 0x0209 |
| 176400 | 0x0008 | | DSD 11289600 | 0x0002 | | 176400 | 0x0001 |
| 192000 | 0x0208 | | DSD 22579200 | 0x00aa | | 192000 | 0x0201 |
| 352800 | 0x0080 | | | | | 352800 | 0x0029 |
| 384000 | 0x0280 | | | | | 384000 | 0x0229 |

### Init sequence (`hm100_enable_init` 0xffffff8008cef648)
1. reg 3 with bit 9 cleared
2. reg 1, reg 2 from the GPO shadows
3. `hm100_set_samplerate(hm100_sample_rate)` (stop, reg 0)
4. `hm100_start`
5. reg 3 bit 1 set, udelay 2000, cleared (load_flash pulse)
6. module 2 ← `hm100_fir_coef_custom` (256 words), done twice
7. `hm100_stop`

Probe (`hm100_probe`) runs `hm100_enable`, `hm100_stop`, `hm100_set_samplerate(44100)`, `hm100_disable`.

## Filters (Darwin)
- `.flt` = 1024 bytes = 256 × int32 FIR taps, loaded into FPGA module 2 via
  `hm100_set_module_coef(2, 0, buf, 256)` (×2) from `hm100_filter_path_set_by_vendor`. Static.
- `hm100_fir_coef_default`: 4 KB in the kernel = 4 filters × 256 taps. Probe copies filter 0 into
  `hm100_fir_coef_custom`, which `hm100_enable_init` reloads on every power-up. `hm100_set_filter_coef`
  (0xffffff8008ceed6c) loads filter idx 0..3 straight from the default table (module 2 only, once) without
  touching the custom buffer. Static.
- NOS = `osr_bypass`; `sar_bypass` disables the R2R correction. Static.

### SAR / R2R calibration (`hm100_sar_coef_data`, bss 0xffffff800a695630, 256 B), static
- Layout: 64 × u32, entries 0..31 = left (module 0, addr 0), 32..63 = right (module 0, addr 0x200).
- Filled by `hm100_probe` (loop at 0xffffff8008cefc2c) with ideal binary weights:
  `buf[i] = buf[32 + i] = 0x80000000 >> i`, i = 0..31. Nothing reads it from a file or from the FPGA.
- Per-unit calibration lives in the FPGA's internal flash. Every `hm100_enable_init` pulses reg 3 bit 1,
  the same bit `load_flash_set(1)` pulses, so the FPGA reloads its stored coefficients into module 0 by
  itself at each power-up (meaning of the bit: guess from the sysfs name; the pulse itself is static).
  The kernel never sends the buffer during normal operation.
- Host paths that touch it (all sysfs, all userspace-driven):
  - `coef_input "1 addr data"`: stores `data` at `buf[(addr & 0x3f) + 32 * ((addr >> 9) & 1)]` and
    writes it live to module 0.
  - `load_flash 0`: resets the buffer to ideal weights and writes both halves to module 0.
  - `write_back`: writes both halves to module 1 (guess: flash staging, used after `erase_flash`).
- Guess at the factory flow: `calib_process start` / other (unmute / mute the active output), tune
  module 0 through `coef_input`, then `erase_flash`, `write_back`.
- For a mainline driver: leave the buffer alone and keep the reg 3 bit 1 pulse in init.

## Never touch
`erase_flash`, `load_flash`, `write_back` sysfs attrs: they hit the FPGA's internal flash
(reg 3 bits 1 / 2 and module 1, see above). `load_flash 0` also overwrites the live per-unit calibration
with ideal weights until the next power-up.
