#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Compare the C encoder (rs6-spdif-encode) with the reference encoders in spdif_ref.py on
# random input, for every rate and input format, fed in odd chunk sizes across block
# boundaries:
#   stock channel status:    the HAL transliteration (spdif_ref.Hal) and the spec encoder
#                            (spdif_ref.iec), fed in the same chunks
#   consumer channel status: iec_cs() below, the spec encoder with a C channel (parity
#                            then covers C too), with the channel status bytes computed here
#                            from IEC 60958-3 / Linux asoundef.h independently of iec958.c
# usage: test-ref.py PATH/TO/rs6-spdif-encode
import os
import random
import struct
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spdif_ref  # noqa: E402

ENC = sys.argv[1]
RATES = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
FS_CODE = {44100: 0, 48000: 2, 88200: 8, 96000: 10, 176400: 12, 192000: 14, 352800: 13, 384000: 5}
ORIG = {44100: 15, 48000: 13, 88200: 7, 96000: 5, 176400: 3, 192000: 1}


def consumer_cs(rate, fmt):
    cs = [0] * 24
    cs[0] = 0x04                    # consumer, PCM, copyright not asserted, no emphasis
    cs[1] = 0x82                    # PCM encoder/decoder, L bit
    cs[3] = FS_CODE[rate]
    cs[4] = (0x02 if fmt == 's16' else 0x0b) | ORIG.get(rate, 0) << 4
    return cs


def iec_cs(samples, cs, nframes0=0):
    """spdif_ref.iec with the C bit of the channel status block; parity over slots 4..31"""
    level = 0
    out = []
    PB, PM, PW = '11101000', '11100010', '11100100'
    for f in range(len(samples) // 2):
        blk = (f + nframes0) % 192
        c = cs[blk // 8] >> (blk % 8) & 1
        for ch in range(2):
            a = (samples[2 * f + ch] >> 8) & 0xffffff
            pre = PB if ch == 0 and blk == 0 else (PM if ch == 0 else PW)
            if level:
                pre = ''.join('1' if x == '0' else '0' for x in pre)
            cells = pre
            level = int(pre[-1])
            bits = [(a >> i) & 1 for i in range(24)] + [0, 0, c]
            bits.append(sum(bits) & 1)
            for d in bits:
                level ^= 1
                cells += str(level)
                if d:
                    level ^= 1
                cells += str(level)
            out.append(int(cells[:32], 2))
            out.append(int(cells[32:], 2))
    return out


def as_x(raw, fmt):
    """input bytes -> the HAL's int32 view (audio in bits 31:8)"""
    if fmt == 's16':
        v = struct.unpack('<%dh' % (len(raw) // 2), raw)
        return [(s << 16) & 0xffffffff for s in v]
    v = struct.unpack('<%dI' % (len(raw) // 4), raw)
    if fmt == 's24':
        return [(s << 8) & 0xffffffff for s in v]
    return list(v)


def main():
    rnd = random.Random(60958)
    fails = 0
    cases = 0
    for fmt in ('s16', 's24', 's32'):
        width = 2 if fmt == 's16' else 4
        for rate in RATES:
            frames = 192 * 4 + rnd.randrange(1, 191)
            raw = bytes(rnd.getrandbits(8) for _ in range(frames * 2 * width))
            chunks = [rnd.choice([1, 7, 92, 100, 191, 192, 193, 500]) for _ in range(6)]
            x = as_x(raw, fmt)
            for mode in ('stock', 'consumer'):
                cases += 1
                p = subprocess.run([ENC, fmt, str(rate), mode] + [str(c) for c in chunks],
                                   input=raw, capture_output=True, check=True)
                got = list(struct.unpack('<%dI' % (len(p.stdout) // 4), p.stdout))
                if mode == 'stock':
                    hal = spdif_ref.Hal()
                    ref, done, i = [], 0, 0
                    while done < frames:
                        n = min(chunks[i % len(chunks)], frames - done)
                        ref += hal.run(x[2 * done:2 * (done + n)])
                        done += n
                        i += 1
                    spec = spdif_ref.iec(x)
                    ok = got == ref == spec
                else:
                    ok = got == iec_cs(x, consumer_cs(rate, fmt))
                if not ok:
                    fails += 1
                    first = next((i for i, (a, b) in enumerate(zip(got, ref if mode == 'stock'
                                  else iec_cs(x, consumer_cs(rate, fmt)))) if a != b), None)
                    print('FAIL %s %d %s: first differing word %s' % (fmt, rate, mode, first))
    if fails:
        print('%d of %d cases failed' % (fails, cases))
        return 1
    print('reference: %d cases match (3 formats x 8 rates x 2 channel status modes)' % cases)
    return 0


if __name__ == '__main__':
    sys.exit(main())
