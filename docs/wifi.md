# Wi-Fi (WCN3990, ath10k_snoc)

The RS6 has a Qualcomm WCN3990 (SDM660 generation). The kernel drives it with the mainline `ath10k_snoc` driver. The WLAN firmware does not run on a chip of its own: it is `wlanmdsp.mbn`, a process on the modem DSP (MSS, remoteproc `4080000.remoteproc`), and the host talks to it over QMI (WLFW) and WMI over the copy engines. This page covers the latency investigation and the scan-timing patch it led to, the WLAN firmware the port installs, the other ath10k/WCN3990 patches in the series, and the problems that are still open.

Evidence tags: "measured" means seen on the unit, "static" means read from a binary or source.

## 1. Latency investigation

Date: 2026-10-22. Setup: station associated on 5 GHz channel 48 (80 MHz), WLAN firmware WLAN.HL.1.0.1.c2-00708 (build date 2019-08-13), kernel 7.2.3-sdm660, schedutil, cpuidle PSCI (WFI, cpu-sleep-0-0 172 us, cpu-sleep-0-1 666 us). All WLAN_CE interrupts are delivered to CPU0 and NAPI is threaded (`netif_threaded_enable` in the snoc `hif_start`). Tools: ping, tcpdump, tracefs (function and event traces), debugfs `fw_stats`, `iw`.

The symptom: ping RTT to the RS6 from a laptop on the same AP averaged 20 to 60 ms with peaks of 200 to 900 ms, and inbound TCP topped out around 5 MB/s.

### Result

The delay is inside the firmware and the air, on the RS6 side only. It has three parts.

1. The firmware holds TX frames for whole beacon intervals (about 100 ms, released at the next TBTT), roughly every 1.3 s, with continuous traffic and with power save off. The host sees the TX completions (`ath10k_txrx_tx_unref`) arrive 50, 100 or 150 ms late. This delays TCP ACKs, which is what limits inbound TCP.
2. Host scans make it much worse. wpa_supplicant started a background scan every 27 to 30 s, each lasting about 6 s through ath10k `hw_scan`. During a scan the RTT mean was 138 ms with a maximum around 900 ms, against 25 ms outside scans.
3. When the link is idle (gaps over 100 ms), the AP buffers inbound frames until the next beacon (TIM). That adds 0 to 100 ms and matches the 100 ms PS inactivity timeout. It explains the 63 ms average at 0.2 s ping spacing.

The AP is not the cause: the laptop to the AP, same channel, power save on, gave avg 2.5 ms and max 18 ms over 400 pings at 50 ms spacing.

### Measurements

Laptop to RS6 unless noted. Times in ms, 100 or more pings per row.

| Setting | Test | Result |
|---|---|---|
| baseline, PS on | 100 pings, 0.2 s apart | avg 60.9, max 218, 4% loss |
| cpuidle states 1 and 2 disabled on all 8 CPUs, PS on | 100 pings, 0.2 s | avg 66.1, max 218 (no improvement) |
| PS off (`iw`) | 100 pings, 0.2 s | avg 33.8, max 107 (halved, ~104 ms stalls remain) |
| PS on | 200 pings, 0.02 s | avg 26.5, max 198 |
| PS on | 200 pings, 0.05 s | avg 21.6, max 134 |
| PS on | 200 pings, 0.09 s | avg 23.3, max 305 |
| PS on | 40 pings, 0.5 s | avg 95.7 |
| PS on | 40 pings, 1 s | avg 107 |
| RS6 to the AP, PS on | 300 pings, 0.02 s | avg 18.4, max 144 |
| RS6 to the AP, PS on | 300 pings, 0.2 s | avg 43.9, max 277 |
| laptop to the AP | 400 pings, 0.05 s | avg 2.5, max 18 |
| laptop to the AP | 100 pings, 0.2 s | avg 4.1, max 31 |
| RS6 to the AP, PS off vs on, 400 pings, 0.05 s, scans included | 4 alternating runs | off: 35.8% and 23.8% of pings over 20 ms; on: 36.3% and 34.0% (no clear PS effect under steady traffic) |

