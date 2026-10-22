# docs

Notes for the HiBy RS6 Linux port: how to install it, what the hardware looks like, the
reverse-engineering of HiBy's GPL stock kernel (4.4.153, firmware 1.80) and the stock boot chain that the
port is based on, and the mainline side of the port. Static analysis unless a page says "confirmed" (seen
in a live trace) or "on Nura".

## Install

- [docs/install.md](docs/install.md): the whole-eMMC install flow (U-Boot into `boot_a`, repartition,
  images), the partition layout and the rules the stock ABL imposes on it.

## Hardware and boot chain

- [docs/hardware.md](docs/hardware.md): the stock device tree, section by section (display, touch,
  storage, USB, charging, LEDs, keys, wireless, audio-adjacent pinctrl, memory, BLSP), and the
  accelerometer through the ADSP's SMGR and the sensor registry.
- [docs/boot-and-partitions.md](docs/boot-and-partitions.md): what the stock XBL and ABL want from the
  GPT: both XBL parsers, how XBL picks ABL by type GUID, ABL's partition names, slot attributes and raw
  write-back, and the Nura layout checked against all of it.

## Audio

- [docs/audio.md](docs/audio.md): the hm100 FPGA DAC (pins, bitstream load over JTAG, control words,
  register map, rate words, init sequence, filters, calibration), the analog chain and the
  `sa_sound_setting` sysfs interface (output sequencing, NJW1195A volume, the attributes that must never be
  written), the stock playback path from the HAL to the FPGA with the exact PO sequence a driver follows,
  the coaxial S/PDIF output and native DSD (stock, the mainline driver and the `rs6-spdif` userspace
  encoder), and the stock Darwin FIR filter files and how `darwinctl` uses them on Nura.

## Power, GPU and Wi-Fi (mainline side)

- [docs/suspend.md](docs/suspend.md): s2idle on SDM660: the wake storm from the ADSP sensor stream,
  hardlockup reports on frozen CPUs, and the sleep-set votes that kept the SoC out of VDD min, with the
  patches that fix them (vmin is reached on the unit); CPU BWMON and DDR floors; and the stock kernel's
  MPM system idle and `mdss_ahb_clk` suspend behaviour compared with the series.
- [docs/gpu-a5xx.md](docs/gpu-a5xx.md): the Adreno 512 CP microcode the port ships (stock PM4, the tulip
  PFP 0x5ff11a for 4 rings with preemption), the GPU hang recovery fixes and the Mesa a5xx patches.
- [docs/wifi.md](docs/wifi.md): WCN3990 latency, the connected-scan timing patch, the WLAN firmware (stock
  c2-00708) and the open Wi-Fi problems.

A flicker-free boot (U-Boot without a framebuffer clear, the kernel taking over ABL's display state, a
Plymouth theme continuing the stock splash) was tried and dropped as too much to maintain. Its notes are
not published; the boot uses Nura's own splash, and the screen blanks once when msm takes over
from simpledrm.

## RE tooling (docs/re-tools/)

- `decode-trace.py`: decodes the ftrace gpio/spi captures into hm100 and NJW1195A control words and Gowin
  JTAG instructions.
- `run-capture.sh`, `device.sh`: the capture scripts for a stock (rooted) RS6, desktop side and on-device
  side.
- `abl-gpt-check.py`, `xbl-gpt-check.py`: offline models of the stock ABL and XBL partition table
  handling.
- `test-repartition-nura.sh`: runs the repartition scripts from `main` (`tools/`) against sparse disk
  images and puts the results through the two models. Needs
  `NURA_GPTDUMP=<gpt_main0.bin of the 1.80 image>` and `NURA_TOOLS=<main>/tools`.

The stock images (ABL, XBL, kernel, HAL) that the notes were derived from are HiBy's and Qualcomm's and
are not in this repository; addresses in the notes refer to the 1.80 images. Capture files named in the
notes (`traces/*.txt`) are not published.
