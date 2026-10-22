# docs

Notes for the HiBy RS6 Linux port: how to install it, what the hardware looks like, and the
reverse-engineering of HiBy's GPL stock kernel and the stock boot chain that the port is based on.
Static analysis unless a page says "confirmed" (seen in a live trace) or "on Nura".

## Install

- [docs/install.md](docs/install.md): the whole-eMMC install flow (U-Boot into `boot_a`, repartition,
  images), the partition layout and the rules the stock ABL imposes on it.

## Hardware and kernel RE (HiBy stock kernel 4.4.153, firmware 1.80)

- [docs/rs6-hardware-map.md](docs/rs6-hardware-map.md): the stock device tree, section by section (display,
  touch, storage, USB, charging, LEDs, keys, wireless, audio-adjacent pinctrl, BLSP).
- [docs/hm100-protocol.md](docs/hm100-protocol.md): the hm100 FPGA DAC: pins, bitstream load over JTAG,
  control words, register map, sample-rate words, init sequence, filters, calibration.
- [docs/sa-sound.md](docs/sa-sound.md): the `sa_sound_setting` sysfs interface, output sequencing, volume (NJW1195A),
  power, MI2S.
- [docs/playback-path.md](docs/playback-path.md): the path from the HAL to the FPGA, with the exact PO sequence the
  mainline driver follows and which attributes must never be written.
- [docs/darwin-filters.md](docs/darwin-filters.md): the stock Darwin FIR filter files, how stock lists and selects them, and
  how `darwinctl` uses them on Nura.
- [docs/sensors.md](docs/sensors.md): the accelerometer through the ADSP's SMGR and the sensor registry.
- [docs/re-mpm-mdss.md](docs/re-mpm-mdss.md): MPM system idle and the `mdss_ahb_clk` suspend behaviour in the stock kernel.

## Port notes (mainline side)

- [docs/suspend.md](docs/suspend.md): s2idle on SDM660: the wake storm from the ADSP sensor stream, hardlockup reports on
  frozen CPUs, and the sleep-set votes that kept the SoC out of VDD min, with the patches that fix them (vmin is
  reached on the unit); CPU BWMON and DDR floors.
- [docs/spdif-dsd.md](docs/spdif-dsd.md): the coaxial S/PDIF output and native DSD: what the stock kernel does, the
  stream format, the mainline driver and the `rs6-spdif` userspace encoder.
- [docs/gpu-a5xx.md](docs/gpu-a5xx.md): the Adreno 512 CP microcode the port ships (stock PM4, the tulip PFP 0x5ff11a for
  4 rings with preemption), the GPU hang recovery fixes and the Mesa a5xx patches.
- [docs/wifi.md](docs/wifi.md): WCN3990 latency, the connected-scan timing patch, the WLAN firmware (stock c2-00708)
  and the open Wi-Fi problems.

A flicker-free boot (U-Boot without a framebuffer clear, the kernel taking over ABL's display state, a Plymouth
theme continuing the stock splash) was tried and dropped as too much to maintain. Its notes are not published;
the boot uses postmarketOS's own splash, and the screen blanks once when msm takes over from simpledrm.

## Boot chain

- [docs/abl-gpt.md](docs/abl-gpt.md): what the stock ABL wants from the GPT.
- [docs/xbl-gpt.md](docs/xbl-gpt.md): what the stock XBL wants from the GPT.

## RE tooling (docs/re-tools/)

- `decode-trace.py`: decodes the ftrace gpio/spi captures into hm100 and NJW1195A control words and Gowin JTAG instructions.
- `run-capture.sh`, `device.sh`: the capture scripts for a stock (rooted) RS6, desktop side and on-device side.
- `abl-gpt-check.py`, `xbl-gpt-check.py`: offline models of the stock ABL and XBL partition table handling.
- `test-repartition-nura.sh`: runs the repartition scripts from `main` (`tools/`) against sparse disk images and puts the
  results through the two models. Needs `NURA_GPTDUMP=<gpt_main0.bin of the 1.80 image>` and `NURA_TOOLS=<main>/tools`.

The stock images (ABL, XBL, kernel, HAL) that the notes were derived from are HiBy's and Qualcomm's and are not in this
repository; addresses in the notes refer to the 1.80 images. Capture files named in the notes (`traces/*.txt`) are not published.
