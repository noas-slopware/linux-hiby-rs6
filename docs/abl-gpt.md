# What the stock ABL wants from the GPT

Decompiled 2026-10-21 to check the Nura repartition layout (`tools/lib/nura-gpt.sh` on the main
branch, `docs/install.md` section 4) before it goes near the device. Ghidra 12 headless only.
The ABL and XBL images are HiBy's/Qualcomm's and are not part of this repository; the findings
are the documented result, the addresses are RVAs in the 1.80 images.

## The binary

- `abl_a` from the 1.80 dump (`abl_a.bin`, ELF32 wrapper). This is
  the ABL that runs now: since `edl setactiveslot a` swapped the A/B type GUIDs, `abl_a`
  carries the ABL type GUID, and XBL loads ABL by type GUID only, first match in table
  order (docs/xbl-gpt.md). `abl_b` is byte-identical to `abl_a` in the 1.80 dump.
- FV = LZMA GUIDed section at file offset 0x3078 (`lzma.FORMAT_ALONE`), 331976 bytes,
  sha256 75c391ce...b436. LinuxLoader PE32+ (AArch64) = FFS section at FV offset 0xb8,
  331780 bytes, extracted as `LinuxLoader.efi`, sha256 08832212...0818. Image
  base 0, so the addresses below are RVAs. It is a HiBy DEBUG build
  (`/mnt/android-disk1/HiBy/sc66/RS6Int/...`, DEBUG_CLANG35) of the Qualcomm LA edk2
  LinuxLoader.
- Decompile everything with a small Ghidra `-postScript` that walks all functions (not published).

| function | name in Qualcomm's source |
|---|---|
| 0x14b8 | LinuxLoaderEntry |
| 0x187a0 | EnumeratePartitions |
| 0x178f0 | UpdatePartitionEntries |
| 0x17ab0 | GetPartitionIndex (exact name, 0x24 chars) |
| 0x17298 | PartitionHasMultiSlot |
| 0x17368 | GetActiveSlot |
| 0x18f78 | GetBootPartitionEntry |
| 0x1a008 | FindBootableSlot, with ValidateSlotGuids and MarkPtnActive inlined |
| 0x19d20 | HandleActiveSlotUnbootable |
| 0x19128 | SetActiveSlot (+ GetMultiSlotPartsList, type-GUID swap) |
| 0x17b38 | UpdatePartitionAttributes, the only raw GPT access |
| 0x5890 | LoadImageAndAuth |
| 0x13038 | GetSystemPath |
| 0x14310 | RecoveryInit (misc) |
| 0x24ebc | CompareMem (edk2 `CompareMemWrapper.c`; 0 = equal) |

Boot path (0x14b8): EnumeratePartitions, UpdatePartitionEntries, PartitionHasMultiSlot(L"boot"),
FindPtnActiveSlot, key check, RecoveryInit, LoadImageAndAuth (0x5890), BootLinux (0xa6b0).
If LoadImageAndAuth fails, it prints "LoadImageAndAuth failed" and starts fastboot. That is
what happened on 10-20.

## 1. How partitions are enumerated

- **ABL does not parse the GPT to find partitions.** 0x187a0 asks for BlockIo handles under
  the eMMC user area (`BLK_IO_SEL_MATCH_ROOT_DEVICE` 0x100, root type
  b615f1f5-5088-43cd-809c-a16e52487d00, after a NAND try with 03ef84a9-...), at most 0x80
  per LUN; eMMC means 1 LUN. 0x178f0 then calls HandleProtocol(gEfiPartitionRecordGuid
  fe2555be-d716-4686-b9d0-79db5921b70d) on each handle and copies the 0x80-byte GPT entry
  into `PtnEntries[i]` (0x3d65c, stride 0x84, LUN at +0x80). The counter (0x4185c) goes up
  for every handle, even one without a record ("does not have partition record, ignore"),
  and stops at 0x80 (`if (0x7f < uVar7 + uVar6 + 1) break`).
- `root=/dev/mmcblk0p%d` takes the raw index (0x13290: `mov w3,w22`, no +1), and stock
  Android booted with it. So `PtnEntries[0]` is the whole-disk handle and entry k sits at
  index k: at most 127 partitions.
- Empty entries, CRCs and entry counts are therefore XBL's business (its PartitionDxe).
  docs/xbl-gpt.md (Ghidra, 2026-10-21) settles it: XBL does NOT stop at an empty entry.
  Both its loader parser (0x140472c8) and PartitionDxe skip empty entries, and PartitionDxe
  makes one handle per surviving entry. A hole therefore shifts every later handle down by
  one, so handle k is no longer entry k: ABL's `mmcblk0pN` and its write-back by position
  (below) then hit the wrong entries. That is why holes are still forbidden. The earlier
  "stop at the first empty entry" inference was wrong. bkerler edl
  stops at the first entry with a zero *unique* GUID (`edlclient/Library/gpt.py:383`).
  ABL itself checks no CRC and does not compare entry counts on the boot path.
