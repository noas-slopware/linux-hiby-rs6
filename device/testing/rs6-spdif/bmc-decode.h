/* SPDX-License-Identifier: MIT */
/*
 * Test-only IEC 60958 decoder for the RS6 word layout: four 32-bit words per frame
 * (L.w0 L.w1 R.w0 R.w1), 32 cells per word, first cell in the MSB. Checks everything a
 * receiver relies on: preamble patterns and their polarity, the block position of B, a
 * transition at every bit cell boundary, even parity, and collects V, U, C and the audio.
 * Written from the spec, independently of iec958.c.
 */
#ifndef RS6_BMC_DECODE_H
#define RS6_BMC_DECODE_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct bmc_dec {
	unsigned int level;	/* last cell */
	unsigned long frame;	/* frames decoded */
	uint8_t cs[2][24];	/* channel status of the current block, per subframe */
	uint8_t last_cs[2][24];	/* last complete block */
	unsigned long blocks;	/* complete blocks */
	char err[160];
};

struct bmc_sub {
	uint32_t a;		/* 24-bit audio */
	unsigned int v, u, c;
};

static inline void bmc_dec_init(struct bmc_dec *d)
{
	memset(d, 0, sizeof(*d));
}

/* B, M, W for a previous cell of 0; the inverted pattern follows a 1 */
static const uint8_t bmc_dec_pre[3] = { 0xe8, 0xe2, 0xe4 };

static inline int bmc_dec_sub(struct bmc_dec *d, uint32_t w0, uint32_t w1, int want,
			      struct bmc_sub *s)
{
	uint64_t cells = (uint64_t)w0 << 32 | w1;
	unsigned int p = w0 >> 24, i, ones = 0, cell1, cell2, bit;
	uint8_t expect = d->level ? (uint8_t)~bmc_dec_pre[want] : bmc_dec_pre[want];

	if (p != expect) {
		snprintf(d->err, sizeof(d->err), "frame %lu: preamble %02x, want %c (%02x) after %u",
			 d->frame, p, "BMW"[want], expect, d->level);
		return -1;
	}
	d->level = p & 1;
	memset(s, 0, sizeof(*s));
	for (i = 0; i < 28; i++) {
		cell1 = (cells >> (63 - 8 - 2 * i)) & 1;
		cell2 = (cells >> (63 - 9 - 2 * i)) & 1;
		if (cell1 == d->level) {
			snprintf(d->err, sizeof(d->err), "frame %lu: no transition at slot %u",
				 d->frame, i + 4);
			return -1;
		}
		bit = cell1 != cell2;
		d->level = cell2;
		ones += bit;
		if (i < 24)
			s->a |= (uint32_t)bit << i;
		else if (i == 24)
			s->v = bit;
		else if (i == 25)
			s->u = bit;
		else if (i == 26)
			s->c = bit;
	}
	if (ones & 1) {
		snprintf(d->err, sizeof(d->err), "frame %lu: odd parity", d->frame);
		return -1;
	}
	return 0;
}

/* one frame; frames are counted from a block start (the stream starts with B) */
static inline int bmc_dec_frame(struct bmc_dec *d, const uint32_t w[4], struct bmc_sub *l,
				struct bmc_sub *r)
{
	unsigned int f = d->frame % 192;

	if (bmc_dec_sub(d, w[0], w[1], f ? 1 : 0, l) < 0 || bmc_dec_sub(d, w[2], w[3], 2, r) < 0)
		return -1;
	d->cs[0][f / 8] |= l->c << (f % 8);
	d->cs[1][f / 8] |= r->c << (f % 8);
	if (f == 191) {
		memcpy(d->last_cs, d->cs, sizeof(d->cs));
		memset(d->cs, 0, sizeof(d->cs));
		d->blocks++;
	}
	d->frame++;
	return 0;
}

#endif
