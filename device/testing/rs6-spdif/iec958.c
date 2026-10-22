// SPDX-License-Identifier: MIT
/*
 * IEC 60958 biphase-mark encoder for the HiBy RS6 coax output. Contract: docs/audio.md,
 * "The coax stream format" (stock HAL spdif_core_process_data 0x65aac, nibble table of
 * spdif_core_init 0x65e74, preambles at 0xb6eb8).
 */
#include <errno.h>
#include <string.h>

#include "iec958.h"

/*
 * 8 cells for 4 data bits, LSB of the nibble first, first cell in bit 7. Every bit flips the
 * line at the start of its cell pair and a 1 flips it again in the middle. Index 2n + level
 * of the cell before. Same 32 bytes as the stock HAL table.
 */
const uint8_t iec958_bmc[32] = {
	0xcc, 0x33, 0xb3, 0x4c, 0xd3, 0x2c, 0xac, 0x53,
	0xcb, 0x34, 0xb4, 0x4b, 0xd4, 0x2b, 0xab, 0x54,
	0xcd, 0x32, 0xb2, 0x4d, 0xd2, 0x2d, 0xad, 0x52,
	0xca, 0x35, 0xb5, 0x4a, 0xd5, 0x2a, 0xaa, 0x55,
};

enum { PRE_B, PRE_M, PRE_W };

/* B, M, W after a 0 cell, then after a 1 cell (stock table at 0xb6eb8) */
static const uint8_t preamble[2][3] = {
	{ 0xe8, 0xe2, 0xe4 },
	{ 0x17, 0x1d, 0x1b },
};

/*
 * Consumer sampling frequency codes, bits 24-27 as the ALSA AES3 byte (Linux
 * include/sound/asoundef.h IEC958_AES3_CON_FS_*; 352.8k and 384k are the IEC 60958-3
 * extension codes, the stock HAL table at 0xb6e14 stops at 192k), and the original
 * sampling frequency, AES4 bits 4-7 (0 = not indicated).
 */
static const struct {
	unsigned int fs;
	uint8_t code, orig;
} fs_table[] = {
	{ 44100, 0, 15 }, { 48000, 2, 13 }, { 88200, 8, 7 }, { 96000, 10, 5 },
	{ 176400, 12, 3 }, { 192000, 14, 1 }, { 352800, 13, 0 }, { 384000, 5, 0 },
};

int iec958_fs_code(unsigned int fs)
{
	size_t i;

	for (i = 0; i < sizeof(fs_table) / sizeof(fs_table[0]); i++)
		if (fs_table[i].fs == fs)
			return fs_table[i].code;
	return -1;
}

int iec958_cs_build(uint8_t cs[IEC958_CS_BYTES], enum iec958_cs_mode mode, unsigned int fs,
		    enum iec958_in_fmt fmt)
{
	size_t i;

	memset(cs, 0, IEC958_CS_BYTES);
	for (i = 0; i < sizeof(fs_table) / sizeof(fs_table[0]); i++)
		if (fs_table[i].fs == fs)
			break;
	if (i == sizeof(fs_table) / sizeof(fs_table[0]))
		return -EINVAL;
	if (mode == IEC958_CS_STOCK)
		return 0;
	/*
	 * ALSA's IEC958 default (alsa.conf pcm.iec958): consumer, linear PCM, copyright not
	 * asserted (copying permitted, SCMS recorders accept it), no pre-emphasis, mode 0;
	 * category PCM encoder/decoder with the L bit; source and channel number unspecified;
	 * clock accuracy level II.
	 */
	cs[0] = 0x04;
	cs[1] = 0x82;
	cs[2] = 0x00;
	cs[3] = fs_table[i].code;
	/* word length: 16 of max 20 for S16, 24 of max 24 otherwise (a subframe holds 24) */
	cs[4] = (fmt == IEC958_IN_S16 ? 0x02 : 0x0b) | fs_table[i].orig << 4;
	return 0;
}

void iec958_init(struct iec958_enc *e, const uint8_t cs[IEC958_CS_BYTES])
{
	e->level = 0;
	e->frame = 0;
	memcpy(e->cs, cs, IEC958_CS_BYTES);
}

void iec958_set_cs(struct iec958_enc *e, const uint8_t cs[IEC958_CS_BYTES])
{
	memcpy(e->cs, cs, IEC958_CS_BYTES);
}

static inline unsigned int parity24(uint32_t x)
{
	x ^= x >> 16;
	x ^= x >> 8;
	x ^= x >> 4;
	x ^= x >> 2;
	x ^= x >> 1;
	return x & 1;
}

/* one subframe: preamble, 24 audio bits LSB first, V U C P; even parity over slots 4-31 */
static inline void subframe(struct iec958_enc *e, uint32_t a, unsigned int pre, unsigned int c,
			    uint32_t *out)
{
	const uint8_t *t = iec958_bmc;
	uint8_t p = preamble[e->level][pre];
	unsigned int lv = p & 1, vucp, i;
	uint8_t b[7];

	a &= 0xffffff;
	vucp = c << 2 | (parity24(a) ^ c) << 3;
	for (i = 0; i < 6; i++) {
		b[i] = t[((a >> (4 * i)) & 15) * 2 + lv];
		lv = b[i] & 1;
	}
	b[6] = t[vucp * 2 + lv];
	e->level = b[6] & 1;
	out[0] = (uint32_t)p << 24 | (uint32_t)b[0] << 16 | (uint32_t)b[1] << 8 | b[2];
	out[1] = (uint32_t)b[3] << 24 | (uint32_t)b[4] << 16 | (uint32_t)b[5] << 8 | b[6];
}

static inline uint32_t sample(enum iec958_in_fmt fmt, const uint8_t *p)
{
	switch (fmt) {
	case IEC958_IN_S16:
		return (uint32_t)(p[0] | p[1] << 8) << 8;
	case IEC958_IN_S24:
		return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16;
	default:
		return (uint32_t)p[1] | (uint32_t)p[2] << 8 | (uint32_t)p[3] << 16;
	}
}

static inline void frame(struct iec958_enc *e, uint32_t l, uint32_t r, uint32_t *out)
{
	unsigned int f = e->frame;
	unsigned int c = (e->cs[f >> 3] >> (f & 7)) & 1;

	subframe(e, l, f ? PRE_M : PRE_B, c, out);
	subframe(e, r, PRE_W, c, out + 2);
	e->frame = f + 1 == IEC958_BLOCK_FRAMES ? 0 : f + 1;
}

void iec958_encode(struct iec958_enc *e, enum iec958_in_fmt fmt, const uint8_t *l,
		   const uint8_t *r, size_t step, size_t frames, uint32_t *out)
{
	size_t n;

	for (n = 0; n < frames; n++, l += step, r += step, out += IEC958_WORDS_PER_FRAME)
		frame(e, sample(fmt, l), sample(fmt, r), out);
}

void iec958_encode_silence(struct iec958_enc *e, size_t frames, uint32_t *out)
{
	size_t n;

	for (n = 0; n < frames; n++, out += IEC958_WORDS_PER_FRAME)
		frame(e, 0, 0, out);
}
