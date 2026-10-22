# RS6 analog chain: sequencing, settings, power, MI2S

Source: stock RS6 1.80 kernel (4.4.153, kallsyms via vmlinux-to-elf), the stock DTB #96 (`dtb96.dts`, appended to the stock boot image),
static disassembly pass (2026-10-20). Everything here is **static** (read from the binary only)
unless marked **guess** or **open**. Addresses are kernel VAs (`Image` offset = VA - 0xffffff8008080000).
Register/frame details for the FPGA itself are in `hm100-protocol.md`.

> **Do not write `dac_type`.** On the live unit (fw 1.80, 2026-10-20) `echo 0 > sa_sound_setting/dac_type` wedged the device and blanked the display until a forced restart; its value read back empty beforehand. Analysis: docs/playback-path.md, "Dangerous attrs".

## Actors

| what | where | notes |
|---|---|---|
| machine glue (`hiby,sound-plat`) | `sound_platform_probe` 0xffffff8008cf2cec | state in `g_sound_platform` (heap, 0x1a0 B) |
| ASoC hooks | `hiby_snd_startup/hw_params/trigger/shutdown` 0xffffff8008cf3c60 / cf3cc0 / cf3b80 / cf3ecc | called from sdm660-common `msm_mi2s_snd_*` |
| FPGA driver (`hiby,hm100`) | `hm100_probe` 0xffffff8008cef86c | see `hm100-protocol.md` |
| volume chip (`njw,njw1195a`) | `njw1195a_spi_write` 0xffffff8008c661d8 | bit-banged on the FPGA's control pins |
| settings sysfs | `sa_sound_setting_probe` 0xffffff8008cf1180 | dispatches through `setting_function` table |

### sound-plat DT lines (`sound_platform_probe`)
SoC gpios are requested by `gpio_request_from_of` (0xffffff8008cf2c64) and driven output-low at probe.
String values are FPGA GPO names, passed to `hm100_set_gpo` (`hbc3000_request_from_of` 0xffffff8008cf2890 just stores the string).

| prop | value | struct off | used by |
|---|---|---|---|
| `audio_dc_dc_en` | TLMM 28 | 0x150 | `hiby_dac_power` |
| `dac_pwr_en` | TLMM 40 | 0x154 | `hiby_dac_power` |
| `lpf_pwr_en` | GPO IOB39A | 0x158 | `hiby_lpf_power` |
| `vol_pwr_en` | TLMM 15 | 0x160 | `hiby_volume_power` (NJW1195A supply, guess) |
| `po_pwr_en` | pm660 GPIO 13 (phandle 0x224 = `pm660-gpio`) | 0x164 | `hiby_po_amp_power` |
| `po_amp_en` | GPO IOB29A | 0x168 | `hiby_po_amp_power` |
| `bal_amp_en` | GPO IOB27B | 0x170 | `hiby_bal_po_amp_power` |
| `pcm_dsd_sel` | GPO IOB35B | 0x178 | `hiby_snd_hw_params` (1 = DSD) |
| `lpf_sel` | TLMM 34 | 0x180 | `hiby_lpf_sel` |
| `po_bal_po_sel` | TLMM 29 | 0x184 | `hiby_headphone_balance_select` (1 = balance) |
| `iv_mute` | GPO IOB35A | 0x188 | `hiby_iv_mute` (1 = mute) |
| `lpf_mute` | TLMM 61 | 0x190 | mute helpers |
| `line_mute` | TLMM 76 | 0x194 | mute helpers |
| `hp_mute` | GPO IOB29B | 0x198 | `hiby_po_mute` (1 = mute) |

### Rail helpers
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

`lo_mute(0)` leaves TLMM76 high while `bal_lo_mute(0)` drives it low, so TLMM76 behaves more like an
LO / BAL-LO selector than a mute (guess).

