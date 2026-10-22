# Linux kernel series

94 patches for the HiBy RS6 (Qualcomm SDM660 / PM660 / PM660L), as `git format-patch --no-signature` output.

Base:

- tree: https://github.com/sdm660-mainline/linux
- branch: `qcom-sdm660-7.2.y` (Linux 7.2.3)
- commit: `dd1ed52c8ceef4f16715118ed0252fe75adbe71d`

Apply:

```
git clone https://github.com/sdm660-mainline/linux && cd linux
git checkout dd1ed52c8ceef4f16715118ed0252fe75adbe71d
git am /path/to/linux-hiby-rs6/patches/linux/0*.patch
```

`git am` of the 94 files on that commit gives the same tree as the author's working branch (tree object
`b06b9cbf9ec4d746b7b4c0924b879f5539be3359`). The kernel config used by the Nura package is
`config-postmarketos-qcom-sdm660.aarch64` in `device/testing/linux-postmarketos-qcom-sdm660/` on the `pmos`
branch; the package builds exactly this series on this base.

## Contents

- 0001-0014: CPRh (Core Power Reduction hardened) and the OSM-aware cpufreq-hw changes. Ported, authors are kept
  (see the table). They are a 7.2 rebase (via the porthole-dev/pmaports tree) of AngeloGioacchino Del Regno's
  CPR3/CPRh code (originally 2020/21) with later fixes by Giuseppe Maggio (debugged on MSM8998).
- 0015-0017: patches from the mailing lists, applied with their original authors and dates (Ulf Hansson: cpuidle
  psci probe deferral; Fabricio Akio: a5xx GPU reset on resume, ath10k TxBF).
- 0018-0042: the base port: SDM630/SDM660 CPRh and OSM data, MPM/idle work, GPU/display clocking and power
  domains, the Sharp LS050T1SX18 panel, the HiBy volume wheel, the hm100 FPGA DAC codec and the q6asm/sm8250
  changes it needs, WCN3990 fixes, Type-C role switching, the SMGR accelerometer fix, bindings, and the RS6
  device tree. `sdm660-hiby-rs6.dts` is based on `sdm660-xiaomi-lavender-common.dtsi` (Alexey Minnekhanov, Dang
  Huynh); the panel driver was generated with linux-mdss-dsi-panel-driver-generator.
- 0043-0050: display and GPU: MDSS bus clock vote, a5xx GPMU register dump fix (Dmitry Baryshkov, applied as
  posted) and hang recovery (fence memptr, preemption records, faults with no submit, every ring checked for a
  hang, hang detector masked until reset). `docs/gpu-a5xx.md` on the `docs` branch.
- 0051-0059, 0070-0072: s2idle: the smp2p "sleepstate" binding (Richard Acayan, applied as posted) and driver
  side, the ADSP sleepstate entry, qcom_smgr buffering/batching fixes and no sensor reports while the AP is
  suspended, and the hardlockup detector skipping CPUs whose tick is frozen in s2idle. `docs/suspend.md`.
- 0060-0068, 0073-0075: audio: native DSD on the q6asm S32-as-S16-pairs path, the hm100 S/PDIF (coax) target
  when nothing is plugged in, a read-only Output Target control, DSD mute handling, PCM and DSD offered only at
  the DAC's rates. `docs/audio.md`.
- 0069: ath10k connected-scan timing while a vdev is up. `docs/wifi.md`.
- 0076-0094: interconnect and clocks for VDD min in s2idle: BLSP I2C/SPI interconnect paths and keep_alive /
  sync_state for the SDM660 NoCs (Fabricio Akio), the video core clock no longer always on (Fabricio Akio), the
  DSI AHB clock across suspend (Arpit Saini), negative QoS offsets in icc-rpm (Konrad Dybcio), the CPU BWMON and
  per-OPP CPU memory bandwidth with stock's DDR floors, the GCC CLKREF parents fed from LN_BB_CLK1, clk-smd-rpm
  dropping handoff votes nobody claimed, and the GPU dropping its bus vote when suspended. `docs/suspend.md`.

