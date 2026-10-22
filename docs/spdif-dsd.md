# RS6 coax S/PDIF and native DSD: what stock does, what mainline does

Two outputs of the RS6 DAC FPGA (hm100) that stock firmware 1.80 drives in ways a generic PCM driver does not: the
coaxial S/PDIF pin and native DSD to the internal DAC. Stock facts come from static analysis of the 1.80 images
(GPL kernel in detail, closed HAL only as the source of a fact) and offline captures.

Related notes: `sa-sound.md` (analog chain, power sequencing), `hm100-protocol.md` (FPGA control words, rate words),
`playback-path.md` (PCM path, clocking, volume).

The comments in the `rs6-spdif` sources and in `ucm-HiFi.conf` cite an earlier numbering of this page: their 9.1
(encoder contract and test vectors) is section 6 here, 9.4 (userspace interface) is section 7.2, and 9 is sections 6
and 7.

## Verification status

- Verified by ear on the unit: native DSD64, DSD128 and DSD256 on the analog outputs. A clip with sound in the left
  channel only confirmed the channel order.
- Not recorded as verified on the unit: DSD512, PCM 768k, the coax S/PDIF output through `rs6-spdif`, and the
  review fixes in section 9 (they are in the kernel the unit runs, but were not tested on their own).
- Sections 2 to 5 were not measured on stock hardware pins. In the stock captures every HiBy Music run had
  `Output Select = Spdif`, so the native-DSD path of the stock kernel was read from code, not seen on a wire.

Evidence tags, as in `playback-path.md`: **confirmed** = seen in a capture, **static** = read from a binary or
config, **inferred** = reasoned from static facts, **guess** = plausible, nothing in the evidence decides it,
**open** = unknown. Captures are "(capture, not published)"; `docs/re-tools/decode-trace.py` decodes them.

## 1. Summary

- **Coax is the stock fallback route, not a user action.** With nothing plugged in, AudioPolicy routes to SPEAKER,
  the HAL maps it to the `spdif` snd device, and the mixer path sets `Output Select = Spdif` (section 3).
- **Kernel S/PDIF is one flag and one table** (`spdif_enabled`, `spdif_table`), which also forces reg0 mode 1.
  **The FPGA does not encode S/PDIF, the HAL does**: in mode 1 the FPGA only forwards its serial data line to the
  S/PDIF pad (sections 2 and 6).
- **Stock native DSD is raw DSD bits as 16-bit PCM over the normal MI2S path**, both channels bit-interleaved; the
  ADSP never learns it is DSD (section 5).
- **How the signal reaches the USB-C connector is not in the software** (section 4).
- **Mainline does both**: nothing plugged in resolves to the Spdif target, a read-only `Output Target` control tells
  userspace where a stream goes, DSD_U32_LE/BE at DSD rate/32 plays natively, and the `rs6-spdif` package provides
  the encoder (sections 7 to 10).

## 2. S/PDIF in the stock kernel

### 2.1 spdif_table (static, read from the ELF)

Entry = u32 rate, u8 f0, u8 f1, u8 f2, u8 pad (8 bytes), 8 entries at 0xffffff8009226a58 (stock 1.80 kallsyms
address). Control word: `reg0 = f0<<9 | (f1&3)<<7 | (f2&0xf)<<3 | mode`, mode = 1 for this table. Register 0 has
opcode 0 in bits 15:10, so the 16-bit frame equals the data word (`hm100-protocol.md`).

| rate | f0 | f1 | f2 | reg0 |
|---|---|---|---|---|
| 44100 | 0 | 0 | 2 | 0x0011 |
| 48000 | 1 | 0 | 2 | 0x0211 |
| 88200 | 0 | 0 | 1 | 0x0009 |
| 96000 | 1 | 0 | 1 | 0x0209 |
| 176400 | 0 | 0 | 0 | 0x0001 |
| 192000 | 1 | 0 | 0 | 0x0201 |
| 352800 | 0 | 0 | 5 | 0x0029 |
| 384000 | 1 | 0 | 5 | 0x0229 |

The lookup is linear and stops at the last entry: **any rate not in the table gets the 384000 word 0x0229** (static).
The PCM/DSD table does the same with the mode bits taken from the requested rate: an unknown rate in 32k..768k gets
mode 0, one above gets mode 2. Confirmed on the wire: 0x0011 at 44.1k, and 0x0009, 0x0001, 0x0201 in the HiBy
Music runs (section 3).

The DSD rate families use the same f2 values: DSD64 f2 = 2 (like S/PDIF 44.1k), DSD128 f2 = 1 (88.2k), DSD256
f2 = 0 (176.4k). **Inferred**: BCLK is the same in both (5.6448 / 11.2896 / 22.5792 MHz); the modes differ in what
the FPGA does with the data line.

### 2.2 hm100_set_spdif_mode and every use of spdif_enabled

`hm100_set_spdif_mode` (0xffffff8008ceff1c) stores the flag. `hm100_set_samplerate` (0xffffff8008cef520) picks the
table from it: `spdif_table` (8 entries, mode 1) if set, else `dsd_i2s_table_hm100` (14 entries, mode 0 if
32000 <= rate <= 768000, else mode 2). It then stores the rate, drops RUN (`hm100_stop`) and writes reg0.