## Output targets
`Output Select` mixer (`output_select_put` 0xffffff8008ce8ad0, texts in `output_select_text`):
None, Lineout, Headset, Balance, Spdif, Coax, Iis, BalanceLo. `hiby_output_switch` (0xffffff8008cf3a04)
maps by strcmp: Lineout = 1, Headset = 2 (PO), Balance = 3 (BAL), Spdif = 4, BalanceLo = 7 (BAL-LO).
Anything else (None, Coax, Iis) queues `switch_work` after 500 jiffies (HZ = 100, so 5 s), which runs
`hiby_target_poweroff(current)` and sets the target to 0 (`switch_work_schedule` 0xffffff8008cf365c).
For a valid target: same as current does nothing; otherwise `hiby_target_poweroff(old)` then
`hiby_target_poweron(new)`, all under `hiby_target_mutex`.

### Power-on (`hiby_target_poweron` 0xffffff8008cf36f0)
Always first: `only_after_poweron_umute = 1`, `hm100_fw_version = 0` (PCM design assumed).
Always last: `current_target_on = target`, `sp+0x134 = 1` (unmute pending).

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

NJW writes in step 15 are wrapped in `hm100_share_spi_lock/unlock` (share-spi-select TLMM13 = 1).
Spdif powers the whole analog chain down and keeps only the FPGA up.

### Mute / unmute (`hiby_target_poweron_mute` 0xffffff8008cf32c4, `_umute` 0xffffff8008cf2b44)
| target | mute | unmute |
|---|---|---|
| BAL (3) | IOB35A = 1, TLMM76 = 0, TLMM61 = 0, IOB29B = 1 | IOB35A = 0, IOB29B = 0, TLMM61 = 0, TLMM76 = 0 |
| PO (2) | IOB35A = 1, po_mute(1) | IOB35A = 0, po_mute(0) |
| BAL-LO (7) | IOB35A = 1 | IOB35A = 0, bal_lo_mute(0) |
| LO (1) | IOB35A = 1 | IOB35A = 0, lo_mute(0) |
| Spdif (4) | nothing | nothing |

### Power-off (`hiby_target_poweroff` 0xffffff8008cf3504), ends with `current_target_on = 0`
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

`hm100_disable` cuts FPGA power, so every output change power-cycles and reprograms the FPGA
(`hm100_enable` reloads the PCM bitstream because `hm100_enabled` was cleared).

### Delays
All delays in the sequences are hardcoded `hiby_delay()` / udelay calls. The names the task
expected (`po_poweron_before` etc.) are not DT properties: they are module statics listed in
`power_delay_array` (0xffffff8009226e70), writable through the `delay_val` attribute, with these
defaults (ms, guess on unit):

| name | default | name | default |
|---|---|---|---|
| lo_poweron_before/after | 200 / 200 | po_poweron_before/after | 300 / 300 |
| lo_poweroff_before/after | 200 / 1000 | po_poweroff_before/after | 200 / 1000 |
| bal_lo_poweron_before/after | 300 / 300 | bal_poweron_before/after | 300 / 300 |
| bal_lo_poweroff_before/after | 200 / 1000 | bal_poweroff_before/after | 200 / 1000 |

No load of these variables (0xffffff800a3044a0..0x4dc) exists in the driver text
(0xffffff8008cec400..0xffffff8008cf4000), so they have no effect. `unmute_delay_ms` / `mute_delay_ms`
(`sp+0x120` / `+0x124`) are zeroed in probe and never written, so trigger work runs immediately.

## Playback sequencing
SEC_MI2S_RX BE link (`msm_mi2s_be_dai_links` 0xffffff800921da28, entry 2): cpu `msm-dai-q6-mi2s.1`,
codec `soc:hiby,hm100-codec` / `hm100-codec-dai`, be_id 0x29, **no `be_hw_params_fixup`**, ops
`msm_mi2s_be_ops` 0xffffff800a2280b8 = {startup, shutdown, hw_params, -, -, trigger}.

1. **startup**: `msm_mi2s_snd_startup` 0xffffff8008ce7808 enables the bit clock (see MI2S), sets
   CBS_CFS, then `hiby_snd_startup`: `hiby_snd_on = 1`, `hm100_set_spdif_mode(current_target_on == 4)`.
