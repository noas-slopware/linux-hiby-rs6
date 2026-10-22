# RS6 GPU: Adreno 512 (a5xx) on mainline msm and freedreno

The RS6 has an Adreno 512 (SDM660, chip id 0x05010200, 272 KB GMEM). It runs on the mainline `msm` DRM driver and
Mesa's freedreno. Three things need more than the stock defaults:

1. The CP microcode (PM4 and PFP) the port ships, and why the PFP is not HiBy's.
2. A GPU hang seen during video playback, and the kernel recovery fixes in the patch series.
3. The Mesa a5xx patches for rendering artifacts.

Tags: **static** = read from a binary or from source, **confirmed** = seen in a log or capture from the unit,
**inferred** = reasoned from static facts, not observed.

Verification status, stated up front:

- The microcode comparison and the choice of PFP are static analysis. The unit has run with the 0x5ff11a PFP
  installed since `firmware-hiby-rs6` 2.10-r4, but the 4-ring check has not been recorded: that the kernel selects
  4 rings with it is expected, not observed. Section 1.6 lists what to check.
- The cause of the video hang is not known. The kernel changes in section 2 are in the kernel the unit runs; no
  hang has been reproduced with them, and their 4-ring branches have not run on the unit.
- The Mesa patches are described by their own commit messages. The A8 test result (section 3) is the only
  measurement here.

## 1. CP microcode

### 1.1 Files and versions

The kernel reads `qcom/a530_pm4.fw` and `qcom/a530_pfp.fw` for the Adreno 512 (the same pair every a5xx loads). The
version is dword 1 of each file (the kernel skips dword 0).

| file | linux-firmware (`firmware-qcom-adreno-a530`) | HiBy stock 2.10 | shipped by the port |
|---|---|---|---|
| `a530_pm4.fw` | 0x005ff063, 19572 B | 0x005ff066, 19652 B | HiBy stock 0x005ff066 |
| `a530_pfp.fw` | 0x005ff08a, 16144 B | 0x005ff112, 16820 B | Xiaomi tulip 0x005ff11a |

The tulip PFP is the file `qcom/a530_pfp.fw` from Nura `vendor-xiaomi-tulip` (Xiaomi tulip, SDM660,
vendor firmware):

    sha256 2a51c25b1f7299cb84c3685d3d1fb88bf0504494456345b2dfde32816e13bc8e

It is on the `firmware` branch as `gpu/a530_pfp-0x5ff11a.fw`. The tulip PM4 is byte-identical to HiBy's stock
0x5ff066 (sha256 starts `a02c9be1`, ends `115f`), so the pair is tulip PFP plus stock PM4. The package manifest
(`MANIFEST.tsv` in `firmware-hiby-rs6`) lists the PFP as "Qualcomm PFP 0x5ff11a, not HiBy".

Header layout (static): file dword 2 is the jump-table offset (file dwords minus 129 in all three PFPs).

| PFP | dword 1 | dword 2 | dword 3 |
|---|---|---|---|
| linux-firmware | 0x005ff08a | 0xf43 | 0x00087001 |
| HiBy stock 2.10 | 0x005ff112 | 0xfec | 0x88020001 |
| Xiaomi tulip | 0x005ff11a | 0x1034 | 0x00113001 |

### 1.2 Why mainline needs a "patched" PFP

Mainline msm enables 4 rings and preemption on a5xx only if `a5xx_ucode_check_version()` sees a PFP with
`CP_WHERE_AM_I` support: the version's low nibble is 0xa and the patch level is at least 1. linux-firmware's
0x5ff08a is such a build. It is a Qualcomm build (base 0x087) with a patch added by CAF, and the patch level sits in
dword 3 as `(base << 12) | level`: `0x087 -> 0x08a`, `0x113 -> 0x11a`.

HiBy's stock PFP 0x5ff112 is a newer Qualcomm build and its low nibble is 2, so mainline loads it and runs **one
ring, no preemption**. The stock kernel (kgsl) preempts by its own means and never uses WHERE_AM_I.