`spdif_enabled` is written only by `hm100_set_spdif_mode`, which is called only by `hiby_snd_startup` with
`current_target_on == 4`. It is read only in `hm100_set_samplerate`. The older `hbc3000` FPGA driver has its own copy
of all this; the RS6 binds `hiby,hm100`, so that copy is dead here. Consequences (static):

- The flag is latched **per stream open** (`hiby_snd_startup`, called from `msm_mi2s_snd_startup`), not at output
  switch. `Output Select = Spdif` must be set before the PCM opens.
- The flag is not reset on stream end or power-off. `hm100_enable_init` calls `hm100_set_samplerate` with the
  stale flag, so the post-load init frame is 0x0001 in one capture (flag left set) and 0x0120 in another (flag 0).
  Harmless, since hw_params rewrites reg0.
- `hiby_snd_hw_params` does not look at the flag. A PCM-format stream does `hm100_program_by_hw_param(0)`,
  clears `output_format`, sets `pcm_dsd_sel` low via `hm100_set_gpo`, then `hm100_set_samplerate(rate)`. There is no
  S/PDIF-specific GPO write. Confirmed: at play, reg1 0x0420 (IOB35B already 0), reg0 0x0011, RUN high.
- STOP and START do no mute or unmute for target 4.

### 2.3 What the Spdif target (4) powers

`hiby_target_poweron` case 4 (`hiby_output_switch` maps the string "Spdif" to 4):

```
hiby_bal_po_amp_power(0); hiby_po_amp_power(0); hiby_volume_power(0);
hiby_lpf_sel(0); hiby_lpf_power(0); hiby_dac_power(0); hm100_enable();
```

Power-off is the same chain ending in `hm100_disable` (`sa-sound.md`; confirmed in the captures: gpio 1023, 15, 34,
55, 28, 40 all low afterwards). So Spdif powers the FPGA (TLMM55, bitstream, init) and nothing else: **the DAC
rails (TLMM28 audio_dc_dc_en, TLMM40 dac_pwr_en) stay off**, the LPF, volume supply and both amps stay off, and
the reg1 mute bits stay as the previous target left them. The AFE clocks come from the FPGA oscillators, not from
the DAC rails (inferred from the netlist). The HiBy Music runs ran start to finish with the rails off; there is no
error in the kernel logs, but also no audio proof from them.

## 3. What selects S/PDIF in stock

The kernel only reports jacks: `sa_sound_switch` polls the four jack GPIOs every 200 ms, debounces 4 reads and sets
switch-class states (`balance`, `balance_lo`, `h2w`, `lineout`; with DT `report_only_one` only the first plugged jack
in DT order reports). `hiby_output_switch` is reached only from the `Output Select` mixer put. No kernel code picks
Spdif for "no jack". The chain (static):

1. **Framework.** `WiredAccessoryManager` has no `spdif`/`iis` kernel switch to observe, so BIT_SPDIF is never set.
   With nothing plugged in, AudioPolicy falls back to `AUDIO_DEVICE_OUT_SPEAKER` (**inferred**: standard Android
   behaviour; the HAL mapping below only makes sense for that device).
2. **HAL `platform_get_output_snd_device`** maps SPEAKER to snd device 11, named "spdif" in the HAL's table (8 "line",
   9 "balance", 10 "balancelo", 12 "iis", 13 "headphones", 2 "speaker"). `out_set_parameters` also handles wired
   names (Lineout, Balance, BalanceLo, Spdif, Iis); that path is not exercised on the RS6.
3. **HAL `enable_snd_device`** calls `output_proxy_spdif(snd_device == 11)`, which switches the HAL's own mixer target,
   then applies the mixer path.
4. **`mixer_paths.xml`, path `spdif`**: `SEC_MI2S_RX Channels = Two`, WCD controls that are no-ops on this card, and
   **`Output Select = Spdif`**. `headphones` sets `Headset`, `line` `Lineout`, `balance` `Balance`, `balancelo`
   `BalanceLo`, `iis` `Iis`; the `speaker` path has no `Output Select`. No path sets `Coax`.
5. **Kernel**: `output_select_put` -> `hiby_output_switch("Spdif")` -> `hiby_target_poweroff(old)` +
   `hiby_target_poweron(4)`. When the HAL puts the stream in standby, `Output Select` returns to None and the switch
   work powers the FPGA down 5 s later.

Not on the path: HiBy Music (it steers its own format conversion by device type, never the mixer), Settings
"Multifunction Output" and `vendor.audio.hiby.hw.output` (stored, never consumed by routing), and adapter
auto-detection (none exists, section 4).

Rates seen in the HiBy Music runs (confirmed, capture not published, all with `Output Select = Spdif`):

| track | reg0 | meaning |
|---|---|---|
| PCM 88.2k | 0x0009 | S/PDIF 88.2k |
| PCM 176.4k | 0x0009 then 0x0001 | 88.2k, then 176.4k (engine reopened once) |
| PCM 352.8k / 384k | 0x0001 / 0x0201 | resampled by the engine to 176.4k / 192k |
| DSD64 | 0x0001 | DoP at 176.4k |
| DSD128 | 0x0009 | converted to PCM at 88.2k |

