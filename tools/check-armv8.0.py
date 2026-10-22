#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# check-armv8.0.py: make sure built packages carry no AArch64 instructions beyond what the RS6 has:
# ARMv8.0-A + CRC32 + the ARMv8.0 crypto extension (AES, PMULL/PMULL2, SHA1, SHA256), i.e. what our
# own builds get from -march=armv8-a+crc+crypto (Kryo 260 = Cortex-A73/A53 class).
#   check-armv8.0.py [--features LLVM-MATTR] <pkg.tar.zst>...
# Needs bsdtar and llvm-objdump (any host arch: the build scripts run it natively in the x86_64 fetcher
# container). Every AArch64 ELF is disassembled twice, once with every architecture feature and once
# with only the allowed ones (llvm-objdump --mattr=-all,+neon,+crc,+aes,+sha2). An instruction that
# decodes differently the second time needs a newer feature: LSE atomics, RDM, dot product, FP16,
# SHA3/SHA512/SM3/SM4, RCpc, BF16, I8MM, SVE/SME, JSCVT, FRINTTS, PAuth outside the hint space,
# DC CVAP (shows up as a bare "sys"), newer system registers (shows up as S3_x_Cx_Cx_x), ...
# Exempt: the hint space (PACIASP/AUTIASP/BTI/XPACLRI/ESB are NOPs on ARMv8.0) and GCC's
# outline-atomics helpers (__aarch64_cas4_acq & co. from libgcc, only reach their LSE instruction after
# "ldrb w16, __aarch64_have_lse_atomics; cbz w16"), recognised by that guard since packages are
# stripped. Kernel alternatives are exempt too: code listed as a replacement in an .altinstructions
# section (the kernel's vDSO in -headers) is only patched in at boot when the CPU has the feature.
# Bytes that decode in neither pass are data. The kernel is skipped (vmlinux in -headers,
# *.ko): it patches LSE & co. in at boot through alternatives, behind its own CPU feature checks. Exit status 1 on any finding; code that picks
# instructions at run time behind a HWCAP check of its own still gets reported and needs a look.
import argparse, os, re, struct, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

ALLOWED = '-all,+neon,+crc,+aes,+sha2'
EM_AARCH64 = 183
KERNEL = re.compile(r'(^|/)usr/lib/modules/[^/]+/(build/vmlinux|.*\.ko)$')
INSN = re.compile(r'^\s*([0-9a-f]+):\s*\t(.*)$')
FUNC = re.compile(r'^[0-9a-f]+ <(.+)>:$')
LSE = re.compile(r'^(cas|casp|swp|ld(add|clr|eor|set|smax|smin|umax|umin)|st(add|clr|eor|set|smax|smin|umax|umin))[a-z]*\s')


def aarch64_elf(path):
    try:
        with open(path, 'rb') as f:
            h = f.read(20)
    except OSError:
        return False
    return len(h) == 20 and h[:4] == b'\x7fELF' and h[5] == 1 and int.from_bytes(h[18:20], 'little') == EM_AARCH64


def alt_replacements(path):
    # arm64 struct alt_instr {s32 orig_offset; s32 alt_offset; u16 cpucap; u8 orig_len; u8 alt_len;},
    # offsets relative to the field; returns the [start, end) address ranges of the replacements
    with open(path, 'rb') as f:
        d = f.read()
    shoff, = struct.unpack_from('<Q', d, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
    secs = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + i * shentsize) for i in range(shnum)]
    if not secs:
        return []
    stroff = secs[shstrndx][4]
    out = []
    for s in secs:
        if d[stroff + s[0]:].split(b'\0')[0] == b'.altinstructions':
            addr, off, size = s[3], s[4], s[5]
            for i in range(size // 12):
                _, a, _, _, alen = struct.unpack_from('<iiHBB', d, off + i * 12)
                start = addr + i * 12 + 4 + a
                out.append((start, start + alen))
    return out


def check_elf(path, rel, mattr):
    alts = alt_replacements(path)
    # llvm-objdump enables every AArch64 feature by default; both listings have the same lines
    full, lim = (subprocess.Popen(['llvm-objdump', '-d', '--no-show-raw-insn', path] + extra,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
                 for extra in ([], ['--mattr=' + mattr]))
    findings, func, prev = [], '?', []
    for a, b in zip(full.stdout, lim.stdout):
        m = FUNC.match(a)
        if m:
            func, prev = m.group(1), []
            continue
        ma, mb = INSN.match(a), INSN.match(b)
        if not ma or not mb:
            continue
        ia, ib = ma.group(2).strip(), mb.group(2).strip()
        if ia != ib and not ia.startswith('<unknown>') and not ib.startswith('hint'):
            guarded = LSE.match(ia + ' ') and len(prev) >= 2 and prev[-1].startswith('cbz\tw16') and prev[-2].startswith('ldrb\tw16')
            pc = int(ma.group(1), 16)
            if not guarded and not any(lo <= pc < hi for lo, hi in alts):
                findings.append('%s: %s: 0x%s: %s' % (rel, func, ma.group(1), ia))
        prev = (prev + [ia])[-2:]
    full.wait(); lim.wait()
    if full.returncode or lim.returncode:
        findings.append('%s: llvm-objdump failed' % rel)
    return findings


def check(pkg, mattr):
    with tempfile.TemporaryDirectory() as d:
        subprocess.run(['bsdtar', '-xf', pkg, '-C', d], check=True)
        elfs = []
        for root, _, files in os.walk(d):
            for fn in files:
                p = os.path.join(root, fn)
                if not os.path.islink(p) and aarch64_elf(p) and not KERNEL.search(os.path.relpath(p, d)):
                    elfs.append(p)
        with ThreadPoolExecutor(os.cpu_count()) as ex:
            res = ex.map(lambda p: check_elf(p, os.path.relpath(p, d), mattr), elfs)
            findings = [f for r in res for f in r]
    for f in findings:
        print('%s: %s' % (os.path.basename(pkg), f))
    print('%s: %d AArch64 ELF file(s), %d finding(s)' % (os.path.basename(pkg), len(elfs), len(findings)))
    return len(findings)


ap = argparse.ArgumentParser()
ap.add_argument('--features', default=ALLOWED, help='llvm-objdump --mattr for the allowed set (default %(default)s)')
ap.add_argument('pkgs', nargs='+')
args = ap.parse_args()
total = sum(check(p, args.features) for p in args.pkgs)
print('%d instruction(s) beyond ARMv8.0+crc+crypto found' % total)
sys.exit(1 if total else 0)