linux-firmware's PFP also has an older PM4 (0x5ff063 against 0x5ff066). Stock PM4 and linux-firmware PM4 have
identical code apart from a new UNKN117 handler (opcode 0x75) and a moved CP_SET_STATE jump-table entry. Mainline a5xx
emits neither. The preemption save/restore code is byte-for-byte the same (static).

### 1.3 What the patched PFP adds

Stock 0x5ff112 does implement CP_WHERE_AM_I (opcode 0x62): it reads the ring read pointer (CP register 0x0b3) and
CP_MEM_WRITEs it to the address in the packet. That is not enough for mainline. The linux-firmware patch changes two
handlers, CP_WHERE_AM_I and CP_CONTEXT_SWITCH_YIELD (opcode 0x6b) (static, per-handler comparison):

1. Both read `CP_RB_CNTL` and test bit 27 (NO_UPDATE). Mainline always sets it.
2. With NO_UPDATE set, both go to a shared tail that writes the read pointer to the address in `CP_RB_RPTR_ADDR`,
   not to the packet's address. The tail reads `CP_CNTL`, and if bit 0 is clear it waits for idle, sets bit 0, does
   the `CP_MEM_WRITE`, waits for the write, waits for idle and restores `CP_CNTL`.
3. Stock YIELD has no such write-back. It ends with a call into the yield-save code and `waitin`.

Mainline depends on the write-back: `a5xx_submit()` and `a5xx_preempt_start()` end with a YIELD and no WHERE_AM_I
(the code says one is not needed after a YIELD), and Mesa's single-command-buffer submits never reach the
`ibs % 32 == 0` WHERE_AM_I. With `has_whereami` the driver reads the ring pointer from the shadow BO, so the YIELD
write-back is the only thing moving it.

### 1.4 What was compared

