# Boot chain and partition table: what the stock XBL and ABL want from the GPT

The stock XBL and ABL of firmware 1.80 decompiled, to check the Nura repartition layout
(`tools/lib/nura-gpt.sh` on the main branch, `docs/install.md` section 6) before it goes near the device.
Decompiled 2026-10-21, Ghidra 12 headless only. The XBL and ABL images are HiBy's and Qualcomm's and are
not part of this repository; the findings are the documented result, and the addresses refer to the 1.80
images (VAs in the XBL loader, RVAs in the PE32 files).

The chain: the boot ROM (PBL) loads `xbl`; the XBL loader (SBL1) loads the images in its config table,
ABL among them, picked by partition type GUID; XBL core (UEFI) makes one BlockIo handle per GPT entry and
its BDS launches LinuxLoader (ABL), which loads `boot_<slot>`. On Nura `boot_a` holds U-Boot.

## Contents

- [The binaries](#the-binaries): XBL, ABL, the decompile and the function tables
- [How the GPT is read](#how-the-gpt-is-read): the XBL loader, XBL core's PartitionDxe, ABL's
  enumeration and its raw write-back, and what follows for holes, entry count, CRCs and the backup
- [How XBL picks ABL](#how-xbl-picks-abl) and [what else XBL needs](#what-else-xbl-needs-from-the-table)
- [Names ABL needs](#names-abl-needs) and [slot attributes](#slot-attributes)
- [Factory packages](#factory-packages)
- [The Nura layout against these rules](#the-nura-layout-against-these-rules)

## The binaries

### XBL

- `xbl_a.bin` and `xbl_b.bin` from `HiBy RS6 1.80.zip` are identical, sha256 f4079b31...af9d (3670016
  bytes, the partition dump). The 1.50 factory `xbl.elf` (sha256 fc94243e...2e41, 2565945 bytes) has the
  same ELF header and all 16 program segments byte-identical; only the padding differs. So everything
  below holds for both. Build: `BOOT.XF.1.4-00277-S660LZB-1`, `OEM_IMAGE_VERSION_STRING=SH-SW-lUCY`
  (`d:\prebuilt_for_qfil\sc66_r01_r034\boot.xf.1.4`).
- XBL is one ELF64 (AArch64) with two programs in it:
  - **XBL loader** (SBL1): code segment at 0x14015000 (file 0x3000, 0x55e5c bytes, sha256
    0ab74f56...7b1e), data at 0x1407a000 (file 0x58e60, 0x7c94 bytes, sha256 c3ba70ef...1ade). Ghidra
    imports `xbl_a.bin` directly as ELF; addresses below are VAs.
  - **XBL core** (UEFI): the FD at 0x9fc00000 (file 0x7e6c0, 0x1b5800 bytes, sha256 21b7970a...3c90). The
    DXE FV is a gzip GUIDed section (1d301fe9-be79-4353-91c2-d23bc959ae0c) in FFS file 9e21fd93-... at FD
    offset 0x29d50, data at 0x29d80, 4699848 bytes unpacked (sha256 debb48d9...32e2). Two small local
    scripts (not published) cut the ELF segments and walk the FV (pad files, LZMA and gzip GUIDed
    sections), writing every PE32 under its UI name. The ones used here (image base 0, addresses are
    RVAs):

| file | sha256 |
|---|---|
| PartitionDxe.efi | 63fcc316...a935 |
| QcomBds.efi | 4d951047...db70 |
| SdccDxe.efi | d59b69e2...ecd3 |
| DiskIoDxe.efi | fe3f7c79...c88b |
| TzDxe.efi, MdtpDxe.efi, LimitsDxe.efi, UFSDxe.efi | GUID scan only, not decompiled |
| uefiplat.cfg, SecParti.cfg | raw sections from the same FV |

Decompiled with a Ghidra `-postScript` that dumps every function (one `.c` per program; not published).
Config-table callbacks are reached only through data pointers, so Ghidra makes no function for some of
them; a second script that creates and decompiles a function at a given address handles those.

| function | what it is |
|---|---|
| 0x140465e0 | hotplug poll of the SDCC device: one node per hardware partition, then one node per GPT entry, **at most 0x40** |
| 0x14046ce8 | GPT open: MBR check, primary header at LBA 1, else backup at `blocks-1` |
| 0x14046d98 | MBR sanity (55AA) |
| 0x14046ef0 | GPT header + entry-array validation |
| 0x140472c8 | next entry: **skips** entries with a zero type GUID |
| 0x14045de4 | node pool, 0x4a nodes |
| 0x14045768 | appends a node to the device list (so the list is in entry order) |
| 0x140454f8 | find partition by **type GUID**: first matching node |
| 0x1402cf7c, 0x1402cfcc | boot_sdcc_hotplug: set partition id, open the image's partition |
| 0x1402e200, 0x1402e174 | boot_elf_loader: open + read ELF header (fatal if open fails), "is it an ELF" |
| 0x1402d8d4 | boot_config: process one config-table entry (load_cancel at +0x48) |
| 0x1407a728 | sbl1_config table, 9 entries of 0x90 bytes; type GUIDs at 0x1407b590-0x1407b660 |
| 0x14023b4c | ABL load_cancel |
| 0x14023e24 | APPSBL entry: repointed at the xbl partition, loads XBL core |
| PartitionDxe 0x25c0 | PartitionInstallGptChildHandles (edk2 Gpt.c, plus a Qualcomm resize/PMBR fix-up) |
| PartitionDxe 0x3008 | PartitionValidGptTable |
| PartitionDxe 0x31b4 | PartitionRestoreGptTable |
| PartitionDxe 0x3668 | PartitionCheckGptEntry |
| PartitionDxe 0x1cac | PartitionInstallChildHandle (installs the fe2555be partition record ABL reads) |
| QcomBds 0xc904, 0xb884 | launch `DefaultBDSBootApp` = LinuxLoader (uefiplat.cfg), then "Press any key to shutdown" |

The same hotplug/GPT code is duplicated in XBLRamDump (0x85e3xxxx-0x85e5xxxx, same 0x40 cap). It only
runs in crash-dump mode; the loader copies are cited.

### ABL

- `abl_a` from the 1.80 dump (`abl_a.bin`, ELF32 wrapper). This is the ABL that runs now: since
  `edl setactiveslot a` swapped the A/B type GUIDs, `abl_a` carries the ABL type GUID, and XBL loads ABL
  by type GUID only, first match in table order (see [How XBL picks ABL](#how-xbl-picks-abl)).
  `abl_a.bin == abl_b.bin` in the 1.80 dump (sha256 7380e5ba...8120), so the analysis covers slot B too.
- FV = LZMA GUIDed section at file offset 0x3078 (`lzma.FORMAT_ALONE`), 331976 bytes, sha256
  75c391ce...b436. LinuxLoader PE32+ (AArch64) = FFS section at FV offset 0xb8, 331780 bytes, extracted as
  `LinuxLoader.efi`, sha256 08832212...0818. Image base 0, so the addresses below are RVAs. It is a HiBy
  DEBUG build (`/mnt/android-disk1/HiBy/sc66/RS6Int/...`, DEBUG_CLANG35) of the Qualcomm LA edk2
  LinuxLoader.
- Decompiled with a small Ghidra `-postScript` that walks all functions (not published).

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
FindPtnActiveSlot, key check, RecoveryInit, LoadImageAndAuth (0x5890), BootLinux (0xa6b0). If
LoadImageAndAuth fails, it prints "LoadImageAndAuth failed" and starts fastboot. That is what happened on
2026-10-20.

## How the GPT is read

There are two independent parsers in XBL. The loader's picks the images XBL loads (and ABL); the UEFI one
makes the BlockIo handles ABL enumerates. ABL itself parses no GPT to find partitions, but rewrites raw
entries on every boot.

### XBL loader (0x14046ce8 and helpers)

- **MBR:** sector 0 is read. If it has 55AA, one of the four MBR entries must be type 0xEE or the disk
  counts as "no GPT" (`while (cVar1 != -0x12)` over `lVar3 + 0x1c2`, stride 0x10). Without 55AA it goes
  straight to the GPT header.
- **Header** (0x14046ef0, called with LBA 1): `"EFI PART"`, CRC32 over a **fixed 0x5c bytes** with the CRC
  field zeroed (`FUN_14047778(lVar8,0x5c,0)`), `MyLBA == lba` (`*(long *)(lVar8 + 0x18) == param_1`),
  `NumberOfPartitionEntries != 0`, `SizeOfPartitionEntry != 0` and a multiple of 128
  (`(*(ushort *)(lVar8 + 0x54) & 0x7f) != 0` fails), last array LBA <= disk block count, then CRC32 of
  `n * size` bytes from `PartitionEntryLBA` (+0x48) must equal +0x58. No check of FirstUsable/LastUsable,
  no check of the entries' ranges, overlaps or attributes.
- **Backup:** if the primary fails, the same check at `blocks - 1`
  (`FUN_14046ef0(*(int *)(DAT_146b44c0 + 0x14) + -1, ...)`), with `MyLBA` = that LBA and the array read
  from the **backup header's own PartitionEntryLBA**. The primary's AlternateLBA is read into a local and
  never used. The loader never writes the GPT.
- **Entries** (0x140472c8): it walks all `NumberOfPartitionEntries` slots and returns the next one whose
  16-byte type GUID is not zero. Empty slots are **skipped, not a stop**:

  ```c
  for (iVar7 = 0x10; 0 < iVar7; iVar7 = iVar7 + -4) {
    if (*piVar8 != 0) { return piVar2; }   /* non-empty: hand it out */
    piVar8 = piVar8 + 1;
  }                                         /* empty: loop to the next slot */
  ```
- **64-entry cap** (0x140465e0): one node per returned entry, in entry order, until the parser runs out,
  the pool is empty, or 64 nodes:

  ```c
  do {
    lVar11 = FUN_140472c8(lVar10);
    if ((lVar11 == 0) || (lVar12 = FUN_14045de4(), lVar12 == 0)) break;
    *(undefined4 *)(lVar12 + 0x30) = 3;                            /* GPT partition node */
    *(byte *)(lVar12 + 0x2d) = *(byte *)(lVar11 + 0x30) >> 2 & 1;  /* attribute bit 2 only */
    FUN_14061b8c(lVar12 + 0x34,0x10,lVar11,0x10);                  /* type GUID */
    *(int *)(lVar12 + 0x44) = *(int *)(lVar11 + 0x20);             /* start, 32 bit */
    *(int *)(lVar12 + 0x48) = (iVar4 - iVar2) + 1;                 /* size, 32 bit */
    ...
  } while ((uint)lVar9 < 0x40);
  ```
  So the XBL loader only knows the **first 64 non-empty entries** of the user area. The node pool (0x4a
  nodes, 0x14045de4) also holds the device and hardware-partition nodes, so 64 is the binding limit. Names,
  unique GUIDs and attributes other than bit 2 are not stored.

### XBL core PartitionDxe (UEFI, 0x25c0)

Plain edk2 `Gpt.c` of the 2015 era, with two Qualcomm additions (the PMBR rewrite and the disk-size
fix-up below; upstream gives up in both cases):

- **PMBR:** looks for an MBR entry with boot indicator 0, type 0xEE, start LBA 1. If there is none it
  still parses the GPT and then **writes a PMBR to LBA 0** (sets entry 0 to boot 0, start 1, type 0xEE,
  55AA).
- **Header** (0x3008): `"EFI PART"`, CRC32 over `HeaderSize` (must be nonzero and <= the block size,
  0x3c28), `MyLBA == lba`, then the array CRC over `n * size` bytes at the header's PartitionEntryLBA
  (0x39d4). No limit on `n` or the entry size.
- **Primary bad:** validates the backup at `LastBlock`; if good, restores the primary from it (0x31b4:
  entries to LBA 2, header to the backup's AlternateLBA).
- **Primary good:** if `AlternateLBA != LastBlock`, it **rewrites the primary header** with
  `AlternateLBA = LastBlock` and `LastUsableLBA = LastBlock - 0x21`, then rebuilds the backup. Otherwise
  it validates the backup at `LastBlock`; if that fails, or its array CRC differs from the primary's
  (`*(uint *)(puVar7 + 0xb) == puVar8[0x16]`), it rebuilds the backup: header at LastBlock, entries at
  **`LastUsableLBA + 1`**:

  ```c
  lVar16 = 2;
  if (param_3[3] == 1) { lVar16 = param_3[6] + 1; }   /* MyLBA == 1: LastUsableLBA + 1 */
  ```
  These writes happen on every boot the condition holds, before ABL runs.
- **Entries** (0x3668, then the loop in 0x25c0): every slot up to `NumberOfPartitionEntries`. An entry
  gets **no handle** if its type GUID is zero (skipped, not a stop), if it is out of range (`End < Start`,
  or Start/End outside FirstUsable..LastUsable), if it overlaps any other non-empty entry (both lose), or
  if attribute bit 1 is set. Every other entry gets a handle with HD device path
  `PartitionNumber = index + 1`, the 0x80-byte entry as the `fe2555be-d716-4686-b9d0-79db5921b70d`
  partition record (what ABL's UpdatePartitionEntries copies) and the ESP flag if the type is
  c12a7328-.... No entry cap here (ABL caps at 127).

### ABL: partitions come from the BlockIo handles

- 0x187a0 asks for BlockIo handles under the eMMC user area (`BLK_IO_SEL_MATCH_ROOT_DEVICE` 0x100, root
  type b615f1f5-5088-43cd-809c-a16e52487d00, after a NAND try with 03ef84a9-...), at most 0x80 per LUN;
  eMMC means 1 LUN. 0x178f0 then calls HandleProtocol(gEfiPartitionRecordGuid
  fe2555be-d716-4686-b9d0-79db5921b70d) on each handle and copies the 0x80-byte GPT entry into
  `PtnEntries[i]` (0x3d65c, stride 0x84, LUN at +0x80). The counter (0x4185c) goes up for every handle,
  even one without a record ("does not have partition record, ignore"), and stops at 0x80
  (`if (0x7f < uVar7 + uVar6 + 1) break`).
- `root=/dev/mmcblk0p%d` takes the raw index (0x13290: `mov w3,w22`, no +1), and stock Android booted
  with it. So `PtnEntries[0]` is the whole-disk handle and entry k sits at index k: at most 127
  partitions.
- Empty entries, CRCs and entry counts are therefore XBL's business (its PartitionDxe). ABL itself checks
  no CRC and does not compare entry counts on the boot path.
- The fastboot GPT-flash checks ("Gpt signature is not correct", "Invalid Max Partition Count", "GPT first
  usable LBA mismatch", "Header CRC mismatch", 0x3426d-0x34c34) are only strings in this build: neither
  Ghidra xrefs nor an operand scan finds any code that uses them. They do not apply.

### ABL: the raw write-back (UpdatePartitionAttributes, 0x17b38)

The one raw GPT access, and it runs on **every** boot through MarkPtnActive. With hard-coded geometry it:

- reads 33 blocks from LBA 1 (header, then entries assumed at LBA 2), and 33 blocks from
  `LastBlock+1-33` (entries assumed at TOTAL-33, header at TOTAL-1). It never reads PartitionEntryLBA from
  either header;
- walks `PtnEntries` and, **for the k-th non-empty one, rewrites raw entry k's type GUID and attributes**
  when they differ. The mapping is by position, not by name or GUID;
- if `NumberOfPartitionEntries * SizeOfPartitionEntry > 0x4000` it prints "Invalid GPT header fields
  MaxPtnCount" and does not write;
- recomputes the entry CRC over `hdr[0x50] * hdr[0x54]` bytes and the header CRC over 0x5c bytes, then
  writes both 33-block windows back (only if something changed).

What follows from that: every entry must reach ABL in table order with no gaps (a hole or a dropped entry
shifts every attribute and type GUID write by one). The backup entry array has to start at TOTAL-33, or
ABL writes into the wrong sectors and leaves the backup CRC covering them. No partition may sit in LBA
1-33 or the last 33 LBAs. With n=68 (8704 bytes) the 16 KiB limit holds.

### Holes, entry count, CRCs and the backup

- **Holes: neither XBL parser stops at the first empty entry.** Both skip it and keep going to
  `NumberOfPartitionEntries`, and PartitionDxe makes one handle per surviving entry. An earlier inference
  that XBL stops at the first empty entry was wrong. What a hole really does: XBL still makes handles for
  every later entry, but handle k is then no longer entry k, so ABL's position-based
  `root=/dev/mmcblk0p%d` and its attribute/type-GUID write-back hit the wrong slots. That is why holes stay
  forbidden, for ABL's sake. The only thing in this stack that stops at an empty entry is bkerler edl
  (`printgpt`; it stops at the first entry with a zero *unique* GUID, `edlclient/Library/gpt.py:383`).
  Whatever hid misc/keystore/.../nura_root on 2026-10-20 was not XBL's parser; a plausible mechanism
  (inferred, not traced) is ABL's shifted write-back filling the hole slot with a successor's type GUID
  and no range, which PartitionDxe then drops as out of range.
- **Entry count:** whatever the header says (`NumberOfPartitionEntries`, entry size a multiple of 128 for
  the loader). Nothing requires 68; that number is inherited from the stock header. The loader sees only
  the first 64 non-empty entries; ABL takes at most 127.
- **CRCs:** both XBL parsers check the header CRC (loader over 92 bytes, UEFI over HeaderSize, so
  HeaderSize must be 92 for them to agree) and the entry-array CRC.
- **Backup:** both XBL parsers look for the backup header at the **last LBA** of the user area (not at the
  primary's AlternateLBA). The loader reads the backup array wherever the backup header points.
  PartitionDxe repairs a bad or stale backup by writing its array at the primary's `LastUsableLBA + 1`,
  and repairs a wrong AlternateLBA by setting LastUsable to `LastBlock - 33`. With LastUsable = TOTAL-34
  that is TOTAL-33, the same place ABL hard-codes.

## How XBL picks ABL

The loader walks the sbl1_config table at 0x1407a728 (one 0x90-byte entry per image: sec type at +0x10,
load flag +0x14, load_cancel fn +0x48, partition **type GUID** pointer +0x50):

| sec type | image | type GUID | load_cancel | if absent |
|---|---|---|---|---|
| 0x16 | pmic | c00eef24-7709-43d6-9799-dd2b411e7a3c | 0x14023798 (boot mode 2/5 only) | fatal |
| 0x200 | apdp | e6e98da2-e22a-4d12-ab33-169e7deaa507 | 0x140237b4 | skipped |
| 5 | devcfg | f65d4b16-343d-4e25-aafc-be99b6556a6d | 0x14023844 | skipped |
| 7 | tz | a053aa7f-40b8-4b1c-ba08-2f68ac71a4f4 | none | fatal |
| 0x15 | hyp | e1a6a689-0c8d-4cc6-b4e8-55a4320fbd8a | none | fatal |
| 0xa | rpm | 098df793-d712-413d-9d4e-89d711772228 | 0x14023888 (not a presence test) | fatal |
| 0x11 | sti | aa9a5c4c-4f1f-7d3a-014a-22bd33bf7191 | 0x14023a2c (debug fuses) | skipped |
| 0x1c | **abl** | **bd6928a1-4ce0-a038-4f3a-1495e3eddffb** | 0x14023b4c | **skipped** |
| 9 | APPSBL | 400ffdcd-... in the table, repointed by 0x14023e24 to xbl dea0ba2c-cbdd-4805-b4f9-f428251c3e98 | - | fatal |

The loader also opens `ddr` (20a0c19c-286a-..., training data), `sec` (303e6ac3-...), `fsc`
(57b90a16-..., EFS cookie), `xbl` again for the eMMC serial number, and `cdt`
(a19f205f-ccd8-4b6d-8f1e-2d9bc24cffb1, absent on the RS6: "Using default CDT").

- **Lookup is by type GUID only.** The ABL cancel fn sets the id and opens image type 0x1b:

  ```c
  FUN_14023efc(&DAT_1407b650);          /* partition id = abl type GUID */
  local_18 = FUN_14023f28();            /* open image 0x1b */
  if (local_18 != 0) {
    FUN_14023f48(&local_18);
    cVar1 = FUN_1402e174(&DAT_1407b650,auStack_40);   /* ELF header ok? */
    if (cVar1 != '\0') return 0;        /* load it */
  }
  return 1;                             /* cancel */
  ```
  0x1402cf7c copies the id into slot 12 of the 0x14-byte table at 0x1407b478; image type 0x1b maps to
  slot 12 (`DAT_14018ee8[0x1b] == 0xc`); a slot with nonzero bytes 1-19 goes to 0x140454f8, which returns
  the first node of type 3 whose stored type GUID matches:

  ```c
  } while ((*(int *)(*(long *)(lVar2 + 0x18) + 0x30) != 3) ||
          (iVar1 = thunk_FUN_14028f6c(*(long *)(lVar2 + 0x18) + 0x34,param_3,0x10), iVar1 != 0));
  ```
- **Not by name, not by slot attributes.** The loader never stores the entry name, and the only attribute
  it keeps is bit 2 (legacy-bootable, node +0x2d), which no lookup uses. Bits 48-55
  (priority/active/successful/unbootable) are not read by XBL at all; they are ABL's. A/B in XBL is purely
  the type-GUID swap (the active slot carries the real GUID, the other
  77036cd4-03d5-42bb-8ed1-37e5a88baa34). PBL picks xbl the same way, presumably (ROM, not available).
- **Two entries with the ABL GUID:** the first one in entry order wins (nodes are appended in order,
  0x140454f8 returns on the first match). Today that is abl_a (#26).
- **None:** 0x14023b4c returns 1, 0x1402d8d4 clears the load flag
  (`if (... (**(code **)(param_2 + 0x48))(param_1), iVar1 == 1)) *(param_2 + 0x14) = 0;`), ABL is silently
  not loaded and XBL core boots anyway. QcomBds then has no LinuxLoader in the "ABOOT FV" region
  (0x9FA00000, uefiplat.cfg), prints "Press any key to shutdown" and powers off on a key (0xb884). No
  fastboot either: only EDL gets you out. The same happens if the ABL GUID entry is past the 64-entry cap,
  or holds something that is not an ELF.
- A missing mandatory image (tz, hyp, rpm, pmic, xbl) fails in 0x1402e200 (`boot_elf_loader.c` 0x53c) and
  lands in the boot error handler.

## What else XBL needs from the table

- Every type GUID the loader opens (table above) must be on one of the **first 64 non-empty entries**. On
  stock that ends at dtbo_b (#64); vbmeta_a/b and userdata are invisible to the loader and nothing there is
  needed.
- No partition name is used by the loader. UEFI drivers look some up: TzDxe by type GUID (ssd
  2c86e742-..., cmnlib 73471795-..., cmnlib64 8ea64893-..., keymaster a11d2a7c-...), MdtpDxe (mdtp
  3878408a-..., mdtpsecapp ea02d680-...), LimitsDxe (limits 10a0c19c-516a-...), UFSDxe (storsec, UFS
  only); QcomBds opens `logfs` and `efiesp` through 0x2f74 with the string as argument (label or partition
  name, not traced), and DisplayDxe, TzDxe and the charger DXE carry the strings `splash`/`logfs`. Found by
  GUID/string scan, not decompiled; none of these entries is touched by Nura.
- No minimum entry count, no partition required at a fixed position, nothing about the entry array beyond
  the CRC. Only the user area carries a GPT; boot1/boot2/RPMB get their own hotplug nodes and no entries.
- For PartitionDxe not to drop or rewrite anything: entries inside FirstUsable..LastUsable, no overlaps, no
  attribute bit 1, a PMBR entry (boot 0, 0xEE, start 1), `AlternateLBA` = last LBA, backup header at the
  last LBA with the same array CRC. Start and size are 32-bit in the loader (fine: the disk is 122142720
  sectors).

## Names ABL needs

| name | used by | missing or wrong |
|---|---|---|
| `boot_a`, `boot_b` | 0x17298 (two `boot_[ab]` names = multislot); 0x18f78 exact names; GetActiveSlot reads both | "No boot partition entry for slot", no bootable slot, fastboot |
| `system_<slot>` | ValidateSlotGuids in 0x1a008 ("system_x" with the slot letter) | "ValidateSlotGuids: No partition entry", FindBootableSlot clears the suffix, "No bootable slot", fastboot |
| `system_<slot>` type GUID | 0x1a008: `CompareMem(boot_<slot>.type, system_<slot>.type, 16) == 0` fails the slot | "BootableSlot %s does not have valid guids", fastboot |
| `system_<slot>` index | GetSystemPath 0x13038, called from 0x5890 only when the boot.img header cmdline (offset 0x40) has no `root=` | "System partition does not exist", "GetSystemPath failed!", fastboot |
| `dtbo_<slot>` | 0x5890 | optional ("No dtbo partition is found, Skip dtbo") |
| misc, by type GUID 82acc91f-357c-4a68-9c8f-689e1b1a23a1 | RecoveryInit 0x14310 (`boot-recovery` only), FFBM 0x146d0 (`ffbm-`) | ignored ("RecoveryInit failed ignore") |

- U-Boot's boot.img cmdline is `uboot2nd` (checked in the built U-Boot boot images and in the pre-U-Boot
  boot_a backup), so GetSystemPath runs on every boot. ABL appends
  `root=/dev/dm-0 dm="system none ro,0 1 android-verity /dev/mmcblk0pN"` to the cmdline it gives U-Boot,
  and U-Boot ignores it.
- Only the **index** of system_<slot> is used. ABL never reads system's contents or size (it loads only
  boot_<slot> and dtbo_<slot>), so a 1 MiB dummy anywhere is fine. vendor_a/b and userdata are not looked
  up on the boot path (userdata/system appear only in the fastboot `partition-type` table at 0x20b74).
- `bootonce-bootloader` is not in the binary. ABL reads misc for `boot-recovery` and `ffbm-` only. The
  string comes from U-Boot (`drivers/fastboot/fb_common.c:96`, written on `fastboot reboot-bootloader`).
  Zeroing misc is still right.

## Slot attributes

Bits of the 64-bit entry attributes: 48-49 priority, 50 active, 51-53 retry count, 54 successful, 55
unbootable. Only ABL reads them.

- GetActiveSlot (0x17368): `boot_a`, then `boot_b`. A slot counts if it is active with priority > 0, and
  `_b` wins only with a strictly higher priority. If neither counts and boot_a's byte 6 has none of 0xc7
  set (first boot), it sets byte 6 = 0x3f and writes the GPT; otherwise "No active slot found".
- FindBootableSlot (0x1a008): if not unbootable and successful, boot. If not successful with retry > 0, it
  lowers the retry count and writes the GPT. Otherwise it hands over to HandleActiveSlotUnbootable
  (0x19d20), which sets unbootable and switches to the other slot if that one is
  `(byte6 & 0xc0) == 0x40`.
- SetActiveSlot (0x19128): the new slot's boot byte 6 becomes 0x3f, the old one gets priority 2 and loses
  active. It swaps the type GUIDs of every A/B pair (names equal except the last character and containing
  `_a` or `_b`).
- MarkPtnActive (inlined at 0x1a354 and 0x19abc): bit 50 is set on **every entry whose name contains the
  slot suffix** (StrStr) and cleared on all others, then 0x17b38 runs.
- Now: boot_a byte 6 = 0x6f (priority 3, active, retry 5, successful), boot_b 0x3a. The scripts leave
  boot_a/boot_b byte-identical.
- `nura_boot` contains `_b`, so it gets bit 50 whenever slot B is active. Linux and U-Boot ignore bits
  48-63, so this is cosmetic. `nura_swap1`/`nura_swap2` differ only in the last character but contain
  neither `_a` nor `_b`, so they are not treated as an A/B pair.

## Factory packages

- HiBy's official 1.50 factory (burn) package has the same partition names and start LBAs as the 1.80
  table. Its `rawprogram_unsparse.xml` writes `BackupGPT` = `gpt_backup0.bin` (33 sectors: 17-sector
  array, zero padding, header) at `start_sector="NUM_DISK_SECTORS-33."` (`rawprogram_unsparse.xml:131`).
  `patch0.xml` sets the backup header's PartitionEntryLBA to `NUM_DISK_SECTORS-33.` and the array CRC to
  `CRC32(NUM_DISK_SECTORS-33.,8704)` (= 68 x 128 bytes; `patch0.xml:18-23`), its MyLBA to
  `NUM_DISK_SECTORS-1.`, LastUsable in both headers to `NUM_DISK_SECTORS-34.` and the primary's AlternateLBA to
  `NUM_DISK_SECTORS-1.`. The 1.80 `rawprogram0.xml` also writes BackupGPT at `NUM_DISK_SECTORS-33.`.
  **Confirmed: the factory backup array is at TOTAL-33**, and the device's backup array sits there.
- The 1.50 `gpt_main0.bin` has the same 68-entry layout as the 1.80 dump (unpatched: Alt and LastUsable 0,
  userdata's end filled in by patch0).
- The 1.80 zip's `gpt_main0.bin` is the stock table the test uses: **68 entries** (entries LBA 2-18, first
  usable 34, last usable TOTAL-34), 67 used. An older synthetic test table had 128. Its
  `gpt_backup0.bin` is the 8704-byte array only: the 1.80 dump kept only the array.

## The Nura layout against these rules

### ABL rules

| rule | new layout |
|---|---|
| boot_a, boot_b present and untouched | yes (#46, #47, byte-identical) |
| system_a, system_b present | #51 (sector 34), #68 (sector 17826048) |
| system_<slot> type differs from boot_<slot> | 8300 vs boot / inactive GUID: yes |
| no holes, all 68 entries handed to ABL in order | 68/68 used; the table is now full |
| <= 127 partitions, entries <= 16 KiB | 68, 8704 bytes |
| nothing in LBA 1-33 or the last 33 | lowest start 34, highest end TOTAL-34 |
| primary entries at LBA 2, header 92 bytes | kept from stock |
| backup entries at TOTAL-33 | **only if the dump already had them there** (sgdisk keeps the dumped location); now pinned |
| no attribute bit 1 (EDK2 drops such entries) | none set |

Script fix (`tools/lib/nura-gpt.sh`): `nura_build_gpt` pins the backup array with `sgdisk -k TOTAL-33`.
`nura_validate` now checks the header geometry ABL assumes (primary at LBA 1, entries at LBA 2, 92-byte
header, <= 16 KiB; backup header at TOTAL-1 with entries at TOTAL-33), that no partition touches ABL's two
windows, that boot_b is present, that system_<s> and boot_<s> have different type GUIDs, and that no entry
has attribute bit 1. `flash-nura-ums.sh` also requires boot_b. The scripts produce TOTAL-33 either way.
Before the fix, a TOTAL-18 backup would have survived the repartition, and ABL's first write-back would
have broken it.

### XBL rules

| XBL rule | Nura table |
|---|---|
| PMBR with 0xEE, boot 0, start 1 | yes (sgdisk PMBR) |
| primary header: EFI PART, HeaderSize 92, MyLBA 1, CRCs | yes |
| AlternateLBA = TOTAL-1 (else PartitionDxe rewrites the primary) | 122142719 |
| backup header at TOTAL-1, same array CRC (else PartitionDxe rewrites it) | yes, entries at TOTAL-33 (= LastUsable+1, so even a repair lands there) |
| entry size multiple of 128, array on the disk | 68 x 128 at LBA 2 |
| loader images on the first 64 non-empty entries | xbl #1, tz #3, rpm #5, hyp #7, pmic #9, abl #26, apdp #30, ddr #36, sec #37, fsc #40, devcfg #54, sti #58 (unchanged positions) |
| exactly one ABL type GUID, on an ELF | abl_a #26 only |
| no new entry takes a GUID XBL looks up | new types are 8300 and 8200 only |
| no entry dropped by PartitionDxe (range, overlap, bit 1) | 68 handles, handle k = entry k |
| not visible to the loader (past 64) | #65 vbmeta_a, #66 vbmeta_b, #67 nura_root, #68 system_b: none needed by XBL |

**Verdict:** the Nura layout satisfies every XBL rule found. No layout change is needed. The one
correction is to the reasoning, not the table: holes are not an XBL stop; they break ABL's position
mapping, so "no holes" stays.

### Offline models and test results

- `docs/re-tools/abl-gpt-check.py <image>` models the ABL side: enumeration under both stop-at-empty and
  EDK2 rules, GetActiveSlot, FindBootableSlot, ValidateSlotGuids, GetSystemPath, and the MarkPtnActive +
  UpdatePartitionAttributes write-back on both GPTs.
- `docs/re-tools/xbl-gpt-check.py <image> 122142720` is an offline model of both XBL parsers.
- `docs/re-tools/test-repartition-nura.sh` builds the stock table from the real 68-entry GPT dump, puts its
  backup array at TOTAL-18, runs both repartition scripts and both models on every produced table, and adds
  negative cases (backup array in the wrong place, system_b with boot_b's type GUID, and a table with a
  hole, which the XBL model must reject).
- Result, 2026-10-21: ALL PASS, and **XBL model: PASS** for the UMS, EDL and TOTAL-33-stock tables. The
  ABL model passed on the stock table as dumped (slot B active) and, with a one-off helper that swaps the
  A/B type GUIDs and flags like `edl setactiveslot a` (not published), with slot A active, which is the
  state of the unit once U-Boot sits in boot_a. In that state ABL boots slot _a with
  `root=/dev/mmcblk0p51`, and its first write-back sets bit 50 on the new system_a only; both GPTs stay
  valid afterwards.

### Rules for future changes

Do not insert entries before #58 (sti) in a way that pushes a loader image past the 64th non-empty entry;
keep LastUsable at TOTAL-34 so XBL's own backup repair and ABL's hard-coded TOTAL-33 agree; never put a
loader type GUID on a second entry; never leave a hole.

Still not provable offline: PBL (boot ROM) reading xbl, and a real reboot through XBL and ABL, which
remains the test.
