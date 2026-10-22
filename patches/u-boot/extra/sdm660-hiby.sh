# HiBy RS6: same load addresses as the stock 1.80 boot_a.img (header v1, Android 9, 2019-07)
flash_offset_base="0x00000000"
flash_offset_kernel="0x00008000"
flash_offset_ramdisk="0x01000000"
flash_offset_second="0x00f00000"
flash_offset_tags="0x00000100"
flash_pagesize="4096"
extra_mkbootimg_args="--header_version 1 --os_version 9.0.0 --os_patch_level 2019-07"