## 4. How the S/PDIF signal gets to the USB-C connector

- **No mux GPIO.** The stock DT's `dp_ctrl` node names TLMM76 and TLMM21 as DisplayPort aux pins, but the stock
  kernel has no DP driver (`# CONFIG_FB_MSM_MDSS_DP_PANEL is not set`; the only `mdss_dp` symbols are clock tables
  and a PLL table). Those pins are the HiBy `line_mute` and balance_lo jack detect, so there is no conflict.
- **No Type-C, PD or accessory code for it.** The Type-C logic is the PM660 SMB2 and `qpnp-pdphy`. The HAL's USB
  branch is for USB-audio-class devices. Nothing in kernel, HAL, Settings, HiBy Music or services detects the coax
  adapter. **Inferred**: the cable is passive and the output is on whenever the FPGA runs in mode 1.
- **Which FPGA pin.** Netlist decode of the PCM bitstream: **IOT42B** forwards the data line only in reg0 mode 1;
  DSD forwarding is IOR24A/IOR17B in mode 2. IOT42B is not one of the GPO pins in `hm100-protocol.md`. Inferred from
  the bitstream, not from a schematic.
- **Which USB-C pin.** Unknown. D+/D- belong to the USB PHY, so SBU1/SBU2 or a repurposed CC-adjacent pin are the
  candidates (**guess**). The software gives no hint.

In stock the signal exists whenever the FPGA is powered, in mode 1, with RUN high. STOP leaves RUN high until the
next hw_params, so within a session the pad stays active between tracks. In mode 0 the pad should be quiet
(inferred from the netlist).

## 5. Native DSD in stock

### 5.1 Kernel side (static, `hiby_snd_hw_params`)

- Playback only; `rate` is the hw_params rate (the SEC link has no `be_hw_params_fixup`, so the BE sees the FE
  params); `fmt` is the first set bit of the format mask.
- **fmt != 49 (not DSD_U16_LE):** `first_dsd_play = 1`, `hm100_program_by_hw_param(0)`, re-apply volume if the
  previous stream was DSD and `plat_dsd_compensate != 0`, `output_format = 0`, `pcm_dsd_sel`/IOB35B low,
  `hm100_set_samplerate(rate)`.
- **fmt == 49:** `current_dsd_mode` string "mdsd" -> `hm100_program_by_hw_param(1)` (reload with the DSD
  bitstream), "dsd" -> `hm100_program_by_hw_param(0)`; re-apply volume if the previous stream was PCM;
  `output_format = 1`; **if `first_dsd_play == 0`** (no stream of any kind since boot): `hm100_set_samplerate(44100)`,
  `hm100_start()`, about 1 ms, `hm100_stop()`; IOB35B high; `hm100_set_samplerate(rate << 5)`.
- `hm100_program_by_hw_param(design)` reloads the FPGA only if the design in SRAM differs (JTAG select 0, load,
  select 1, `hm100_enable_init`, about half a second); `hiby_target_poweron` resets the remembered design to 0.
- Settings' "DSD filter" list is `mdsd` ("Darwin Default") / `dsd` ("Darwin 1"), and the live unit's last
  `vendor_func` value was `dsd_mode mdsd`, so **stock's normal DSD path is the separate DSD bitstream**, reloaded
  at every PCM/DSD change. The "dsd" alternative keeps the PCM design and only selects reg0 mode 2. What the DSD
  bitstream does differently is **open** (its netlist was not analysed).
- Rate words (`dsd_i2s_table_hm100`, `hm100-protocol.md`): DSD64 2822400 -> reg0 0x0012, DSD128 5644800 -> 0x000a,
  DSD256 11289600 -> 0x0002, DSD512 22579200 -> 0x00aa. The userspace convention is `rate << 5` of the ALSA rate.
- Volume: `dsd_compensate` adds `5 * plat_dsd_compensate` (0.1 dB units) to the NJW volume on DSD. The `.data`
  default is 6 (+3 dB); the stock init wrote the user value, 0 on the unit.

### 5.2 Machine and q6 path (static)

The FE offers S16_LE, S24_LE, S32_LE, S24_3LE and **DSD_U16_LE**, rates 8000..768000. `msm_pcm_prepare` maps every
format except S32/S24 to a 16-bit ASM stream and declares plain linear PCM at `hiby_fixed_samplerate()` = 384000; the
DSD-specific ASM media format block is called only from the compress-offload driver. The DAI accepts DSD_U16_LE as
16-bit and starts the AFE at 384000, so the AFE is 16-bit stereo at 384000 whatever the real DSD rate (the FPGA is
the I2S clock master, `playback-path.md`). Which ADM topology the stock path used depends on ACDB data that was not
decoded (**open**). Mainline uses NULL topologies on the ASM stream (`ASM_NULL_POPP_TOPOLOGY` 0x10C68) and the COPP
(`NULL_COPP_TOPOLOGY` 0x10312).

