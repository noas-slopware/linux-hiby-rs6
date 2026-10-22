/* SPDX-License-Identifier: MIT */
/*
 * IEC 60958 (S/PDIF) biphase-mark encoder in the layout the HiBy RS6 DAC FPGA forwards to its
 * coaxial pin (docs/audio.md, "The coax stream format"). One stereo frame becomes four 32-bit
 * words, L.w0 L.w1 R.w0 R.w1, each holding 32 BMC cells, first cell in the MSB:
 *
 *   w0 = pre << 24 | bmc(a[3:0]) << 16 | bmc(a[7:4]) << 8 | bmc(a[11:8])
 *   w1 = bmc(a[15:12]) << 24 | bmc(a[19:16]) << 16 | bmc(a[23:20]) << 8 | bmc(V U C P)
 *
 * a is the 24-bit sample. The line level and the block position carry across calls.
 */
#ifndef RS6_IEC958_H
#define RS6_IEC958_H

#include <stddef.h>
#include <stdint.h>

#define IEC958_BLOCK_FRAMES	192
#define IEC958_CS_BYTES		24
#define IEC958_WORDS_PER_FRAME	4

enum iec958_in_fmt {
	IEC958_IN_S16,		/* S16_LE: a = s16 << 8 */
	IEC958_IN_S24,		/* S24_LE: low 24 bits of a 32-bit container */
	IEC958_IN_S32,		/* S32_LE: a = s32 >> 8, bits 7:0 do not fit a subframe */
};

enum iec958_cs_mode {
	IEC958_CS_CONSUMER,	/* IEC 60958-3 consumer block: rate, word length, copy permitted */
	IEC958_CS_STOCK,	/* stock HiBy HAL: V = U = C = 0, only P */
};

struct iec958_enc {
	uint8_t level;			/* last cell on the line, 0 or 1 */
	uint8_t frame;			/* position in the 192-frame block, 0 = B preamble */
	uint8_t cs[IEC958_CS_BYTES];	/* channel status, bit n = cs[n / 8] >> (n % 8) */
};

/* fs code (IEC 60958-3 bits 24-27, ALSA byte order) or -1 if the RS6 has no S/PDIF word for fs */
int iec958_fs_code(unsigned int fs);

/* channel status block for a stream; 0 or -EINVAL for an unsupported rate */
int iec958_cs_build(uint8_t cs[IEC958_CS_BYTES], enum iec958_cs_mode mode, unsigned int fs,
		    enum iec958_in_fmt fmt);

/* start a stream: line low, frame 0 of a block */
void iec958_init(struct iec958_enc *e, const uint8_t cs[IEC958_CS_BYTES]);

/* replace the channel status, keeping the line level and the block position */
void iec958_set_cs(struct iec958_enc *e, const uint8_t cs[IEC958_CS_BYTES]);

/*
 * Encode frames stereo frames. l and r point at the first left and right sample, step is the
 * distance in bytes from one frame's sample to the next (interleaved or not). out receives
 * 4 * frames words.
 */
void iec958_encode(struct iec958_enc *e, enum iec958_in_fmt fmt, const uint8_t *l,
		   const uint8_t *r, size_t step, size_t frames, uint32_t *out);

/* digital silence (a = 0), continuing the stream */
void iec958_encode_silence(struct iec958_enc *e, size_t frames, uint32_t *out);

/* bmc table, index 2 * nibble + previous level; exported for the tests */
extern const uint8_t iec958_bmc[32];

#endif