The comparison was done function by function on `qrisc-disasm -g 5ff` output (Mesa's a5xx CP disassembler). Local
labels were renumbered, delay-slot branch targets relabelled, and callees paired structurally starting from the 128
jump-table entries. The walk reached 3884 of 4076 stock and 3926 of 4148 tulip instructions; the rest (boot code,
a few nops, dead code) was diffed separately and is identical or unreachable.

Every difference between stock 0x5ff112 and tulip 0x5ff11a (static):

1. Header: patched builds insert one extra dword (the patch level) before the first instruction. Stock dword 3
   (0x88020001) is not a header, it is the first instruction `mov $02, 0x1`. All code in tulip is shifted by one.
2. CP_WHERE_AM_I gains the NO_UPDATE-gated write-back.
3. CP_CONTEXT_SWITCH_YIELD gains the same write-back.
4. The IB2 skip wait (reached from the draw packets, SET_STATE and SKIP_IB2_ENABLE_*): stock waits while bit 2 of
   CP register 0x0b7 is set; tulip waits until the register is 0, pauses about 10 cycles and waits for 0 again. It
   only acts when `$14 & 0x340 == 0x340` inside an IB2. Mesa emits SKIP_IB2_ENABLE_GLOBAL with 0 and never emits
   SKIP_IB2_ENABLE_LOCAL, and msm emits neither, so the wait never runs on mainline.
5. CP_DRAW_PRED_SET, sub-mode 4: stock takes the fourth reference pair as (lo, lo), tulip as (lo, hi). Looks like a
   bug fix (a streamout overflow predicate; a reading, not proven). Mesa a5xx and msm never emit
   CP_DRAW_PRED_SET.
6. Layout only: two absolute jumps that the disassembler cannot decode move with the code, and tulip carries a dead
   copy of the write-back tail after WHERE_AM_I (linux-firmware has the same dead copy).

All other jump-table entries pair with equal code, callees included: the hardware-injected context-switch handler
(UNKN12: SAVE/RESTORE_ADDR and the 0x27C4BAFC record magic), CP_ME_INIT, SET_SECURE_MODE, INDIRECT_BUFFER_PFE,
PREEMPT_ENABLE_GLOBAL/LOCAL, YIELD_ENABLE, SET_RENDER_MODE, SET_PROTECTED_MODE, EVENT_WRITE and the boot code.

Tulip against linux-firmware: the WHERE_AM_I and YIELD handlers are equal, callees included, so tulip's patch is
the same patch. The rest of the difference is the Qualcomm base drift 0x087 to 0x113, the same list as
linux-firmware to stock, so it is stock's code. One drift item matters for 4 rings: the context-switch handler in
stock and tulip adds a mode keyed on bit 31 of CP register 0x06a, set only by CP_ME_INIT dword 0 bit 6. Mainline
sends mask 0x2f, so bit 6 is clear and that path is never taken.

### 1.5 Why the stock microcode with only WHERE_AM_I was rejected

The first idea was to leave HiBy's PFP alone and make the kernel treat 0x5ff112 as having WHERE_AM_I. Static
analysis says that breaks the GPU, and it was not applied.

- **No YIELD write-back.** With 4 rings the shadow ring pointer is written only by `a5xx_flush(..., true)` (ME_INIT,
  secure mode). So: the drain wait in `hw_init` times out (`timeout waiting to drain ringbuffer 0`); the ring's free
  space shrinks with every submit until `OUT_PKT` waits a full timeout (`timeout waiting for space in ringbuffer N`),
  which is a hang in practice; and `get_next_ring()` judges non-current rings by `wptr == shadow`, so the CP
  ping-pongs between rings.
- **Adding a WHERE_AM_I after each YIELD** (the obvious kernel change) has two holes. A ring switched out at its
  YIELD keeps a stale shadow until it runs the trailing WHERE_AM_I, and convergence of the switching logic could not
  be proven without also changing `get_next_ring()` to use fences. More important, stock WHERE_AM_I is a plain
  CP_MEM_WRITE, while the shadow BO is mapped privileged (`MSM_BO_MAP_PRIV`, so `IOMMU_PRIV`). The patched tail
  wraps its write in a `CP_CNTL` bit 0 set and restore, and stock's own switch handler sets that bit while it
  touches the privileged records and clears it afterwards. **Inferred**: `CP_CNTL` bit 0 marks CP memory accesses as
  privileged. If so, the write would fault in the SMMU at the shadow address and `a5xx_me_init` would fail, or the
  shadow would freeze after the first preemption switch. Only a device test could settle it.
- Mapping the shadow unprivileged would avoid the fault, but on a5xx every user cmdstream shares the kernel's VM
  (no per-process pagetables), so any client could forge the ring pointer. The kernel treats that as the hole closed
  by "drm/msm: Disable the RPTR shadow", so it was not an option.

The tulip PFP removes the question: stock's code with linux-firmware's proven write-back, and the privileged tail
runs the way it does with linux-firmware.

What is and is not proven about the pair (static):

- 0x5ff11a with PM4 0x5ff066 is the pair Xiaomi's kgsl runs, where NO_UPDATE is clear and the tail never executes.
- The tail is proven on mainline only through linux-firmware 0x5ff08a with PM4 0x5ff063. That combination is what the
  RS6 ran with 4 rings before (the hang log below shows ring 2).
- No one is known to run 0x5ff11a on mainline msm. What bounds the risk is that WHERE_AM_I and YIELD equal
  linux-firmware's and everything else equals stock's.
- Whether stock kgsl really preempts at runtime on the RS6 was not checked. kgsl lists ADRENO_PREEMPTION for the
  Adreno 512.

A latent bug in the mainline check: an unpatched Qualcomm build whose version ends in 0xa would also pass it (dword 3
is then the first instruction, whose low nibble is at least 1 on every build seen), so it would get 4 rings with no
write-back. It does not apply to the shipped file.

### 1.6 Where the files are installed, and how to check

`firmware-hiby-rs6` installs, besides the zap shader (`/usr/lib/firmware/a512_zap.mbn`, also under `postmarketos/`):

    /usr/lib/firmware/updates/qcom/a530_pm4.fw    HiBy stock 0x5ff066
    /usr/lib/firmware/updates/qcom/a530_pfp.fw    Xiaomi tulip 0x5ff11a

`updates/` is searched before `qcom/`, so these win over `firmware-qcom-adreno-a530` without a file conflict. The
package's initramfs list names both microcode files and the zap shader:

    /usr/lib/firmware/updates/qcom/a530_pm4.fw
    /usr/lib/firmware/updates/qcom/a530_pfp.fw
    /usr/lib/firmware/a512_zap.mbn

They have to be in the initramfs because `msm` binds the GPU from there. Without them the first firmware load fails
and the GPU only comes up once the rootfs is mounted. After changing the files, regenerate the initramfs.

Expected on a boot with this pair (**expected, not recorded as observed on the unit**):

    sha256sum /usr/lib/firmware/updates/qcom/a530_pfp.fw    # 2a51c25b...bc8e
    cat /sys/kernel/debug/dri/0/gpu                         # as root; lists "- id: 0" to "- id: 3"
    dmesg | grep -E 'drain ringbuffer|space in ringbuffer|preemption timed out|Preemption failed|gpu fault|hangcheck'

- Idle: each ring's `rptr` equals its `wptr`. Under KWin plus Firefox, rings 1 and 2 show `last-fence` and
  `retired-fence` moving. There is no separate preemption counter; the GPU line in `/proc/interrupts` rising while
  rings other than 0 retire is the evidence.
- The `dmesg` grep should print nothing from boot through a video session.
- Reading the `gpu` debugfs file is safe on the RS6 since patch 0044 (section 2).

Failure signatures:

| symptom | meaning |
|---|---|
| only `- id: 0` in debugfs, no error | the stock 0x5ff112 PFP is still loaded (stale initramfs) |
| `gpu fault` at the shadow address, then `timeout waiting to drain ringbuffer 0 rptr/wptr = 0/...`; no GPU | write-back not reaching the shadow (not expected: same tail as linux-firmware) |
| `timeout waiting for space in ringbuffer N`, then a hang | shadow stops moving mid-session |
| `preemption timed out` (10 s) or `Preemption failed to complete` | context-switch trouble; recovery goes through `msm_gpu_hw_fault()` |
| high GPU IRQ rate when idle, rings other than 0 with `rptr != wptr` forever | switch ping-pong |

## 2. GPU hang during video, and the recovery fixes

### 2.1 What happened

Firefox 154 on m.youtube.com, Mesa 26.2.5 with patches 0101 to 0105 and `noblit` off, kernel running 4 rings on
linux-firmware's PFP (confirmed, kernel log):

    CP | opcode error | possible opcode=0x00000000
    gpu fault ring 2 fence 1ff8d status 800001C1 rb 16ae/16ae ib1 0000000020A87000/1f30 ib2 00000000208BF000/01a4
    recover_worker: hangcheck recover!
    gpu fault ring 2 fence 1ff8e status 800001C1 rb 16b0/16d3 ...
    hangcheck detected gpu lockup rb 2!  completed fence: 130748  submitted fence: 130960
    (repeating every second for minutes: completed 130748 / submitted 130961, no "offending task", no devcoredump)

What the fault line says (static, decoded against `a5xx.xml` and the downstream kgsl snapshot code):

- `RBBM_STATUS 0x800001C1` has only the CP busy. RB, SP, TP, VFD, CCU and the 2D engine are idle, so the ME stopped
  on a packet it could not parse; it was not stuck inside a draw or a blit.
- `possible opcode=0x00000000`: the rejected header is a zero dword. A zero is a type-0 packet, which the a5xx CP
  refuses (only PKT4 and PKT7 are legal).
- IB1 is at least 7984 dwords (a nearly full 32 KB primary chunk) and IB2 at least 420 dwords. The size fits a
  tiled draw batch of a Firefox frame, not a blit batch (a blit batch is about 230 dwords). The ring itself was fully
  consumed; the CP was inside the IB2 of the last submit on ring 2.

Where a zero header can come from, none proven:

1. A command-stream BO reused while the GPU still read it. Userspace reuses ring BOs as soon as the fences say idle,
   and a fresh BO is zero-filled. If the kernel retired submits early, in-flight BOs get handed out. One cause would
   explain both the zero and the fence trouble below, so it was the leading guess.
2. A wild GPU write into the ring BO, the fence memptr or the control fence (a5xx shares one VM between all
   clients).
3. A packet whose length the CP counts differently from what Mesa emits. Every packet patch 0105 adds or newly reaches
   was audited against the stock driver's encoding (CP_SET_RENDER_MODE, CP_BLIT, the PKT4 groups, the post-blit
   events, texture state sizes, IB sizes): nothing found.
