# HiBy RS6 hardware

The RS6's hardware as the stock device tree describes it, section by section (sections 0 to 12 and the
TLMM GPIO summary), and the accelerometer, which is not in the device tree because the ADSP drives it
(section 13). The audio chain behind the HiBy nodes of section 9 is in `docs/audio.md`.

## Contents

- [0. Regulator quick table](#0-regulator-quick-table-only-the-ones-consumers-below-reference)
- [1. Display](#1-display-sharp-ls050t1sx18-1080p-video-dsi), [2. Touchscreen](#2-touchscreen),
  [3. Storage](#3-storage), [4. USB](#4-usb), [5. Charging and battery](#5-charging-and-battery),
  [6. LEDs](#6-leds), [7. Keys and other input](#7-keys-and-other-input), [8. Wireless](#8-wireless)
- [9. Audio-adjacent and HiBy audio-platform pinctrl](#9-audio-adjacent-non-fpga-and-hiby-audio-platform-pinctrl)
- [10. Memory](#10-memory), [11. BLSP instances](#11-blsp-instances-with-status-okay),
  [12. Other HiBy-specific nodes](#12-other-hiby-specific-or-unusual-vendor-nodes)
- [13. Accelerometer (auto-rotate)](#13-accelerometer-auto-rotate)
- [TLMM GPIO usage summary](#tlmm-gpio-usage-summary)

## Sources and conventions

Device tree source: `dtb96.dts`, the DTB #96 appended to the stock boot image, decompiled with dtc (msm-4.4, Android 9, SDM660 + PM660 + PM660L). Every `Lnnn` is a line in that file. Phandles were resolved by grepping `phandle = <0x..>`. GPIO numbers are decimal TLMM numbers unless a PMIC is named. A node counts as enabled when `status` is "okay"/"ok" or absent (downstream qcom convention), disabled otherwise. "unresolved" means the DTB does not say.

Conventions used below:
- `ldoaN` rpm resources are PM660 (`pm660_lN`), `ldobN` are PM660L (`pm660l_lN`), `bobb` is `pm660l_bob`. Ranges are the downstream rpm-regulator min/max constraints in microvolts.
- Downstream GPIO flag cell 0 = active high, 1 = active low (0x2008 on the touch irq is a vendor flag, treated as active high plus irq flags).
- Drive strength is in mA (dts value is hex mA: 0x02=2, 0x06=6, 0x08=8, 0x0a=10, 0x10=16).
- SPMI layout (L2265): `pm660@0` L2283 (SID0: PON, GPIOs, VADC, smb2, fg), `pm660@1` L2827 (SID1: haptic), `pm660l@2` L2858 (SID2: PON2, GPIOs), `pm660l@3` L3005 (SID3: LPG pwm, rgb, WLED, flash, LCDB, analog codec).

## 0. Regulator quick table (only the ones consumers below reference)

| Name | Range (uV) | Line | Used by |
|---|---|---|---|
| pm660_s4 | 1805000-2040000 | L4964 | analog codec cp/pa (L3341, L3344) |
| pm660_l1 | 1150000-1250000 | L5017 | gdsc/dsi vdda-1p2 (L16064) |
| pm660_l5 | 525000-950000 | L5070 | icnss vdd-0.8-cx-mx (L5801) |
| pm660_l8 | 1750000-1900000 | L5137 | sdhc1 vdd-io (L4528) |
| pm660_l10 | 1780000-1950000 | L5187 | qusb vdda18, ssphy core, DP vdda-1p8, gt9xx vdd (disabled) |
| pm660_l11 | 1780000-1950000 | L5209 | DSI ctrl vddio (L16131), gt9xx vcc-i2c (disabled) |
| pm660_l6 / _pin_ctrl | 1200000-1370000 | L5089 / L5100 | BT vdd-pa (L16901), icnss vdd-1.3-rfa (L5803) |
| pm660_l9 / _pin_ctrl | 1750000-1900000 | L5156 / L5167 | BT vdd-core (L16900), icnss vdd-1.8-xo (L5802) |
| pm660_l19 / _pin_ctrl | 3200000-3400000 | L5313 / L5324 | BT vdd-ldo (L16902), icnss vdd-3.3-ch0 (L5804) |
| pm660l_l1 | 800000-925000 (min read from DTB via fdtget, dts prints it garbled) | L5472 | usb qusb/ssphy vdd, DP vdda-0p9 |
| pm660l_l2 | 350000-3100000 | L5491 | sdhc2 vdd-io (L4564) |
| pm660l_l3 | 1710000-3600000 | L5510 | DSI ctrl vdd = panel vdd (L16132), gt1x vdd_ana (L11909) |
| pm660l_l4 | 1700000-2950000 | L5529 | sdhc1 vdd (L4525) |
| pm660l_l5 | 1721000-3600000 | L5548 | sdhc2 vdd (L4561) |
| pm660l_l7 | 2700000-3125000 (parent pm660_l10) | L5584 | qusb vdda33, pdphy vdd, codec mic bias |
| pm660l_bob / _pin1 | 3300000-3600000 | L5691 / L5704 | tavil mic bias (disabled path), BT chip-pwd (L16903) |
| lcdb_ldo, lcdb_ncp | 4000000-6000000 (read via fdtget) | L3262, L3271 | DSI lab-supply / ibb-supply |
| smb2-vbus, smb2-vconn | none | L2684, L2690 | pdphy vbus/vconn |

## 1. Display (Sharp LS050T1SX18 1080p video DSI)

**Correction (live unit, 2026-10-20):** the bootloader picks the panel on the cmdline, `mdss_mdp.panel=1:dsi:0:qcom,mdss_dsi_ls050t1sx18_1080p_video:...` (the live stock `/proc/cmdline`). The real panel is the Sharp LS050T1SX18 node at L15951, not the r63311 that `qcom,dsi-pref-prim-pan` names. Same reset sequence, supplies (`panel-supply-entries = <0x241>`), backlight PWM and on/off DCS as below, plus two vendor writes before display-on (0xd3 0x06, 0xd4 0x04). Porches: h-fp 96, h-pw 8, h-bp 56, v-fp 4, v-pw 2, v-bp 4. The r63311 table below is kept for reference only.

| Item | Value | Line |
|---|---|---|
| Panel node | `qcom,mdss_dsi_r63311_1080p_video` "r63311 1080p video mode dsi panel", phandle 0x251 | L15793 |
| Controller using it | `qcom,mdss_dsi_ctrl0@c994000` (`qcom,dsi-pref-prim-pan = <0x251>`), compatible `qcom,mdss-dsi-ctrl`, regs dsi_ctrl c994000, dsi_phy c994400, mmss_misc c828000. Parent `qcom,mdss_dsi@0` L16062, `hw-config = "single_dsi"` (ctrl1 @c996000 L16152 points at a different panel, 0x256, not used) | L16121, L16140, L16067 |
| Panel mode | 1080x1920, 60 fps, 24 bpp, video, burst, 4 lanes (`lane_map_0123`), hsync-pulse, `rgb_swap_rgb` | L15797-15831 |
| Timings | h-fp 36 (0x24), h-bp 24, h-pw 24, v-fp 4, v-bp 12, v-pw 2. Computed pixel clock = 1164 x 1938 x 60 = 135349920 Hz | L15801-15807 |
| D-PHY timing | `qcom,mdss-dsi-panel-timings = <0xd6322200 0x62662636 0x28030400>`, t-clk-post 3, t-clk-pre 0x1c, phy-v2 table at | L15826-15827, L15840 |
| DCS sequences | on-command `<0x5010000 0x78000129 0x5010000 0x78000111>` = DCS 0x29 (display on) wait 120 ms, then 0x11 (sleep out) wait 120 ms, sent in LP mode. Off: 0x28 wait 120 ms, 0x10 wait 150 ms (0x96), HS mode. No init table at all (panel init done by bootloader/panel defaults) | L15823-15824 |
| Reset sequence | `<1 20 0 48 1 48>` = (high, 20 ms), (low, 48 ms), (high, 48 ms) | L15837 |
| Reset GPIO | `qcom,platform-reset-gpio = <&tlmm 53 0>` (0xe5 0x35 0x00) = TLMM gpio53, active high, set on the DSI controller, not in the panel node | L16144 |
| TE GPIO | `qcom,platform-te-gpio = <&tlmm 59 0>` (0xe5 0x3b) = gpio59 | L16145 |
| Panel-level enable/backlight gpios | none. No bklight-en, no lcd-en, no `qcom,mdss-dsi-*-gpio` in the active panel node | grep over L15793-15850 |
| Pinctrl | `pinctrl-0 = <0x252 0x253>` (active), `pinctrl-1 = <0x254 0x255>` (sleep), names mdss_default / mdss_sleep | L16142-16143 |
|  mdss_dsi_active | gpio53 gpio, drive 8, bias-disable | L11430 |
|  mdss_dsi_suspend | gpio53 gpio, drive 2, bias-pull-down | L11446 |
|  mdss_te_active / suspend | gpio59 function `mdp_vsync`, drive 2, bias-pull-down (both) | L11465, L11481 |
| DSI ctrl supplies | `vddio-supply` = 0x17c = pm660_l11 (1.78-1.95 V); `vdd-supply` = 0x181 = pm660l_l3 (1.71-3.6 V); `lab-supply` = 0x24d = lcdb_ldo; `ibb-supply` = 0x24e = lcdb_ncp | L16131-16134 |
| DSI block supplies | gdsc-supply 0x163 = gdsc_mdss, vdda-1p2 = 0x107 = pm660_l1 (1.15-1.25 V), vdda-0p9 = 0x103 = pm660l_l1 (0.8-0.925 V) | L16064-16066 |
| `qcom,panel-supply-entries = <0x241>` | node `dsi_panel_pwr_supply` L16307: vddio 1.8-1.95 V (1800000-1950000, load 100 mA), vdd 2.8 V fixed (2800000), lab 4.6-6.0 V (4600000-6000000), ibb 4.6-6.0 V (post-on-sleep 10 ms). vddio->pm660_l11, vdd->pm660l_l3, lab/ibb->lcdb | L15845, L16313-16346 |
| LCDB | `qpnp-lcdb@ec00` compatible `qcom,qpnp-lcdb-regulator`, reg 0xec00, irq sc-irq, enabled. `qpnp-labibb-regulator` (L3299 area) is `status = "disabled"`, `qpnp-oledb` disabled | L3252, L3302 |
| Backlight type | `qcom,mdss-dsi-bl-pmic-control-type = "bl_ctrl_pwm"`, bl-min-level 1, bl-max-level 0xfff (4095), `qcom,mdss-dsi-bl-pwm-pmi` flag, bank-select 2, pwm-frequency 0x172 (370, mdss treats it as period in us, ~2.7 kHz) | L15838-15844 |
| Backlight PWM | `pwms = <0x24a 0 0>` = 0x24a = `pwm@b400` under pm660l@3, compatible `qcom,qpnp-pwm`, reg 0xb400 (+ lut 0xb042 0x7e), `qcom,channel-id = <4>` (LPG channel 4), `qcom,period = 0x172`, default duty 0xb9 (185), `status = "okay"`, `#pwm-cells = <2>` | L15845, L3057-3075 |
| WLED | `qcom,leds@d800` compatible `qcom,qpnp-wled`, reg 0xd800/0xd900, **status "ok" (enabled)**, led-strings-list [01 02], fs-curr 25 mA (0x61a8 uA), ovp 29600 mV, ilim 970 mA, switch-freq 800 kHz, dim-mode hybrid. Not referenced by the active panel (panel uses PWM), so whether a WLED string is physically populated is unresolved | L3120-3144 |
| Physical size | `qcom,mdss-pan-physical-width/height-dimension` absent for r63311 (other panels have them, e.g. L14667) | unresolved |
| Splash | cont-splash region `splash_region@9d400000` (see section 10) referenced by `mdss_fb_primary` `linux,contiguous-region = <0x23e>` | L14520-14523 |
| Other | MDP `qcom,mdss_mdp@c900000` L14395 (`qcom,mdss-pref-prim-intf = "dsi"`), DP controller `qcom,dp_ctrl@c990000` is "ok" but is a reference leftover (see section 4) | L14395, L16198 |

## 2. Touchscreen

Both goodix nodes sit under `i2c@c175000` (L11855, `qcom,i2c-msm-v2`, status ok, reg 0xc175000, SPI irq 0x5f=95, 400 kHz (0x61a80), SDA/SCL = gpio2/gpio3 function `blsp_i2c1`, drive 2, bias-disable active / bias-pull-up sleep; pinctrl nodes L9477, L9493). In mainline sdm630.dtsi this is `blsp_i2c1` (`i2c@c175000`).

| Node | Status | Details | Line |
|---|---|---|---|
| `goodix@5d` `goodix,gt9xx` | **disabled** | reg 0x5d, reset 66, irq 67, vdd = 0x0c7 = pm660_l10, vcc-i2c = 0x17c = pm660_l11, coords 0x2cf x 0x57d, product-id "9147", has touch keys | L11878-11900 |
| `goodix_ts@14` `goodix,gt1x` | **enabled (no status)** | reg 0x14, `interrupt-parent` tlmm, `interrupts = <67 2>` (gpio67, IRQ_TYPE_EDGE_FALLING), `goodix,reset-gpio = <&tlmm 66 0>`, `goodix,irq-gpio = <&tlmm 67 0x2008>`, `vdd_ana-supply` = 0x181 = pm660l_l3 (1.71-3.6 V), no separate i2c-vcc. `goodix,default-config0` = vendor config blob, first bytes `42 38 04 80 07 0a` = version 0x42, x-max 0x0438 (1080), y-max 0x0780 (1920), 10 touches | L11902-11914 |
| Pinctrl | `pmx_ts_active = <0x17d 0x17e>`, `pmx_ts_suspend = <0x17f 0x180>` | L11911-11913 |
|  ts_int_active | gpio67 gpio, drive 16, bias-pull-up | L11596 |
|  ts_int_suspend | gpio67 gpio, drive 2, bias-disable | ts_mux L11562 block |
|  ts_reset_active | gpio66 gpio, drive 16, bias-pull-up | L11564 |
|  ts_reset_suspend | gpio66 gpio, drive 2, bias-pull-down | ts_mux L11562 block |

GT1x (not GT9xx) is the active controller, I2C address 0x14. Mainline driver is `goodix,gt1x` family via `goodix_ts` (compatible `goodix,gt911`-like, 1080x1920 from config). Note the reset line is high-idle with pull-up, irq falling edge.

## 3. Storage

| Item | sdhc_1 (eMMC) | sdhc_2 (microSD) |
|---|---|---|
| Node | `sdhci@c0c4000` L4497, `qcom,sdhci-msm-v5`, status ok, aliases sdhc1 L16710 | `sdhci@c084000` L4538, `qcom,sdhci-msm-v5`, status ok, aliases sdhc2 L16711 |
| Regs | hc_mem c0c4000, cmdq_mem c0c5000 | hc_mem c084000 |
| IRQs (SPI) | hc 0x6e (110), pwr 0x70 (112) | via interrupt-map: hc SPI 0x7d (125), pwr SPI 0xdd (221), status = TLMM gpio54 (L4574) |
| Bus | 8-bit, `qcom,nonremovable`, speed modes HS400 1.8 V / HS200 1.8 V / DDR 1.8 V, max clk 0x16e36000 (384 MHz), crypto engine ref `sdhc-msm-crypto = <0xd1>` | 4-bit, speed modes SDR12/25/50/104, DDR50, max clk 0xbebc200 (200 MHz) |
| vdd-supply | 0xd2 = pm660l_l4 (1.7-2.95 V), level 2.95 V, 200 uA..0x8b290 (570 mA) | 0x4f = pm660l_l5 (1.721-3.6 V), level 2.95 V |
| vdd-io-supply | 0xd3 = pm660_l8 (1.75-1.9 V), level 1.8 V, always-on, lpm-sup | 0x50 = pm660l_l2 (0.35-3.1 V), levels 1.8-2.95 V |
| cd-gpios | none (nonremovable) | `<&tlmm 54 1>` = gpio54 **active low** (L4575) |
| Pinctrl active | sdc1_clk_on L9290 (drive 16, bias-disable), sdc1_cmd_on L9312 (drive 10, pull-up), sdc1_data_on L9335 (drive 10, pull-up), sdc1_rclk_on L9357 (pull-down) | sdc2_clk_on L9377 (drive 16, bias-disable), sdc2_cmd_on L9399 (drive 10, pull-up), sdc2_data_on L9421 (drive 10, pull-up), cd_on L9443 (gpio54, drive 2, pull-up) |
| Pinctrl sleep | sdc1_*_off (clk drive 2 bias-disable at L9301, others L9323/L9346/L9367) | sdc2_*_off, cd_off L9459 (gpio54, drive 2, bias-disable) |

Android fstab: vendor partition on `c0c4000.sdhci` (eMMC), ext4, slotselect (L16765-16772), so the eMMC is A/B.

## 4. USB

| Item | Value | Line |
|---|---|---|
| Primary controller | `ssusb@a800000` `qcom,dwc-usb3-msm` + child `dwc3@a800000` (`snps,dwc3`), SPI irqs hs_phy 0x15b, ss_phy 0xf3, pwr_event 0xb4 (dwc3 core irq 0x83), `USB3_GDSC-supply` = gdsc_usb30, `qcom,usb-dbm` = `dbm@a8f8000` (`qcom,usb-dbm-1p5`), tx-fifo-resize, u1u2-disable, **no dr_mode** (otg by extcon). `usb-phy = <qusb@c012000, ssphy@c010000>` | L8978-9016, L9131 |
| extcon | `extcon = <0x174>` = `qcom,usb-pdphy@1700` (PM660 PD phy, SID0). No id gpio, no vbus detect gpio, no separate extcon node | L8994 |
| Type-C / PD | none external (no fusb302, no tcpc). Type-C CC + PD PHY are in PM660: `qcom,qpnp-smb2` irq "type-c-change" (L2668) and `qcom,usb-pdphy@1700` compatible `qcom,qpnp-pdphy`, reg 0x1700, irqs sig-tx/sig-rx/msg-tx/msg-rx/msg-tx-failed/msg-tx-discarded/msg-rx-discarded, `vdd-pdphy-supply` = pm660l_l7, `vbus-supply` = smb2-vbus (0x7e), `vconn-supply` = smb2-vconn (0x7f), `qcom,default-sink-caps = <5000 3000 9000 3000>` (mV, mA pairs: 5 V 3 A, 9 V 3 A) | L2665-2707 |
| HS PHY (primary) | `qusb@c012000` `qcom,qusb2phy`, regs c012000 (0x180), tune2 efuse 0x780240 bit 0x19 x4, ref_clk 0x188018. vdd = pm660l_l1 (level 0.925 V), vdda18 = pm660_l10, vdda33 = pm660l_l7. init-seq pairs (val,offset): f8@80 b3@84 83@88 c0@8c 30@08 79@0c 21@10 14@9c 9f@1c 00@18, phy-clk-scheme cml, major-rev 1 | L9083-9103 |
| SS PHY | `ssphy@c010000` `qcom,usb-ssphy-qmp-v2`, regs c010000, vls_clamp 0x1fcb244, tcsr_usb3_dp_phymode 0x1fcb248; vdd = pm660l_l1, core = pm660_l10 (1.8 V), `qcom,vbus-valid-override` | L9105-9122 |
| Secondary | `hsusb@c200000` + `qusb@c014000` + `usb_nop_phy`: **disabled**, host-only | L9139-9198 |
| SBU / DP | `qcom,dp_ctrl@c990000` (`qcom,mdss-dp`) is `status = "ok"` with `qcom,dp-usbpd-detection = <0x174>`, `qcom,aux-en-gpio = <&tlmm 76 0>`, `qcom,aux-sel-gpio = <&tlmm 21 0>`, `qcom,usbplug-cc-gpio = <&tlmm 58 0>`. gpio76/gpio21 are the same pins the HiBy audio nodes use (`line_mute`, `balance_lo` jack detect), so DP/SBU muxing is almost certainly not wired on the RS6 (reference leftover). Pinctrl `mdss_dp_aux_active` (gpio76, gpio21: drive 8, bias-disable) L11498, `mdss_dp_usbplug_cc_active` (gpio58: drive 16, bias-disable) L11530. Real SBU mux: unresolved | L16198-16230 |
| Audio over USB-C | `usb_audio_qmi_dev` L9124; tavil `usbc_analog_en1/en2` pinctrl nodes under disabled slim@151c0000 (L4156, L4165) are not used | L9124 |

## 5. Charging and battery

| Item | Status / value | Line |
|---|---|---|
| `qcom,qpnp-smb2` | **enabled** (no status), SID0, io-channels rradc (charger_temp, charger_temp_max, usbin_i, usbin_v), `dpdm-supply` = qusb@c012000, `qcom,wipower-max-uw = 5000000` (0x4c4b40), thermal-mitigation table 3000000..500000 uA (0x2dc6c0 0x2625a0 0x1e8480 0x16e360 0xf4240 0x7a120). Sub-blocks chgr@1000, otg@1100, bat-if@1200, usb-chgpth@1300, dc-chgpth@1400, chgr-misc@1600. No fcc/fv/float properties in the node, so settings come from the fg battery profile and defaults | L2636-2694 |
| `qpnp,fg` `qcom,fg-gen3` | **enabled** (`status = "okay"`), rradc batt_id and die_temp, `qcom,fg-rsense-sel = 0`, `qcom,cycle-counter-en`, `qcom,fg-force-load-profile`, `qcom,battery-data = <0x80>` = `/qcom,battery-data` L16924. Subnodes batt-soc@4000, batt-info@4100, memif@4400 | L2777-2814 |
| `/qcom,battery-data` | `qcom,batt-id-range-pct = 15`. Two profiles: `qcom,itech_3000mah` (batt-id 100 kohm, max-voltage 4350000 uV (0x426030), cc-cv threshold 4340 mV (0x10f4), fastchg 3000 mA (0xbb8), beta 3435 (0xd6b), type "itech_b00826lf_3000mah_ver1660_jan10th2017", checksum 0xfb8f, fg-profile-data 50 words at L16938) and `qcom,ascent_3450mah` (batt-id 60 kohm, 4350000 uV, fastchg 3450 mA (0xd7a), type "ascent_3450mah_averaged_masterslave_jul11th2017", checksum 0x7c33). These look like Qualcomm reference profiles (PMI8998GUI), not RS6 specific; the RS6 battery profile for fg-gen3 is unresolved | L16924-16951 |
| smb1351 parallel charger | `smb1351-charger@1d` `qcom,smb1351-charger`, reg 0x1d on `i2c@c176000` (blsp1 qup2, gpio6/gpio7), **parent bus is `status = "disabled"`** so it never probes. Props: `qcom,parallel-charger`, `qcom,float-voltage-mv = <4400>` (0x1130), `qcom,recharge-mv = <100>`, `qcom,parallel-en-pin-polarity = <1>`. No irq, no gpios | L11917-11948 |
| cw2015 fuel gauge | `cw2015@62` compatible `cw,cw2015`, reg 0x62, on `i2c@c1b6000` (status okay). Only property is `config-data` (16 u32 = 64 bytes). No irq, no gpio, no power-supplies, no monitor interval | L12045-12049 |
| MP2731 or other charger | none found (grep for mp2731, bq, max77, rt9 compatibles: none). The only unusual-vendor compatibles are listed in section 12 | n/a |

cw2015 `config-data` as bytes (big-endian split of the u32 cells), ready for mainline `cellwise,battery-profile = /bits/ 8 <...>` (64 bytes, matches the binding's minItems/maxItems 64):

```
17 67 71 67 67 64 63 59 66 6b 43 53 55 59 45 39
30 29 23 1b 1e 2b 3e 4c 38 18 0c cd 36 56 64 80
89 8b 8e 8c 3c 19 79 30 0a 35 16 41 6d 9a aa 0d
22 6a 9c c6 80 64 69 cb 2f 00 64 a5 b5 08 40 49
```

Which gauge actually feeds Android (PM660 fg-gen3 or cw2015) is unresolved: both are enabled downstream. The 4.35 V charge limit in the battery profiles and 4.4 V float on the smb1351 suggest a high-voltage (4.35 V) cell.

## 6. LEDs

| Item | Value | Line |
|---|---|---|
| lp5562 | `ti@30` compatible `ti,lp5562`, reg 0x30 on `i2c@c1b6000` (blsp2 qup2, gpio22/gpio23 function `blsp_i2c6`, drive 2, bias-disable active / pull-up sleep, 400 kHz, status okay), `clock-mode = [01]` (1 = internal clock per mainline binding), `enable-gpio = <&pm660l_gpios 8 0>` (0x192 = pm660l@2 gpios, pin 8, active high). Mainline name is `enable-gpios` | L12051-12056, L2899 |
| lp5562 channels | chan0 "R", chan1 "G", chan2 "B", chan3 "W": each `led-cur = [20]` (0x20 = 3.2 mA, mA x10), `max-cur = [60]` (0x60 = 9.6 mA). Plus a `pattern` subtree with 13 vendor patterns (hex strings, `white` flag on pattern5) | L12057-12161 |
| pm660l gpio 8 | gpio@c700 L2967: status ok, mode 1 (digital output), pull 5 (no pull), vin-sel 0, src-sel 0, invert 0, master-en 1 | L2967-2977 |
| qpnp RGB LED | `qcom,leds@d000` `qcom,leds-qpnp` label rgb, **enabled**: rgb_0 "red" id 3 pwms = 0x82 (`pwm@b300`), rgb_1 "green" id 4 pwms 0x83 (`pwm@b200`), rgb_2 "blue" id 5 pwms 0x84 (`pwm@b100`); max-current 12 mA, pwm-us 1000, default-state off, blink LUT idx 0..0x16. Whether this RGB is physically populated alongside the lp5562 is unresolved | L3077-3118 |
| Flash LED | `qcom,leds@d300` `qcom,qpnp-flash-led-v2`, enabled in DT (reference leftover, no flash on RS6 known) | L3147 |
| Haptic | `qcom,haptic@c000` `qcom,qpnp-haptic` under pm660@1, enabled, LRA, direct play, vmax 3200 mV (0xc80), ilim 800 mA (0x320). Presence on RS6 unresolved | L2833-2855 |

## 7. Keys and other input

| Device | Details | Line |
|---|---|---|
| `gpio_keys` (`gpio-keys`, status okay) | pinctrl names tlmm_gpio_key_active/suspend: `0x260` (L11395) / `0x261` (L11411) = gpio56, gpio64, gpio113 function gpio, drive 2, bias-pull-up (both states). Only gpio56 is used by a key below, gpio64 and gpio113 have no consumer in this DT | L16516-16541 |
|  `vol_up` | label volume_up, `gpios = <&pm660l_gpios 7 1>` (0x192 pin 7, active low), code 0x73 = 115 KEY_VOLUMEUP, wakeup, debounce 15 ms. pm660l gpio 7: input, no pull flag 0 = pull-up 30 uA, vin 0 (L2956-2965) | L16524-16531 |
|  `play_pause` | `gpios = <&tlmm 56 1>` (active low), code 0xa4 = 164 KEY_PLAYPAUSE, wakeup, debounce 15 ms | L16533-16540 |
| `ring_keys` (`ring-keys`, vendor driver) | the volume wheel: `clockwise-gpios = <&tlmm 42 0>`, `anticlockwise-gpios = <&tlmm 43 0>`, pinctrl `ring_key_active/suspend` 0x262/0x263 (L10224, L10240): gpio42, gpio43 function gpio, drive 2, bias-pull-up. Children `vol_down` code 0x72=114 direction 1, `vol_up` code 0x73=115 direction 2. Mapping of direction to cw/ccw is unresolved (a mainline `rotary-encoder` on gpio42/43 with `linux,axis` or key emulation is the usual substitute) | L16543-16563 |
| PM660 PON | `qcom,power-on@800` (SID0) compatible `qcom,qpnp-power-on`, irqs kpdpwr, resin, resin-bark, kpdpwr-resin-bark, `qcom,pon-dbc-delay = 15625 us` (0x3d09), kpdpwr sw debounce, `qcom,system-reset`, store-hard-reset-reason. `pon_1`: type 0 (KPDPWR), pull-up, `linux,code = 0x74` = 116 KEY_POWER, support-reset 0, s1-timer 0x1a40 (6720 ms), s2-timer 2000 ms, s2-type 4. `pon_2`: type 1 (RESIN), pull-up, `linux,code = 0x72` = 114 KEY_VOLUMEDOWN, no reset | L2306-2331 |
| PM660L PON | `qcom,power-on@800` (SID2): `qcom,secondary-pon-reset`, hard-reset-poweroff-type 4, no keys | L2878-2883 |
| Accelerometer (KXTJ2-1009) | **not present** anywhere in the DT. No kxtj, kionix, accel, gyro, proximity, light, hall or compass node. Only `qcom,msm-ssc-sensors` stub (L16512). The RS6 does have one: the ADSP's sensor core drives it on its own I2C bus, see section 13 | grep over whole file |
| Other input | `hiby,earpods_adc` is disabled (section 9) | L16624 |

## 8. Wireless

| Item | Value | Line |
|---|---|---|
| WLAN `qcom,icnss@18800000` | compatible `qcom,icnss`, enabled. regs membase 0x18800000 (0x800000), smmu_iova_base 0xa0000000 (256 MB), iova_ipa 0xb0000000; 12 SPI irqs 0x19d-0x1a9 (skip 0x1a3); iommus `<&apps_smmu 0x1a00>, <&apps_smmu 0x1a01>`; clock rpmcc `<0x26 0x14>` = rf_clk1 ("cxo_ref_clk_pin"); `qcom,smmu-s1-bypass`; `qcom,wlan-msa-memory = 0x100000`, `qcom,wlan-msa-fixed-region = <0xf7>` = `wlan_msa_mem@85700000` | L5793-5812 |
| WLAN supplies (volt level uV) | vdd-0.8-cx-mx = pm660_l5 (config 847000-847000, 0xcf080); vdd-1.8-xo = pm660_l9_pin_ctrl (1.75-1.9 V); vdd-1.3-rfa = pm660_l6_pin_ctrl (1.2-1.37 V, config 1200000-1370000); vdd-3.3-ch0 = pm660_l19_pin_ctrl (3.2-3.4 V, config 3200000-3400000). No wlan-en gpio | L5801-5808 |
| Bluetooth `bt_wcn3990` | top-level, compatible `qca,wcn3990`, `clocks = <rpmcc rf_clk1>`, supplies: `qca,bt-vdd-core` = pm660_l9 (1.8-1.9 V, 1800000-1900000), `qca,bt-vdd-pa` = pm660_l6 (1.3-1.37 V, 1300000-1370000), `qca,bt-vdd-ldo` = pm660_l19 (3.3-3.4 V), `qca,bt-chip-pwd` = pm660l_bob_pin1 (3.6 V fixed 0x36ee80). No reset/enable gpio, no uart phandle in the node | L16898-16913 |
| BT HCI UART | `serial@0c1b0000` (blsp2 uart2, SPI irq 0x72, **status ok**) with pins gpio28/29/30/31 function `blsp_uart6_b`, drive 2, bias-pull-up (active, L11330), output-low gpio (sleep, L11346). By position it is the BT UART, but those four GPIOs are also claimed elsewhere (gpio28 audio_dc_dc_en and hm100 ctrl pin, gpio29 po_bal_po_sel, gpio30/31 are `blsp_i2c8_a` for `i2c@c1b8000` L12189). Real BT wiring is unresolved | L3867-3877 |
| BT audio (btfm) | `slim@15240000` (`qcom,slim-ngd`, enabled) with child `wcn3990` `qcom,btfmslim_slave`, elemental-addr 00 01 20 02 17 02, ifd addr 00 00 20 02 17 02. Sound card sets `qcom,wcn-btfm` | L4182-4196, L13968 |

## 9. Audio-adjacent (non-FPGA) and HiBy audio-platform pinctrl

Sound card in use: `sound` compatible `qcom,sdm660-asoc-snd`, model "sdm660-snd-card", **status okay** (`sound-tavil` L13934 is disabled). Codec set = `msm-stub-codec.1`, `msm-dig-codec`, PM660L `analog-codec@f000` (L3332, enabled; cdc-vdda-cp and cdc-vdd-pa = 0x88 = pm660_s4 (levels 1.9-2.05 V and 2.04 V), mic-bias = pm660l_l7 at 3088000 uV, mclk 9.6 MHz), `msm_sdw_codec`, ext-disp. Internal MI2S "sec" (dev-id 1, rx-lines 1, tx-lines 2, the DT says SDM is master: `qcom,msm-mi2s-master = <1 1 1 1>`; the stock kernel zeroes these flags at probe and the FPGA is the clock master, see `docs/audio.md`) has pinctrl: `sec_mi2s_active` gpio24/gpio25 (SCK/WS, drive 8, bias-disable, output-high, L11766), `sec_mi2s_sd0` gpio26 (drive 8, bias-disable, L11802), `sec_mi2s_sd1` gpio27 (drive 8, bias-disable, L11837). Sleep: all pull-down, drive 2 (L11750, L11786, L11821). That is the likely serial audio link to the HM100 FPGA (consumer not stated in the DTB, so unresolved). `us-euro` mic swap pinctrl `wcd_gnd_mic_swap_active` = gpio63, drive 2, bias-disable, output-high (L10747). Refs: L13344-13353, L13964-13993.

| Item | Details | Line |
|---|---|---|
| `hiby,sa_sound_switch` | compatible `hiby,sa_sound_switch`, vendor switch-class driver, `report_only_one`. Pinctrl `gpio_sound_switch_active/suspend` = 0x26d/0x26e (L11631/L11647): gpio14, gpio21, gpio41, gpio72, function gpio, drive 2, **bias-disable in both states** (no internal pull, so external pulls on the board) | L16638-16698 |
|  balance | `<&tlmm 72 0>` (active high), type 1, sdev "balance", hw_id 1, status 1 | L16647-16650, L16670 |
|  balance_lo | `<&tlmm 21 0>`, sdev "balance_lo", hw_id 2, status 1 | L16652-16655, L16677 |
|  headset | `<&tlmm 41 0>`, sdev "h2w", hw_id 3, switch_status 2 | L16657-16660, L16684 |
|  lineout | `<&tlmm 14 0>`, sdev "lineout", hw_id 4, status 1 | L16662-16665, L16691 |
| `hiby,earpods_adc` | **disabled**. `sdev_name "h2w"`, `qcom,earpods-vadc = <0x79>` = pm660 vadc@3100, channel 0x12 (= `gpio2_adc1`, L2613), min 100, max 200, key_status 1 | L16624-16636 |
| `hiby,sound-plat` | compatible `hiby,sound-plat`, pinctrl 0x26b/0x26c (r8-sound-plat group, L10318/L10334): **gpio29, gpio40, gpio55, gpio76**, function gpio, drive 2, bias-disable (both states). Pinctrl groups for other HiBy models exist but are not referenced: `n9-sound-plat` L10448, `n9_gpio_sound_switch` L10479, `r8_gpio_sound_switch` L10351 | L16603-16622 |
|  audio_dc_dc_en | `<&tlmm 28 0>` | L16608 |
|  dac_pwr_en | `<&tlmm 40 0>` | L16609 |
|  vol_pwr_en | `<&tlmm 15 0>` | L16611 |
|  po_pwr_en | `<&pm660_gpios 13 0>` (0x224 = pm660@0 gpios, pin 13: output, no pull, vin 0, master-en 1, L2439-2448) | L16612 |
|  lpf_sel | `<&tlmm 34 0>` | L16615 |
|  po_bal_po_sel | `<&tlmm 29 0>` | L16616 |
|  lpf_mute | `<&tlmm 61 0>` | L16619 |
|  line_mute | `<&tlmm 76 0>` | L16620 |
|  string "IOB..." entries | `lpf_pwr_en "IOB39A"`, `po_amp_en "IOB29A"`, `bal_amp_en "IOB27B"`, `pcm_dsd_sel "IOB35B"`, `iv_mute "IOB35A"`, `hp_mute "IOB29B"`: these are FPGA IO bank pin names (HM100), not SoC GPIOs | L16610-16621 |
| `hiby,hm100` | compatible `hiby,hm100` (FPGA, protocol in `docs/audio.md`), 5 pinctrl states 0x264-0x268 (L11666-L11730, hm100 group L11664): jtag_active gpio8/9/10/11/44 (drive 2, bias-disable); jtag_suspend same pins pull-down; `jtag_as_spi` gpio8, gpio11 function `blsp_spi3` (drive 6, bias-disable); ctrl_active gpio28, gpio68, gpio69, gpio70, gpio71 (drive 2, bias-disable, no consumer property for 68-71); ctrl_suspend gpio8-11 + gpio28 pull-down | L16565-16586 |
|  hm100 gpios | `power-gpio` 55, `reset-gpio` 12, `share-spi-select` 13, `jtag-select` 44, spi-sdo 8, spi-clk 11, spi-cs 10, jtag-tdi 8, jtag-tdo 9, jtag-tck 11, jtag-tms 10 (all active high flag 0), flags `jtag-io-as-spi-io`, `jtag-spi-mode`. JTAG pins and SPI3 pins are the same four GPIOs (8-11) | L16573-16585 |
| `hiby,hm100-codec` | compatible `hiby,hm100-codec`, empty ASoC codec stub | L16588-16590 |
| `njw,njw1195a` | volume/mux chip (NJR NJW1195A, SPI-like 3-wire), `njw1195a,spi-share` flag, sdo gpio8, clk gpio11, cs gpio10 (shared with SPI3/JTAG). Pinctrl 0x269/0x26a (njw11195a group L10413, active L10415, suspend L10431) lists **gpio77, gpio34, gpio61**, drive 6, bias-disable in both states, which do not match the spi gpios (8/11/10), so the pinctrl group looks stale (gpio34 = lpf_sel, gpio61 = lpf_mute elsewhere) | L16592-16601 |
| Other audio gpios | `audio_ext_clk` `qcom,audio-ref-clk-gpio = <&pm660_gpios 3 0>` but node is **disabled** (L14027); `qcom,wsa-disable`, tavil/wcd9xxx-irq disabled | L14015-14028 |

Caution for mainline pinctrl: the HiBy `sound_plat` pinctrl lists gpio29/40/55/76 while the consumer properties use gpio28/40/15/34/29/61/76, so any pins not in the pinctrl state (28, 15, 34, 61) get no explicit mux or bias downstream. Reconcile with the board schematic or by probing.

## 10. Memory

`memory` node is empty (`reg = <0 0 0 0>`, L16730, filled by the bootloader). Reserved-memory (L16777, `#address-cells = <2>`, `#size-cells = <2>`):

| Node | Base | Size | Flags | Line |
|---|---|---|---|---|
| wlan_msa_guard@85600000 | 0x85600000 | 0x100000 | removed-dma-pool, no-map | L16782 |
| wlan_msa_mem@85700000 | 0x85700000 | 0x100000 | removed-dma-pool, no-map (phandle 0xf7, icnss) | L16788 |
| removed_regions@85800000 | 0x85800000 | 0x3700000 | removed-dma-pool, no-map | L16796 |
| modem_fw_region@8ac00000 | 0x8ac00000 | 0x7e00000 | removed-dma-pool, no-map | L16802 |
| adsp_fw_region@92a00000 | 0x92a00000 | 0x1e00000 | removed-dma-pool, no-map | L16810 |
| pil_mba_region@94800000 | 0x94800000 | 0x200000 | removed-dma-pool, no-map | L16818 |
| cdsp_fw_region@94a00000 | 0x94a00000 | 0x600000 | removed-dma-pool, no-map | L16826 |
| venus_fw_region | alloc-ranges 0x80000000..0xa0000000 | 0x800000 | shared-dma-pool, reusable, align 4 MB | L16834 |
| adsp_region | alloc-ranges 0..0xffffffff | 0x800000 | shared-dma-pool, reusable, align 4 MB | L16844 |
| qseecom_region | alloc-ranges 0..0xffffffff | 0x1400000 | shared-dma-pool, reusable | L16854 |
| secure_region | alloc-ranges 0..0xffffffff | 0x5c00000 | shared-dma-pool, reusable | L16864 |
| linux,cma | alloc-ranges 0..0xffffffff | 0x2c00000 | shared-dma-pool, reusable, `linux,cma-default` | L16874 |
| splash_region@9d400000 (label "cont_splash_mem") | 0x9d400000 | 0x23ff000 | plain reg, not no-map (phandle 0x23e, referenced by mdss_fb_primary) | L16883 |
| dfps_data_mem@0x9f7ff000 (label "dfps_data_mem") | 0x9f7ff000 | 0x1000 | plain reg (phandle 0x25f) | L16890 |

Missing from this list vs a mainline sdm660 map: smem, tz/hyp/xbl, rmtfs, mpss. Those come from the bootloader-provided memory map or are not in this dtb: unresolved.

## 11. BLSP instances with status okay

Mainline `sdm630.dtsi` (in the sdm660-mainline tree) already defines `blsp_i2c1` (c175000), `blsp_i2c3`, `blsp_i2c5`, `blsp_i2c6` (c1b6000), `blsp_i2c8` (c1b8000), `blsp_spi7`, `blsp1_uart1`, `blsp1_uart2`, `blsp2_uart1`. It has **no** `spi@c177000` and **no** `serial@c1b0000`, so those two must be added for the RS6.

| Downstream node (alias) | Base | Status | SDA/SCL or pins | Attached | Line |
|---|---|---|---|---|---|
| `i2c@c175000` (i2c1) | 0xc175000 | okay | gpio2/gpio3 `blsp_i2c1` | goodix gt1x @0x14 (gt9xx @0x5d disabled) | L11855 |
| `i2c@c176000` (i2c2) | 0xc176000 | **disabled** | gpio6/gpio7 | smb1351 @0x1d (dead) | L11917 |
| `i2c@c1b6000` (i2c6) | 0xc1b6000 | okay | gpio22/gpio23 `blsp_i2c6` | cw2015 @0x62, lp5562 @0x30 | L12022 |
| `i2c@c1b8000` (i2c8) | 0xc1b8000 | okay | gpio30/gpio31 `blsp_i2c8_a` (conflicts with blsp2 uart2 pins) | nothing attached | L12189 |
| other i2c (c177000, c178000, c1b5000, c1b7000) | | disabled | | | L11950, L11974, L11998, L12165 |
| `spi@c177000` (spi3, blsp1 qup3) | 0xc177000 | okay | gpio8/9/10/11 `blsp_spi3` drive 6 bias-disable (pinctrl 0x19d/0x19e L10014/L10030), BAM consumer pipe 8 producer 9, max 50 MHz | `hbc3000_ram@0` `hiby,hbc3000_ram`, reg 0, max 10 MHz, status okay. Same pins as HM100 JTAG, so the SPI is a mux of the FPGA programming/data bus | L12259-12287 |
| other spi (c175000, c176000, c178000, c1b5000..c1b8000) | | disabled | | | L12213 and following |
| `serial@0c170000` (serial0, console) | 0xc170000 | okay | gpio4/gpio5 `blsp_uart2`, drive 2, bias-pull-up (active), gpio output-low (sleep), pinctrl L9211, L9227 | debug console, `stdout-path = serial0` | L3546, L16701 |
| `serial@0c1b0000` | 0xc1b0000 | okay | gpio28-31 `blsp_uart6_b` | BT HCI uart by position, see section 8 | L3867 |
| `serial@0c16f000` | 0xc16f000 | disabled | | | L3558 |
| I2C common | `qcom,i2c-msm-v2`, clk-freq-out 400000, clk-freq-in 19200000 (0x124f800), BLSP1 master-id 0x56, BLSP2 0x54, sps-dma phandles 0x178 (BLSP1, c144000) / 0x18b (BLSP2) | | | | |

## 12. Other HiBy-specific or unusual-vendor nodes

| Compatible | Where | Notes | Line |
|---|---|---|---|
| `hiby,hm100`, `hiby,hm100-codec`, `njw,njw1195a`, `hiby,sound-plat`, `hiby,earpods_adc`, `hiby,sa_sound_switch` | top-level in `/soc` | section 9 | L16565-16698 |
| `hiby,hbc3000_ram` | SPI3 cs0 | section 11 | L12282 |
| `ring-keys` | `/soc` | volume wheel, section 7 | L16544 |
| `cw,cw2015`, `ti,lp5562`, `goodix,gt1x`, `goodix,gt9xx`, `qca,wcn3990` | | sections 2, 5, 6, 8 | |
| `qcom,qpnp-smb2`, `qcom,fg-gen3`, `qcom,qpnp-pdphy`, `qcom,leds-qpnp`, `qcom,qpnp-wled`, `qcom,qpnp-haptic` | PMIC | downstream-only qpnp drivers, no mainline equivalents with these bindings | |
| aliases | | serial0=c170000, serial1=c1b0000, serial2=c16f000, sdhc1/2, spi1-8, i2c1-8 | L16706-16727 |
| chosen | | `bootargs = "rcupdate.rcu_expedited=1"`, `stdout-path = "serial0"` | L16701-16704 |
| pm660 gpios (SID0) enabled with config | pm660 pin2 (master-en 0), pin3 (output, pull 4=down 10 uA, src-sel 2), pin4 (input, vin 1), pin11 (input), pin13 (output, po_pwr_en). Consumers other than pin13 are unresolved (pin2 and pin3 double as ADC inputs `gpio2_adc1`/`gpio3_adc0` L2613-2633) | L2351-2448 |
| pm660l gpios (SID2) enabled | pin3 (output, no pull), pin4 (input), pin6 (output, src-sel 2), pin7 (input, vol_up key), pin8 (output, lp5562 enable). Consumers of 3, 4, 6 unresolved | L2914-2976 |
| Vendor leftovers enabled but irrelevant | `qcom,mdss_dsi_ctrl1`, DP, flash LED, haptic, smb2 DC path, camera/venus etc. | |

## 13. Accelerometer (auto-rotate)

The RS6's G-sensor (Kionix KXTJ2-1009, per HiBy's spec page) is not on any Linux I2C bus.
The Snapdragon Sensor Core inside the ADSP drives it, and Linux reads it over QMI. All the
kernel code is already in the sdm660-mainline tree. The only missing piece was the sensor
registry file.

### How it works

1. The ADSP boots (`qcom_q6v5_pas`). Its remoteproc adds the `qcom_common.sns-reg.N`
   auxiliary device. `qcom_sns_reg` loads `qcom/sensors/sns.reg-hiby,rs6` and serves it as
   QMI service 0x10f (Sensor Registry) on the APSS.
2. The ADSP's Sensor Manager (SMGR) reads its config groups from that service. Then it
   probes the sensors listed in the registry and publishes QMI service 0x100 instance 50
   (SMGR). Without the registry no SMGR service appears, which was Nura's state before the registry file
   was packaged.
3. The QRTR bus turns service 0x100 into a device with modalias `qrtr:100:3201`, so udev
   loads `qcom_smgr`. That driver adds a `qcom-smgr-accel` platform device, which loads
   `qcom_smgr_accel` and creates the IIO device `qcom-smgr-accel`. It has buffer-only
   channels and no trigger. Values are 1/65536 m/s², and `in_mount_matrix` converts SMGR's
   frame to the IIO one.
4. iio-sensor-proxy (3.9 handles buffers without a trigger) tags it `iio-buffer-accel`.
   KWin rotates the screen, because `autoRotation` is `InTabletMode` and Plasma Mobile is
   always in tablet mode.

### Evidence

- This is the SMGR stack, not SEE. The ADSP image has 399 `sns_smgr_*`/`sns_rh_*`/`sns_sam_*`
  strings and no `sns_client`, `sns_suid` or `pb_decode`. The vendor partition ships the
  SMGR-era `libsensor1.so`, `libsensor_reg.so` and `sensors.ssc.so`. Stock ran only
  `sensors.qti` (the registry server); `sscrpcd` is "Only for SLPI" in
  `init.qcom.sensors.sh`. The dsp partition has no sensor modules, so SMGR is static in
  `adsp.mdt`.
- Today's QRTR services on ADSP node 5 are 0x33, 0xf, 0x42, 0x118, 0x132, 0x107, 0x108,
  0x301, 0x1001, 0x2b and 0x18. There is no 0x100. dmesg shows `qcom_sns_reg` failing with
  `-ENOENT` on `sns.reg-hiby,rs6`.
- In the registry (stock `persist:/sensors/sns.reg`, 25468 bytes), group 2690 (SSI SMGR
  cfg, file offset 0x1700) has slot 0 = KXTJ2. Its fields are UUID
  `629d45ef8abb474a8dbc2d309af3d123`, off_to_idle 100000, idle_to_ready 20000, i2c_bus 3,
  reg_group 1000, cal_grp 0, gpio1/gpio2 0xffff (polled, no IRQ), sensor_id 0,
  I2C address 0x0e, data_type 1, sens_default 1, flags 0, vdd 0x83, vddio 0x8e. The axis
  map (group 1000 @0x0a00) is -2, 1, 3. This matches the `:hardware sdm660` block of
  `vendor/etc/sensors/sensor_def_qcomdev.conf` ("SSI SMGR Cfg 0 [ACCEL] KXTJ2"). Slots 1-3
  still hold the QRD's ICM20608, BMM150 and STK3311; SMGR drops whichever doesn't answer.
- The ADSP has a driver for it. All four registry UUIDs appear in the ADSP image's
  driver table (KXTJ2 at blob offset 0x43aaab), next to the `KXCJK`/`KIONIX` info strings.
- "i2c_bus 3" is the ADSP's own sensor QUP, not BLSP1 QUP3. In the sensor PD's DAL
  config, `I2CDRV_I2C_3` has CHIP_BUS_INDEX 2, CHIP_BLOCK_OFFSET 0x437000 (with
  `LPASS_SENSOR_BLSP_QUP0..2`) and LPASS_PLL_SRC_FREQ 99.84 MHz. Its SDA/SCL are DAL GPIO
  configs 0x1c021/0x1c031, which is GPIO 2/3, function 1, on the LPASS TLMM. Linux
  configures neither pin; `lpi_tlmm` only uses 18-26. BLSP1 QUP3's pins (gpio10/11) belong
  to the hm100 bit-bang, and stock left `i2c@c177000` disabled.

### Options

- Kernel SMGR client (`qcom_sns_reg` + `qcom_smgr*`, Yassine Oudjana's v2 series plus
  Alexey Minnekhanov's in-kernel registry server). This one is chosen. It is the same
  route msm8996 scorpio uses (`firmware-xiaomi-scorpio` installs
  `qcom/sensors/sns.reg-xiaomi,scorpio`).
- libssc / iio-sensor-proxy's `ssc-*` drivers don't work here. They speak SEE (protobuf
  over QMI), and this ADSP has no SEE at all. The stock udev rule already tags
  `fastrpc-adsp` as `ssc-light ssc-compass`, and on this boot iio-sensor-proxy exited with
  "No sensors or missing kernel drivers".
- Linux owning the bus with `kxcjk-1013` isn't possible. The bus is a QUP inside LPASS's
  sensor block, clocked from the LPASS PLL. Mainline has no driver for those clocks or
  that QUP, and the ADSP owns them while it runs.

### Packaging

- Nura: `firmware-hiby-rs6` carries `sensors/sns.reg` (the `firmware` branch;
  `tools/make-firmware-tarball.sh` takes it from `persist.bin`, listed in MANIFEST.tsv). It
  installs it as `/usr/lib/firmware/qcom/sensors/sns.reg-hiby,rs6`. The kernel config
  already has `CONFIG_QRTR(_SMD)=m`, `CONFIG_QCOM_SNS_REG=m`, `CONFIG_IIO_QCOM_SMGR=m` and
  `CONFIG_IIO_QCOM_SMGR_ACCEL=m`. iio-sensor-proxy comes with Plasma Mobile. No DT change.
- Arch Linux Ports: the same file at the same path in the firmware package, the same
  kernel options, and `iio-sensor-proxy` from the repos. Nothing here depends on the libc.
- Kernel: "iio: common: qcom_smgr: fix sampling_frequency" in `patches/linux`. `qcom_smgr` ignored a
  written `in_accel_sampling_frequency`, because buffering always used the default rate (highest native, capped by SMGR's max).
  `read_avail` also handed the IIO core a stack array. Both are fixed there. The later SMGR patches
  (default rate, buffering, no reports while the AP sleeps) are described in `docs/suspend.md`.

### Still to check on the device

- On the running RS6 (no reboot), bind `qcom_sns_reg` with the registry, wait for
  `qrtr:100:3201` and read samples; that also shows SMGR's max rate. Then start iio-sensor-proxy and check `monitor-sensor`.
- Orientation. SMGR applies the registry axis map (-2,1,3, the QRD value HiBy kept), and
  the driver's matrix does the rest. Held upright in portrait, iio-sensor-proxy must say
  "normal". If it doesn't, fix it with an `ACCEL_MOUNT_MATRIX` hwdb entry in
  device-hiby-rs6.
- After a reboot, check that KWin follows when iio-sensor-proxy starts
  after the session. The fastrpc-adsp rule starts it at boot, before SMGR is up, and it
  exits.
- Suspend: settled in `docs/suspend.md` (Part 1). Stock tells the ADSP when the AP sleeps
  through the outbound smp2p entry `sleepstate` (remote-pid 2, `qcom,smp2pgpio-sleepstate-out`,
  stock DT). Mainline had no such driver, and with the accel buffer enabled through s2idle SMGR
  kept sending reports and waking the AP about 240 times per second; the series now drives
  `sleepstate` and stops the reports, and the GLINK IRQ counts in /proc/interrupts across a
  suspend are the check.

## TLMM GPIO usage summary

| GPIO | Use | Source |
|---|---|---|
| 2, 3 | I2C1 SDA/SCL (touch) | L11870 |
| 4, 5 | UART console | L9211 |
| 6, 7 | I2C2 (disabled, smb1351) | L11932 |
| 8, 9, 10, 11 | SPI3 / HM100 JTAG (TDI/MOSI, TDO/MISO, TMS/CS, TCK/CLK) | L12275, L16581 |
| 12 | HM100 reset | L16574 |
| 13 | HM100 share-spi-select | L16579 |
| 14 | lineout jack detect | L16664 |
| 15 | vol_pwr_en | L16611 |
| 21 | balance_lo jack detect (also DP aux-sel) | L16654, L16229 |
| 22, 23 | I2C6 (cw2015, lp5562) | L12037 |
| 24, 25, 26, 27 | sec MI2S SCK, WS, SD0, SD1 | L11747-11860 |
| 28 | audio_dc_dc_en (also hm100 ctrl pin, blsp2 uart pin) | L16608 |
| 29 | po_bal_po_sel (also blsp2 uart pin) | L16616 |
| 30, 31 | I2C8 and blsp2 uart pins (conflict) | L12204, L11330 |
| 34 | lpf_sel | L16615 |
| 40 | dac_pwr_en | L16609 |
| 41 | headset jack detect | L16659 |
| 42, 43 | volume wheel (cw, ccw) | L16549 |
| 44 | hm100 jtag-select | L16585 |
| 53 | DSI reset | L16144 |
| 54 | microSD card detect (active low) | L4575 |
| 55 | hm100 power | L16573 |
| 56 | play_pause key (active low) | L16535 |
| 58 | DP usbplug cc (reference leftover) | L16230 |
| 59 | DSI TE (mdp_vsync) | L16145 |
| 61 | lpf_mute | L16619 |
| 63 | wcd gnd/mic swap (output-high) | L10747 |
| 64, 113 | gpio_key pinctrl only, no consumer | L11395 |
| 66, 67 | touch reset, irq | L11907-11908 |
| 68-71 | hm100 ctrl pinctrl only, no consumer property | L11714 |
| 72 | balance jack detect | L16649 |
| 76 | line_mute (also DP aux-en) | L16620, L16228 |
| 77 | njw1195a pinctrl only | L10415 |
