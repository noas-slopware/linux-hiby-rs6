# MPM system idle and mdss_ahb_clk suspend: stock RE (firmware 1.80, slot B)

Source: stock kernel #16 (slot B), imported into Ghidra, symbols from
kallsyms (vmlinux-to-elf). Everything below was decompiled in Ghidra (Dump.java)
or read as data from the slot B `Image`. Struct offsets come from the
decompiled code. Addresses are kernel virtual addresses.

## A. MPM and the system (CCI) level

### A1. When stock requests 0x42000343 and how

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
   (see A3). Then `cpu_cluster_pm_enter`, and `last_level` is set.
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

### A2. Wakeup: SPI 171 and `msm_mpm_exit_sleep`

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

### A3. vMPM timer

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

Kernel changes for A: none.

## B. mdss_ahb_clk "status stuck at 'on'" in system suspend

### Clock definition (data at `mmss_mdss_ahb_clk` @ ffffff800a126c30)

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

### Stock order (mdss_mdp.c and the DSI)

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

### Mainline difference

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

### Fix (carried in `patches/linux`, see "drm/msm/dsi: vote the MMSS NoC AHB clock on SDM660" and the SDM630/SDM660 DT patch)

- `drivers/gpu/drm/msm/msm_mdss.c`: `mdp5_mdss_parse_clock()` gets an
  optional "mnoc" clock as bulk entry 0 (`MDP5_MDSS_NUM_CLOCKS` 3 -> 4), so
  it is enabled before "iface" and disabled after it, as in
  `mdss_mdp_clk_ctrl`. The comment cites the stock addresses.
- `arch/arm64/boot/dts/qcom/sdm630.dtsi`: mdss node gets
  `<&mmcc MNOC_AHB_CLK>` / "mnoc".
- `Documentation/devicetree/bindings/display/msm/qcom,mdss.yaml`:
  optional 5th clock "mnoc".

Other mdp5 SoCs that do not list "mnoc" are unaffected (optional get, NULL clock).

## Open checks (need the device)

1. B: suspend with the fix and confirm the warning is gone. If it is not,
   read MMCC 0x5024 (mnoc_ahb CBCR) and 0x2308 at the moment it fires,
   via debugfs `clk_summary` or a `pr_info` in `mdss_runtime_suspend`.
   Expected: mnoc_ahb enabled while mdss_ahb is disabled.
2. A2: confirm RPM raises SPI 171 on system-PC exit: its count in
   `/proc/interrupts` grows in step with the system-pc usage count in
   `/sys/kernel/debug/pm_genpd/power-domain-system/idle_states`. Check it
   for both timer and pin wakeups.
3. A1: watch for system-pc while an RPM SMD request is outstanding (stock
   forbids it), and for missed or late RPM ACKs after system-pc. If any
   show up, port stock's `msm_rpm_waiting_for_ack` veto and the RX-interrupt
   mask.
4. A3: compare the wake time against the programmed hrtimer (a timer-only
   wake with an idle system); expect about the exit latency (4.5 ms) late,
   the same as stock.
