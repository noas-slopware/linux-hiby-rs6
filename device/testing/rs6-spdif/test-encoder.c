// SPDX-License-Identifier: MIT
/*
 * Encoder unit test: the stock HAL nibble table, the test vectors of docs/audio.md, "The coax
 * stream format", and a bit-exact round trip through an independent decoder for every rate,
 * input format, channel status mode and layout (interleaved, separate buffers), in random chunk
 * sizes across block boundaries.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bmc-decode.h"
#include "iec958.h"

static int failures;

#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL: " __VA_ARGS__); printf("\n"); failures++; } } while (0)

static uint64_t rng = 0x9e3779b97f4a7c15ULL;

static uint32_t rnd(void)
{
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return (uint32_t)(rng >> 16);
}

/* ideal BMC of a nibble, LSB first, first cell in bit 7, from the line level p */
static uint8_t ideal_bmc(unsigned int n, unsigned int p)
{
	unsigned int lvl = p, v = 0, i;

	for (i = 0; i < 4; i++) {
		lvl ^= 1;
		v = v << 1 | lvl;
		if (n >> i & 1)
			lvl ^= 1;
		v = v << 1 | lvl;
	}
	return v;
}

static void test_table(void)
{
	unsigned int n, p;

	for (n = 0; n < 16; n++)
		for (p = 0; p < 2; p++)
			CHECK(iec958_bmc[2 * n + p] == ideal_bmc(n, p), "bmc table entry %u", 2 * n + p);
}

static void test_vectors(void)
{
	static const uint32_t silence[8] = {
		0xe8cccccc, 0xcccccccc, 0xe4cccccc, 0xcccccccc,
		0xe2cccccc, 0xcccccccc, 0xe4cccccc, 0xcccccccc,
	};
	static const uint32_t tone[8] = {
		0xe8d4b4cb, 0x532cb332, 0xe4aaaaaa, 0xaaaaaacc,
		0xe2d4b4cb, 0x532cb332, 0xe4aaaaaa, 0xaaaaaacc,
	};
	int32_t in[4] = { 0x12345600, (int32_t)0xffffff00, 0x12345600, (int32_t)0xffffff00 };
	uint8_t cs[IEC958_CS_BYTES], zero[16] = { 0 };
	struct iec958_enc e;
	uint32_t out[8];
	int mode;

	/* consumer channel status has C = 0 in frames 0 and 1 too, so both modes match */
	for (mode = 0; mode < 2; mode++) {
		iec958_cs_build(cs, mode ? IEC958_CS_STOCK : IEC958_CS_CONSUMER, 44100, IEC958_IN_S32);
		iec958_init(&e, cs);
		iec958_encode(&e, IEC958_IN_S32, zero, zero + 4, 8, 2, out);
		CHECK(!memcmp(out, silence, sizeof(out)), "silence vector (mode %d)", mode);
		iec958_init(&e, cs);
		iec958_encode(&e, IEC958_IN_S32, (uint8_t *)in, (uint8_t *)in + 4, 8, 2, out);
		CHECK(!memcmp(out, tone, sizeof(out)), "L = 0x123456, R = -1 vector (mode %d)", mode);
	}
	iec958_init(&e, cs);
	iec958_encode_silence(&e, 2, out);
	CHECK(!memcmp(out, silence, sizeof(out)), "encode_silence vector");
}

static uint32_t expect_a(enum iec958_in_fmt fmt, const uint8_t *p)
{
	switch (fmt) {
	case IEC958_IN_S16:
		return ((uint32_t)(int32_t)(int16_t)(p[0] | p[1] << 8) << 8) & 0xffffff;
	case IEC958_IN_S24:
		return (p[0] | p[1] << 8 | (uint32_t)p[2] << 16) & 0xffffff;
	default:
		return ((uint32_t)(p[0] | p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24) >> 8);
	}
}

static const unsigned int rates[] = { 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000 };
static const char *const fmt_names[] = { "S16_LE", "S24_LE", "S32_LE" };