- **The one raw GPT access is UpdatePartitionAttributes (0x17b38)**, and it runs on
  **every** boot through MarkPtnActive. With hard-coded geometry it:
  - reads 33 blocks from LBA 1 (header, then entries assumed at LBA 2), and 33 blocks from
    `LastBlock+1-33` (entries assumed at TOTAL-33, header at TOTAL-1). It never reads
    PartitionEntryLBA from either header;
  - walks `PtnEntries` and, **for the k-th non-empty one, rewrites raw entry k's type GUID
    and attributes** when they differ. The mapping is by position, not by name or GUID;
  - if `NumberOfPartitionEntries * SizeOfPartitionEntry > 0x4000` it prints "Invalid GPT
    header fields MaxPtnCount" and does not write;
  - recomputes the entry CRC over `hdr[0x50] * hdr[0x54]` bytes and the header CRC over
    0x5c bytes, then writes both 33-block windows back (only if something changed).

  What follows from that: every entry must reach ABL in table order with no gaps (a hole
  or a dropped entry shifts every attribute and type GUID write by one). The backup entry
  array has to start at TOTAL-33, or ABL writes into the wrong sectors and leaves the
  backup CRC covering them. No partition may sit in LBA 1-33 or the last 33 LBAs. With
  n=68 (8704 bytes) the 16 KiB limit holds.
- The fastboot GPT-flash checks ("Gpt signature is not correct", "Invalid Max Partition
  Count", "GPT first usable LBA mismatch", "Header CRC mismatch", 0x3426d-0x34c34) are only
  strings in this build: neither Ghidra xrefs nor an operand scan finds any code that uses
  them. They do not apply.

## 2. Names ABL needs and what it does with them

| name | used by | missing or wrong |
|---|---|---|
| `boot_a`, `boot_b` | 0x17298 (two `boot_[ab]` names = multislot); 0x18f78 exact names; GetActiveSlot reads both | "No boot partition entry for slot", no bootable slot, fastboot |
| `system_<slot>` | ValidateSlotGuids in 0x1a008 ("system_x" with the slot letter) | "ValidateSlotGuids: No partition entry", FindBootableSlot clears the suffix, "No bootable slot", fastboot |
| `system_<slot>` type GUID | 0x1a008: `CompareMem(boot_<slot>.type, system_<slot>.type, 16) == 0` fails the slot | "BootableSlot %s does not have valid guids", fastboot |
| `system_<slot>` index | GetSystemPath 0x13038, called from 0x5890 only when the boot.img header cmdline (offset 0x40) has no `root=` | "System partition does not exist", "GetSystemPath failed!", fastboot |
| `dtbo_<slot>` | 0x5890 | optional ("No dtbo partition is found, Skip dtbo") |
| misc, by type GUID 82acc91f-357c-4a68-9c8f-689e1b1a23a1 | RecoveryInit 0x14310 (`boot-recovery` only), FFBM 0x146d0 (`ffbm-`) | ignored ("RecoveryInit failed ignore") |

- U-Boot's boot.img cmdline is `uboot2nd` (checked in the built U-Boot boot images and in the
  pre-U-Boot boot_a backup), so GetSystemPath runs on every boot. ABL appends
  `root=/dev/dm-0 dm="system none ro,0 1 android-verity /dev/mmcblk0pN"` to the cmdline it
  gives U-Boot, and U-Boot ignores it.
- Only the **index** of system_<slot> is used. ABL never reads system's contents or size
  (it loads only boot_<slot> and dtbo_<slot>), so a 1 MiB dummy anywhere is fine. vendor_a/b
  and userdata are not looked up on the boot path (userdata/system appear only in the
  fastboot `partition-type` table at 0x20b74).
- `bootonce-bootloader` is not in the binary. ABL reads misc for `boot-recovery` and `ffbm-`
  only. The string comes from U-Boot (`drivers/fastboot/fb_common.c:96`, written on
  `fastboot reboot-bootloader`). Zeroing misc is still right.

## 3. Slot attributes (bits of the 64-bit entry attributes)

48-49 priority, 50 active, 51-53 retry count, 54 successful, 55 unbootable.

- GetActiveSlot (0x17368): `boot_a`, then `boot_b`. A slot counts if it is active with
  priority > 0, and `_b` wins only with a strictly higher priority. If neither counts and
  boot_a's byte 6 has none of 0xc7 set (first boot), it sets byte 6 = 0x3f and writes the
  GPT; otherwise "No active slot found".