During a continuous 0.02 s stream the RTTs look like `180 159 138 117 95 73 154 133 ...`: each value drops by exactly the send interval, so packets queue and are released at one instant. The releases land 1 to 4 ms before the next beacon event reaches the host (beacons every 102.3 ms), in runs of one to three beacon intervals.

Direction split (tcpdump on the RS6 with `ping -D` from the laptop, clock offset calibrated from the minimum):

- 0.2 s spacing: inbound request delay (AP buffering) mean 30.7 ms, 41% over 20 ms. Outbound reply delay mean 32.6 ms, 36% over 20 ms. Host turnaround from request to reply: 0.13 to 0.23 ms at most.
- 0.02 s spacing, 400 pings: inbound excess mean 4.2 ms, only 4 pings over 20 ms (the first burst, from idle). Outbound excess: 80 pings over 20 ms, in groups of 15 (3 x 5) every 64 packets, i.e. every 1.28 s.

Once traffic flows, inbound is fine and the RS6's own TX is what stalls.

### Host paths ruled out

- RX path (ftrace of the WLAN_CE IRQs, `netif_receive_skb`, `napi_poll`): for a stalled reply from the RS6 to the AP, the CE_1 (HTT/data RX) interrupts stop from +8 ms to +158 ms after the TX, and only CE_2 (WMI) fires at +8 and +158. Then CE_1 resumes, NAPI polls take 0.2 to 0.5 ms each and the reply reaches the stack within about 1 ms. No interrupt means the firmware had not posted the data yet.
- cpuidle: disabling the idle states changed nothing (table above).
- cpufreq: CPU0 sat at 633 MHz when idle, not correlated with stalls.
- IRQ affinity: all WLAN_CE IRQs go to CPU0 (affinity 0-7, effective 0). The hop to the NAPI thread on another CPU costs microseconds. Not changed.
- Queueing: qdisc on wlan0 is `noqueue`; `netdev_budget` 300, `dev_weight` 64, no ksoftirqd problem seen.
- TX completion trace (`ath10k_htt_tx_64` against `ath10k_txrx_tx_unref`, 300 pings at 0.05 s, one scan inside): 138 of 367 TX frames completed more than 20 ms late (max 754 ms during the scan). Outside the scan the pattern repeats every about 1.35 s as `+101 ms, +51 ms`: two frames sent 50 ms apart complete together.
- Host WMI activity: in a quiet 100-ping window with no scan, the function trace of `ath10k_wmi_cmd_send*`, `ath10k_mac_op_*` and `ath10k_peer_*` showed only beacon `mgmt_rx` events (10 per second), and a 205 ms stall still happened. The 1.33 s event is not triggered by the host driver or by userspace through mac80211.
- Other counters: `iw station` showed tx retries 0, tx failed 0, beacon loss 0, DTIM 3, signal -66 dBm. `fw_stats` showed 54749 TX retries of 1.03 M frames (5%), failures 0, and "Excessive retries" 139357 of 1.1 M HW-queued PPDUs (12.6%, worth watching). No ath10k warnings in dmesg. The PS code in `ath10k_mac_vif_setup_ps` is stock, and the two ath10k patches in the tree at the time (0017 and 0037) touch neither TX scheduling, PS nor scanning.

### Scans

`cfg80211:rdev_scan` and `cfg80211:cfg80211_scan_done` over about 75 s showed scans each lasting about 6.0 s (`aborted: false`), issued by wpa_supplicant as two `drv_hw_scan` calls (ath10k does not set `SINGLE_SCAN_ON_ALL_BANDS`, so mac80211 splits a request per band). During a scan the firmware posts a `ath10k_wmi_event_scan` plus `chan_info` pair about every 50 ms.

Correlated run, 1500 pings at 0.05 s over 76 s:

| | pings | mean | median | p90 | p99 | max | over 20 ms |
|---|---|---|---|---|---|---|---|
| during scans | 234 | 137.9 | 51.7 | 505 | 797 | 898 | 61.5% |
| outside scans | 1265 | 25.0 | 2.1 | 102.6 | | | 23.1% |