2. **hw_params**: `msm_mi2s_snd_hw_params` 0xffffff8008ce5628 calls `hiby_snd_hw_params` and returns 0.
   Playback only. `rate = params_rate`, `fmt = first bit of the format mask`.
   - **PCM** (fmt != 0x31):
     1. `first_dsd_play = 1`
     2. `hm100_program_by_hw_param(0)`: reprograms the PCM design only if `hm100_fw_version != 0`
     3. if the previous stream was DSD and `plat_dsd_compensate != 0`: `lrch_volume_imm_set(target, L, R, 0)`
     4. `output_format = 0`, `hm100_set_gpo(IOB35B, 0)`
     5. `hm100_set_samplerate(rate)` (stops the FPGA, writes reg 0)
   - **DSD** (fmt == 0x31 = `DSD_U16_LE`, checked against `snd_pcm_format_names`):
     1. `current_dsd_mode` "mdsd": `hm100_program_by_hw_param(1)` (loads `FS_dsd_data`);
        "dsd" (default): `hm100_program_by_hw_param(0)` (keeps the PCM design); other: no reprogram
     2. if the previous stream was PCM and `plat_dsd_compensate != 0`: volume update
     3. `output_format = 1`
     4. first DSD stream since boot only: `hm100_set_samplerate(44100)`, `hm100_start`, 1 ms, `hm100_stop`
     5. `hm100_set_gpo(IOB35B, 1)`
     6. `hm100_set_samplerate(rate << 5)` (so DSD64 must arrive as 88200 frames/s; guess on the
        userspace convention)
3. **trigger** (`hiby_snd_trigger` 0xffffff8008cf3b80, returns -1 if `hiby_snd_on == 0`):
   - START / PAUSE_RELEASE / RESUME (cmd 1, 4, 6): `hm100_start` (reset-gpio TLMM12 high), queue
     `unmute_work` with delay 0. `unmute_work_schedule` 0xffffff8008cf2c1c cancels mute work and,
     if `sp+0x134`, calls `hiby_target_poweron_umute(current_target_on)`.
   - STOP (cmd 0): queue `mute_work` with delay 0: `hiby_target_poweron_mute(current_target_on)`,
     `sp+0x134 = 1`. The FPGA is **not** stopped; it stays running until the next `hm100_set_samplerate`.
   - PAUSE_PUSH, SUSPEND: nothing.
4. **shutdown**: `hiby_snd_shutdown` clears `hiby_snd_on`; `msm_mi2s_snd_shutdown` drops the clock.

`hm100_program_by_hw_param(design)` 0xffffff8008cf2254: if `design != hm100_fw_version`: jtag-select
(TLMM44) = 0, program `FS_dsd_data` (design 1) or `FS_data` (0), jtag-select = 1, `hm100_enable_init`,
then `hm100_fw_version = design`.

## Volume

### `lrch_volume_imm_set(target, l, r, now)` 0xffffff8008cf28d0
- Acts only for target 2 (PO) and 3 (BAL). LO / BAL-LO have no NJW volume.
- `base = plat_pregain`; `+ 5 * plat_vol_gain` unless target is 1 or 7; `+ 5 * plat_dsd_compensate`
  when `output_format == 1`.
- Balance `b = plat_vol_lrbalance`: b < 0 gives L += -5b, b > 0 gives R += 5b.
- `L = njw1195a_volume_db[l] + offL`, clamp to [-955, 315], `code = 255 - (L + 955) / 5`; same for R.
  Units are 0.1 dB, so one code step is 0.5 dB and code 255 is the floor (guess on the dB meaning).
- `now = 1`: share-SPI lock, NJW words `codeL<<8 | 0x00`, `codeL<<8 | 0x10`, `codeR<<8 | 0x20`,
  `codeR<<8 | 0x30`, unlock. `now = 0`: queue `volume_work` (0xffffff8008cf2a44), which steps
  `current_left/right_level` by 1 per jiffy toward `left/right_level`, writing each step.
- `njw1195a_volume_db` (0xffffff8009226ff8, `blobs/njw1195a_volume_db.bin`): 102 x int32, index =
  level 0..100: -960, -880, -830, ... -280, then 0.5 dB steps to 0 at index 100 and 101.

### Mixer entry points
`Plat Left Playback Volume` (`plat_lch_vol_put` -> `hiby_lch_vol_put` 0xffffff8008cf3990) only stores
`left_level` (clamped 0..100). `Plat Right Playback Volume` (`hiby_rch_vol_put` 0xffffff8008cf39b8)
stores `right_level` and calls `lrch_volume_imm_set(target, left, right, 0)`. Write Left first.