### 5.3 HAL side (static)

- `$pcm_open` diverts every card-0 non-mmap open into the HiBy software mixer. Tinyalsa format 5 means DSD; the
  `rate` field is then the DSD bit rate (2822400 / 5644800 / 11289600 / 22579200) and frames are 8 bytes:
  `[L0 R0 L1 R1 L2 R2 L3 R3]`, one byte per channel, oldest first.
- `output_proxy_set_type` opens card 0, device 13 (MultiMedia5), 2 ch, tinyalsa format 5 which maps to ALSA
  DSD_U16_LE (49), rate = `dsd_rate >> 5` (DSD64 = 88200). Eight bytes are two 4-byte DSD_U16 frames, so the true
  frame rate on the wire is 2x the declared one (DSD64: 176400 frames/s, BCLK 5.6448 MHz, the same bit clock as
  `spdif_table` 44.1k).
- **Data transform** (`output_proxy_callback`, DSD branch): for each byte pair `(b0, b1)` it writes
  `out0 = even(b0 & 15) | odd(b1 & 15)` and `out1 = even(b0 >> 4) | odd(b1 >> 4)`, where `even(n)` spreads the 4 bits
  of n to bit positions 0, 2, 4, 6 and `odd(n)` to 1, 3, 5, 7. This is a Morton interleave of the two channel bytes:
  b0 on the even bits, b1 on the odd ones. Tables: odd `00 02 08 0a 20 22 28 2a 80 82 88 8a a0 a2 a8 aa`, even
  `00 01 04 05 10 11 14 15 40 41 44 45 50 51 54 55`. No half-word swap in this branch (unlike PCM and S/PDIF).
  b0/b2 belong to the first (left) channel and b0 is older than b2 (read off the DoP builder in the same function).
- DSD64 over the S/PDIF output is DoP (marker byte alternating 0x05/0xFA); DSD128 and above reached the stock
  captures only as PCM converted by the player engine.

## 6. The coax stream format (encoder contract)

