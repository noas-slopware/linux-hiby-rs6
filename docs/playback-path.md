# RS6 playback path: HAL to FPGA, PO first

Source: stock 1.80 **slot B** (running firmware): `vendor_b` HAL `lib64/hw/audio.primary.sdm660.so`
(Ghidra 12.1 with its `.gnu_debugdata` MiniDebugInfo symbols, HAL addresses are ELF vaddrs), slot B
kernel `bootb/Image` (#16; addresses below are #16 kallsyms), `system_b` apps and framework, and the
offline captures taken with `docs/re-tools/run-capture.sh` (the capture files named below, e.g. `play_44100_16.txt`, are not published). No device access for this note.

Tags: **confirmed** = seen in a capture (trace, dmesg, tinymix, getprop), **static** = read from a
binary, **inferred** = reasoned from static facts, not observed, **open** = not settled.

Capture caveats:
- The `out_*`, `play_*` and `set_*` traces of the 1219 capture are byte-identical copies of the auto1 run (38/38 files `cmp` equal).
  There is one set of PO evidence, not two.
- Every `app_*` capture (HiBy Music, 1219 run) ran with `Output Select = Spdif`, because getprop has
  `vendor.audio.hiby.hw.output=spdif`. Its reg0 frames come from `spdif_table`: 0x0009 = 88.2k, 0x0001 = 176.4k,
  0x0201 = 192k. Those captures show the HAL's S/PDIF branch, not PO.
- PO evidence = the auto1 tinyplay runs (kernel path only, HAL bypassed) plus the settings sweep, which
  ran with target PO and has full kernel logs (`traces/set_amp_eneble_0.dmesg`).
- `docs/re-tools/decode-trace.py` drops the **first** control frame of a trace when CS is already low at
  the first event: `out_Lineout.txt` lines 21-71 hold a 0x04b8 frame that is not in the decode. The
  first reg3 frame after a JTAG load also decodes as "18 bits 0x00c10". That is reg3 = 0x010; CS and CLK are
  not idle-high yet when it starts.
- Slot A and slot B sequencing code is the same: call order and immediates match for
  `hiby_snd_*`, `hiby_target_*`, `lrch_volume_imm_set`, `hm100_enable*`, `hm100_program`,
  `hm100_set_samplerate`, `hiby_output_switch` and `output_select_put`. Only the `sa_sound_setting` table moved (see Q5).

## 1. Rate handling, 44.1k family (PO)

| stage | 44.1k track | 48k track | evidence |
|---|---|---|---|
| App to HAL | AudioTrack at the file rate; HiBy Music's engine (`libhibyservice.so`) is an AudioTrack client | same | static |
| HAL stream intake | `$pcm_open` 0x5c410 diverts every card-0 non-mmap open into the HiBy mixer (`hmixer_stream_open`); accepts 32k..768k PCM and DSD64..512 | same | static |
| HAL software resampling | none by default. `PP_resample` exists, driven by `enable_force_rate`/`sample_rate` (`sa_set_fixed_samplerate*` 0x66d50/0x66d98, exported, no caller inside the HAL). **Caveat:** the HAL has an optional DSP unit (off by default, internal target only); with it on, the PCM and reg0 rate may differ from the track. Not documented here | same | static |
| HAL output PCM (DSP unit off) | `output_proxy_set_type` 0x5e560: `pcm_open(card 0, device 13, PCM_OUT, cfg)`. Device 13 is MultiMedia5 (low-latency FE; `audio_platform_info.xml` id 13, `/proc/asound/pcm` "00-13"; the one open hw_params block in the app captures is the 4th of 21 in glob order, which is `pcm13p`). cfg = 2 ch, **rate 44100**, **S16_LE**, period 512 × 8 (`op_pcm_param` 0xe74fc) | rate 48000, period 512 × 8 | static. The branch mapping is confirmed: the app hw_params periods (88.2k: 1024/8192, 176.4k and 192k: 2048/16384) fit only the S/PDIF branch's `rate<<1` table lookup, so `DAT_000fb868 == 1` is S/PDIF, 2 is USB and 0 is the internal DAC |
| HAL sample packing | `output_proxy_callback` 0x5d438: float to int32 with clamp, then `s = s>>16 \| s<<16` and `pcm_write(frames*8 bytes)`. Each 32-bit sample goes out as two 16-bit words, high then low, so one audio frame = **two** S16 stereo PCM frames | same | static |
| `SEC_MI2S_RX SampleRate` / `Format` | never set by the HAL: the strings are absent, and the backend cfg names `INT0_MI2S_RX`. They stay at the boot default KHZ_48 / S16_LE (tinymix lines 2942/2950 in both static dumps) | same | confirmed |
| what those enums do | only feed `msm_mi2s_set_sclk` 0xffffff8008ce30b8 (rate × 2 × 16 = 1.536 MHz), which programs the **EBIT** clock id, see clocking | same | static + confirmed |
| `hiby_snd_hw_params` 0xffffff8008cf3fd4 | rate 44100, format 2 (S16_LE). The SEC_MI2S BE has no fixup, so the FE params pass through | 48000 | confirmed: `set_amp_eneble_0.dmesg` lines 19-26 "inner_hw_params format:2 samplerate:44100" |
| hm100 reg0 | `hm100_stop` (gpio12=0), frame **0x0120** | **0x0320** | confirmed: `play_44100_16.txt` line 72 (gpio12=0), dmesg "samplerate:44100 0x0120"; `play_48000_16` same lines |
| FPGA clock family | bit 9 = 0: **45.1584 MHz** | bit 9 = 1: **49.152 MHz** | static meaning of f0, values confirmed |
| q6 ASM/ADM/AFE | all forced to 384000 (`hiby_fixed_samplerate` 0xffffff8008ce9f5c), so the ADSP sees one rate end to end and never converts | same | confirmed: dmesg "bit_width = 16 ... ws_src = 0x0 sample_rate = 384000", "afe_get_cal_hw_delay: Unable to find delay for sample rate 384000" |

**Clocking: the SoC is the I2S slave, and the FPGA is the clock master.**
- Confirmed: the AFE I2S config goes out with `ws_src = 0x0` (external).
- Static:
  - `msm_dai_q6_mi2s_set_fmt` 0xffffff8008c73b80 only sets that value for `CBM_CFM`.
  - The SEC link uses the global `msm_mi2s_snd_startup` 0xffffff8008ce7ac8. It picks CBM_CFM plus the
    **EBIT** clock id when `mi2s_intf_conf[1].msm_is_mi2s_master == 0`.
  - The DT still says master: `qcom,msm-mi2s-master = <1 1 1 1>`, in dtb96 of both slots (the slot B appended DTB #96 is identical).
    But `msm_asoc_machine_probe` 0xffffff8008ce6440 overwrites all four flags with 0 right after parsing
    them (`str wzr` at 0xffffff8008ce6858..64, before "qcom,audio-routing"). Slot A has the same code at
    0xffffff8008ce6598. This is a HiBy patch.
- So the FPGA drives BCLK and WS from its 45.1584 / 49.152 MHz crystals.
- That is how 44.1k works over a "384 kHz" port: 384000 is a dummy rate that keeps the ADSP from
  resampling, and the real frame rate is whatever reg0 selects.
- sa-sound.md's "SoC is bit/frame clock master" is wrong for the running firmware.
- **Inferred wire format:** 16-bit slots, words L_hi, L_lo, R_hi, R_lo over two WS periods,
  BCLK = 64 × Fs (2.8224 MHz at 44.1k; 49.152 MHz at 768k, which equals the crystal and so explains the 768k cap).
  Not observed on the wire. The tinyplay runs fed plain 16-bit silence, so they prove nothing about the audio content.

## 2. PO sequence (power-on, select, play, stop, power-off)

GPO bits in reg1 (shadow `hm100_gpio_group0_val`): 2 IOB27B bal_amp_en, 3 IOB29A po_amp_en,
4 IOB29B hp_mute, 5 IOB35A iv_mute, 6 IOB35B pcm_dsd_sel, 7 IOB39A lpf_pwr_en. `hm100_set_gpo`
0xffffff8008cf00b0 rewrites the whole reg1 every call, even when nothing changed (static; trace shows the repeat frames).
Every reg1 write is a 16-bit control frame on gpio 8/10/11. TLMM 13 = 1 only around NJW1195A words.

**gpio44 (jtag-select):** traced only as `set 0`: 10 events, one per bitstream load, and never `set 1`.
Idle debugfs shows `out 0`. Every control and NJW write in every trace happens with **gpio44 = 0** (confirmed).
`hm100_program` leaves it at 0. Only the DSD `hm100_program_by_hw_param` path sets 1 after a load.

### Power-on PO: `Output Select` = Headset, `hiby_target_poweron(2)` 0xffffff8008cf3a04
Static (slot B, same as the slot A table in sa-sound.md). PO power-on was never traced. The shared steps are
confirmed in `out_Balance.txt` (BAL power-on, same chain), with the measured gaps in the right column.

| # | action | pins / frames | BAL trace check |
|---|---|---|---|
| 1 | `hiby_po_mute(1)` | TLMM61=0, then reg1 \|= IOB29B (0x030 from 0x020) | 61=0 then 0x0430 at +80 us |
| 2 | `hiby_dac_power(1)` | TLMM28=1, 10 ms, TLMM40=1 | 10.0 ms |
| 3 | `hm100_enable` | TLMM55=1, 50 ms, TLMM44=0, JTAG IDCODE/USERCODE, SRAM load over blsp_spi3 (444672 B, ~464 ms), then `hm100_enable_init`: reg3 0x000 (0x010 with NOS), reg1 shadow, reg2 0x000, gpio12=0, reg0 rate, gpio12=1, reg3 \|= 0x002, 2 ms, reg3 &= ~0x002, module 2 ← filter 0 ×2 (0x4002, 0x4400, 1024 × 0x48xx, 0x4c00), gpio12=0 | 50.0 ms; load 0.46 s; init ~140 ms. The coef bytes equal `hm100_fir_coef_default` filter 0 (big-endian words), sent twice: confirmed |
| 4 | 10 ms; `hiby_lpf_power(1)` | reg1 \|= IOB39A (0x0b0) | confirmed |
| 5 | 10 ms; `hiby_lpf_sel(1)` | TLMM34=1 | confirmed |
| 6 | **10 ms** (BAL: 50 ms); `hiby_volume_power(1)` | TLMM15=1 | BAL 50 ms |
| 7 | `hiby_po_amp_power(1)` | pm660 GPIO13 (global 1023, `hiby,po_pwr_en`)=1, 10 ms, reg1 \|= IOB29A (0x0b8) | 10.1 ms |
| 8 | 10 ms; `hiby_bal_po_amp_power(0)` | reg1 IOB27B=0 (0x0b8 rewritten) | BAL sets 1 instead (0x0bc), then waits 50 ms |
| 9 | 10 ms; `lrch_volume_imm_set(2, L, R, 1)` | TLMM13=1, NJW `cL<<8\|0x00`, `cL<<8\|0x10`, `cR<<8\|0x20`, `cR<<8\|0x30`, TLMM13=0 | confirmed (0x8e00..0x8e30) |
| 10 | NJW input select | TLMM13=1, **0x2840, 0x0050**, TLMM13=0 (BAL: 0x2840, 0x2850) | BAL words confirmed |
| 11 | `hiby_headphone_balance_select("headphone")` | TLMM29=0 | BAL sets 29=1 |
| 12 | `current_target_on = 2`, unmute pending | | |

### Play: hw_params, then trigger START (confirmed, `play_44100_16.txt`, `set_amp_eneble_0.dmesg`)
1. startup: EBIT clock "rate 1411200" (here the sweep had set KHZ_44P1), `hiby_snd_startup`: `hm100_set_spdif_mode disable`.
2. hw_params: `hm100_program_by_hw_param(0)` (no-op while the PCM design is loaded), reg1 IOB35B=0 (0x0b8 frame, raw lines 21-71, missed by the decoder), `hm100_stop` gpio12=0 (line 72), reg0 0x0120.
3. prepare: AFE port start at 384000.
4. START (~33 ms later in the trace): gpio12=1 (line 124), then `unmute_work`: IOB35A=0 → reg1 0x098, `po_mute(0)`: IOB29B=0 → reg1 **0x088**, TLMM61=0 (line 227). PO steady state: reg1 = 0x088 (po_amp_en + lpf_pwr_en).

### Stop: trigger STOP (confirmed, `play_44100_16` at 2343264.748)
`mute_work`: IOB35A=1 → 0x0a8, then `po_mute(1)`: TLMM61=0, IOB29B=1 → 0x0b8. gpio12 **stays high**
until the next hw_params. A rate change therefore always runs muted: stream close → STOP mute → hw_params (stop, reg0) → START → unmute.

### Power-off PO: `hiby_target_poweroff(2)` 0xffffff8008cf3818 (confirmed, `out_Lineout.txt` raw lines 20-282)
TLMM61=0 (l.20), reg1 0x0b8 IOB29B=1 (l.21-71), 10 ms, reg1 0x0b8 IOB27B=0 (l.73-122), pm660 GPIO13=0 (l.123),
10 ms, reg1 0x0b0 IOB29A=0, TLMM15=0 (l.175), TLMM34=0 (l.176), reg1 0x030 IOB39A=0, TLMM55=0 (l.228),
TLMM28=0 (l.229), 10 ms, TLMM40=0 (l.230), reg1 0x020 IOB29B=0, TLMM61=0 (l.282).
Every output switch power-cycles the FPGA and reloads it (`hm100_disable`).

## 3. Deltas for the other outputs (static, confirmed in out_* traces)

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

TLMM61 (lpf_mute) never goes high on PO/BAL. TLMM76 (line_mute) is high in LO and low in BAL-LO,
so it looks like the LO / BAL-LO selector (inferred). `Iis`, `Coax` and `None` keep the old target and
power it off 5 s later through `switch_work` (confirmed: `out_Iis.txt`, 4.6 s after play).

## 4. Volume

- HAL: `adev_set_master_volume` 0x242f8 sets level = (int)(v × 100 + 0.5), clamped to 0..100, writes
  **Plat Left**, then **Plat Right** (static). That is the only writer. The caller is AudioFlinger master volume
  (inferred: services.vdex has 19 MasterVolume strings, and HiBy Music sets no Plat control directly).
- Kernel: `hiby_lch_vol_put` 0xffffff8008cf3ca4 only stores `left_level`. `hiby_rch_vol_put` 0xffffff8008cf3ccc
  stores `right_level` and calls `lrch_volume_imm_set(current_target_on, L, R, 0)`, which queues
  `volume_work`: one level step per jiffy (10 ms) until it reaches the target, with each step written to the NJW.
- Boot defaults (.data): `left_level = right_level = 90`, `plat_dsd_compensate = 6`; `plat_pregain` and
  `plat_vol_gain` start at 0 in bss until the init rc writes the properties.
- **Readback is fake:** both Plat controls use `plat_dummy_get` 0xffffff8008ce8040 (`return 0`), so tinymix always
  shows 0. A script that saves and restores them, like `device.sh vol()`, writes volume 0 (static).
- Code: `x = njw1195a_volume_db[level] + pregain + 5×gain(-24/-12/0) [+ 5×dsd_compensate on DSD] ± 5×lrbalance`,
  clamp to [-955, 315], `code = 255 - (x + 955)/5` (0.5 dB/step, 255 = floor). Words: `code<<8 | 0x00/0x10` (L),
  `|0x20/0x30` (R). Example: level 90 with gain middle gives x = -110, code 0x56. The traced 0x8e = level 39 + middle
  (confirmed words, `out_Balance`).
- LO and BAL-LO have no NJW volume: `lrch_volume_imm_set` returns for targets 1 and 7.
- Mute around rate changes: see §2. The HAL's `hal_primary_output_mute` (DSD streams only, before
  `pcm_close`) sets a **"Mute Output"** control that the kernel does not have; the string is not in `Image`.
  It is a no-op (static).

## 5. sa_sound_setting at boot and playback start

Nothing in the kernel or the HAL writes these attrs. The only writer is init: `vendor/etc/init/hw/init.hiby.audio.rc`
turns `vendor.audio.hiby.hw.*` property changes into sysfs writes. Settings and `services.vdex` set the
properties when they restore user settings at boot, and when the user changes them (static; boot timing inferred).
Playback start writes no attr.

Slot B table (`setting_function` 0xffffff800a3041a8; #16 inserts `mute_enable` at slot 3, so slot A
numbers from 3 on are off by one):

| attr | slot → handler | written by stock (prop, live value) | hardware effect |
|---|---|---|---|
| lrbalance | 0 `plat_set_lrbalance` | yes, 0 | ±0.5 dB per unit on one side |
| pregain | 1 `plat_set_pregain` | rc trigger exists; prop unset on this unit | volume offset in 0.1 dB |
| gain | 2 `plat_set_gain` | yes, middle | -12 / -6 / 0 dB on PO/BAL |
| mute_enable (new) | 3 NULL | no | none, stores the string |
| lo_gain | 4 stub | no rc trigger (prop `vendor.audio.hw.lo_gain=high`); the `high` read back is the probe default (`sa_sound_setting_probe` strcpys gain "low", lo_gain "high", bal_po_lo "bal_po", timbre "monitor") | none |
| digital_filter | 5 `plat_set_digital_filter` | yes, sharp_roll_off | module 2 ← built-in filter 0..3, lost at next power-up |
| dsd_digital_filter, timbre, bal_po_lo_switch, mqa_source, turbo | 6, 7, 9, 10, 11 stubs | timbre/bal_po_lo/turbo yes; mqa_source "no" at every boot (`on boot` sets both mqa props to no) | none |
| dsd_compensate | 8 `plat_set_dsd_compensate` | yes, 0 | +0.5 dB per unit on DSD |
| power_p_pplus, balpo_po_a_ab, balpo_po_t_n, digital_output_type, **amp_eneble** | 12-16 NULL | **no** (props exist: power_p, zoom_ab, transistor_t; no rc trigger) | none |
| vendor_func | 17 `plat_set_vendor_func` | yes, last value `dsd_mode mdsd`; Settings also sends `nos_enable on/off`, `filter_path <f>` | NOS (reg3 bit 4), .flt to module 2, DSD bitstream choice |
| dac_type | none / get slot 19 NULL | **no**; `init.qcom.sh` only reads it into `ro.vendor.hiby.dac_type` (empty) | none, see below |
| dsd_filter, lo_output_select, play_next, led_work_state, on_boot_completed | 20-24 NULL | no | none |

So on the RS6, `amp_eneble`, `balpo_po_a_ab` (Class A/AB) and `power_p_pplus` do nothing in hardware,
and the RS6 stock image never writes them. They are leftovers from other HiBy models: the RS6 kernel
and DT are built on the shared HiBy SDM660 BSP, which still carries `r8-sound-plat`,
`r8_gpio_sound_switch`, `r8_gpio_switch` and `n9-*` pinctrl groups (`dtb96.dts` L10316-L10479).
The RS6's own `hiby,sound-plat` node points at the `r8-sound-plat` group (gpio29/40/55/76), so the R8
naming is the BSP's, not a sign that R8 code paths are live here.
The attrs match other SDM660 Android 9 DAPs: Turbo is the HiBy R8's mode (store.hiby.com R8 page), and
Class A/AB (`balpo_po_a_ab`), P/P+ (`power_p_pplus`) and Transistor/Nutube timbre (`balpo_po_t_n`) are the
Cayin N8ii's switches (en.cayin.cn N8ii features page; HiFi Oasis lists it as Snapdragon 660 + Android 9).
The `n9-*` groups are probably a Cayin codename; no public "Cayin N9" product turned up. The sweep traces
for them show only unrelated stream start/stop frames, hundreds of ms after the write (confirmed).
Live hm100 state before the RE: `osr_bypass = 1`, NOS on (user setting), so every traced reg3 carries bit 4.

## Dangerous attrs

- **`dac_type` (both slots): the store returns 0.** `set_dac_type_function` (#15 0xffffff8008cf0f68,
  #16 0xffffff8008cf1228) does `printk("%s %s\n", __func__, buf); return 0;` with no other effect and no valid
  values. A sysfs store that returns 0 makes `write(2)` return 0 for a non-empty buffer. mksh's `echo`
  (Android root shell) retries short writes in a loop, so `echo 0 > dac_type` spins forever, and every spin
  prints a line on `console=ttyHSL0,115200` (cmdline), with tracing on as well in the sweep.
  - The handler itself is static.
  - The endless loop, the console flood, and through them the stall and blank display are inferred.
    The sweep log stops right after "== dac_type".
  - The show handler calls `setting_function[18]` (#15) or `[19]` (#16). Both are NULL, so a read returns 0 bytes,
    which is why the value read back empty.
  - Nothing in stock writes it. **Never write it**: any write from a shell hangs it.
- **Unbounded `strcpy` in every string store.** `set_mute_enable`, `set_on_boot_completed`,
  `set_play_next_value`, `set_*_filter`, `set_gain`, `set_turbo` and the rest copy `buf` with `strcpy`.
  - The destinations are 16-byte bss buffers (32 B for the two filter names; `mqa_source_str` has 4 B).
  - The ones that accept any string (`mute_enable`, `on_boot_completed`, `play_next`) accept anything up to PAGE_SIZE-1 (4095 bytes). So do
    the prefix-checked ones (`on…`, `yes…`) once the prefix matches.
  - About 336 bytes from `mute_str`, or 32 from `turbo_str`, overwrite the `g_sound_platform` pointer
    (0xffffff800a695ca8). The next audio operation then oopses (static layout; crash inferred).
  - Even `echo yes > mqa_source` writes "yes\n\0" (5 bytes) into a 4-byte buffer and clobbers a byte of `pregain`.
  - Keep writes short. Never write these from untrusted input.
- **FPGA flash:** `erase_flash`, `load_flash`, `write_back` (see hm100-protocol.md). `load_flash 0` replaces
  the live R2R calibration with ideal weights.
- **`firmware_load <file>`** overwrites `FS_data` in RAM. The next output switch programs whatever was
  loaded, which can leave the DAC dead until reboot (static).
- **`coef_input`** writes module 0 live: it corrupts calibration until the next power-up. **`sar_bypass 1`**
  turns off the R2R correction.
- **`input_select` ≠ 0** moves the FPGA input away from I2S: silence. **`power_down 1`** powers down the FPGA core until the next output power-on.
- **`calib_process start`** and **`mute_port <out> 0`** unmute the amps outside the stream: pops.
- **`Output Select`** (mixer): every change power-cycles and reloads the FPGA and the amps (pop risk).
  None, Coax and Iis cut power 5 s later.
- Harmless: `filter_path` (returns 1024 on success, errno on failure); `delay_val` (no effect); the store
  of every other attr returns `count` (all checked in #16).

## Who writes what outside the HAL (Q7)

Nobody writes sysfs or runs tinymix directly. Searched every partition, the HiByMusic dex and native libs, and
Settings/services:
- HiBy Music (`classes*.dex`, `libhibyservice.so`) plays through AudioTrack and reads and sets
  `vendor.audio.hiby.hw.*` properties (digital_output_type, iisspdif, lrbalance, play_next). Its only `/sys` reads are cpufreq/thermal/net.
- Settings and `services.vdex` set `vendor.audio.hiby.hw.*`, `vendor.audio.hw.vendor_func` and `vendor.audio.hiby.hw.darwin.filter_path`.
  init (`init.hiby.audio.rc`) turns the first two into sysfs writes. The HAL reads `darwin.filter_path` at
  PCM open and hands it to its own DSP unit (`hmixer_get_dsp_hdr()->set("darwin_filter_path")`); no sysfs write was found (static).
- `audiomonitor` (root, started from that rc) only touches `vendor.audio.hiby.hw.audio_stop_timeout`
  and `sample_quality`.
- The HAL sets mixer controls: `Output Select`, `SEC_MI2S_RX Channels`, the MultiMedia5 routing (mixer_paths
  `headphones`/`balance`/`line`/`balancelo`/`spdif`/`iis` and `low-latency-playback`), `Plat Left/Right`, and the
  nonexistent `Mute Output`. It also sets `vendor.audio.hiby.hw.sample_rate` / `sample_quality`, which drive the LED rc.

## Minimal sequence for our driver (PO, 44.1k and 48k family PCM)

Clocking and data path:
1. Make the SoC MI2S (SEC, gpio24-27) the **clock consumer**: codec is bitclock and frame master, q6afe EBIT, AFE `ws_src` external. Confirmed on stock, despite the `<1 1 1 1>` in the DT.
2. Keep the ADSP from resampling. Run ASM, ADM and AFE at one fixed nominal rate (stock uses 384000, 16-bit, 2 ch) and keep the real rate only in hw_params for the codec. Confirmed on stock; the mainline recipe is inferred.
3. Feed 32-bit samples as two S16 words, high word first, so one audio frame = 2 S16 stereo frames. This is what stock does (static). That the FPGA needs it is inferred. Verify on hardware with a non-silent tone before relying on it (open).

Probe:
4. Request outputs low: TLMM 8, 10, 11, 12, 13, 15, 28, 29, 34, 40, 44, 55, 61, 76 and pm660 GPIO13.
5. Load `FS_data` (and `FS_dsd_data`) with `request_firmware`.
6. GPO shadow starts at IOB35A | IOB29B (muted). reg3 shadow starts at 0, so NOS is off.

PO power-on, in order (static, timing confirmed on the BAL twin):
7. TLMM61=0; set IOB29B in the shadow.
8. TLMM28=1, 10 ms, TLMM40=1.
9. TLMM55=1, 50 ms, TLMM44=0, then the JTAG/SPI SRAM load (hm100-protocol.md). Check USERCODE. **Leave TLMM44=0.** Drive TLMM10 (CS) and TLMM11 (CLK) high before the first control frame.
10. Init the FPGA:
    1. reg3=0x000, reg1=shadow, reg2=0x000.
    2. gpio12=0, reg0=rate frame, gpio12=1.
    3. reg3=0x002, 2 ms, reg3=0x000.
    4. Module 2 ← filter 0: 0x4002, 0x4400, 1024 byte frames 0x48xx (each 32-bit word MSB first), 0x4c00. Send it twice.
    5. gpio12=0.
11. 10 ms, IOB39A=1 (write reg1).
12. 10 ms, TLMM34=1.
13. 10 ms, TLMM15=1.
14. pm660 GPIO13=1, 10 ms, IOB29A=1.
15. 10 ms, IOB27B=0.
16. 10 ms, TLMM13=1, NJW L/R volume words (§4), TLMM13=0.
17. TLMM13=1, NJW 0x2840, 0x0050, TLMM13=0.
18. TLMM29=0.

hw_params (rate R):
19. IOB35B=0, gpio12=0, reg0 = 0x0120 (44.1k), 0x0320 (48k), 0x0090 (88.2k), 0x0290 (96k), 0x0008 (176.4k), 0x0208 (192k), 0x0080 (352.8k), 0x0280 (384k). The 44.1k/48k values are confirmed, the rest are table values.

trigger START:
20. gpio12=1, then IOB35A=0, IOB29B=0, TLMM61=0 (reg1 0x098, then 0x088). Confirmed.

trigger STOP:
21. IOB35A=1, TLMM61=0, IOB29B=1 (reg1 0x0a8, then 0x0b8). Leave gpio12 high. Confirmed.

Volume:
22. On a level change, write the four NJW words under TLMM13=1. Ramp them if you want stock's anti-zipper behaviour (1 code per 10 ms).

PO power-off (confirmed):
23. TLMM61=0, IOB29B=1, 10 ms, IOB27B=0.
24. pm660 GPIO13=0, 10 ms, IOB29A=0.
25. TLMM15=0, TLMM34=0, IOB39A=0.
26. TLMM55=0.
27. TLMM28=0, 10 ms, TLMM40=0.
28. IOB29B=0, TLMM61=0.

Do not expose `dac_type`-style no-op attrs. Bound every string copy.

## Open (static analysis could not settle)

- The I2S wire framing (16-bit slots, hi/lo word order, WS period). Needs a scope or a tone test.
- Who turns on the HAL resampler (`enable_force_rate`), and whether HiBy Music's own "Fixed SampleRate" defaults on.
- The PCM rate the HAL opens on PO above 192k. The `op_pcm_param` table allows up to 768k for the internal path, but no PO capture exists.
- DSD on PO: the tinyalsa format id 5 mapping, `dsd_mode mdsd` reloads. Out of scope for v1.