### NJW1195A (`njw1195a_*`, DT `njw,njw1195a`)
- Pins: `njw1195a,spi-sdo` TLMM8, `spi-clk` TLMM11, `spi-cs` TLMM10 (latch), `spi-share` present
  (struct +0x2c / +0x28 / +0x24, `njw1195a_probe` 0xffffff8008c65de8).
- `njw1195a_spi_write(w)` 0xffffff8008c661d8: CLK 0, LATCH 1 then 0, then 16 x (CLK 0, DATA = bit15,
  shift, CLK 1), CLK 0, LATCH 1. MSB first, latched on LATCH rising. It does not touch share-spi-select;
  callers must hold `hm100_share_spi_lock` (TLMM13 = 1).
- Word: bits 15:8 data, bits 7:4 select, bits 3:0 = 0. Selects used: 0x0..0x3 volume, 0x4 / 0x5
  input select. Reading 0x0..0x3 as volume ch1..4 and the low nibble as chip address 0 matches the
  datasheet layout as remembered, not checked (guess).
- `njw1195a_set_volume(l, r)` 0xffffff8008c664a0: clamp to [-955, 95], `code = 255 - (v + 955) / 5`,
  stores L in +0x1c, R in +0x18, then `njw1195a_spi_write_both` 0xffffff8008c663f8 writes
  `L<<8 | 0x00`, `L<<8 | 0x20`, `R<<8 | 0x10`, `R<<8 | 0x30` with 5 us gaps. Channel-to-select mapping
  differs from `lrch_volume_imm_set` (L on 0x00/0x10 there). Not called by the sound-plat paths found.
- `njw1195a_set_mute(1)` 0xffffff8008c66574: 0xff00, 0xff20, 0xff10, 0xff30.
- Input select: `njw1195a_intput_select` 0x2840/0x2850; `_po(tube)` 0x6040/0x6050 else 0x2040/0x2050;
  `_bal_po(tube)` 0x7040/0x7050 else 0x2840/0x2850. No caller found for the tube variants.

## Settings sysfs

### `sa_sound_setting` attrs (`sa_sound_setting_attributes` 0xffffff800a303cd0, all 0644)
Pattern: string attrs strncmp against a list, strcpy into a `*_str` buffer, then call slot N of the
table registered by `sa_sound_setting_register(setting_function)` (table at 0xffffff800a304140).
Slots 11..15 and 17..23 are NULL, so those attrs only store the string.

