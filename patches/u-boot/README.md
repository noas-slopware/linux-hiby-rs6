# U-Boot series

6 patches for the HiBy RS6, as `git format-patch --no-signature` output.

Base:

- tree: https://github.com/sdm660-mainline/u-boot
- branch: `release/v2026.10-sdm660`
- commit: `608a227567373f0274617e8829398fb0c1f1c1a5`

Apply:

```
git clone -b release/v2026.10-sdm660 https://github.com/sdm660-mainline/u-boot && cd u-boot
git checkout 608a227567373f0274617e8829398fb0c1f1c1a5
git am /path/to/linux-hiby-rs6/patches/u-boot/0*.patch
```

What they do: clock divider fix for the RCG, QUP I2C clock/probe fixes, pinctrl function for the
BLSP2 I2C6 bus, the RS6 device tree (`sdm660-hiby-rs6.dts`, based on the SDM660 lavender tree,
Alexey Minnekhanov), and the off-mode charging screen with battery digits (`rs6_charger.c`).

## Build

The board fragment is `board/qualcomm/hiby-rs6.config` (added by patch 0006). It goes on top
of `qcom_defconfig`, `qcom-sdm660-phone.config` and `qcom-downstream.config`. The build line from
`docs/install.md` (docs branch):

```
make CROSS_COMPILE=aarch64-linux-gnu- O=.output qcom_defconfig qcom-sdm660-phone.config \
     qcom-downstream.config hiby-rs6.config
make CROSS_COMPILE=aarch64-linux-gnu- O=.output -j"$(nproc)"
cp .ci/*.sh .output/ && cp -r .ci/bootimg_params .output/ && cd .output && ./bootimg-all.sh
```

`bootimg-all.sh` needs `.ci/bootimg_params/sdm660-hiby.sh` (boot image header v1 with the stock
`boot_a` load addresses). Upstream's `.gitignore` hides that directory, so it is not part of the
series: it is in `extra/sdm660-hiby.sh`. Copy it to `.ci/bootimg_params/` before the last step.

## Not in this series

A silent boot environment (no framebuffer clear, no logo) and button labels for the boot menu were tried
as part of a flicker-free boot and dropped with it; they are not published. The U-Boot on the author's unit
is again the off-mode charging build without them.

`git am` of the 6 files on the base commit gives the same tree as the author's working branch (tree object
`01729e5e697d7112c61d7993f132cf2dfdf49ed0`).

## Authors in the series

| patch | author |
|---|---|
| 0001-clk-qcom-replace-the-RCG-divider-instead-of-ORing-it.patch | Noa Himesaka <himesaka@noa.codes> |
| 0002-i2c-qup-fail-probe-when-the-clocks-can-t-be-enabled.patch | Noa Himesaka <himesaka@noa.codes> |
| 0003-pinctrl-qcom-sdm660-add-the-blsp_i2c6-function.patch | Noa Himesaka <himesaka@noa.codes> |
| 0004-clk-qcom-sdm660-add-the-BLSP2-AHB-and-QUP2-I2C-clock.patch | Noa Himesaka <himesaka@noa.codes> |
| 0005-arm-dts-qcom-add-the-HiBy-RS6.patch | Noa Himesaka <himesaka@noa.codes> |
| 0006-mach-snapdragon-add-HiBy-RS6-off-mode-charging.patch | Noa Himesaka <himesaka@noa.codes> |

## License

GPL-2.0-only for the new files (SPDX headers inside the patches), as U-Boot.
