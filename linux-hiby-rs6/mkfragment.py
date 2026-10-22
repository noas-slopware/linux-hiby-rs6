#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Make config-rs6.fragment: what the HiBy RS6 needs on top of Arch Linux Ports' aarch64 kernel config.
#   mkfragment.py <Arch config.aarch64> <Nura RS6 config> <kernel tree (RS6 series applied)> <out fragment>
# The tree is only read, to map each symbol to the Kconfig file that defines it.
import sys, re, os
def load(p):
    d = {}
    for l in open(p):
        m = re.match(r'^CONFIG_([A-Z0-9_]+)=(.*)$', l)
        if m: d[m.group(1)] = m.group(2); continue
        m = re.match(r'^# CONFIG_([A-Z0-9_]+) is not set', l)
        if m: d[m.group(1)] = 'n'
    return d
arch = load(sys.argv[1]); pm = load(sys.argv[2])
kmap = {}
tree = sys.argv[3]
for dp, dn, fn in os.walk(tree):
    dn[:] = sorted(d for d in dn if not d.startswith('.'))
    for f in sorted(fn):
        if not f.startswith('Kconfig'): continue
        p = os.path.join(dp, f)
        for l in open(p, errors='replace'):
            m = re.match(r'^\s*(?:menu)?config ([A-Z0-9_]+)', l)
            if m: kmap.setdefault(m.group(1), os.path.relpath(p, tree))
lvl = {'n': 0, 'm': 1, 'y': 2}
# Arch's choice wins for these drivers: generic, not RS6 hardware, or other SoCs
ARCH_WINS = set('''BLK_DEV_LOOP BLK_DEV_LOOP_MIN_COUNT BLK_DEV_NBD BLK_DEV_RAM BLK_DEV_RAM_SIZE ZRAM
BLK_DEV_MD MD_AUTODETECT MD_LINEAR MD_RAID0 MD_RAID1 MD_RAID10 MD_RAID456 BLK_DEV_DM DM_CRYPT
HID_REDRAGON I2C_HID SERIO_SERPORT FWCTL GNSS PTP_1588_CLOCK_KVM PTP_1588_CLOCK_VMCLOCK LEGACY_PTYS
LEGACY_PTY_COUNT NULL_TTY OVMF_DEBUG_LOG IOMMU_DEBUGFS UEVENT_HELPER UEVENT_HELPER_PATH
FW_LOADER_USER_HELPER MFD_STMPE STMPE_I2C KEYBOARD_STMPE PINCTRL_ELIZA PINCTRL_HAWI PINCTRL_IPQ5210
USB_NET_DRIVERS INPUT_UINPUT I2C_CHARDEV ANDROID_BINDER_DEVICES DRM_PANIC_BACKGROUND_COLOR
DRM_PANIC_SCREEN DRM_FBDEV_OVERALLOC MMC_BLOCK_MINORS THERMAL_EMERGENCY_POWEROFF_DELAY_MS
DEVFREQ_GOV_PERFORMANCE DEVFREQ_GOV_POWERSAVE DEVFREQ_GOV_USERSPACE GPIO_LINE_MUX I3C_OR_I2C
DRM_EFIDRM'''.split())
# RS6 needs these outside drivers/ (Arch's value conflicts with the device)
NONDRIVER_RS6 = {
    'CMA_SIZE_MBYTES': 'the SDM660 DTs define no default CMA pool; Nura ran with 32 MiB',
}
# RS6 overrides of Arch drivers it enables
FORCE = {
    'ARM_PSCI_CHECKER': ('n', 'boot-time PSCI hotplug/suspend self-test: never run with the RS6 OSI cluster idle / CPRh bring-up'),
    'RPMB': ('y', 'Arch has RPMB=m, which caps MMC_BLOCK at m; the RS6 root is on eMMC with mmc_block built in'),
}
def isdrv(f):
    return f.startswith('drivers/') or f.startswith('sound/')