4. Stale ring contents executed after a resume. Patch 0016 fixes that case; its signature
   (`timeout waiting to drain ringbuffer`) was not in the quoted log.

No Mesa change was made for the hang: nothing in it pointed to a specific packet. An upstream lead: the freedreno
list mentions (2026-10-04) an issue with the blitter programming on SDM660 that the developer meant to fix; no MR
or issue for it was found as of 2026-10-21. If one lands, compare it with patch 0105 first.

### 2.2 Why the kernel never recovered

The fence numbers show it (static, from the msm fence code):

- `submitted fence` only advances when the scheduler runs a job, and each ring has at most 8 unsignalled submits. So
  with 130961 submitted, every submit up to 130953 had a signalled fence, yet the fence memptr read 130748 for
  minutes. It had gone backwards by 205 or more, or something wrote a far-ahead value into it earlier. Either way it
  no longer described what the GPU completed.
- `recover_worker()` named the guilty submit as `memptr + 1` (seqno 130749). That submit had been retired long
  before, `find_submit()` returned NULL, and the worker bailed out: no reset, no crash state, 57 times. The same
  bail-out shows in another A512 report (an SDM660 phone): `hangcheck recover!` without `offending task` for two
  minutes, including after a preemption timeout.
- Nothing in the kernel writes the memptr backwards. The writers are the CP itself, `adreno_hw_init` (only lowers a
  memptr that is ahead) and recovery. Because the memptr BO is writable by any a5xx cmdstream, a wild write or a CP
  replaying stale ring contents can put any value there. Which one happened is not provable from the log.