| attr | store fn | accepted input | slot -> handler | hardware effect |
|---|---|---|---|---|
| lrbalance | `set_lrbalance` 0xffffff8008cf2010 | `%d` | 0 `plat_set_lrbalance` | `plat_vol_lrbalance` = v, volume update (0.5 dB per unit) |
| pregain | `set_pregain` 0xffffff8008cf1f94 | `%d` | 1 `plat_set_pregain` | `plat_pregain` = v (0.1 dB units), volume update |
| gain | `set_gain` 0xffffff8008cf1a9c | low / middle / high | 2 `plat_set_gain` | `plat_vol_gain` = -24 / -12 / 0 (x5: -12 / -6 / 0 dB), volume update, PO/BAL only |
| lo_gain | `set_lo_gain` 0xffffff8008cf1850 | low / middle / high | 3 `plat_set_lo_gain` | stub (`ret`) |
| digital_filter | `set_digital_filter` 0xffffff8008cf1108 | any string | 4 `plat_set_digital_filter` 0xffffff8008cf2418 | index in `digital_fileter` -> `hm100_set_fir_coef(i)` |
| dsd_digital_filter | `set_dsd_digital_filter` 0xffffff8008cf1090 | any string | 5 | stub |
| timbre | `set_timbre` 0xffffff8008cf19c0 | default / monitor / warm / tube | 6 | stub |
| dsd_compensate | `set_dsd_compensate` 0xffffff8008cf1f14 | `%d` | 7 `plat_set_dsd_compensate` | `plat_dsd_compensate` = v (default 6, so +3 dB on DSD), volume update |
| bal_po_lo_switch | `set_bal_po_lo_switch` 0xffffff8008cf17a4 | bal_po / bal_lo | 8 | stub |
| mqa_source | `set_mqa_source` 0xffffff8008cf1914 | yes / no | 9 | stub |
| turbo | `set_turbo` 0xffffff8008cf16f8 | on / off | 10 | stub |
| power_p_pplus | `set_power_p_pplus_switch` | power_p / power_pplus | 11 | NULL |
| balpo_po_a_ab | `set_balpo_po_a_ab_switch` | zoom_a / zoom_ab | 12 | NULL |
| balpo_po_t_n | `set_balpo_po_t_n_switch` | transistor_t / transistor_n | 13 | NULL |
| digital_output_type | `set_diftal_output_type` | spidf/iis / analog | 14 | NULL |
| amp_eneble | `set_amp_enable_type` | on / off | 15 | NULL |
| vendor_func | `set_vendor_function` 0xffffff8008cf0f28 | raw buffer | 16 `plat_set_vendor_func` 0xffffff8008cf22d0 | see below |
| dac_type | `set_dac_type_function` | ignored, returns 0 | none | none |
| dsd_filter | `set_dsd_filter` | dsd_low / dsd_middle / dsd_high | 19 | NULL |
| lo_output_select | `set_lo_output_type` | line_out / pre_out | 20 | NULL |
| play_next | `set_play_next_value` | any string | 21 | NULL |
| led_work_state | `set_led_work_state_type` | led_off / led_on | 22 | NULL |
| on_boot_completed | `set_on_boot_completed` (write only) | any string | 23 | NULL |

`digital_fileter` (0xffffff8009226e20): sharp_roll_off, slow_roll_off, short_delay_sharp_roll_off,
short_delay_slow_roll_off, super_sharp_roll_off, super_slow_roll_off, low_dispersion_short_delay.
`hm100_set_filter_coef` rejects index > 3, so only the first four do anything; each loads 1 KB of
`hm100_fir_coef_default` into module 2 once. It does not update `hm100_fir_coef_custom`, so the next
`hm100_enable_init` (every output power-on) reverts to the custom/default buffer.

`plat_set_vendor_func`: `sscanf("%s %s", key, val)`:
- `nos_enable on|off` -> `hm100_osr_bypass_set_by_vendor(1|0)` (reg 3 bit 4)
- `filter_path <file>` -> `hm100_filter_path_set_by_vendor` (1024-byte `.flt` into module 2, twice)
- `dsd_mode dsd|mdsd` -> `current_dsd_mode` (default "dsd")

### sound-plat attrs (`sys_hiby_platform_group` 0xffffff80092271b8, write only)
| attr | fn | input | effect |
|---|---|---|---|
| delay_val | `sys_set_delay_val` 0xffffff8008cf24b0 | `%s %d` | sets a `power_delay_array` var (prefix strncmp); unused |
| mute_port | `sys_set_mute_val` 0xffffff8008cf33bc | `%s %d`, name lineout / headset / balance / balance_lo | v != 0: `hiby_target_poweron_mute(1/2/3/7)`, else `_umute` |

### hm100 attrs (`hm100_attributes` 0xffffff800a22a1e8)
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

