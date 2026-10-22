# Accelerometer (auto-rotate)

The RS6's G-sensor (Kionix KXTJ2-1009, per HiBy's spec page) is not on any Linux I2C bus.
The Snapdragon Sensor Core inside the ADSP drives it, and Linux reads it over QMI. All the
kernel code is already in the sdm660-mainline tree. The only missing piece was the sensor
registry file.

## How it works

1. The ADSP boots (`qcom_q6v5_pas`). Its remoteproc adds the `qcom_common.sns-reg.N`
   auxiliary device. `qcom_sns_reg` loads `qcom/sensors/sns.reg-hiby,rs6` and serves it as
   QMI service 0x10f (Sensor Registry) on the APSS.
2. The ADSP's Sensor Manager (SMGR) reads its config groups from that service. Then it
   probes the sensors listed in the registry and publishes QMI service 0x100 instance 50
   (SMGR). Without the registry no SMGR service appears, which is Nura's state today.
3. The QRTR bus turns service 0x100 into a device with modalias `qrtr:100:3201`, so udev
   loads `qcom_smgr`. That driver adds a `qcom-smgr-accel` platform device, which loads
   `qcom_smgr_accel` and creates the IIO device `qcom-smgr-accel`. It has buffer-only
   channels and no trigger. Values are 1/65536 m/s², and `in_mount_matrix` converts SMGR's
   frame to the IIO one.
4. iio-sensor-proxy (3.9 handles buffers without a trigger) tags it `iio-buffer-accel`.
   KWin rotates the screen, because `autoRotation` is `InTabletMode` and Plasma Mobile is
   always in tablet mode.

## Evidence

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

## Options

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

## Packaging

- pmOS: `firmware-hiby-rs6` carries `sensors/sns.reg` (the `firmware` branch;
  `tools/make-firmware-tarball.sh` takes it from `persist.bin`, listed in MANIFEST.tsv). It
  installs it as `/usr/lib/firmware/qcom/sensors/sns.reg-hiby,rs6`. The kernel config
  already has `CONFIG_QRTR(_SMD)=m`, `CONFIG_QCOM_SNS_REG=m`, `CONFIG_IIO_QCOM_SMGR=m` and
  `CONFIG_IIO_QCOM_SMGR_ACCEL=m`. iio-sensor-proxy comes with Plasma Mobile. No DT change.
- Arch Linux Ports: the same file at the same path in the firmware package, the same
  kernel options, and `iio-sensor-proxy` from the repos. Nothing here depends on the libc.
- Kernel: "iio: common: qcom_smgr: fix sampling_frequency" in `patches/linux`. `qcom_smgr` ignored a
  written `in_accel_sampling_frequency`, because buffering always used the default rate (highest native, capped by SMGR's max).
  `read_avail` also handed the IIO core a stack array. Both are fixed there.

## Still to check on the device

- On the running RS6 (no reboot), bind `qcom_sns_reg` with the registry, wait for
  `qrtr:100:3201` and read samples; that also shows SMGR's max rate. Then start iio-sensor-proxy and check `monitor-sensor`.
- Orientation. SMGR applies the registry axis map (-2,1,3, the QRD value HiBy kept), and
  the driver's matrix does the rest. Held upright in portrait, iio-sensor-proxy must say
  "normal". If it doesn't, fix it with an `ACCEL_MOUNT_MATRIX` hwdb entry in
  device-hiby-rs6.
- After a reboot, check that KWin follows when iio-sensor-proxy starts
  after the session. The fastrpc-adsp rule starts it at boot, before SMGR is up, and it
  exits.
- Suspend. Stock tells the ADSP when the AP sleeps through the outbound smp2p entry
  `sleepstate` (remote-pid 2, `qcom,smp2pgpio-sleepstate-out`, stock DT). Mainline has no
  such driver. If something keeps the accel buffer enabled through s2idle, SMGR may keep
  sending reports and waking the AP. Check the GLINK IRQ counts in /proc/interrupts
  across a suspend while auto-rotate is on.