sections = {'new': [], 'drv': [], 'nondrv': [], 'force': []}
for s, v in sorted(pm.items(), key=lambda x: (kmap.get(x[0], '~'), x[0])):
    a = arch.get(s)
    if a == v: continue
    f = kmap.get(s, '?')
    if s in NONDRIVER_RS6:
        sections['nondrv'].append((s, v, f, a, NONDRIVER_RS6[s])); continue
    if not isdrv(f):
        continue
    if s in ARCH_WINS: continue
    if a is None:
        if v == 'n': continue
        sections['new'].append((s, v, f, a, '')); continue
    if v in lvl and a in lvl:
        if lvl[v] > lvl[a]: sections['drv'].append((s, v, f, a, ''))
    elif v not in lvl and a not in lvl:
        # non-tristate value inside a driver that Nura set: only follow it when its feature is ours
        if s.startswith('CRYPTO_DEV_QCE'): sections['drv'].append((s, v, f, a, ''))
for s, (v, why) in FORCE.items():
    sections['force'].append((s, v, kmap.get(s, '?'), arch.get(s), why))
def line(s, v):
    return ('# CONFIG_%s is not set' % s) if v == 'n' else ('CONFIG_%s=%s' % (s, v))
out = []
out.append('''# HiBy RS6 on top of Arch Linux Ports' aarch64 kernel config (config.aarch64 next to this file:
# bschnei/linux, branch aarch64, commit df552a59d849, the config of [core] linux 7.2.11.arch1-1 on
# arch.bens.haus). Merged in prepare() with scripts/kconfig/merge_config.sh, then olddefconfig.
# Generated from the Nura RS6 config (config-postmarketos-qcom-sdm660.aarch64, pmos branch) by these rules:
#  - Arch's value stays for everything outside drivers/ and sound/ (scheduler, HZ, preemption, LSMs incl.
#    Landlock, filesystems incl. F2FS as a module with compression, crypto, networking, debug info, compiler);
#  - SDM660/RS6 symbols that Arch's config does not have at all (sdm660-mainline and our series) take the Nura value;
#  - a driver the Nura config enables more strongly (n < m < y) keeps the Nura level: the SoC base drivers
#    (clocks, pinctrl, RPM/SMD, regulators, interconnect, CPR, rpmpd, SDHCI, PHYs, DRM, simpledrm, rpmsg) stay
#    built in as on every RS6 boot so far (sync_state and handoff timing were tuned that way);
#  - except a short list where Arch's choice wins (generic, not RS6 hardware, or other SoCs), see mkfragment.py;
#  - plus the RS6 overrides at the end.
# Do not edit by hand: regenerate with mkfragment.py (next to this file), then review the diff.
''')
def emit(title, items):
    out.append('\n# ---- %s (%d)' % (title, len(items)))
    last = None
    for s, v, f, a, why in items:
        d = f.rsplit('/', 1)[0] if f != '?' else '?'
        if d != last:
            out.append('# %s' % f); last = d
        if why: out.append('# %s' % why)
        out.append(line(s, v) + ('' if a is None else '   # Arch: %s' % a).replace('# Arch: n', '# Arch: off'))
emit('not in the Arch config: sdm660-mainline and RS6 series symbols', sections['new'])
emit('drivers the RS6 needs built in / enabled (Arch has them lower)', sections['drv'])
emit('RS6 needs outside drivers/', sections['nondrv'])
emit('RS6 overrides of Arch choices', sections['force'])
# merge_config does not accept trailing comments on value lines: put them on the line before
fixed = []
for l in out:
    m = re.match(r'^(CONFIG_[A-Z0-9_]+=.*?|# CONFIG_[A-Z0-9_]+ is not set)   # (Arch: .*)$', l)
    if m: fixed.append('# ' + m.group(2)); fixed.append(m.group(1))
    else: fixed.append(l)
open(sys.argv[4], 'w').write('\n'.join(fixed) + '\n')
print({k: len(v) for k, v in sections.items()})