## Power management
| fn | addr | does |
|---|---|---|
| `hm100_power_enable(g, on)` | 0xffffff8008cee6c4 | regulator if `hm100,power-regulator`, else power-gpio (TLMM55) = on. RS6 uses the gpio |
| `hm100_enable` | 0xffffff8008cef714 | if `!hm100_enabled`: `hm100_program` (power on, 50 ms, up to 3 tries of jtag-select = 0 + `hbc3000_program_ram`; on failure jtag-select = 1, power off, 1 s, power on, 50 ms). Then `hm100_enable_init` if loaded |
| `hm100_enable_init` | 0xffffff8008cef648 | reg 3 (power_down cleared), reg 1, reg 2, `hm100_set_samplerate(last)`, start, reg 3 bit 1 pulse 2 ms, FIR module 2 from `hm100_fir_coef_custom` x2, stop |
| `hm100_disable` | 0xffffff8008cef4e0 | power off, `hm100_enabled = 0` |
| `hm100_start` / `hm100_stop` | 0xffffff8008cef214 / 0xffffff8008cef410 | reset-gpio TLMM12 = 1 / 0 |
| `hm100_done` | 0xffffff8008ceff68 | `hm100_stop` |
| `hm100_suspend` | 0xffffff8008cee150 | (cancel program work if no `jtag-spi-mode`), power off, `hm100_enabled = 0`, SDO / CLK / CS low |
| `hm100_resume` | 0xffffff8008cee26c | CS (TLMM10) high; without `jtag-spi-mode` also power on and queue reprogram after 500 jiffies. RS6 has `jtag-spi-mode`, so nothing is reloaded until the next `hm100_enable` |
| `hm100_poweroff` | 0xffffff8008cee114 | power off (shutdown hook) |
| `sound_platform_suspend` | 0xffffff8008cf2474 | `flush_delayed_work(switch_work)` |
| `sound_platform_resume` | 0xffffff8008cf216c | printk only |

`hm100_program` leaves jtag-select at 0 after a successful load, while `hm100_program_by_hw_param`
sets it back to 1 before `hm100_enable_init`. Which level the control port needs: **open**.

## MI2S (SEC_MI2S, internal-codec card `qcom,sdm660-asoc-snd`)
- **Master**: `msm_asoc_machine_probe` 0xffffff8008ce6180 reads `qcom,msm-mi2s-master` (u32[4]) into
  `mi2s_intf_conf[i].msm_is_mi2s_master` and `qcom,msm-mi2s-ext-mclk` into `.msm_is_ext_mclk` (absent
  on RS6, so no MCLK). DT `<1 1 1 1>`: in `msm_mi2s_snd_startup` 0xffffff8008ce7808 master != 0 keeps
  fmt = `CBS_CFS` (0x4000) and the IBIT clock. The SoC is bit/frame clock master.
- **Clock**: `msm_mi2s_set_sclk` 0xffffff8008ce7638 sets `mi2s_clk[1]` = {clk_id 0x102 (SEC_MI2S IBIT),
  freq = `mi2s_rx_cfg[1].sample_rate x 2 x w`}, w = 32 for S24_LE / S32_LE / S24_3LE else 16, via
  `afe_set_lpass_clock_v2`. `mi2s_rx_cfg[1]` defaults to 48000 / S16_LE / 2 ch (1.536 MHz) and only
  changes through the `SEC_MI2S_RX SampleRate` (8k, 16k, 32k, 44.1k, 48k, 96k, 192k) and
  `SEC_MI2S_RX Format` (S16_LE, S24_LE, S24_3LE, S32_LE) controls. No 88.2k / 176.4k entries.
- **AFE port pinned to 384 kHz**: `hiby_fixed_samplerate` 0xffffff8008ce9c9c returns 384000. It
  replaces the rate in `msm_dai_q6_mi2s_hw_params` (+0x1d0, i2s port config), `msm_dai_q6_mi2s_prepare`
  (+0xbc, `afe_port_start`), `msm_pcm_routing_hw_params` (+0x54), `msm_pcm_prepare` (compress
  media format) and `msm_pcm_playback_app_type_cfg_ctl_put`. The q6 dai accepts S16_LE, SPECIAL and
  DSD_U16_LE as 16-bit and S24_LE / S24_3LE as 24-bit.
- **How > 192k reaches the FPGA**: the SEC_MI2S_RX link has no `be_hw_params_fixup`, so the BE
  params are the FE params and `hiby_snd_hw_params` reads the real FE rate and format. The BE
  SampleRate enum only feeds the LPASS bit-clock computation. DSD is selected by format
  `DSD_U16_LE` plus `rate << 5`, and by `dsd_mode` for the bitstream choice.
- **Open**: with the AFE port at 384 kHz the bit clock the FPGA actually sees is 384000 x 2 x 16 =
  12.288 MHz only if userspace sets SampleRate = 192k and a 32-bit Format (guess). How 44.1k-family
  rates are carried over a fixed 384 kHz port (DSP resampling vs a HiBy passthrough) is not visible
  in the kernel.