Patches by other authors keep their own tags. On the Noa Himesaka patches, AI assistance is disclosed with
`Assisted-by: Claude:claude-opus-5-5` (0031, 0046, 0048, 0049 and 0050 also `Assisted-by: Claude:claude-mythos-5-1`)
and a `Claude-Session` link. The DCO sign-off of the Noa-authored patches is intentionally left out of
the series (no `Signed-off-by`).

## Authors in the series

| patch | author |
|---|---|
| 0001-pmdomain-qcom-add-support-for-CPR-v3-v4-and-Hardened.patch | AngeloGioacchino Del Regno <angelogioacchino.delregno@somainline.org> |
| 0002-cpufreq-qcom-hw-implement-CPRh-aware-OSM-programming.patch | AngeloGioacchino Del Regno <angelogioacchino.delregno@somainline.org> |
| 0003-cpufreq-qcom-hw-only-read-a-DCVS-control-register-th.patch | Giuseppe Maggio <jertlok@proton.me> |
| 0004-pmdomain-qcom-cpr3-arm-the-CPRh-loop-only-once-the-O.patch | Giuseppe Maggio <jertlok@proton.me> |
| 0005-cpufreq-qcom-hw-BRINGUP-walk-the-OSM-setup-one-step-.patch | Giuseppe Maggio <jertlok@proton.me> |
| 0006-pmdomain-qcom-cpr3-BRINGUP-walk-the-CPRh-setup-one-p.patch | Giuseppe Maggio <jertlok@proton.me> |
| 0007-cpufreq-qcom-hw-do-not-device-link-a-CPU-to-its-CPRh.patch | Giuseppe Maggio <jertlok@proton.me> |
| 0008-cpufreq-qcom-hw-let-the-genpd-core-bind-the-CPRh-req.patch | Giuseppe Maggio <jertlok@proton.me> |
| 0009-pmdomain-qcom-cpr3-look-up-the-CPRh-thread-instead-o.patch | Giuseppe Maggio <jertlok@proton.me> |
| 0010-cpufreq-qcom-hw-msm8998-request-a-corner-before-star.patch | Giuseppe Maggio <jertlok@proton.me> |
| 0011-cpufreq-qcom-hw-msm8998-program-the-APM-threshold-co.patch | Giuseppe Maggio <jertlok@proton.me> |
| 0012-cpufreq-qcom-hw-msm8998-do-not-enable-the-droop-FSMs.patch | Giuseppe Maggio <jertlok@proton.me> |
| 0013-cpufreq-qcom-hw-cpr3-msm8998-default-the-bring-up-ga.patch | Giuseppe Maggio <jertlok@proton.me> |
| 0014-cpufreq-qcom-hw-msm8998-busy-poll-the-ACD-transfers.patch | Giuseppe Maggio <jertlok@proton.me> |
| 0015-cpuidle-psci-Fix-support-for-probe-deferral-by-dropp.patch | Ulf Hansson <ulfh@kernel.org> |
| 0016-drm-msm-a5xx-Reset-the-GPU-when-resuming-it.patch | Fabricio Akio <fabricioakio@gmail.com> |
| 0017-wifi-ath10k-don-t-reset-TxBF-on-disassociation.patch | Fabricio Akio <fabricioakio@gmail.com> |
| 0018-cpuidle-psci-report-probe-deferral-through-dev_err_p.patch | Noa Himesaka <himesaka@noa.codes> |
| 0019-pmdomain-qcom-cpr3-add-SDM630-SDM660-CPRh.patch | Noa Himesaka <himesaka@noa.codes> |
| 0020-cpufreq-qcom-hw-add-SDM630-SDM660-OSM-programming.patch | Noa Himesaka <himesaka@noa.codes> |
| 0021-cpufreq-dt-platdev-block-SDM630-and-SDM660.patch | Noa Himesaka <himesaka@noa.codes> |
| 0022-dt-bindings-CPRh-and-OSM-for-SDM630-SDM660.patch | Noa Himesaka <himesaka@noa.codes> |
| 0023-soc-qcom-spm-fix-the-SDM660-L2-SAW-AVS-setup.patch | Noa Himesaka <himesaka@noa.codes> |
| 0024-irqchip-qcom-mpm-program-the-vMPM-wakeup-timer-befor.patch | Noa Himesaka <himesaka@noa.codes> |
| 0025-pmdomain-governor-no-next-hrtimer-during-system-wide.patch | Noa Himesaka <himesaka@noa.codes> |
| 0026-fs-don-t-charge-do_file_open_root-lookups-to-the-cal.patch | Noa Himesaka <himesaka@noa.codes> |
| 0027-drm-msm-adreno-attach-all-GPU-power-domains.patch | Noa Himesaka <himesaka@noa.codes> |
| 0028-drm-msm-dsi-vote-the-MMSS-NoC-AHB-clock-on-SDM660.patch | Noa Himesaka <himesaka@noa.codes> |
| 0029-drm-panel-add-Sharp-LS050T1SX18.patch | Noa Himesaka <himesaka@noa.codes> |
| 0030-Input-misc-add-the-HiBy-volume-wheel.patch | Noa Himesaka <himesaka@noa.codes> |
| 0031-ASoC-codecs-add-the-HiBy-hm100-FPGA-DAC.patch | Noa Himesaka <himesaka@noa.codes> |
| 0032-ASoC-qcom-q6asm-dai-fixed-rate-streams-and-S32-as-16.patch | Noa Himesaka <himesaka@noa.codes> |
| 0033-ASoC-qcom-sm8250-codec-clocked-secondary-MI2S.patch | Noa Himesaka <himesaka@noa.codes> |
| 0034-Bluetooth-hci_qca-set-the-WCN3990-supply-voltages.patch | Noa Himesaka <himesaka@noa.codes> |
| 0035-regulator-qcom_smd-add-qcom-rpm-exact-voltage.patch | Noa Himesaka <himesaka@noa.codes> |
| 0036-power-supply-qcom_smbx-Type-C-role-switching-and-OTG.patch | Noa Himesaka <himesaka@noa.codes> |
| 0037-wifi-ath10k-keep-a-stopped-device-recoverable.patch | Noa Himesaka <himesaka@noa.codes> |
| 0038-iio-common-qcom_smgr-fix-sampling_frequency.patch | Noa Himesaka <himesaka@noa.codes> |
| 0039-dt-bindings-pinctrl-qcom-sdm630-allow-config-only-st.patch | Noa Himesaka <himesaka@noa.codes> |
| 0040-dt-bindings-watchdog-qcom-wdt-add-SDM660-APSS.patch | Noa Himesaka <himesaka@noa.codes> |
| 0041-arm64-dts-qcom-sdm630-sdm660-CPU-DVFS-idle-GPU-and-d.patch | Noa Himesaka <himesaka@noa.codes> |
| 0042-arm64-dts-qcom-add-the-HiBy-RS6.patch | Noa Himesaka <himesaka@noa.codes> |
| 0043-drm-msm-mdss-vote-the-MMSS-NoC-AHB-clock-on-SDM660.patch | Noa Himesaka <himesaka@noa.codes> |
| 0044-drm-msm-a5xx-don-t-read-the-GPMU-registers-on-GPUs-w.patch | Dmitry Baryshkov <dmitry.baryshkov@oss.qualcomm.com> |
| 0045-drm-msm-a5xx-say-why-the-GPMU-registers-are-only-dum.patch | Noa Himesaka <himesaka@noa.codes> |
| 0046-drm-msm-don-t-trust-a-fence-memptr-no-submit-wrote.patch | Noa Himesaka <himesaka@noa.codes> |
| 0047-drm-msm-a5xx-don-t-free-the-preemption-records-twice.patch | Noa Himesaka <himesaka@noa.codes> |
| 0048-drm-msm-reset-the-GPU-on-a-hardware-fault-with-no-su.patch | Noa Himesaka <himesaka@noa.codes> |
| 0049-drm-msm-check-every-ring-for-a-hang.patch | Noa Himesaka <himesaka@noa.codes> |
| 0050-drm-msm-a5xx-mask-the-hang-detector-until-the-GPU-is.patch | Noa Himesaka <himesaka@noa.codes> |
| 0051-dt-bindings-soc-qcom-smp2p-add-sleepstate-support.patch | Richard Acayan <mailingradian@gmail.com> |
| 0052-soc-qcom-smp2p-tell-the-remote-through-sleepstate-wh.patch | Noa Himesaka <himesaka@noa.codes> |
| 0053-arm64-dts-qcom-sdm630-add-the-ADSP-sleepstate-SMP2P-.patch | Noa Himesaka <himesaka@noa.codes> |
| 0054-iio-common-qcom_smgr-fix-the-QMI-layouts-of-the-buff.patch | Noa Himesaka <himesaka@noa.codes> |
| 0055-iio-common-qcom_smgr-default-to-the-lowest-native-ra.patch | Noa Himesaka <himesaka@noa.codes> |
| 0056-iio-common-qcom_smgr-check-the-AckNak-of-buffering-r.patch | Noa Himesaka <himesaka@noa.codes> |
| 0057-iio-common-qcom_smgr-no-sensor-reports-while-the-AP-.patch | Noa Himesaka <himesaka@noa.codes> |
| 0058-iio-common-qcom_smgr-batch-samples-up-to-the-buffer-.patch | Noa Himesaka <himesaka@noa.codes> |
| 0059-watchdog-hardlockup-skip-CPUs-whose-tick-is-frozen-f.patch | Noa Himesaka <himesaka@noa.codes> |
| 0060-ASoC-dt-bindings-qcom-q6asm-dais-native-DSD-on-qcom-.patch | Noa Himesaka <himesaka@noa.codes> |
| 0061-ASoC-qcom-q6asm-dai-native-DSD-on-qcom-s32-as-s16-pa.patch | Noa Himesaka <himesaka@noa.codes> |
| 0062-arm64-dts-qcom-sdm660-hiby-rs6-note-native-DSD-on-Mu.patch | Noa Himesaka <himesaka@noa.codes> |
| 0063-ASoC-qcom-q6asm-dai-offer-DSD-at-the-DSD-rates-only.patch | Noa Himesaka <himesaka@noa.codes> |
| 0064-ASoC-codecs-hiby-hm100-play-on-S-PDIF-with-nothing-p.patch | Noa Himesaka <himesaka@noa.codes> |
| 0065-ASoC-codecs-hiby-hm100-add-a-read-only-Output-Target.patch | Noa Himesaka <himesaka@noa.codes> |
| 0066-ASoC-codecs-hiby-hm100-leave-the-target-off-after-a-.patch | Noa Himesaka <himesaka@noa.codes> |
| 0067-ASoC-codecs-hiby-hm100-native-DSD.patch | Noa Himesaka <himesaka@noa.codes> |
| 0068-ASoC-codecs-hiby-hm100-keep-DSD-muted-across-pauses-.patch | Noa Himesaka <himesaka@noa.codes> |
| 0069-wifi-ath10k-use-connected-scan-timing-while-a-vdev-i.patch | Noa Himesaka <himesaka@noa.codes> |
| 0070-iio-common-qcom_smgr-accept-NAK_REPORT_ID-on-an-ADD-.patch | Noa Himesaka <himesaka@noa.codes> |
| 0071-iio-common-qcom_smgr-one-info-line-for-a-rate-fallba.patch | Noa Himesaka <himesaka@noa.codes> |
| 0072-iio-common-qcom_smgr-undo-the-probe-on-every-failure.patch | Noa Himesaka <himesaka@noa.codes> |
| 0073-ASoC-codecs-hiby-hm100-say-when-a-DSD-unmute-after-a.patch | Noa Himesaka <himesaka@noa.codes> |
| 0074-ASoC-qcom-q6asm-dai-offer-PCM-at-the-DAC-s-rates-onl.patch | Noa Himesaka <himesaka@noa.codes> |
| 0075-ASoC-codecs-hiby-hm100-log-an-unreachable-PCM-rate-a.patch | Noa Himesaka <himesaka@noa.codes> |
| 0076-arm64-dts-qcom-sdm630-Add-interconnect-paths-to-the-.patch | Fabricio Akio <fabricioakio@gmail.com> |
| 0077-arm64-dts-qcom-sdm660-hiby-rs6-give-the-hm100-SPI-co.patch | Noa Himesaka <himesaka@noa.codes> |
| 0078-interconnect-qcom-sdm660-Enable-keep_alive-and-sync_.patch | Fabricio Akio <fabricioakio@gmail.com> |
| 0079-clk-qcom-mmcc-sdm660-Do-not-keep-the-video-core-cloc.patch | Fabricio Akio <fabricioakio@gmail.com> |
| 0080-drm-msm-dsi-fix-AHB-clock-staying-enabled-across-sus.patch | Arpit Saini <arpit.saini@oss.qualcomm.com> |
| 0081-arm64-dts-qcom-sdm630-Switch-the-NoCs-to-two-interco.patch | Noa Himesaka <himesaka@noa.codes> |
| 0082-interconnect-qcom-icc-rpm-Allow-negative-QoS-offset.patch | Konrad Dybcio <konrad.dybcio@linaro.org> |
| 0083-interconnect-qcom-sdm660-Start-the-BIMC-region-after.patch | Noa Himesaka <himesaka@noa.codes> |
| 0084-dt-bindings-interconnect-qcom-msm8998-bwmon-Add-SDM6.patch | Noa Himesaka <himesaka@noa.codes> |
| 0085-arm64-dts-qcom-sdm630-Add-the-CPU-BWMON.patch | Noa Himesaka <himesaka@noa.codes> |
| 0086-dt-bindings-opp-qcom-osm-Allow-a-peak-bandwidth-per-.patch | Noa Himesaka <himesaka@noa.codes> |
| 0087-cpufreq-qcom-hw-Vote-the-bandwidth-of-the-starting-f.patch | Noa Himesaka <himesaka@noa.codes> |
| 0088-arm64-dts-qcom-sdm630-Add-the-CPU-memory-paths.patch | Noa Himesaka <himesaka@noa.codes> |
| 0089-arm64-dts-qcom-sdm660-hiby-rs6-Add-stock-s-DDR-floor.patch | Noa Himesaka <himesaka@noa.codes> |
| 0090-dt-bindings-clock-qcom-gcc-sdm660-Add-the-CXO2-input.patch | Noa Himesaka <himesaka@noa.codes> |
| 0091-clk-qcom-gcc-sdm660-Fix-parent-for-CLKREF-clocks.patch | Noa Himesaka <himesaka@noa.codes> |
| 0092-arm64-dts-qcom-sdm630-Feed-the-GCC-CLKREF-clocks-fro.patch | Noa Himesaka <himesaka@noa.codes> |
| 0093-clk-qcom-smd-rpm-Drop-the-handoff-votes-nobody-claim.patch | Noa Himesaka <himesaka@noa.codes> |
| 0094-drm-msm-gpu-Remove-the-bus-vote-when-the-GPU-is-susp.patch | Noa Himesaka <himesaka@noa.codes> |

## License

GPL-2.0-only, as the tree they apply to. New files carry their own SPDX headers inside the patches.
