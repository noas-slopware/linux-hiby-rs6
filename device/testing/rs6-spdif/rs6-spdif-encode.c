// SPDX-License-Identifier: MIT
/*
 * Test helper: encode interleaved stereo PCM from stdin to RS6 S/PDIF words on stdout
 * (little-endian u32, L.w0 L.w1 R.w0 R.w1 per frame), feeding the encoder in the given chunk
 * sizes (frames, cycled) so the reference comparison crosses calls and block boundaries.
 *
 *   rs6-spdif-encode s16|s24|s32 RATE consumer|stock CHUNK...
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "iec958.h"

int main(int argc, char **argv)
{
	enum iec958_in_fmt fmt;
	enum iec958_cs_mode mode;
	uint8_t cs[IEC958_CS_BYTES], *in = NULL;
	size_t width, len = 0, cap = 0, frames, done = 0, n;
	struct iec958_enc e;
	uint32_t *out;
	int c = 0, i;

	if (argc < 5) {
		fprintf(stderr, "usage: %s s16|s24|s32 RATE consumer|stock CHUNK...\n", argv[0]);
		return 2;
	}
	fmt = !strcmp(argv[1], "s16") ? IEC958_IN_S16 :
	      !strcmp(argv[1], "s24") ? IEC958_IN_S24 : IEC958_IN_S32;
	width = fmt == IEC958_IN_S16 ? 2 : 4;
	mode = !strcmp(argv[3], "stock") ? IEC958_CS_STOCK : IEC958_CS_CONSUMER;
	if (iec958_cs_build(cs, mode, strtoul(argv[2], NULL, 10), fmt) < 0) {
		fprintf(stderr, "unsupported rate %s\n", argv[2]);
		return 2;
	}
	for (;;) {
		if (len == cap) {
			cap = cap ? 2 * cap : 65536;
			in = realloc(in, cap);
			if (!in)
				return 1;
		}
		n = fread(in + len, 1, cap - len, stdin);
		if (!n)
			break;
		len += n;
	}
	frames = len / (2 * width);
	out = malloc(frames * 16 + 16);
	if (!out)
		return 1;
	iec958_init(&e, cs);
	while (done < frames) {
		n = strtoul(argv[4 + c], NULL, 10);
		c = (c + 1) % (argc - 4);
		if (!n || n > frames - done)
			n = frames - done;
		iec958_encode(&e, fmt, in + done * 2 * width, in + done * 2 * width + width,
			      2 * width, n, out + done * 4);
		done += n;
	}
	for (i = 0; i < (int)(frames * 4); i++) {
		uint8_t b[4] = { out[i], out[i] >> 8, out[i] >> 16, out[i] >> 24 };

		fwrite(b, 1, 4, stdout);
	}
	free(in);
	free(out);
	return 0;
}