- FindBootableSlot (0x1a008): if not unbootable and successful, boot. If not successful
  with retry > 0, it lowers the retry count and writes the GPT. Otherwise it hands over to
  HandleActiveSlotUnbootable (0x19d20), which sets unbootable and switches to the other
  slot if that one is `(byte6 & 0xc0) == 0x40`.
- SetActiveSlot (0x19128): the new slot's boot byte 6 becomes 0x3f, the old one gets
  priority 2 and loses active. It swaps the type GUIDs of every A/B pair (names equal
  except the last character and containing `_a` or `_b`).
- MarkPtnActive (inlined at 0x1a354 and 0x19abc): bit 50 is set on **every entry whose name
  contains the slot suffix** (StrStr) and cleared on all others, then 0x17b38 runs.
- Now: boot_a byte 6 = 0x6f (priority 3, active, retry 5, successful), boot_b 0x3a. The
  scripts leave boot_a/boot_b byte-identical.
- `nura_boot` contains `_b`, so it gets bit 50 whenever slot B is active. Linux and U-Boot
  ignore bits 48-63, so this is cosmetic. `nura_swap1`/`nura_swap2` differ only in the last
  character but contain neither `_a` nor `_b`, so they are not treated as an A/B pair.

## 4. The layout against these rules

The stock table is not what the old test modelled. The 1.80 zip's `gpt_main0.bin` has
**68 entries** (entries LBA 2-18, first usable 34, last usable TOTAL-34), 67 used. The
synthetic test table had 128.

| rule | new layout |
|---|---|
| boot_a, boot_b present and untouched | yes (#46, #47, byte-identical) |
| system_a, system_b present | #51 (sector 34), #68 (sector 17826048) |
| system_<slot> type differs from boot_<slot> | 8300 vs boot / inactive GUID: yes |
| no holes, all 68 entries handed to ABL in order | 68/68 used; the table is now full |
| ≤ 127 partitions, entries ≤ 16 KiB | 68, 8704 bytes |
| nothing in LBA 1-33 or the last 33 | lowest start 34, highest end TOTAL-34 |
| primary entries at LBA 2, header 92 bytes | kept from stock |
| backup entries at TOTAL-33 | **only if the dump already had them there** (sgdisk keeps the dumped location); now pinned |
| no attribute bit 1 (EDK2 drops such entries) | none set |

Script fix (`tools/lib/nura-gpt.sh`): `nura_build_gpt` pins the backup array with
`sgdisk -k TOTAL-33`. `nura_validate` now checks the header geometry ABL assumes (primary
at LBA 1, entries at LBA 2, 92-byte header, ≤ 16 KiB; backup header at TOTAL-1 with entries
at TOTAL-33), that no partition touches ABL's two windows, that boot_b is present, that
system_<s> and boot_<s> have different type GUIDs, and that no entry has attribute bit 1.
`flash-nura-ums.sh` also requires boot_b.

The device's backup array sits at TOTAL-33. HiBy's 1.50 factory package
(HiBy's official 1.50 burn package, same partition names and start
LBAs as the 1.80 table) writes `gpt_backup0.bin` (33 sectors) at `NUM_DISK_SECTORS-33.`
(`rawprogram_unsparse.xml:131`) and patches the backup header's PartitionEntryLBA to
`NUM_DISK_SECTORS-33.`, its CRC over `CRC32(NUM_DISK_SECTORS-33.,8704)` = 68 x 128 bytes
(`patch0.xml:18-23`). The 1.80 dump kept only the array. The scripts produce TOTAL-33 either
way. Before the fix, a TOTAL-18
backup would have survived the repartition, and ABL's first write-back would have broken
it.

`docs/re-tools/abl-gpt-check.py <image>` models all of the above (enumeration under both
stop-at-empty and EDK2 rules, GetActiveSlot, FindBootableSlot, ValidateSlotGuids,
GetSystemPath, and the MarkPtnActive + UpdatePartitionAttributes write-back on both GPTs).
`docs/re-tools/test-repartition-nura.sh` builds the stock table from the real 68-entry GPT dump,
puts its backup array at TOTAL-18, runs both scripts and the model, and adds negative cases (backup
array in the wrong place, system_b with boot_b's type GUID). Result, 2026-10-21: ALL PASS, on
the stock table as dumped (slot B active) and, with a one-off helper that swaps the A/B type GUIDs and
flags like `edl setactiveslot a` (not published), with slot A active, which is the state of the unit
once U-Boot sits in boot_a. In that state ABL boots slot _a with `root=/dev/mmcblk0p51`, and its first
write-back sets bit 50 on the new system_a only; both GPTs stay valid afterwards.

XBL's GPT handling and the Nura tables are checked in docs/xbl-gpt.md (and by
`docs/re-tools/xbl-gpt-check.py`, run by the test). `abl_a.bin == abl_b.bin` in
the 1.80 dump (sha256 7380e5ba...). A real reboot through XBL and ABL remains the test.