Outside scans the stalls recurred at 1.4, 2.8, 4.1, 5.4, 6.7, 8.1 and 9.4 s, a period of about 1.33 s (13 beacons).

## 2. Fix: connected-scan timing (patch 0069)

`0069-wifi-ath10k-use-connected-scan-timing-while-a-vdev-i.patch`

### What ath10k sent before (static)

`ath10k_hw_scan` calls `ath10k_wmi_start_scan_init`, which fills the same timing for every scan, associated or not: dwell 50 ms active and 150 ms passive, `min_rest_time` 50, `max_rest_time` 500, `idle_time` 0. mac80211 passes nothing about association to `drv_hw_scan`, and the "go home every 125 ms" logic in mac80211 exists only for software scans. With hw_scan the driver and firmware decide everything.

The firmware rest logic (comment on `struct wmi_start_scan_common`, same text in Qualcomm's `wmi_unified.h`): stay home at least `min_rest_time`, then check for TX/RX activity every `idle_time` and leave when idle, but leave at `max_rest_time` regardless. With `idle_time = 0` the activity check is off, so the firmware leaves as soon as the 50 ms minimum expires and `max_rest_time` is never used. That is the 50 ms rhythm in the trace. 50 ms is shorter than the 102.4 ms beacon interval, so about half of the returns catch no beacon. The AP keeps the buffered frames (PS on, TIM) until a later return, which fits the 500 to 900 ms tail better than the 150 ms off-channel dwell alone.

### What Qualcomm's driver sends when connected (static)

Read from the stock driver (`qca_cld3_wlan.ko`, qcacld 5.1.1.73W, from the stock 1.80 vendor image), registry defaults decoded from `.data` and relocations, and cross-checked in the qcacld-3.0 source (`csr_set_default_scan_timing`, `csr_scan_request`, `wma_get_buf_start_scan_cmd`). When any session is connected the driver switches to the `*Conc` values; otherwise rest and idle are 0. The stock `WCNSS_qcom_cfg.ini` overrides none of the connected values.

| ini | stock default | goes to |
|---|---|---|
| gActiveMaxChannelTimeConc | 40 | dwell_time_active |
| gPassiveMaxChannelTimeConc | 110 | dwell_time_passive |
| gRestTimeConc | 100 | max_rest_time |
| gMinRestTimeConc | 50 | min_rest_time |
| gIdleTimeConc | 25 | idle_time |
| hostscan_adaptive_dwell_mode / _no_conn | 2 (moderate) / 1 (conservative) | scan_ctrl_flags bits 21-23 |
| gScanProbeRepeatTime, gScanNumProbes | 0, 0 | repeat_probe_time = dwell/2, n_probes 2 |
| sta_scan_burst_duration | 0 | burst_duration 0 (go home after every foreign channel) |

The driver also uses `max_scan_time` 30000 and `probe_delay` 0.

Upstream: ath10k, ath11k and ath12k in the 7.2 tree all use the same idle-scan constants (50/150/50/500, idle 0) with no connected branch. ath11k and ath12k carry an `adaptive_dwell_time_mode` field that nothing sets. No posted patch for this was found, so 0069 is new code, not a backport.

### What 0069 does

`ath10k_mac_scan_set_conn_params()` runs right after `ath10k_wmi_start_scan_init()` in `ath10k_hw_scan()`. It only changes anything when at least one vdev is up (associated STA, or a started AP/IBSS/mesh). Scans with no vdev up (the initial scan) and the remain-on-channel path keep the old values. Beacon interval is 100 TU in the table below.

| field | before | connected |
|---|---|---|
| dwell_time_active | 50 | 40 |
| dwell_time_passive | 150 | 110 |
| min_rest_time | 50 | 103 (one beacon interval, `DIV_ROUND_UP(bi_TU * 1024, 1000)`, clamped to 50..150) |
| max_rest_time | 500 (unused) | 206 (2 x min_rest_time) |
| idle_time | 0 | 25 |
| scan_ctrl_flags | unchanged | plus dwell mode MODERATE (2) in bits 21-23 (WMI-TLV only) |

Unchanged: repeat_probe_time 0, probe_spacing_time 0, probe_delay 5, max_scan_time 20000, burst_duration_ms 0, num_probes 3, scan_priority LOW.

Reasons for the numbers:

- `idle_time` 25 turns the activity check on, so the firmware stays home while frames are moving instead of leaving on a fixed 50 ms timer. This is the change that matters most.
- `min_rest_time` is one beacon interval (not qcacld's 50), so every return covers a TBTT and the AP can drain what it buffered. The largest beacon interval of all up vdevs is used, clamped to 150 ms so a long-interval AP cannot stretch the scan past `max_scan_time`.
- `max_rest_time` is two beacon intervals (not 500, qcacld uses 100). Under steady traffic `idle_time` keeps the radio home until `max_rest_time`, so 500 would make one band take over 12 s and risk the 20 s `max_scan_time`.
- Dwell 40/110 and moderate adaptive dwell are what Qualcomm's own driver uses for connected scans on this firmware. Adaptive dwell lets the firmware leave an active channel early once probe responses stop.
- When userspace passes an explicit scan `duration`, the old override applies and the dwell mode goes back to default.

The dwell-mode bits follow Qualcomm's `wmi_unified.h` (`WMI_SCAN_DWELL_MODE_MASK 0x00E00000`, shift 21). ath10k does not send `WMI_SCAN_ADAPTIVE_DWELL_CONFIG_CMDID`, which the stock driver does, so the firmware uses its built-in mode parameters. This is the one knob that could not be proven from the sources. If the firmware rejected it, the scan would report `start failed` instead of `started`. The rest, idle and dwell values go through `ath10k_wmi_put_start_scan_common()`, so non-TLV (10.x) firmware gets them too; only the dwell-mode bits are TLV-only.

### Expected scan time (computed, KR regdomain: about 13 x 2.4 GHz active, 9 x 5 GHz active, 16 x 5 GHz DFS passive, each band its own hw_scan)

| | before | after, idle link | after, busy link |
|---|---|---|---|
| 2.4 GHz hw_scan | 13x50 + 12x50 = 1.25 s | 13x40 + 12x103 = 1.8 s | 13x40 + 12x206 = 3.0 s |
| 5 GHz hw_scan | 9x50 + 16x150 + 24x50 = 4.05 s | 9x40 + 16x110 + 24x103 = 4.6 s | 9x40 + 16x110 + 24x206 = 7.1 s |
| longest single time off channel | 150 ms | 110 ms | 110 ms |
| home share on DFS hops | 25% (50 of 200) | 48% (103 of 213) | 65% (206 of 316) |

Plus about 10 ms per channel switch. A full background scan should take about 6.5 s on a quiet link (about 6 s measured before the change) and up to about 10 s on a busy one. The structural worst case from scanning alone is about 220 ms: a frame arrives just as the radio leaves (110 ms away plus 10 ms for the switch), then waits up to one beacon interval after the return for the TIM.

### Measured effect

After the patch was loaded on the unit the maximum RTT during scans fell from 898 ms to 220 ms, which matches the structural worst case above. Only these two numbers were recorded for that run; the mean, percentiles and whether the firmware accepted the dwell-mode bits are not recorded. The 1.33 s firmware hold is separate, still fires during scans and gives 200 to 300 ms peaks outside them, so a maximum in that range does not mean the patch failed.

### How to check

1. Set the ath10k debug mask to MAC plus WMI (`echo 0x12 > /sys/module/ath10k_core/parameters/debug_mask`). At the next background scan dmesg must show `mac scan connected dwell 40/110 rest 103-206 idle 25` followed by `scan event started`, not `start failed`. Set the mask back to 0 afterwards.
2. In the same log, the gap between a `scan event bss channel` line and the next `scan event foreign channel` line should be at least 103 ms (up to 206 ms with traffic) instead of 50 ms.
3. Scan duration: tracefs events `cfg80211:rdev_scan` and `cfg80211:cfg80211_scan_done`; expect `aborted: false` and about 6.5 s (idle) to 10 s (busy).
4. Latency: `ping -i 0.05` from another station on the same AP for about 76 s so it spans two or three scans.
5. Roaming data still arrives: `iw dev wlan0 scan dump` right after a scan should list the 2.4 and 5 GHz neighbours, and `wpa_cli bss` should show fresh `age` values.

## 3. WLAN firmware

The package `firmware-hiby-rs6` (in the `pmos` branch) installs these WCN3990 files:

| file | what |
|---|---|
| `/usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin` | board data, generated at build time |
| `/usr/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin` | ath10k firmware container (API 5), generated at build time |
| `/usr/lib/firmware/wlanmdsp.mbn` | the WLAN firmware itself, loaded by the modem |

### board-2.bin and firmware-5.bin (static)

HiBy's firmware ships the WCN3990 board files as `bdwlan.*`. The APKBUILD turns them into one `board-2.bin` with `ath10k-bdencoder` (from qca-swiss-army-knife). Each file becomes an entry named `bus=snoc,qmi-board-id=<id>`: `bdwlan.bin` is the default for unprogrammed board ids (`ff`), `bdwlan.bXX` is board id 0xXX, `bdwlan.XXX` is board id 0xXXX.

`firmware-5.bin` is created with `ath10k-fwencoder` without passing any firmware image (the WLAN firmware is `wlanmdsp.mbn`, below). It carries the feature flags and ops versions that tell ath10k how to talk to the modem-hosted firmware:

- features `wowlan`, `no-nwifi-decap-4addr-padding`, `allows-mesh-bcast`, `mgmt-tx-by-ref`, `non-bmi`, `single-chan-info-per-channel`
- WMI op version `tlv`, HTT op version `tlv`
- firmware API 5

### wlanmdsp.mbn: HiBy's c2-00708

The port installs HiBy's own WLAN.HL.1.0.1.c2-00708, `image/wlanmdsp.mbn` on the `firmware` branch, as is.

Installing a new `wlanmdsp.mbn` in place on a running unit hard-reset it once, 5 s into the package install,
most likely because the file the running WLAN firmware was loaded from was overwritten under the live modem.
Follow WLAN firmware changes with a reboot (or install them with the modem stopped).

Described in section 2.

## 5. Known problems

### The 1.33 s firmware hold is unexplained

Roughly every 1.33 s (13 beacons) the firmware holds host TX frames until the next TBTT, with continuous traffic and with power save off. It was seen on c2-00708 and is not triggered by host WMI activity (section 1). Without an air capture the candidates could not be separated:

1. Firmware-internal periodic off-channel or background work (roam/RSSI or channel survey) during which it sets PM=1 and the AP and firmware wait for a beacon. This fits release-at-beacon timing. No host-visible scan event accompanies it, only `mgmt_rx`.
2. The firmware's own STA power-save state machine ignoring the host's PS-off setting (the stalls persist with `power_save off`; ath10k only sends `WMI_STA_PS_MODE_DISABLED`).
3. Beacon/DTIM-synchronous TX gating tied to the AP's WMM parameters (this AP advertised an invalid AIFSN=1 for ACI 3, which the stack replaces with 2).

A monitor-mode capture on a second radio would show whether the hold is a PM=1 null frame to the AP or genuine no-ack retries. No upstream report or fix for a periodic ~100 ms TX hold on WCN3990 was found.

### NetworkManager takes wlan0 down around every s2idle

Before each sleep NetworkManager brings wlan0 down (`reason 'sleeping'`, wpa_supplicant `nl80211: deinit`). Every NM-driven sleep is therefore an `ath10k_stop` (QMI mode OFF) before it and an `ath10k_start` after it, not a suspend of a running device. Patch 0037 covers crashes while the interface is down in this window. The WLAN firmware is started again through QMI on every resume, and a healthy resume takes about 0.6 s from `internal-starting` to `disconnected`, including that start.

## Open items

- Cause of the 1.33 s TX hold.
- Whether the firmware accepts the dwell-mode bits sent by 0069 on every unit (the `scan event started` check in section 2).
