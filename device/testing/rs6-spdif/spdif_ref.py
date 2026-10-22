# SPDX-License-Identifier: MIT
# Reference encoder by the RS6 S/PDIF analysis (docs/spdif-dsd.md 9.1), unchanged except for
# the __main__ guard: Hal is a transliteration of the stock HAL's spdif_core_process_data
# (0x65aac) instruction listing, iec() an IEC 60958 encoder written from the spec (V=U=C=0).
# HAL spdif_core_process_data (0x65aac, from the instruction listing) vs. an IEC 60958 encoder
# written from the spec, then the q6asm S32 pair path. Prints test vectors.
import random
PRE = [0xe8, 0xe2, 0xe4, 0x17, 0x1d, 0x1b]          # 0xb6eb8: B M W for level 0, then level 1

def bmc_nib(n, p):                                  # spdif_core_init table, verified LSB first
    lvl, v = p, 0
    for i in range(4):
        lvl ^= 1; v = v << 1 | lvl
        if (n >> i) & 1: lvl ^= 1
        v = v << 1 | lvl
    return v
TAB = [bmc_nib(n, p) for n in range(16) for p in (0, 1)]

class Hal:
    def __init__(s): s.prev = 0; s.blk = 0          # +0x1208, +0x120c (reset: 0)
    def run(s, samples):                            # interleaved L R int32, n frames
        out = []; n = len(samples) // 2
        for f in range(n):
            for ch in range(2):
                if ch == 0:
                    if f == s.blk: pre = PRE[s.prev * 3]; s.blk = f + 192
                    else: pre = PRE[s.prev * 3 + 1]
                else: pre = PRE[s.prev * 3 + 2]
                x = samples[2 * f + ch] & 0xffffffff
                w18 = (x >> 8)                       # extr with [0x1200] = 0, [0x1204] = 0
                par = sum(bin((w18 >> (8 * k)) & 0xff).count('1') for k in range(4))
                w18 |= (par << 27) & 0xffffffff
                b = []; last = pre & 1
                for sh in (8, 12, 16, 20, 24, 28):
                    v = TAB[((x >> sh) & 0xf) * 2 + (last & 1)]; b.append(v); last = v
                v = TAB[((w18 >> 24) & 0xf) * 2 + (last & 1)]; b.append(v)
                out.append(pre << 24 | b[0] << 16 | b[1] << 8 | b[2])
                out.append(b[3] << 24 | b[4] << 16 | b[5] << 8 | b[6])
                s.prev = v & 1
        s.blk = (s.blk - n) % 192
        return out

def iec(samples, nframes0=0):
    # from the spec: 32 slots, BMC, preambles B/M/W, V=U=C=0, even parity over slots 4..31
    level = 0; out = []
    PB, PM, PW = '11101000', '11100010', '11100100'
    for f in range(len(samples) // 2):
        for ch in range(2):
            a = (samples[2 * f + ch] >> 8) & 0xffffff
            pre = PB if ch == 0 and (f + nframes0) % 192 == 0 else (PM if ch == 0 else PW)
            if level: pre = ''.join('1' if c == '0' else '0' for c in pre)
            cells = pre; level = int(pre[-1])
            bits = [(a >> i) & 1 for i in range(24)] + [0, 0, 0]
            bits.append(sum(bits) & 1)
            for d in bits:
                level ^= 1; cells += str(level)
                if d: level ^= 1
                cells += str(level)
            out.append(int(cells[:32], 2)); out.append(int(cells[32:], 2))
    return out

if __name__ == "__main__":
    random.seed(6)
    h = Hal(); ok = True; done = 0
    for chunk in (100, 92, 192, 7, 500):               # crosses block boundaries in odd chunks
        smp = [random.getrandbits(32) for _ in range(2 * chunk)]
        a = h.run(smp); b = iec(smp, done); done += chunk
        ok &= a == b
    print("HAL == IEC spec encoder:", ok)

    # q6asm S32 pair path: ror32 per S32 sample in place, then S16 words to the I2S in memory order
    def ror16(w): return ((w >> 16) | (w << 16)) & 0xffffffff
    hal_s16 = []
    for w in Hal().run([0, 0] * 2):                    # HAL: swap halves, write as S16 LE
        s = ror16(w); hal_s16 += [s & 0xffff, s >> 16]
    q6_s16 = []
    for w in Hal().run([0, 0] * 2):                    # encoder S32 sample = word, kernel ror32
        s = ror16(w); q6_s16 += [s & 0xffff, s >> 16]
    print("HAL S16 stream == S32 FE + ror32:", hal_s16 == q6_s16)
    print("I2S slot order (16-bit, first first):", ' '.join('%04x' % x for x in hal_s16[:8]))
    print("silence, 3 frames, S32 FE samples:")
    for i, w in enumerate(Hal().run([0, 0] * 3)):
        print('  frame %d %s w%d %08x' % (i // 4, 'LR'[(i // 2) % 2], i % 2, w))
    print("L = 0x123456 << 8, R = -1 << 8 (24-bit -1), frame 0 and 1:")
    for i, w in enumerate(Hal().run([0x12345600, -256 & 0xffffffff] * 2)):
        print('  frame %d %s w%d %08x' % (i // 4, 'LR'[(i // 2) % 2], i % 2, w))
