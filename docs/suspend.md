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
  `0x42000343` (see `re-mpm-mdss.md`, A1). genpd "Time(ms) 0" for system-pc is s2idle accounting
  with timekeeping frozen, not a missing request.
- The APSS `xo_count` stayed 0: while the APSS slept, its sleep-set votes still needed the XO.
  MPSS, ADSP and CDSP release the XO on their own most of the time, and TZ's counter stays 0 even
  when vmin works. Nothing to fix on the DSP side.

Prerequisites already in the series (stock side in `re-mpm-mdss.md`): 0023 (L2 SAW AVS setup), 0024
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
related MNOC AHB ordering fix is in `re-mpm-mdss.md`.

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
