# System suspend (s2idle) and VDD min on the RS6

What kept the RS6 from sleeping properly in `s2idle` on the mainline-based kernel, and what the
patch series changes. Two problems, in this order:

1. The SoC woke about 240 times per second while "asleep", and the buddy hardlockup detector
   reported lockups on CPUs that were simply in s2idle.
2. With that fixed, the SoC slept for minutes but never reached VDD min (the RPM `vmin` counter
   stayed 0), because the application processor (APSS) kept sleep-set votes that hold the XO.

Patch numbers are `patches/linux/NNNN-*.patch` on the `main` branch (94 patches on sdm660-mainline
`qcom-sdm660-7.2.y`). rNN is the `linux-postmarketos-qcom-sdm660` package revision that ran on the unit;
r29 is exactly the published series, earlier ones lacked part of it. Evidence tags: "static" = read from a binary, config or source tree,
"confirmed" = seen on the unit.

## Contents

- [Status](#status) and [reading the RPM sleep stats](#reading-the-rpm-sleep-stats)
- [Part 1: wakeups and hardlockup reports](#part-1-wakeups-and-hardlockup-reports)
- [Part 2: reaching VDD min](#part-2-reaching-vdd-min)
- [CPU bandwidth: BWMON and the DDR floor per frequency](#cpu-bandwidth-bwmon-and-the-ddr-floor-per-frequency)
- [Stock reference: MPM and mdss_ahb_clk](#stock-reference-mpm-and-mdss_ahb_clk): system-level idle, wakeup,
  the vMPM timer and the `mdss_ahb_clk` suspend warning, stock against the series
- [How to check](#how-to-check) and [open items](#open-items)

## Status

Confirmed on the unit:

- r29 is the published series (tip: patch 0094). One `rtcwake -m freeze -s 60`: `qcom_stats` vmin
  Count 0 -> 4, Accumulated Duration 1172968545 ticks of 19.2 MHz (61.1 s, the whole sleep). vlow
  stayed 0.
- Same run: `qcom-clk-smd-rpm` `state_synced` 1, the CLKREF clock under `ln_bb_clk1_a` in
  `clk_summary`, `rf_clk1_pin` 1/1 while Wi-Fi is up, Wi-Fi linked right after resume and scanning,
  no new dmesg errors and no "Failed to set bw" / "Failed to set required opps".
- r27 (wakeup and lockup fixes in, vmin work not yet): two `rtcwake -m freeze -s 300` runs, one
  with the charger plugged in and one unplugged. Each was one uninterrupted sleep (`sleep_time` bin
  256-512 s +1, `power-domain-system` S2idle +1), woken by the RTC. ADSP glink interrupts over the
  whole window: 872 and 1731, all in the 30 to 55 s of awake time around the sleep. No hard LOCKUP
  reports, `hardlockup_count` 0. vmin stayed 0 in both, which started the second investigation.

Not measured: see "Open items".

## Reading the RPM sleep stats

`qcom_stats` (debugfs `qcom_stats/`) reads the RPM data RAM at 0x290000; the stats offset is the low
16 bits of the word at +0x14, the same place the stock kernel's `qcom,rpm-stats` uses (static). The
records are `vlow` (XO shutdown, "xosd") and `vmin` (XO shutdown plus CX and MX at retention). The
Accumulated Duration is in 19.2 MHz ticks: seconds = value / 19200000. In the r29 run vmin counted
and vlow did not; whether the two are exclusive on this RPM is not known, so read vmin.

"Client Votes" is not a mask of current voters but a history of per-subsystem XO votes, one byte
each. The bit to master mapping is undocumented, so it is not decoded.

The RPM also keeps per-master stats (`APSS MPSS ADSP CDSP TZ`, the `qcom,rpm-master-stats@778150`
block of the stock DT). sdm630.dtsi has no node for them. They were read with a debug module that is
not published. Results (confirmed):

- The APSS does send the system-level sleep: after one 60 s freeze, APSS shutdowns 0 -> 1,
  `power-domain-system` usage 0 -> 1, cluster0/1 L2 power collapse 0 -> 1. That is PSCI state
  `0x42000343` (see [When stock requests system-pc](#when-stock-requests-system-pc-0x42000343)). genpd "Time(ms) 0" for system-pc is s2idle accounting
  with timekeeping frozen, not a missing request.
- The APSS `xo_count` stayed 0: while the APSS slept, its sleep-set votes still needed the XO.
  MPSS, ADSP and CDSP release the XO on their own most of the time, and TZ's counter stays 0 even
  when vmin works. Nothing to fix on the DSP side.

Prerequisites already in the series (stock side in [Stock reference](#stock-reference-mpm-and-mdss_ahb_clk)): 0023 (L2 SAW AVS setup), 0024
(program the vMPM wakeup timer before sleep, "never" for system suspend), 0025 (in s2idle the genpd
governor reports KTIME_MAX as `next_hrtimer`).

## Part 1: wakeups and hardlockup reports

Symptom (r26): one s2idle of 2562.8 s ended with `Watchdog detected hard LOCKUP on cpu N` lines
every 12.597 s of kernel time; a suspend with less than about 12.6 s of awake kernel time logged none.

### Cause 1: the ADSP streamed the accelerometer into a sleeping AP (confirmed)

- The SoC woke about 240 times per second: `power-domain-system` counted 1,082,669 system-pc
  requests (614,300 succeeded, 468,369 refused by PSCI and retried; 614,300 / 2562.8 s = 239.7/s)
  and `/sys/kernel/debug/sleep_time` had 1,122,330 entries in the `0 - 1 s` bin and none above. There
  was no long quiet sleep.
- The source was the ADSP glink interrupt (`glink-smem`, GIC SPI 157), 240.1/s on an idle device.
  It is `IRQF_NO_SUSPEND`, so it runs in s2idle but is not a wake IRQ: the machine goes back to
  sleep every time and `suspend_stats` / `wakeup_sources` show nothing.
- The traffic was `qcom-smgr-accel`: buffer enabled by iio-sensor-proxy, 200 Hz, one SMGR report per
  sample. `qcom_smgr` never told SMGR that the AP was suspending and had no suspend handling.
- Stock does it differently (static). The stock `smp2p_sleepstate` driver drives the outbound SMP2P
  entry `"sleepstate"` to the ADSP: BIT(12) = "AP awake", cleared on `PM_SUSPEND_PREPARE`, set on
  `PM_POST_SUSPEND`, each followed by `msleep(25)`. The ADSP sensor code reads it. The stock sensors
  HAL (`SMGRSensor::SMGRPrepareAddMsg`) sets `notify_suspend` on every buffering request with
  `proc_type 0` and `send_indications_during_suspend` = the sensor's wakeup flag, so the
  accelerometer sends nothing while the AP sleeps.

### Cause 2: the buddy hardlockup detector does not know about s2idle (confirmed)

- `tick_freeze()` shuts down the tick of every CPU except the last, which suspends timekeeping. With
  CPU0 and CPU5 cycling through freeze and unfreeze 240 times per second, monotonic time and
  sched_clock advanced only in the awake slices (122.6 s of kmsg time over 2562.8 s). CPU1-4, 6 and
  7 never woke and their watchdog hrtimers never ran.
- CPU0's hrtimer fires about every 4.2 s of that awake time and checks its buddy CPU1. Three misses
  (`watchdog_hardlockup_miss_thresh`, so about 12.6 s) produce a report. The backtrace shows
  `cpuidle_enter_s2idle`, where an idle s2idle CPU sits. The reports were false positives.
- Nothing in the tree or upstream handled s2idle in the detector; `touch_nmi_watchdog()` is a
  one-shot flag and is not enough.

### Fix A: stop the stream while the AP sleeps (0051 to 0058, 0070 to 0072)

- 0051 `dt-bindings: soc: qcom,smp2p: add sleepstate support` (Richard Acayan, Acked-by Krzysztof
  Kozlowski), 0053 `arm64: dts: qcom: sdm630: add the ADSP sleepstate SMP2P entry` (SoC level, as
  stock's sdm660 DT).
- 0052 `soc: qcom: smp2p: tell the remote through "sleepstate" when the AP sleeps`: stock's bit,
  polarity and delay. The bit is set at setup, cleared by a PM notifier on `PM_SUSPEND_PREPARE`, set
  again on `PM_POST_SUSPEND`.
- 0057 `iio: common: qcom_smgr: no sensor reports while the AP is suspended`: every buffering ADD
  sends `notify_suspend` (`proc_type` APPS, no indications during suspend), as stock does for a
  non-wakeup sensor. A PM notifier at priority 1 deletes the report of every streaming sensor before
  the smp2p notifier says "asleep"; one at priority -1 adds them back after it says "awake". The IIO
  buffers stay enabled. These are PM notifiers, not `dev_pm_ops`, because device suspend callbacks
  run after `PM_SUSPEND_PREPARE`, when the bit already says "asleep", and nothing shows whether SMGR
  answers requests then. The -1 notifier also marks the suspend as armed so an aborted suspend, where
  it would not hear `PM_POST_SUSPEND`, still gets its reports back. A mutex serialises the requests
  with the streaming and suspend state.
- 0054 `fix the QMI layouts of the buffering messages` (static, against the stock `libsensor1.so`
  IDL tables): the notify-suspend TLV is a u32 plus a u8, a buffering indication has an array of up
  to 5 index entries and up to 100 samples of `{s32 data[3], u16 timestamp_offset, u8 flags,
  u8 quality}`, and the largest message is 0x68c bytes. The old receive buffer (0x110) would have cut
  off a report of more than about 14 samples. Timestamps follow the stock HAL (index timestamp plus
  the sum of offsets).
- 0055 `default to the lowest native rate from 15 Hz` instead of the highest (200 Hz). iio-sensor-proxy
  only raises rates below 10 Hz, and Android rotates from SENSOR_DELAY_UI (66.667 ms).
- 0056 `check the AckNak of buffering responses` (the driver only looked at the QMI result). Rules as
  the stock HAL's `processBufferingResp`: ACK_SUCCESS and ACK_MODIFIED pass, anything above is a
  refusal. A refused rate falls back to the default, each native rate, then the maximum, and keeps
  the first SMGR takes. 0070 accepts NAK_REPORT_ID on an ADD as stock does, 0071 reduces the fallback
  to one info line instead of up to 35 warnings, 0072 undoes the probe on every failure in order.
- 0058 `batch samples up to the buffer watermark`: up to the IIO watermark per report, limited to
  what SMGR can buffer for the sensor and 100 per report. Where SMGR buffers nothing, a report is one
  sample, as in the stock HAL.

### Fix B: the detector skips CPUs whose tick is frozen (0059)

`watchdog/hardlockup: skip CPUs whose tick is frozen for s2idle`:

- A per-CPU flag is set in `tick_freeze()` and cleared in `tick_unfreeze()`, which also touches the
  CPU like `arch_touch_nmi_watchdog()`.
- `watchdog_hardlockup_check()` resets the counters of a frozen target and returns, but only while
  `pm_suspend_in_progress()`. After the thaw a CPU needs the usual number of missed checks (3 for
  buddy) before it is reported, so a real lockup is still caught.
- The flag is set and cleared by the CPU itself under `tick_freeze_lock`, around the window in which
  its tick is off. A CPU stuck in PSCI keeps the flag but it stops counting once the suspend state
  returns to `PM_SUSPEND_ON`, so it is reported after resume. Accepted gap: not reported while the
  suspend is still in progress.
- Nothing is disabled (`watchdog_hardlockup_enable()` / `disable()` and the cpumask are untouched).
  The tree is buddy only. No upstream posting for this was found.

## Part 2: reaching VDD min

With the wake storm gone the sleeps were clean (r27) but vmin stayed 0, also with the cable out, so
USB was not the reason. The question became which APSS sleep-set vote holds the XO.

### Which votes hold it (confirmed, debug module)

On r27 a debug module zeroed selected APSS sleep-set RPM votes in `suspend_late` and restored them
in `resume_early`. Bits: 0 to 4 the interconnect bus clocks (BIMC, SNOC, CNOC, MMAXI, AGGRE2), 5 to
11 the rpmcc clocks nobody prepares (LN_BB_CLK1/2/3, RF_CLK1, DIV_CLK1, CE1, IPA), 12 `bi_tcxo`.

| Votes zeroed | Sleep | vmin Count | APSS xo_count |
|---|---|---|---|
| none (r27 as is) | 60 s | 0 -> 0 | 0 -> 0 |
| bits 0 to 12, everything | 60 s | 0 -> 3, 60.4 s accumulated | 0 -> 1, 60.4 s |
| everything except `bi_tcxo` | 40 s | 0 -> 0 | 0 -> 0 |
| bus clocks only | about 20 s, cut short | 3 -> 3 | 1 -> 1 |

With every APSS sleep vote released the SoC sits in vmin for the whole suspend (3 entries because the
other masters wake it now and then). Without the `bi_tcxo` release it never does. The last row was cut
short and is not evidence. `bi_tcxo` alone and everything-but-the-buses never ran, so which votes are
individually necessary was not bisected on the unit. Blockers 3 and 4 were found statically from r28
dumps, and r29 as a whole reached vmin. r28 had blockers 1 and 2 fixed and was still at 0.

### Blocker 1: `bi_tcxo` stayed prepared (0079, 0080)

`clk-smd-rpm` votes in `.prepare`: a prepared non-active-only RPM clock votes 1 in the sleep set, and
`bi_tcxo` is the parent of every MMCC clock fed from the XO. The clock tree at `machine_suspend`
(`clk_summary` plus clk tracepoints replayed up to the suspend) showed two paths to it:

- `video_core_clk_src`, enabled and prepared with no consumer. It is `CLK_IS_CRITICAL` in
  `mmcc-sdm660.c`, nothing records why, it only feeds Venus, and it is not critical on MSM8996 or
  MSM8998. 0079 `clk: qcom: mmcc-sdm660: Do not keep the video core clock always on` (Fabricio Akio)
  drops the flag.
- `mdss_ahb_clk` (under `ahb_clk_src`), prepared with the display off and every MDSS user
  runtime-suspended. The holder is the DSI PHY: `pm_clk_add(dev, "iface")` prepares the clock, and
  `pm_clk_suspend()` only disables it, since unpreparing is limited to clocks whose prepare already
  enables them (`clk_is_enabled_when_prepared()`), which a branch clock is not. 0080 `drm/msm/dsi: fix
  AHB clock staying enabled across suspend` (Arpit Saini, Qualcomm) unprepares it in `suspend_late` and
  prepares it in `resume_early`, with `DPM_FLAG_NO_DIRECT_COMPLETE`. It was posted and tested on an
  RPMh SoC. On this SMD-RPM SoC the unprepare ends in an RPM write in that phase; 13 RPM writes from
  `suspend_late` and 13 from `resume_early` all returned 0 (confirmed, debug module).

A code audit of the other holders under `bi_tcxo` (DPU, DSI, MDSS, the MMSS SMMU, icc-rpm interface
clocks, Venus) found nothing still prepared at `machine_suspend` once these two are in (static). The
related MNOC AHB ordering fix is in [mdss_ahb_clk in system suspend](#mdss_ahb_clk-in-system-suspend).

### Blocker 2: interconnect votes stuck at INT_MAX (0078, 0076, 0077)

The interconnect core starts every node at INT_MAX and only lowers it in `icc_sync_state()`, which the
SDM660 provider never hooked up (confirmed: every node in `interconnect_summary` read 2147483647). BIMC,
SNOC, CNOC, MMSS AXI and A2NOC sat at maximum in the sleep set too.

- 0078 `interconnect: qcom: sdm660: Enable keep_alive and sync_state` (Fabricio Akio) hooks up
  `icc_sync_state()` and enables `keep_alive` (a 19.2 MHz active-only floor, sleep set left free). On
  a Moto X4 it takes the screen-off battery current from 117 mA to 68 mA. The bus-clocks-only row
  shows it alone does not release the XO, but it is the same class of stale sleep vote.
- 0076 `Add interconnect paths to the BLSP I2C and SPI controllers` (Fabricio Akio) and 0077 (the
  RS6 board's `blsp_spi3`, which the hm100 loader uses; stock votes `qcom,master-id = <86>` for it).
  With the boot-time INT_MAX votes gone, a QUP DMA transfer needs its own path or it can run with the
  buses at their sleep-set vote as the SoC enters system sleep. Fabricio saw an I2C transfer hang the
  SoC without the paths, and 5,000 transfers through about 3,000 sleep entries with them.

Providers' `sync_state` waits for every `interconnects` consumer to probe; if one never does, all NoCs
stay at INT_MAX without a dmesg error.

### Blocker 3: the GPU kept 1.2 GB/s of DDR voted in the sleep set (0094)

After blockers 1 and 2, r28's `interconnect_summary` had one non-zero `RPM_ALWAYS_TAG` request:
`5000000.gpu` peak 1200000 on `mas_oxili` and `slv_ebi`, with the GPU runtime-suspended (confirmed).

`disable_clk()` in `msm_gpu.c` parks the core clock with `dev_pm_opp_set_rate(dev, 27000000)`, which
selects one of the lowest OPPs. On SDM660 both carry `opp-peak-kBps = <1200000>` and nothing removes
the vote until resume, so BIMC stayed at about 300 MHz in the sleep set. On r27 this was hidden
because every NoC was at INT_MAX anyway. Stock votes 0 while the GPU sleeps (static): `_slumber` ->
`kgsl_pwrctrl_disable` -> `kgsl_pwrctrl_axi(0)` -> `kgsl_pwrctrl_buslevel_update(false)` sets bus
level 0 for the `grp3d` client, and the `qcom,gpubw` devbw is active-only with a 0 first entry.

0094 `drm/msm/gpu: Remove the bus vote when the GPU is suspended` calls `dev_pm_opp_set_opp(dev, NULL)`
at the end of `disable_clk()`, as the a6xx GMU and GMU wrapper suspend paths already do. It drops the
bandwidth and the parked OPP's required-opps; the next `dev_pm_opp_set_rate()` on resume programs both
again.

### Blocker 4: rpmcc handoff votes nobody takes back (0093, 0090 to 0092)

`clk_smd_rpm_handoff()` votes every RPM clock at 1 / INT_MAX in both sets at probe and does not mark it
enabled. There is no `.is_prepared`, so `clk_disable_unused()` never touches these clocks. A clock and
its `_a` peer share one RPM resource, and a prepare or unprepare of either rewrites both sets, so the
handoff vote disappears once a consumer has used the pair. A pair nobody prepares keeps it for the
life of the boot: on SDM660 `ln_bb_clk1/2/3` and `rf_clk1` (software enable), the `ln_bb_clk1/2/3`
pin-control votes, `div_clk1` and `ce1`. XO buffers voted on keep the XO on.

Upstream sees the same: Imran Shaik, "clk: qcom: smd-rpm: Skip proxy votes on clocks for QCM2290"
(2026-09), where Stephan Gerhold suggested sending a "disable" for unclaimed clocks after `sync_state`.
Brian Masney's "clk: implement sync_state support" is the generic version, still under review.

Stock avoids it through the msm-4.4 clock framework (static): every RPM clock is registered with
`CLK_ENABLE_HAND_OFF`, the probe prepares each one, and `clk_disable_unused()` unprepares what nobody
claimed, writing the peer's vote (0 if unused) to both sets. Stock does not register the sleep-set
`ln_bb_clk1` at all; `ln_bb_clk1_ao` is its only LN_BB_CLK1 clock.

0093 `clk: qcom: smd-rpm: Drop the handoff votes nobody claimed at sync_state` adds a `sync_state` that,
under the driver lock, sends 0 to the active and sleep set of every pair where neither clock is
enabled. It uses `sync_state` rather than `late_initcall` so modular consumers (`ath10k_snoc`) have
claimed their clocks first; if a consumer never probes, nothing is dropped. It is generic for every
rpmcc SoC.

LN_BB_CLK1 needs a real consumer first. The SDM660 CLKREF branches (RX0/RX1 USB2, USB3, UFS) gate the
reference on the CXO2 pad, which LN_BB_CLK1 drives; stock's QUSB2, QMP USB3, UFS and DP PLL all take
`ref_clk_src` = `ln_bb_clk1_ao` (static). In mainline they were parentless root clocks, so the USB2
PHY's reference rested on the handoff vote alone.

- 0090 `dt-bindings: clock: qcom,gcc-sdm660: Add the CXO2 input` (optional third clock).
- 0091 `clk: qcom: gcc-sdm660: Fix parent for CLKREF clocks`: parent "cxo2", "xo" as global-name
  fallback so an old DT behaves as before (same pattern as the MSM8996 fix by Bjorn Andersson).
- 0092 `arm64: dts: qcom: sdm630: Feed the GCC CLKREF clocks from LN_BB_CLK1`: wired to the active-only
  `RPM_SMD_LN_BB_A_CLK`, as stock does.

What 0093 drops, and why nothing breaks (static unless noted):

| RPM pair | Stock consumer | After the series |
|---|---|---|
| `ln_bb_clk1` / `_a` | QUSB2, SS PHY, UFS PHY, DP: `ln_bb_clk1_ao` | `gcc_*_clkref_clk` -> `cxo2` = `ln_bb_clk1_a`, prepared by the USB2 PHY while powered |
| `ln_bb_clk1/2/3_pin` | none | none |
| `ln_bb_clk2` | `audio_ext_clk_lnbb`, only a WCD934x codec the RS6 lacks | none |
| `ln_bb_clk3` | none | none |
| `rf_clk1` (software enable) | none (icnss and BT use `rf_clk1_pin`) | none |
| `div_clk1` | `audio_ext_clk`, disabled | none |
| `ce1` | crypto voter clocks, only while crypto runs | none (no crypto node in sdm630.dtsi) |

Left alone because a consumer holds or rewrites them: `bi_tcxo`/`bi_tcxo_a`, `pcnoc`, `ipa`, `qdss`,
`rf_clk1_pin`/`rf_clk1_a_pin`. The RS6 audio path (q6afe I2S to the hm100 FPGA DAC) uses no rpmcc
clock. `ath10k_snoc` holds `rf_clk1_pin` while the firmware is powered and releases it in
`ath10k_hw_power_off`, as stock's icnss does; 0093 only matters in the boot window before ath10k first
binds, and `sync_state` waits for the Wi-Fi node before dropping anything (confirmed on r29: `rf_clk1_pin`
1/1, Wi-Fi works after resume).

## CPU bandwidth: BWMON and the DDR floor per frequency

With the providers synced (0078), BIMC runs at what consumers vote, down to the 19.2 MHz floor, and the
CPUs vote nothing. Stock scales DDR for the CPU through two active-only clients (static): the bandwidth
monitor (`qcom,bimc-bwmon4` at 0x01008000 and 0x01001000, SPI 183, driving the `cpubw` devfreq device)
and `mincpubw`, which maps CPU frequency to a DDR floor. Both are active-only, so they drop out of the
RPM sleep set when the APSS power-collapses, which is what vmin needs. The patches port both the
mainline way and keep that property.

- 0081 `arm64: dts: qcom: sdm630: Switch the NoCs to two interconnect cells`: all six NoCs
  `#interconnect-cells = <2>`, every existing path `RPM_ALWAYS_TAG` (icc-rpm already maps tag 0 to
  ALWAYS, so no vote changes). The tag cell is what allows an active-only vote.
- 0082 `interconnect: qcom: icc-rpm: Allow negative QoS offset` (Konrad Dybcio, from the MSM8998
  interconnect series) and 0083 `Start the BIMC region after the CPU BWMON`. The BWMON v4 registers
  are the first 0x300 bytes of the BIMC block and BIMC QoS port 0 starts at 0x01008300. Both icc-rpm
  and icc-bwmon request their MMIO regions, so with BIMC at `<0x01008000 0x78000>` the bwmon probe
  could not map its registers. BIMC now starts at 0x01008300 with `.qos_offset = -0x300`, so every BKE
  register keeps its absolute address. DT and driver change together: either half alone writes the BIMC
  QoS settings 0x300 bytes off.
- 0084 `dt-bindings: interconnect: qcom,msm8998-bwmon: Add SDM660 CPU BWMON`
  (`qcom,sdm660-cpu-bwmon`, falling back to `qcom,msm8998-bwmon`) and 0085 `Add the CPU BWMON`: monitor
  0x01008000/0x300, global 0x01001000/0x200, SPI 183, path APSS -> EBI with `RPM_ACTIVE_TAG` on both
  ends so the vote lands only in the RPM active set.
- OPP table of 0085: stock's `qcom,bw-tbl` (MiB/s) 762 1144 1571 2086 2597 2929 3879 4943 5163 5931
  6881. It starts at 762 because stock's post-boot script sets cpubw `min_freq` 762. Stock's devbw votes
  `ib = MiB/s * 2^20`, and msm_bus and icc-rpm both divide the peak by the 4-byte EBI width to get the
  BIMC rate, so each OPP is `MiB/s * 1048576 / 1000` kB/s, the same RPM request: 799014 kB/s (about
  199.8 MHz) up to 7215251 kB/s (about 1803.8 MHz). The GPU OPPs use the same convention (MHz * 4000).

The bwmon reacts one 4 ms window after the traffic, so stock also raises DDR with the CPU clock:
`mincpubw` with the `cpufreq` governor, `cpu-to-dev-map-0` for the little cluster and `cpu-to-dev-map-4`
for the big one, vote = maximum over all CPUs, a frequency taking the first map entry at or above it
(checked by disassembling the stock `devfreq_cpufreq_get_freq`, static). Mainline form: `interconnects`
on the CPU nodes (0088), `opp-peak-kBps` in the CPU OPP tables (0086 binding, 0089 values), voted by
qcom-cpufreq-hw from `->target_index()`, active-only.

| Cluster | OPP (MHz) | Stock floor (MiB/s) | opp-peak-kBps |
|---|---|---|---|
| pwrcl | 300, 633.6 | 762 | 799014 |
| pwrcl | 902.4, 1113.6, 1401.6 | 1571 | 1647312 |
| pwrcl | 1536, 1747.2, 1843.2 | 2929 | 3071279 |
| perfcl | 300, 1113.6 | 762 | 799014 |
| perfcl | 1401.6 | 2086 | 2187329 |
| perfcl | 1747.2 | 2929 | 3071279 |
| perfcl | 1958.4, 2150.4 | 3879 | 4067426 |
| perfcl | 2208 | 6881 | 7215251 |

Every floor is also a bwmon OPP, so the two votes compare 1:1. 0087 `cpufreq: qcom-hw: Vote the
bandwidth of the starting frequency` closes a gap: `__cpufreq_driver_target()` returns early when the
target equals `policy->cur`, so a cluster whose governor keeps asking for the frequency the OSM already
runs at (performance at the top, or schedutil under steady full load from boot) never voted. The driver
now votes the bandwidth of the frequency in the OSM perf-state register once the OPPs are in. CPU
devices set only `of_node`, so fw_devlink makes no links for them and the providers' `sync_state` does
not wait on CPUs (static, 7.2.3 source).

Not ported: stock's `memlat` (latency-driven floors), and stock's `io_percent 85` / `up_scale 250`
headroom on the bwmon vote. If latency-bound work is slower than with all buses at INT_MAX, look there.

## Stock reference: MPM and mdss_ahb_clk

How the stock kernel (firmware 1.80, slot B) handles MPM system idle and the `mdss_ahb_clk` suspend
warning, and how the series compares. Source: stock kernel #16 (slot B), imported into Ghidra, symbols from
kallsyms (vmlinux-to-elf). Everything below was decompiled in Ghidra (Dump.java)
or read as data from the slot B `Image`. Struct offsets come from the
decompiled code. Addresses are kernel virtual addresses.

### MPM and the system (CCI) level

#### When stock requests system-pc (0x42000343)

Call chain (idle): `lpm_cpuidle_enter` @ ffffff80089c2690
-> `cluster_prepare(cluster, cpumask, cpu_idx, from_idle=1, now)` @ ffffff80089c1648
-> recursion into the parent cluster -> `psci_enter_sleep` @ ffffff80089c2424.
`cluster_select` and `cluster_configure` are inlined into `cluster_prepare`.

`cluster_prepare`, per level of the tree:

1. Returns at once if `child_idx < cluster->min_child_level` (+0x6d0).
2. ORs the CPU mask into `cluster->child_cpus` (+0x700), and into the vote
   mask (level +0x60, stride 0xd0) of every level whose `min_child_idx` is
   <= `child_idx`.
3. Unlocks and returns unless `child_cpus == num_children_in_sync` (+0x6f8),
   so only the last CPU of the cluster gets past this point (last man).
4. Selection (inlined `cluster_select`): a level is a candidate only if its
   vote mask equals `child_cpus`, the latency and residency limits hold, and,
   for a `notify-rpm` level, `msm_rpm_waiting_for_ack()` is false. During
   suspend, an idle-path `notify-rpm` level is skipped.
5. If the chosen level has `notify-rpm` (+0xa0): `get_cluster_sleep_time()`,
   then `msm_rpm_enter_sleep(0, nextcpu mask)`, then `msm_mpm_enter_sleep()`
   (see [vMPM timer](#vmpm-timer)). Then `cpu_cluster_pm_enter`, and `last_level` is set.
6. Recurses into the parent with this cluster's whole `child_cpus` and the
   chosen level index.

For the system node (stock DT `qcom,pm-cluster@0` label "system"),
system-pc has `qcom,min-child-idx = <3>`, `qcom,notify-rpm` and
`qcom,is-reset`. So a cluster's CPUs count toward the system-pc votes only
when that cluster picked L2 PC (index 3). The system level is evaluated only
when all 8 CPUs are in the system's `child_cpus`. So **yes: stock asks for
system-pc only as the very last CPU, with the other cluster already down in
L2 PC.** The other cluster's last CPU made its own PSCI call earlier, with
only its cluster bits, because `get_cluster_id()` adds the system bits only
once the system's `child_cpus` is complete.

Parameter composition (`psci_enter_sleep`, Ghidra listing at
ffffff80089c24b8..24e0):
`state = ((affinity_count & 3) << 24) | (cpu_level.is_reset << 30) | cpu_level.psci_id | get_cluster_id()`.
`get_cluster_id` @ ffffff80089c2374 walks to the root and, for each node
whose `last_level != default_level`, ORs `(psci_mode_mask & level.psci_mode) << psci_mode_shift`
and increments the affinity count. On the last CPU: CPU PC 3 | is_reset
0x40000000 | L2 PC (4 << 4) | system-pc (3 << 8) | affinity 2 << 24 =
**0x42000343**, which is the value the series puts in `system_pc`.

Mainline ordering (series DT: cpu PDs -> cluster_pd0/1 -> system_pd -> mpm):

- `genpd_power_off()` powers the child off first, then calls the parents. The
  cluster domain is chosen before system_pd, and system_pd before the MPM
  `power_off`, all on the last CPU before `psci_cpu_suspend_enter`. Stock
  has the same order: cluster level, then system level with the RPM/MPM
  notify, then the PSCI call.
- `psci_pd_power_off()` overwrites the per-CPU domain state rather than
  ORing it. The topmost domain's `arm,psci-suspend-param` is used whole, so
  0x42000343 is the full stock value. Matches.
- Stock's min-child-idx=3 rule has no direct genpd equivalent: genpd powers
  off system_pd when both cluster PDs are off, in any state. The residency
  argument in the sdm660.dtsi comment holds, because `cpu_power_down_ok()`
  evaluates system_pd over all CPUs' stored `next_hrtimer`. If cluster B
  picked a state shallower than L2 PC at t0 because of residency, then at a
  later t1 the system's idle window is shorter still, and system-pc needs
  more residency+entry latency (15338+10831 us) than L2 PC. The same holds
  for a latency-QoS limit, since system_pd includes every CPU's constraint.
  The one gap is a QoS limit that gets relaxed while cluster B sleeps:
  B stays shallow and system-pc can still be picked. Stock's vote mask
  forbids that. Rare, but it is a semantic difference.

Stock behaviour that mainline does not reproduce at the system level:

- `msm_rpm_waiting_for_ack()` @ ffffff800850d344 (RPM wait list not empty)
  vetoes every `notify-rpm` level. Mainline `qcom_smd_rpm` waits for ACKs
  synchronously, so all CPUs can idle with a request in flight, and nothing
  stops system-pc then.
- `msm_rpm_enter_sleep()` @ ffffff800850c3b4 masks the RPM SMD/GLINK RX
  interrupt (`smd_mask_receive_interrupt(ch, 1, cpumask)`) and flushes the
  dirty sleep-set requests. `msm_rpm_exit_sleep()` @ ffffff800850b278 drains
  the sleep ACKs and unmasks. Mainline sends sleep-set votes immediately, so
  the flush has no equivalent need, but the RX-interrupt mask has no
  equivalent at all.
- Dynamic wake routing: `msm_mpm_enter_sleep` calls
  `__irq_set_affinity(mpm_irq, nextcpu)` (stock DT has no
  `qcom,disable-dynamic-int-routing`), so RPM's wake SPI lands on the CPU
  with the earliest timer. Mainline leaves SPI 171 on its default CPU. That
  costs an extra CPU wake, not correctness: the broadcast timer still wakes
  the right CPU once the counter runs again.
- If `mbox_send_message()` fails in `mpm_pd_power_off()`, system_pd has
  already stored 0x42000343, so the CPU enters system-pc with RPM never
  notified. Stock bails out of the level when `msm_rpm_enter_sleep` fails.
  With `knows_txdone` and an immediate `mbox_client_txdone()` the queue
  cannot fill, so this is theoretical.

#### Wakeup: SPI 171 and `msm_mpm_exit_sleep`

`msm_mpm_dev_probe` @ ffffff800854cb78 requests the vMPM IPC interrupt
(DT `<0 0xab 1>`, SPI 171) with `devm_request_threaded_irq(..., msm_mpm_irq, NULL, 0x4001 = IRQF_NO_SUSPEND | IRQF_TRIGGER_RISING, ...)`
and calls `irq_set_irq_wake(irq, 1)`. `msm_mpm_irq` @ ffffff800854c918 is
`return IRQ_HANDLED;` and does nothing else. The interrupt exists only to be
taken. Stock also re-targets it to the next-waking CPU before every system
sleep (above), which only makes sense if RPM raises it to wake the AP. So
stock clearly expects RPM to raise SPI 171 on wakeup. The RPM firmware
itself is not in this kernel, so that last step is inferred, not read.

`msm_mpm_exit_sleep(from_idle)` @ ffffff800854d9d8, called from
`cluster_unprepare` @ ffffff80089c135c (after `msm_rpm_exit_sleep` and
`lpm_wa_cx_unvote_send`, IRQs still off):

```
mask = from_idle ? msm_mpm_enabled_irq : msm_mpm_wake_irq;
for each bank i:
    pending = vMPM STATUS[i] & mask[i];          /* vMPM word i + 4*n + 2 */
    for each set bit k:
        irq = msm_mpm_irqs_m2a[32*i + k];
        desc = irq_to_desc(irq);
        if (irq && desc && !(desc->irq_data.common->state & IRQD_LEVEL))
            irq_set_irqchip_state(irq, IRQCHIP_STATE_PENDING, true);
```

So yes, it reads STATUS and replays **edge** wakeups (level ones are skipped)
as pending state. Mainline `qcom_mpm_handler()` (SPI 171) does the same:
STATUS & ENABLE, skip level, `irq_set_irqchip_state(PENDING)`. **No
mainline change is needed for the replay.** The differences: stock replays
synchronously in the idle exit path, mainline when SPI 171 is taken.
Stock masks with its shadow enabled/wake bitmaps, mainline with the vMPM
ENABLE register. Under `IRQCHIP_MASK_ON_SUSPEND` only wake IRQs stay
enabled in s2idle, which equals stock's `msm_mpm_wake_irq`.

GPIO pins: the replay is a no-op on both kernels.

- Stock: `msm_mpm_enable_irq_exclusive` @ ffffff800854cf98 stores the GPIO's
  Linux IRQ in `m2a`. The TLMM `msm_gpio_irq_chip` @ ffffff800a061590 has
  only ack/mask/unmask/set_type/set_wake (+0xe0 `irq_set_irqchip_state` is
  NULL), and the 4.4 TLMM domain is not hierarchical. Stock's
  `irq_set_irqchip_state` @ ffffff800810b4d4 walks `chip+0xe0` and then
  `parent_data`, and returns -EINVAL.
- Mainline: `msm_gpio_irq_chip` has no `irq_set_irqchip_state`,
  `qcom_mpm_chip` has none, and a GPIO-only MPM pin's parent level is
  disconnected (`irq_domain_disconnect_hierarchy`), so this also returns
  -EINVAL.

Both kernels therefore rely on TLMM latching the GPIO edge itself. Both
leave the TLMM interrupt configured for MPM-routed GPIOs: stock's
`msm_gpio_irq_*` program TLMM and then call the MPM extension hooks;
mainline does not set `skip_wake_irqs` for MPM, because
`irq_domain_qcom_handle_wakeup()` only tests the PDC flag. The TLMM intr
config is the same on both, so GPIO wake behaviour matches stock. Whether
TLMM really latches during vdd_min is a hardware fact; stock depends on it
just as much.

#### vMPM timer

`cluster_prepare` (system level, `notify-rpm`):
`us = get_cluster_sleep_time(..)`, which is `(min next_event over the cluster's CPUs - now)/1000`,
0 if already due. In suspend it is `suspend_wake_time*1000`, or ~0 if unset.
Then `sclk = (us+1)/1000000*32768 + ((us+1)%1000000*1000)/30517` (32 kHz ticks).

`msm_mpm_enter_sleep(sclk, from_idle, cpumask)` @ ffffff800854d81c:

```
wakeup = sclk ? CNTVCT + ((sclk * 19200000) >> 15) : ~0ULL;   /* CNTVCT re-read while low word == 0xffffffff */
vMPM[0] = lo(wakeup); vMPM[1] = hi(wakeup);
for bank i: ENABLE[i] = from_idle ? enabled : wake; FALLING[i]; RISING[i]; POLARITY[i]; STATUS[i] = 0;
dsb; *ipc (0x17911008) = 1 << 1; dsb;
if (cpumask) __irq_set_affinity(mpm_irq, cpumask);
```

The series matches this: an absolute 64-bit virtual-counter value at 19.2 MHz,
TIMER0 = low word at +0, TIMER1 = high at +4, ~0 = never, STATUS cleared,
all of it ordered before the IPC write (`regmap_write`, so `writel`, to
APCS +8, BIT(1)). The value source is the same too: stock uses the
tick-device `next_event`, mainline `dev->next_hrtimer =
tick_nohz_get_next_hrtimer()`, which is the same field. Differences, none
of which matter:

- Stock floors the delay to 32 kHz granularity after adding 1 us, so it
  wakes 0..30.5 us early. Mainline converts exactly. Neither subtracts exit
  latency.
- Stock's `sclk == 0` (delay < 30 us) means "never", a stock bug that the
  15.3 ms residency makes unreachable. Mainline wakes at once for delta <= 0.
- With no timers at all, stock's arithmetic overflows. Mainline's
  `cpu_power_down_ok()` starts from `ktime_set(KTIME_SEC_MAX, 0)`, not
  KTIME_MAX, so it programs a value about 292 years out instead of ~0.
  Effectively "never".
- s2idle: the series' governor sets `next_hrtimer = KTIME_MAX`, which gives ~0, the
  same as stock suspend without `suspend_wake_time`.
- Stock's CNTVCT read loops while the low word reads 0xffffffff (msm-4.4
  QTimer read workaround). Mainline arm64 has no such workaround for this
  SoC.

Kernel changes for the MPM side beyond 0023 to 0025: none.

### mdss_ahb_clk in system suspend

The symptom on mainline: the clock framework's "status stuck at 'on'" warning for `mdss_ahb_clk`, in system suspend
only.

#### Clock definition (data at `mmss_mdss_ahb_clk` @ ffffff800a126c30)

| field | stock | mainline |
|---|---|---|
| halt_reg | 0x2308 | 0x2308 |
| halt_check | 0 = BRANCH_HALT | BRANCH_HALT |
| hwcg_reg / bit | 0 / 0 (no HWCG) | 0x2308 / 1 |
| enable | 0x2308 BIT(0) | same |
| ops | clk_branch2_ops | same |
| flags | 0x1000 (handoff, see below), parent ahb_clk_src | CLK_SET_RATE_PARENT |

0x1000 is msm-4.4's enable-handoff flag: in `clk_register` @ ffffff8008b7543c,
`flags & 0x1000` with the clock on at boot sets `need_handoff_*` and
prepares/enables it; `clk_disable_unused` drops that later. It plays no
part in suspend.

`clk_branch2_disable` @ ffffff8008b7e324 calls `clk_disable_regmap` and
then `clk_branch_wait(br, false, clk_branch2_check_halt)`. `clk_branch_wait`
@ ffffff8008b7dfe4 skips the check only when HWCG is active; for
BRANCH_HALT it polls 200 x 1 us and on timeout prints "%s: status stuck at
'o%s'" plus a WARN, the same as mainline. `clk_branch2_check_halt` on
disable returns bit 31 (CLK_OFF). **Stock has the same halt semantics: no
skip, no reset, no extra wait.** Mainline's extra HWCG field can only skip
the check, never cause it.

#### Stock order (mdss_mdp.c and the DSI)

Stock MDP clock slots, from `mdss_mdp_probe` @ ffffff800840cce8: 0
iface_clk = mmss_mdss_ahb_clk, 1 bus_clk = mdss_axi, 2 core_clk = mdp,
3 lut_clk, 4 vsync_clk, 5 mnoc_clk = **mmss_mnoc_ahb_clk**, 6
throttle_bus_clk (IDs mapped through `mmcc_660_clocks` @ ffffff800a1255d8).

`mdss_mdp_clk_ctrl(off)` @ ffffff800840a620:
vsync, lut, core, axi, **AHB, then MNOC AHB**, throttle axi,
`mdss_iommu_ctrl(0)` (SMMU detach, RT bus vote off), bus idle context,
reg-bus vote 0, then `pm_runtime_put` -> `mdss_mdp_runtime_suspend` @
ffffff800840cc1c -> `mdss_mdp_footswitch_ctrl(0)` @ ffffff800840c708:
memory retention flags (with all clocks re-enabled briefly, AHB inside
MNOC again, `mdss_mdp_memory_retention_ctrl` @ ffffff80084097f8), then
`regulator_disable(gdsc)`. On: GDSC, reg-bus, SMMU attach, bus, then
**MNOC AHB, then AHB**, then axi, core, lut, throttle, vsync.
`mdss_mdp_pm_suspend` @ ffffff800840caac only calls the footswitch.

DSI (`qcom,mdss_dsi@0` core clocks: mdp_core_clk, mnoc_clk, iface_clk,
bus_clk, core_mmss_clk): `dsi_core_clk_start` @ ffffff8008472cac enables
mdp_core, **mnoc, then iface**, then bus and misc ahb; `dsi_core_clk_stop`
@ ffffff8008472f14 reverses that (iface off before mnoc).

Stock invariant: MDSS AHB is never switched without MMSS MNOC AHB on, and
the GDSC goes off last. The SMMU (stock DT also gives it mmss_mnoc_ahb and
the RPM mmssnoc_axi) is detached only after the MDP clocks are off.

#### Mainline difference

- `msm_mdss` (mdp5 path) takes only "iface", "bus" and "vsync";
  `clk_bulk_disable` disables vsync, then bus, then iface last. It never
  holds MNOC_AHB.
- The DSI host for sdm660 (`dsi_sdm660_bus_clk_names` = iface, bus, core,
  core_mmss) never requests "mnoc", even though the DT lists it.
- The only MNOC_AHB user left is `mmss_smmu` ("iface-mm"). In runtime PM it
  stays up for its 20 ms autosuspend, longer than the MDSS teardown takes,
  which is why runtime display-off is quiet. In system suspend
  `arm_smmu_pm_suspend` can run before `mdss_pm_suspend` (no device link
  between them), so the last MDSS AHB disable runs with MNOC AHB off. That
  is the one ordering difference against stock, and it matches the
  symptom: final disable, no refcount leak, system suspend only.

#### Fix

In `patches/linux`: 0043 `drm/msm/mdss: vote the MMSS NoC AHB clock on SDM660` (`msm_mdss.c`), 0028
`drm/msm/dsi: vote the MMSS NoC AHB clock on SDM660` (the DSI side and the binding) and the SDM630/SDM660
DT patch 0041.

- `drivers/gpu/drm/msm/msm_mdss.c`: `mdp5_mdss_parse_clock()` gets an
  optional "mnoc" clock as bulk entry 0 (`MDP5_MDSS_NUM_CLOCKS` 3 -> 4), so
  it is enabled before "iface" and disabled after it, as in
  `mdss_mdp_clk_ctrl`. The comment cites the stock addresses.
- `arch/arm64/boot/dts/qcom/sdm630.dtsi`: mdss node gets
  `<&mmcc MNOC_AHB_CLK>` / "mnoc".
- `Documentation/devicetree/bindings/display/msm/qcom,mdss.yaml`:
  optional 5th clock "mnoc".

Other mdp5 SoCs that do not list "mnoc" are unaffected (optional get, NULL clock).

## How to check

```sh
cat /sys/kernel/debug/qcom_stats/vmin /sys/kernel/debug/qcom_stats/vlow
rtcwake -m freeze -s 60
cat /sys/kernel/debug/qcom_stats/vmin /sys/kernel/debug/qcom_stats/vlow   # vmin Count up, duration about the sleep

cat /sys/bus/platform/drivers/qcom-clk-smd-rpm/*/state_synced   # 1
cat /sys/devices/platform/soc@0/*interconnect*/state_synced     # 1 on all six NoCs
dmesg | grep -i 'handoff vote'                                  # nothing
grep -E '^ *(bi_tcxo|video_core_clk_src|mdss_ahb_clk|ln_bb_clk1_a|ln_bb_clk1|gcc_rx0_usb2_clkref_clk|rf_clk1_pin) ' \
    /sys/kernel/debug/clk/clk_summary
    # clkref listed under ln_bb_clk1_a; with USB up ln_bb_clk1_a is 1 1 and ln_bb_clk1 0 0;
    # rf_clk1_pin 1 1 while wlan0 is up

d=/sys/kernel/debug/interconnect/interconnect_summary
grep -A14 '^slv_ebi' $d    # no 2147483647; gpu 0 once idle; cpu0, cpu4, 1008000.pmu carry tag 1

grep glink-smem /proc/interrupts            # sample twice for a rate (r26, accelerometer claimed: 240/s idle)
cat /sys/kernel/debug/sleep_time            # long sleeps land in the 64-128 s ... 256-512 s bins
cat /sys/kernel/debug/pm_genpd/power-domain-system/idle_states
cat /sys/kernel/hardlockup_count; dmesg | grep -c 'hard LOCKUP'
```

CPU floors: pin each cluster (`scaling_min_freq` / `scaling_max_freq` under
`/sys/devices/system/cpu/cpufreq/policy0` and `policy4`) and read the request next to the CPU in
`slv_ebi`: 300 MHz gives 799014 for both, the tops (1843200 / 2208000) give cpu0 3071279 and cpu4
7215251. Both policies must exist: a CPU path or OPP bandwidth that does not resolve fails that
cluster's cpufreq init with "Invalid opp table in device tree".

BIMC QoS offset after 0083: `busybox devmem 0x01008300 32` and `0x01018300` (fixed-mode ports 0 and 4)
read 1, `0x0100c300` (bypass port 1) reads 0.

If vmin stays 0:

- `state_synced` 0: a consumer never bound, so nothing was dropped (`devices_deferred`, and the
  `consumer:` links under the driver's sysfs directory).
- vlow counts but vmin does not: XO shuts down but CX/MX do not reach retention. Check the rpmpd
  corners in `pm_genpd_summary`.
- Both 0: something still holds the XO or a bus. Look for an `interconnect_summary` request with the
  `RPM_ALWAYS_TAG` that is not 0, and for any rpmcc pair still enabled other than `bi_tcxo_a`,
  `pcnoc_a` and, with Wi-Fi up, `rf_clk1_pin`.

## Open items

Not measured:

- vmin was checked on one 60 s sleep on r29. Longer sleeps, repeated cycles and the cable-in case on
  r29 are not recorded.
- The BWMON and CPU floor checks on the unit (driver bound, SPI 183 counting under load, `slv_ebi`
  values at pinned frequencies, `state_synced` on all six NoCs) are not part of the r29 result. r29
  carries the patches and reached vmin with them, so the active-only tags do not leak into the sleep
  set.
- Fix B was never exercised alone: with Fix A in, a normal suspend has no window of more than about
  12.6 s with one CPU awake and another frozen. Showing it needs a sustained `IRQF_NO_SUSPEND` source,
  for example a kernel with Fix B but without Fix A.
- The accelerometer after Fix A: the KXTJ2's `max_buffered_samples` on this firmware (decides whether
  batching does anything), its native rate list, what SMGR does with a rate outside it, and whether the
  extra roughly 40/s on top of the 200 Hz stream in r26 belongs to the stream. The probe line prints the
  buffered-sample count and the default rate. Whether SMGR answers QMI requests while "sleepstate" says
  asleep is avoided by ordering, never tested.
- Runtime XO holds while awake with the screen off: the DSI bus clock, the DPU vsync clock, the MMSS
  SMMU and the DSI PHY were still seen prepared in an r28 dump. This does not affect s2idle but keeps
  the XO up in runtime idle. Not investigated.

Choices:

- `cxo2` is the active-only `LN_BB_CLK1` (stock parity). With the cable in and the AP power-collapsed,
  the USB PHY loses its reference while the buffer is off, as on stock. A gadget staying `configured`
  through a suspend was not checked on r29.
- Bluetooth does not claim `rf_clk1_pin` (stock's `bt_wcn3990` does). The `qcom,wcn3990-bt` binding's
  `clocks` is the 32.768 kHz sleep clock, not the RF reference, so adding one is a binding change.
  Today BT relies on Wi-Fi holding the pin. With Wi-Fi down and BT up the pin vote was already 0
  before this series.
- Wi-Fi drops while asleep: NetworkManager takes `wlan0` down before the kernel suspends (r26 journal)
  and reassociation takes about 5 s. Staying connected would need ath10k WoWLAN, a wake-armed WLAN
  interrupt and NetworkManager left running.
- 0093 is generic for every rpmcc SoC; Imran Shaik's QCM2290 patch is per SoC. Brian Masney's clk
  `sync_state` series would be its generic home if merged.
- `CONFIG_QCOM_ICC_BWMON` is a module. The providers' `sync_state` waits for the bwmon node to probe,
  so the module must be installed or every NoC stays at INT_MAX. Building it in removes the coupling.
- Upstream status: 0051 is Richard Acayan's, with an Ack; 0076, 0078 and 0079 are Fabricio Akio's
  posted patches (Reviewed-by Dmitry Baryshkov on list; no v2 of 0078 as of 2026-10-22); 0080 is
  Arpit Saini's posted patch; 0082 is Konrad Dybcio's, from Dmitry Baryshkov's MSM8998 interconnect
  series. The rest (smp2p sleepstate driver, SMGR changes, hardlockup change, GPU vote, 0090 to 0093,
  BWMON and floor patches) is not upstream; a search found no sdm630/sdm660 bwmon or mincpubw posting.

Stock comparisons that need the device:

1. mdss_ahb_clk: suspend with the fix and confirm the warning is gone. If it is not,
   read MMCC 0x5024 (mnoc_ahb CBCR) and 0x2308 at the moment it fires,
   via debugfs `clk_summary` or a `pr_info` in `mdss_runtime_suspend`.
   Expected: mnoc_ahb enabled while mdss_ahb is disabled.
2. Wakeup: confirm RPM raises SPI 171 on system-PC exit: its count in
   `/proc/interrupts` grows in step with the system-pc usage count in
   `/sys/kernel/debug/pm_genpd/power-domain-system/idle_states`. Check it
   for both timer and pin wakeups.
3. System-level idle: watch for system-pc while an RPM SMD request is outstanding (stock
   forbids it), and for missed or late RPM ACKs after system-pc. If any
   show up, port stock's `msm_rpm_waiting_for_ack` veto and the RX-interrupt
   mask.
4. vMPM timer: compare the wake time against the programmed hrtimer (a timer-only
   wake with an idle system); expect about the exit latency (4.5 ms) late,
   the same as stock.