- A second symptom: any crash-state capture (devcoredump, `cat /sys/kernel/debug/dri/0/gpu`) reset the SoC. The a5xx
  register dump list included the GPMU aperture 0xA800..0xAC60, which only the A530 and A540 have; reading it on
  other parts resets the board. That is also why no devcoredump ever appeared.

### 2.3 The fixes in the kernel series

The fixes map to these patches in `patches/linux/` on the `main` branch (subjects as in the series):

| patch | subject | what it does |
|---|---|---|
| 0016 | `drm/msm/a5xx: Reset the GPU when resuming it` (Fabricio Akio) | On SDM630/660 and MSM8998 GX stays on until the SMMU suspends, so a resumed GPU keeps its state and the CP its ring pointer; `hw_init` then rewinds the ring and the CP runs stale contents (`timeout waiting to drain ringbuffer 0 rptr/wptr = 23/C`). Soft reset on every resume, and take devfreq's busy-counter baseline again afterwards. |
| 0044 | `drm/msm/a5xx: don't read the GPMU registers on GPUs without a GPMU` (Dmitry Baryshkov, Reviewed-by Konrad Dybcio, Tested-by Alexey Minnekhanov) | Splits the GPMU ranges into their own array, collected only on A530/A540. Crash state and the `gpu` debugfs file no longer reset the board on A512. |
| 0045 | `drm/msm/a5xx: say why the GPMU registers are only dumped on A530/A540` | Comment only. |
| 0046 | `drm/msm: don't trust a fence memptr no submit wrote` | A memptr ahead of the last allocated fence was not written by our submits. `msm_fence_completed()`, `msm_update_fence()` and `msm_gpu_retire()` answer from `completed_fence` alone in that case and log ratelimited, also for a memptr that went backwards. `get_next_ring()` in a5xx applies the same rule, since a memptr behind completed work kept the CP on that ring forever. |
| 0047 | `drm/msm/a5xx: don't free the preemption records twice` | When preemption is turned off after init (no WHERE_AM_I in the PFP), `a5xx_preempt_fini()` ran twice, freeing the records twice, and `a5xx_submit()` kept pointing the CP at the freed record. The fallback now looks like A510's single ring. |
| 0048 | `drm/msm: reset the GPU on a hardware fault with no submit to blame` | Recovery requests carry a reason (hangcheck or hardware fault, the latter from every adreno fault path). The worker blames the oldest unsignalled submit on the hung ring instead of `memptr + 1`; a hardware fault resets the GPU even with nothing to blame. Fences are updated only after the reset, never backwards. The hangcheck timer is stopped during recovery. Includes the `put_task_struct()` and reset-before-retire fixes from upstream. |
| 0049 | `drm/msm: check every ring for a hang` | The hangcheck checks all rings on what they completed as far as known. A ring the CP is not on counts as hung only after the CP sat on an empty ring for two checks in a row (a switch in flight looks like that once). With one ring it is the old check. |
| 0050 | `drm/msm/a5xx: mask the hang detector until the GPU is reset` | The hang detector refires every few ms (the two `gpu fault` lines above are 7 ms apart) and each interrupt asked for another recovery. The RBBM interrupts are masked, as a6xx does, until `hw_init`. Also prints the completed fence next to the submitted one. |