What the data on the I2S line must be for the FPGA to put valid S/PDIF on its pad in reg0 mode 1. Read from the
stock HAL (`spdif_core_process_data`, the nibble table built by `spdif_core_init`, the preamble bytes, and
`output_proxy_callback`'s half swap) and cross-checked: a transliteration of the HAL code and an encoder written
from the IEC 60958 spec agree bit for bit on random input across odd chunk sizes and block boundaries. The FPGA
adds nothing: **the stream carries biphase-mark cells, 128 x fs of them per second**.

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

How the words travel: the FE is S32 on a DAI with `qcom,s32-as-s16-pairs`, so the q6asm-dai ack hook rotates each
sample by 16 in place (`ror32(w, 16)`, the HAL's own half swap) and the DSP sees 16-bit stereo, high half first. The
ASM, ADM and AFE run 16-bit stereo at the fixed 384000 (NULL topologies); the FPGA clocks I2S with BCLK = 128 x fs,
16-bit slots, MSB first, and forwards the data line to its S/PDIF pin. The declared FE rate equals the true FE frame
rate. (Stock declared fs while writing 4 S16 frames per audio frame, 4x off, which only worked because tinyalsa wrote
blocking.)

Test vectors (S32 samples as the encoder writes them, stream start, previous level 0):

```
silence:            f0: e8cccccc cccccccc e4cccccc cccccccc   f1: e2cccccc cccccccc e4cccccc cccccccc
L = 0x123456,       f0: e8d4b4cb 532cb332 e4aaaaaa aaaaaacc
R = -1 (24 bit)     f1: e2d4b4cb 532cb332 e4aaaaaa aaaaaacc
```

DoP is the encoder's business: DSD64 = DoP at fs 176400 (FE 352800), DSD128 = fs 352800 (FE 705600), as stock
(`(dsd >> 5) << 1`). There is no DoP DSD256, since `spdif_table` has no 705.6k entry.

## 7. Mainline design

### 7.1 Targets and the resolved target

Targets are stock's: OFF (T_NONE), LO 1, PO 2, BAL 3, **Spdif 4**, BAL-LO 7. `hm100_resolved()` is the `Output`
control if set, else the plugged jack, else **Spdif (nothing plugged in)**, as stock. Every stream therefore gets a
real target in hw_params and the FPGA, which is the I2S clock provider, always runs for an open stream. The former
"clocks only" target (T_CLK) is gone for that reason.

Each stream carries one flag, `spdif` (stock `spdif_enabled`), latched in `hm100_startup` from the resolved target:
what the stream **contains**. The target is where it **goes**.

Power chains are stock's (section 2.3); power-off drops the rails before the FPGA. No mute or unmute work for Spdif.
`hm100_enable_init` writes the 0x0120 init frame on every power-up, Spdif included.

reg0 per stream (`stream_word`):

| stream | reg0 |
|---|---|
| `spdif` latched, linear FE format, `rate x frame bytes / 16` in `spdif_table` | the `spdif_table` word (mode 1), e.g. S32 at 88200 -> fs 44100 -> 0x0011 |
| `spdif` latched, no table entry (a plain stream at 44.1k/48k, or S16 below 176.4k) | the PCM word of the FE rate (mode 0): clocks at the stream's own rate, S/PDIF pin quiet. Stock would run off the table to 0x0229, many times too fast |
| not latched | the PCM word of the FE rate |
| native DSD FE format | never a `spdif_table` word; `fe_frame_bytes` returns 0 for DSD formats |

The kernel takes a stream as S/PDIF cells exactly when it got a `spdif_table` word. The word follows the **stream**,
not the target, as in stock. This is what makes the switches below safe.

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

### 7.2 Userspace interface

- `Output`: `Auto, Lineout, Headset, Balance, BalanceLo, Spdif` (Spdif appended, so saved indices keep their
  meaning). Stock's enum also has `Coax` (5) and `Iis` (6); no code path exists for them.
- `Output Target` (read-only, volatile, the same names without Auto): `hm100_resolved()`, the target a stream opened
  now runs on. It reads Spdif through an idle power-off. A value event follows every switch (jack change in Auto,
  Output change).
- Rule for encoders and UCM: read `Output Target` before opening; on an event, close and reopen (Spdif: through the
  encoder, S32_LE at 2 x fs; anything else: plain PCM). The kernel keeps the wrong kind of data off each output during
  the gap, but the new output is silent until the reopen.
- A **plain** S32 stream at 88.2k to 768k opened while the target is Spdif is indistinguishable from encoder output at
  fs = rate / 2: it gets the mode 1 word and puts non-BMC words on the coax pin. Receivers find no preambles and stay
  unlocked. This is why userspace must read the control first.
- Boot window: the first debounced jack result lands about 1 s after probe. With a jack plugged at boot,
  `Output Target` reads Spdif until then, and a stream opened in that window latches `spdif` and stays muted on the
  jack's output after the switch. The event that follows is real; the reopen it triggers fixes it.

## 8. Native DSD in mainline

### 8.1 Format: DSD_U32_LE and DSD_U32_BE at DSD rate / 32

| DSD | FE rate (frames/s) | reg0 | BCLK | 16-bit stereo frames/s at the AFE |
|---|---|---|---|---|
| DSD64 | 88200 | 0x0012 | 5.6448 MHz | 176400 |
| DSD128 | 176400 | 0x000a | 11.2896 MHz | 352800 |
| DSD256 | 352800 | 0x0002 | 22.5792 MHz | 705600 |
| DSD512 | 705600 | 0x00aa | 45.1584 MHz | 1411200 (not verified) |

Stereo only, offered only on a `qcom,s32-as-s16-pairs` FE (the RS6's MultiMedia1) that also has `qcom,fixed-rate`;
no new DT property. Why not stock's DSD_U16_LE at DSD/32: PipeWire counts DSD rates in bytes per channel per second
with a floor of 352800 (DSD64), so stock's tuple (88200 x 2 bytes) is below its floor and would never play DSD64;
MPD tries DSD_U8, then host-endian DSD_U32, then DSD_U16. DSD_U8 is not offered (its rates exceed the FE's 768000).
A DSD_U32 stereo frame is 8 bytes, the HAL's frame, and the declared rate equals the true FE frame rate. With both
U32 variants neither player converts endianness.

### 8.2 Data path

1. The player writes DSD_U32 frames at DSD/32 into MultiMedia1.
2. `q6asm_dai_ack` converts each period in place, before it is queued: per frame, the L and R 32-bit words (MSB =
   oldest bit, so byte 3 is the oldest), then four 16-bit words, oldest bytes first, each `even(L byte) | odd(R byte)`.
   On the wire (MSB first) a word is `R7 L7 R6 L6 ... R0 L0`. DSD silence (0x69) becomes 0x3cc3. This is exactly what
   the stock HAL sent. An offline check ran the HAL's table code and the kernel function on 4800 random frames, for
   both U32 byte orders: byte-identical.
3. ASM: linear PCM, 16 bit, 2 ch, `ASM_NULL_POPP_TOPOLOGY`, media format at the fixed 384000. `q6asm_dai_hw_params`
   refuses DSD on an FE without `qcom,fixed-rate`, since the DSP would resample.
4. ADM: `NULL_COPP_TOPOLOGY`, opened at the BE rate after `sm8250_be_hw_params_fixup` (384000, S16, 2 ch).
5. AFE SEC_MI2S_RX: 16 bit, 384000 nominal, external BCLK and WS from the FPGA.
6. hm100 (`hm100_hw_params` -> `hm100_stream_setup`): FE format via `fe_format()`, DSD rate = FE rate x 32, which
   must give a mode-2 word or the stream is refused. Then, as stock: design for `DSD Mode`, volume update if the stream
   kind changed and `DSD Compensate` is not 0, the first-DSD kick if no stream has played since the module loaded
   (reg0 0x0120, RUN high, 1 ms, RUN low), IOB35B high, RUN low, reg0 = DSD word. START raises RUN as for PCM.

The channel assignment (b0 = left, oldest bit in bit 7) was **inferred** from the HAL; a left-only clip played on the
unit confirmed the channel order, so the kernel sends what stock sent and the order is right.

### 8.3 hm100 state

- Controls: `DSD Mode` (`mdsd`, `dsd`; default `mdsd`, as the stock Settings wrote at boot) and `DSD Compensate`
  (-254..254, default 6, stock's `.data` value, +3 dB on DSD). Both apply from the next stream or volume write.
  `mdsd` loads `hiby/rs6/hm100-dsd.bin` (`hm100-dsd-gw1n9c.bin` for the GW1N-9C part, picked by IDCODE; extract
  with `tools/extract-hm100-blobs.py`); `dsd` keeps the PCM design and selects mode 2.
- `hm100_program_design()` is stock's `hm100_program_by_hw_param`: it reloads only when the other design is in SRAM.
  A failed load fails the stream and marks the design unknown (stock ignored the error).
- Every PCM stream goes back through the same helper: PCM design, IOB35B low, `stream_word()`.
- An output switch under an open DSD stream brings the DSD design back before RUN goes high.
- A DSD stream on Spdif (nothing plugged in): mode 2, analog side down, S/PDIF pin quiet.
- With the default `DSD Compensate` of 6 a DSD stream plays 3 dB louder than PCM at the same wheel level; the stock unit's own setting was 0.

### 8.4 Bit-exactness through the DSP

Stock DSD went through the plain linear-PCM ASM/ADM/AFE path with no DSD flag anywhere. Mainline does the same with
less in the way: ASM, COPP and AFE all at 384000 (no rate conversion), 16 bit throughout (no width conversion), NULL
topologies (no soft volume, EQ or dither; mainline sends no ACDB calibration), 2 in and 2 out at unity. Any gain,
dither or requantization in the DSP would flip the newest bits of every word and turn DSD into loud broadband noise.
DSD64, DSD128 and DSD256 were verified by ear on the unit, which is consistent with unchanged words (**inferred**; no
pattern capture at the I2S pins was made). DSD256 means a true 705.6k frames/s against a declared 384000 AFE rate;
DSD512 (1.41M) and PCM 768k (1.536M) are the same order or higher and are not verified.

## 9. Review fixes (kernel, not tested on their own)

Behaviour of `hiby-hm100.c` and `q6asm-dai.c` after the audio review. None of this is recorded as verified on the
unit.

- **DSD pause, suspend and start.** On PAUSE_PUSH and SUSPEND the AFE port, still clocked, sends 0x0000 words, and at
  START, RESUME and PAUSE_RELEASE it does until the stream's data arrives. For PCM that is the zero level. For DSD
  every bit 0 is the most negative level (DSD silence is 0x69, 0x3cc3 interleaved): a DC step at the output. Stock
  never hit this because its HAL stopped streams and never paused them (its trigger ignores PAUSE_PUSH and SUSPEND).
  Now DSD is muted on PAUSE_PUSH, SUSPEND and STOP (PCM keeps stock's behaviour), and its unmute waits
  `dsd_unmute_ms` (module parameter, default 50, writable at runtime) from the latest START, RESUME or
  PAUSE_RELEASE. 50 ms is a margin; the ASM-to-AFE start latency was never measured. The mute work runs on the
  high-priority workqueue because it races the DSP draining the last words. The mute and unmute works no longer
  cancel each other, and a DSD mute queues the unmute again itself, so an unmute always lands after the mute, at any
  `dsd_unmute_ms` including 0. Residual: on an xrun the mute must land within the tail still held by ADM and AFE,
  or a DC pulse of a few ms reaches the output.
- **Design reload (PCM <-> DSD) is muted first.** The reload takes about 0.6 s with the rails, the NJW and the amps
  powered, and the FPGA pins carrying iv_mute, hp_mute, po_amp_en, bal_amp_en and lpf_pwr_en are unconfigured
  meanwhile. Before the JTAG select goes low the driver now mutes synchronously, asserts the SoC-side LO and BAL-LO
  mutes (TLMM61 `lpf_mute`, TLMM76 `line_mute`; the only mutes that hold while the FPGA has no design) and waits
  10 ms. The output opens only in the unmute work of a started stream. Gowin's GW1N schematic manual (UG284) says all
  GPIOs are high-impedance with weak pull-ups during configuration, so the mute pins should float high (muted) and
  the amp enables float enabled; an external pull-down on the board would change that (board side unknown).
- **`fe_frame_bytes`** returned 8 for DSD_U32 stereo (ALSA counts the DSD formats as linear). It now returns 0 for
  DSD explicitly (`fe_is_dsd()`).
- **Rates are negotiated in q6asm-dai.** On the RS6 FE, DSD is offered only at 88200, 176400, 352800 and 705600, and
  PCM only at the DAC's rates (44.1, 48, 88.2, 96, 176.4, 192, 352.8, 384, 705.6, 768 kHz); other rates go through
  plughw resampling. The matching rate checks in hm100 are now debug-level.
- **A failed FPGA load leaves the target off** and fails the stream (before, the target was marked on and every
  later hw_params retried up to three times with 1 s power cycles). While the failure stands, hw_params fail at once
  with -EIO; the next stream open clears it and retries once.

## 10. Userspace: the rs6-spdif package

Package `device/testing/rs6-spdif` (postmarketOS, `pmos` branch), built with meson, MIT. It installs two ALSA
plugins and `50-rs6-spdif.conf` into `alsa.conf.d`.

**`rs6_spdif` (PCM plugin).** Applications open it at the audio rate fs: S16_LE, S24_LE or S32_LE, stereo, any
access type, fs one of the eight rates of section 6. It opens the card's playback PCM at S32_LE, 2 channels, 2 x fs
(period 960 frames = 480 audio frames, 8 periods) and writes four BMC words per audio frame (`iec958.c`, the
contract of section 6). No resampling, dither or volume; S32 input loses bits 7:0.
- Because the kernel latches the S/PDIF flag at open, the plugin opens the card PCM only while `Output Target`
  reads Spdif, re-reads it after the open, and closes the card PCM as soon as the target changes.
- While **detached** (target elsewhere, or the device busy) it keeps time on CLOCK_MONOTONIC, discards the data and
  retries every 100 ms, so neither `aplay` nor PipeWire sees an error. The card PCM is opened at the first data,
  not when an application only probes the configuration.
- Config: `card` (default `HiByRS6`), `device`, `slave`, `ctl`, and `channel_status`: `consumer` (default; ALSA's
  IEC958 default block with the IEC 60958-3 sampling-frequency and word-length codes, including the extension codes
  for 352.8k and 384k) or `stock` (V = U = C = 0, like the stock HAL).

**`rs6_jack` (control plugin).** Two read-only boolean controls derived from `Output Target`: `SPDIF Jack` on while
the target is Spdif, `DAC Jack` on for anything else. UCM points `JackCTL` of both devices at them, so PipeWire
treats the two sinks like a headphone jack pair: it offers the one that can play and makes it the default. Every
`Output Target` event becomes a value event on both controls.

**Tests** (`meson test`): the encoder against the section 6 vectors, against the HAL transliteration and against a
spec encoder (Python), the plugin end to end through alsa-lib, and a target test that needs a sound card.

### UCM (`device-hiby-rs6`, `ucm-HiFi.conf`, `ucm-card.conf`)

- The card file's `FixedBootSequence` sets `SEC_MI2S_RX Audio Mixer MultiMedia1`, the card's only route. The verb
  does not switch it off again (that made PCM opens outside the verb fail with "no backend DAIs enabled").
- Two devices on the one playback PCM, one usable at a time:
  - `Headphones` (priority 200): `hw:${CardId},0`, mixer element `Headphone`, jack `DAC Jack`.
  - `SPDIF` (priority 100): `rs6_spdif:${CardId}`, jack `SPDIF Jack`, no hardware volume (the analog side is off).
    UCM resolves PCMs in its own ALSA configuration, so the profile declares the `rs6_spdif` PCM in
    `LibraryConfig`; `rs6_jack` comes from the system configuration.
- UCM never sets `Output`, or every profile activation would overwrite the user's choice. `Auto` follows the jacks;
  the DAC page can pin one.

### WirePlumber (`wireplumber-rs6.conf`, `wireplumber-output-handover.lua`)

- `api.alsa.ignore-dB = true` and `api.acp.disable-pro-audio = true` on the card. The only hardware volume is the
  NJW1195A's 100 steps; with a dB scale ACP would apply the remainder in software to every sample.
- `api.alsa.headroom = 1024` on the coax sink (matched by `~.*rs6_spdif:.*`): the card PCM behind it moves its
  position once per 960-frame period and the plugin cannot flag itself as a batch device. The coax sink is
  bit-perfect at 100 % volume; below that PipeWire scales in software.
- `output-handover.lua`: the two sinks share the card PCM. When a jack change moves the target, the `rs6_jack`
  controls mark the old sink's route unavailable; the script suspends a sink of this card at once when it goes idle
  with no available route, instead of after the 5 s idle suspend that would block the new sink. (The coax sink
  releases the PCM itself the moment the target moves.)

## 11. How to check

Card id `HiByRS6` (see `aplay -l`).

**Target and coax.** With nothing plugged in and `Output` = Auto, `amixer -c HiByRS6 cget name='Output Target'` reads
Spdif. `aplay -D rs6_spdif:HiByRS6 file.wav` (any of the eight rates) logs "target 4 on" and advances the card PCM's
position at 2 x fs; a coax DAC or S/PDIF analyzer on the cable checks lock, rate and bit-exactness. Plug headphones
during coax playback: no burst, the analog output stays muted until the stream reopens.

**Native DSD** (headphones plugged in first: with nothing plugged in the stream goes to Spdif and is silent).
- While playing, `/proc/asound/card*/pcm0p/sub0/hw_params` shows `format: DSD_U32_LE` (MPD) or `DSD_U32_BE`
  (PipeWire) and `rate: 88200` for DSD64. The first DSD stream after PCM logs the `hm100-dsd.bin` load.
- PipeWire: `pw-cli enum-params <sink node> EnumFormat | grep -i -A2 dsd`, then `pw-dsdplay --target <sink node>
  file.dsf` (`pw-cat --dsd`; nothing else may be playing). MPD: an `alsa` output with `device "hw:CARD=HiByRS6,DEV=0"`,
  `dop "no"`, `mixer_type "none"`, with PipeWire released from the device; volume stays on the DAC's `Headphone`.
- Listen for the right pitch and speed and both channels on the right sides; broadband noise means the words are
  being changed. Repeat with `amixer -c HiByRS6 cset name='DSD Mode' dsd`. Set `DSD Compensate` to 0 before comparing
  levels with PCM.

**Review fixes.** A raw DSD64 silence stream is 0x69 bytes: `python3 -c "import sys;
sys.stdout.buffer.write(b'\x69' * (88200 * 8 * 30))" > dsd64-silence.raw`.
- Pause DC check: force the output (`amixer -c HiByRS6 cset name='Output' Headset`), play with `aplay -i -D
  hw:CARD=HiByRS6,DEV=0 -t raw -f DSD_U32_LE -c 2 -r 88200 dsd64-silence.raw` and read DC volts (tip and ring to
  sleeve) before, during and after a pause (space) and across a suspend: near 0 V throughout. A PCM zero stream is
  the control. Set `Output` back to Auto afterwards.
- Start window: compare a thump at stream start with `dsd_unmute_ms` set to 0 and to 50
  (`/sys/module/snd_soc_hiby_hm100/parameters/dsd_unmute_ms`).
- Design reload: PCM track, DSD file, PCM again, with no thump and no unmute before the stream starts.
- Rate negotiation: `aplay ... -f DSD_U32_LE -r 96000 dsd64-silence.raw` warns "rate is not accurate (requested =
  96000Hz, got = 88200Hz)" and plays, with no "rate not supported" line in `dmesg`.
- Failed load: make the requested design file unavailable and play DSD (the open fails with one "load failed" line),
  then PCM (works).
- Regression: PCM on every output at 44.1k and 48k, idle power-off, suspend while playing.

## 12. Open items

1. The USB-C pin that carries S/PDIF, and the adapter wiring (needs a schematic or a probe).
2. Whether the S/PDIF pad is quiet in modes 0 and 2 (the netlist says the data line reaches IOT42B only in mode 1),
   and whether mode 0 runs with the DAC rails off (stock never ran that).
3. The coax output through `rs6-spdif`: no receiver result is recorded for lock, rates (352.8k and 384k need an
   FE of 705.6k and 768k), bit-exactness, and whether receivers accept the default consumer channel status or need
   the `stock` all-zero one.
4. DSD512 and PCM 768k, and whether the q6 path sustains a true 1.41M / 1.536M frames/s with the AFE declared at
   384000. DSD256 (705.6k) plays on the unit.
5. The review fixes of section 9 on the unit: the ASM-to-AFE start latency behind the 50 ms default, whether the
   high-priority mute beats the DSP drain on xrun, pause and STOP, whether the mute work runs before system suspend,
   and the board-level pulls on the FPGA mute and amp-enable nets during a design load.
6. What the DSD bitstream (`mdsd`) does that the PCM design's mode 2 does not, and which `DSD Mode` the by-ear
   listens used (not recorded).
7. The JTAG-select level after a design load is 1, as stock; no capture shows control writes at that level. The
   first-DSD kick never ran on a pin in the stock captures.
8. The stock ACDB topology for the SEC_MI2S / MultiMedia5 path, and whether the ADM matrix mixer is lossless on
   arbitrary 16-bit words at unity (structurally a copy; a pattern capture at the I2S pins would settle it).
9. `Output Target` reads Spdif for about 1 s after probe when a jack is plugged at boot (section 7.2). Seeding the
   jack state with a synchronous read in probe would close the window.

## Kernel patches

All in the 94-patch series on `main` (`patches/linux/`). `rs6-spdif` is the `pmos` branch package.

| patch | change |
|---|---|
| 0031 | hm100 FPGA DAC driver: load, rate words, power sequencing, jack follow, controls |
| 0032 | q6asm-dai: `qcom,fixed-rate` and `qcom,s32-as-s16-pairs` (S32 as two 16-bit words, high first) |
| 0033 | sm8250: codec-clocked secondary MI2S, AFE fixed at 384 kHz |
| 0060, 0061, 0062 | native DSD_U32_LE/BE on the s32-as-s16-pairs FE: binding, in-place interleave, DT note |
| 0063 | q6asm-dai offers DSD at the DSD rates only (section 9) |
| 0064 | Spdif target; Auto with nothing plugged resolves to it; per-stream `spdif` flag and `spdif_table` words |
| 0065 | read-only `Output Target` control and its events |
| 0066 | a failed FPGA load leaves the target off |
| 0067 | native DSD in hm100: `DSD Mode`, `DSD Compensate`, design reload with mute, first-DSD kick, `fe_is_dsd` |
| 0068 | DSD muted across pause, suspend and restart; `dsd_unmute_ms` |
| 0073 | comment fix for the DSD mute/unmute ordering |
| 0074, 0075 | q6asm-dai offers PCM at the DAC's rates only; the matching hm100 rate check logs at debug level |