static void test_roundtrip(enum iec958_in_fmt fmt, unsigned int fs, enum iec958_cs_mode mode,
			   int separate)
{
	const size_t frames = 192 * 6 + 77, width = fmt == IEC958_IN_S16 ? 2 : 4;
	uint8_t *buf = malloc(frames * 2 * width), *lb = malloc(frames * width),
		*rb = malloc(frames * width);
	uint32_t *out = malloc(frames * 16), *one = malloc(frames * 16);
	uint8_t cs[IEC958_CS_BYTES];
	struct iec958_enc e;
	struct bmc_dec d;
	size_t i, done;
	const char *what = fmt_names[fmt];

	for (i = 0; i < frames * 2 * width; i++)
		buf[i] = rnd();
	/* some full-scale and zero samples */
	memset(buf, 0, 2 * width);
	memset(buf + 2 * width, 0xff, 2 * width);
	for (i = 0; i < frames; i++) {
		memcpy(lb + i * width, buf + 2 * i * width, width);
		memcpy(rb + i * width, buf + (2 * i + 1) * width, width);
	}
	CHECK(!iec958_cs_build(cs, mode, fs, fmt), "cs_build %u", fs);

	/* one call */
	iec958_init(&e, cs);
	iec958_encode(&e, fmt, buf, buf + width, 2 * width, frames, one);

	/* random chunks, interleaved or from separate buffers */
	iec958_init(&e, cs);
	for (done = 0; done < frames; ) {
		size_t n = 1 + rnd() % 300;

		if (n > frames - done)
			n = frames - done;
		if (separate)
			iec958_encode(&e, fmt, lb + done * width, rb + done * width, width, n,
				      out + done * 4);
		else
			iec958_encode(&e, fmt, buf + done * 2 * width, buf + done * 2 * width + width,
				      2 * width, n, out + done * 4);
		done += n;
	}
	CHECK(!memcmp(out, one, frames * 16), "%s %u: chunked != one call", what, fs);

	bmc_dec_init(&d);
	for (i = 0; i < frames; i++) {
		struct bmc_sub l, r;

		if (bmc_dec_frame(&d, out + 4 * i, &l, &r) < 0) {
			CHECK(0, "%s %u mode %d: %s", what, fs, mode, d.err);
			break;
		}
		if (l.a != expect_a(fmt, buf + 2 * i * width) ||
		    r.a != expect_a(fmt, buf + (2 * i + 1) * width)) {
			CHECK(0, "%s %u: frame %zu audio %06x %06x", what, fs, i, l.a, r.a);
			break;
		}
		if (l.v || l.u || r.v || r.u || l.c != r.c) {
			CHECK(0, "%s %u: frame %zu V/U/C", what, fs, i);
			break;
		}
	}
	CHECK(d.blocks == 6, "%s %u: %lu blocks", what, fs, d.blocks);
	CHECK(!memcmp(d.last_cs[0], cs, IEC958_CS_BYTES) &&
	      !memcmp(d.last_cs[1], cs, IEC958_CS_BYTES), "%s %u: channel status differs", what, fs);
	free(buf);
	free(lb);
	free(rb);
	free(out);
	free(one);
}

static void test_cs(void)
{
	uint8_t cs[IEC958_CS_BYTES];
	static const uint8_t code[8] = { 0, 2, 8, 10, 12, 14, 13, 5 };
	static const uint8_t orig[8] = { 15, 13, 7, 5, 3, 1, 0, 0 };
	unsigned int i;

	for (i = 0; i < 8; i++) {
		iec958_cs_build(cs, IEC958_CS_CONSUMER, rates[i], IEC958_IN_S24);
		CHECK(cs[0] == 0x04 && cs[1] == 0x82 && cs[2] == 0 && cs[3] == code[i] &&
		      cs[4] == (0x0b | orig[i] << 4), "consumer cs at %u", rates[i]);
		iec958_cs_build(cs, IEC958_CS_CONSUMER, rates[i], IEC958_IN_S16);
		CHECK(cs[4] == (0x02 | orig[i] << 4), "consumer cs word length S16 at %u", rates[i]);
		iec958_cs_build(cs, IEC958_CS_STOCK, rates[i], IEC958_IN_S32);
		CHECK(!memcmp(cs, (uint8_t[IEC958_CS_BYTES]){ 0 }, IEC958_CS_BYTES), "stock cs zero");
	}
	CHECK(iec958_cs_build(cs, IEC958_CS_CONSUMER, 32000, IEC958_IN_S16) < 0, "32k refused");
	CHECK(iec958_cs_build(cs, IEC958_CS_CONSUMER, 768000, IEC958_IN_S16) < 0, "768k refused");
}

int main(void)
{
	unsigned int r, f, m, s;

	test_table();
	test_vectors();
	test_cs();
	for (r = 0; r < 8; r++)
		for (f = 0; f < 3; f++)
			for (m = 0; m < 2; m++)
				for (s = 0; s < 2; s++)
					test_roundtrip(f, rates[r], m, s);
	if (failures) {
		printf("%d failure(s)\n", failures);
		return 1;
	}
	printf("encoder: all checks passed (8 rates x 3 formats x 2 channel status modes x 2 layouts)\n");
	return 0;
}