The 4-ring branches of this recovery code (`find_hung_ring()` choosing a non-current ring, the stranded and deferred
hangcheck cases, a preemption fault through `msm_gpu_hw_fault()`) have not been exercised on the unit. A first hang with 4 rings
is their first test.

Not changed: the memptr BO stays writable by any a5xx cmdstream, because there is no privileged mapping without
per-process pagetables.

Other GPU patches in the series, unrelated to the hang:

- 0027 `drm/msm/adreno: attach all GPU power domains`: on SDM630/660 GX is fed from CX through the GFX LDO, and the
  OPPs carry required-opps for CX and MX, which the OPP core votes only through attached domain devices.
- 0094 `drm/msm/gpu: Remove the bus vote when the GPU is suspended`: the parked 27 MHz OPP kept a 1.2 GB/s DDR
  vote on the always-on RPM tag while the GPU was suspended, which kept BIMC clocked and the SoC out of XO shutdown
  and VDD minimization. The vote is now removed on suspend, as KGSL does.

### 2.4 What the new kernel prints, and what is still open

On a recurrence the new lines identify the case: `fence memptr N went backwards, completed fence is M`, or
`fence memptr N is ahead of the last fence M, not trusting it`, then `offending task: ...`, the register dump and a
devcoredump. To collect it:

    ls /sys/class/devcoredump/                         # devcdN appears for the crash state
    cat /sys/class/devcoredump/devcd*/data > gpu-crash.txt
    echo 1 > /sys/class/devcoredump/devcdN/data        # release it, or wait 5 minutes
    echo 1 > /sys/module/msm/parameters/rd_full        # before the hang: hangrd dumps every BO of the guilty submit
    cat /sys/kernel/debug/dri/0/hangrd > hang.rd       # blocks until a hang

Off the device, Mesa's `crashdec -f gpu-crash.txt` decodes the registers, the ring and IB1/IB2 around the faulting
packet, and `cffdump hang.rd` decodes the guilty submit. A zero at the start of a fresh sub-allocation chunk points
to BO reuse; a "went backwards" line with a seqno one ring lap older (the ring is 8192 dwords, about 209 Firefox
submits) points to the CP replaying old ring contents.

Open items:

- Whether the memptr went backwards or something wrote far ahead is undecided. The new log lines decide it.
- Which submit the CP is really in is a guess: with a consistent memptr it is fence + 1; a fault in the tail of a
  submit (after its fence write) blames the next one. Telling them apart needs each submit's ring offset against
  `CP_RB_RPTR`.
- The hang was seen with 4 rings, linux-firmware's PFP and PM4 0x5ff063. The shipped setup changes both the PM4 (to
  0x5ff066) and the PFP, and adds the recovery fixes. If the hang comes back with tulip plus 0x5ff066, the ME is
  cleared and suspicion moves to 4 rings and preemption. If it does not, the new PM4 or the fence and recovery
  fixes did it. Either outcome is bisect data.
- The behaviour of all of section 2.3 on the unit is not recorded.

## 3. Mesa a5xx patches

Mesa 26.2.5 on the RS6 carries six patches on top of Alpine's package, in `patches/mesa/` on the `main` branch.
They fix Adreno 512 rendering artifacts (mesa#8442) and Qt text. The commit messages explain each in detail; read
them for the register values and the stock-driver functions they follow.

| patch | subject | summary |
|---|---|---|
| 0101 | Use the blob's RB_CCU_CNTL values on A508 | Fabricio Akio (Mesa MR !45465). A508 lost most pixels of a direct-to-memory render with the A530 value. |
| 0102 | Don't 2D copy between linear surfaces on A508 | Fabricio Akio. A 2D `BLIT_OP_COPY` between linear surfaces writes nothing on A508. |
| 0103 | Re-emit fragment textures when the fragment program changes | Fabricio Akio. A scissored clear between two draws left the second draw without texture state. |
| 0104 | Use the blob's RB_CCU_CNTL values on A509 and A512 | Computed from the stock driver's formula: 0x08000000 in bypass and 0x2010f080 in GMEM mode for the A512 (read from the stock Adreno 512 driver with Ghidra). |
| 0105 | Program the A508/A509/A512 the way Qualcomm's driver does | Four changes, below. |
| 0106 | Read A8 as A8 in SCALE blits | Fixes Qt text, below. |

Patch 0105 changes four things:

- **Highest bank bit.** freedreno hardcoded `RB_MODE_CNTL` and `TPL1_MODE_CNTL` for bank bit 15 (captured from an
  A530). The kernel programs the UCHE for the SoC's value, 14 on SDM660, so the units disagreed about where a tiled
  texture lives. Mesa now asks the kernel (`MSM_PARAM_HIGHEST_BANK_BIT`), falls back to the GPU table and derives
  both registers, as the stock driver does (0x42 and 0x4c4 on the RS6).
- **ECO bits.** `RB_DBG_ECO_CNTL` bit 9 (errata 97) is kept set on A505/506/508/509/512, and `SP_DBG_ECO_CNTL` bit 30
  only on A510 and A530.
- **2D copies.** The stock driver never issues a plain `BLIT_OP_COPY` on A508/509/512. It always uses the SCALE form
  (render mode BLIT2DSCALE, `CP_BLIT` op 3, which reads the source through the texture pipe). 0105 emits copies that
  way for same-format texture and buffer blits and leaves the rest to u_blitter.
- **Post-blit sync.** After every 2D blit: `PC_CCU_FLUSH_COLOR_TS` twice, `PC_CCU_INVALIDATE_COLOR`,
  `PC_CCU_INVALIDATE_DEPTH` and a wait for idle.

The commit message ties two RS6 symptoms to it: tiled corruption on the lock screen when blits take the 3D path
(`FD_MESA_DEBUG=noblit`), and UI elements that vanish for a frame when they take the 2D engine.

Patch 0106: the SCALE source descriptor has no swizzle, and 0105 mapped `A8_UNORM` to `TFMT5_8_UNORM` (value in red,
alpha 1) with `RB5_A8_UNORM` as the destination, so every A8 texel a SCALE blit touched became 0xff. Qt's GLES backend
keeps its glyph caches in `GL_ALPHA` (A8), and glyph uploads to a busy cache go through a staging blit, so each new
glyph became a solid box. The stock driver reads A8 as `TFMT5_A8_UNORM`; 0106 does the same for the SCALE source
only. The blit test: with 0105 alone, 7393 of 7400 pixels of an alpha upload were wrong through the blit path
and 0 with `noblit`; with 0106 the blit path has 0 wrong pixels and the same CRCs as `noblit`.

One unrelated item: with `FD_MESA_DEBUG=ttile` (off by default), BGRA8, 565, 4444 and 5551 tiled
textures read wrong even with `noblit`.

## 4. Open items

- Result of a boot with the tulip PFP: 4 rings in debugfs and a clean `dmesg` (section 1.6). Not recorded.
- Cause of the video hang (section 2.4).
- Executing the 4-ring branches of the recovery code on the unit.
- An upstream fix for the SDM660 blitter programming issue, if one appears (section 2.1).
- The tulip PFP is not HiBy's: it is recorded in the package manifest as such, and the stock-PFP route remains
  available only with a kernel change that has no proof of working (section 1.5).
