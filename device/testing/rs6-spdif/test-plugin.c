// SPDX-License-Identifier: MIT
/*
 * End-to-end test of the rs6_spdif ALSA plugin through alsa-lib, as aplay and PipeWire use it:
 * the card PCM is replaced by a "file" PCM on "null" (test-alsa.conf), so the real hw_params
 * path at S32_LE 2 x fs, the transfer, start, pause, drop/prepare and drain run unchanged and
 * the encoded stream lands in a file. Every rate, input format and channel status mode, with
 * RW and MMAP access, interleaved and not. The file must decode bit-exact to the input, be
 * one continuous BMC stream, end in silence up to a whole card period, and equal the encoder
 * library's output. A plugin whose card PCM cannot be opened must keep time like a device.
 *
 * Needs ALSA_CONFIG_PATH with test-alsa.conf and RS6_TEST_CAPTURE (set by meson).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <alsa/asoundlib.h>

#include "bmc-decode.h"
#include "iec958.h"

#define SLAVE_PERIOD 960

static int failures;
static const char *capture;

#define CHECK(cond, ...) do { if (!(cond)) { printf("FAIL: " __VA_ARGS__); printf("\n"); failures++; } } while (0)
#define TRY(x) do { int _e = (x); if (_e < 0) { printf("FAIL: %s: %s\n", #x, snd_strerror(_e)); failures++; goto out; } } while (0)

static uint64_t rng = 0x243f6a8885a308d3ULL;

static uint32_t rnd(void)
{
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return (uint32_t)(rng >> 16);
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

static const unsigned int rates[] = { 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000 };
static const snd_pcm_format_t formats[] = { SND_PCM_FORMAT_S16_LE, SND_PCM_FORMAT_S24_LE,
					    SND_PCM_FORMAT_S32_LE };
static const enum iec958_in_fmt enc_fmt[] = { IEC958_IN_S16, IEC958_IN_S24, IEC958_IN_S32 };

static int set_params(snd_pcm_t *pcm, snd_pcm_format_t fmt, unsigned int rate,
		      snd_pcm_access_t access, snd_pcm_uframes_t period, unsigned int periods)
{
	snd_pcm_hw_params_t *hw;
	snd_pcm_uframes_t buffer = period * periods;
	int err;

	snd_pcm_hw_params_alloca(&hw);
	if ((err = snd_pcm_hw_params_any(pcm, hw)) < 0 ||
	    (err = snd_pcm_hw_params_set_access(pcm, hw, access)) < 0 ||
	    (err = snd_pcm_hw_params_set_format(pcm, hw, fmt)) < 0 ||
	    (err = snd_pcm_hw_params_set_channels(pcm, hw, 2)) < 0 ||
	    (err = snd_pcm_hw_params_set_rate(pcm, hw, rate, 0)) < 0 ||
	    (err = snd_pcm_hw_params_set_period_size_near(pcm, hw, &period, NULL)) < 0 ||
	    (err = snd_pcm_hw_params_set_buffer_size_near(pcm, hw, &buffer)) < 0)
		return err;
	return snd_pcm_hw_params(pcm, hw);
}

/* write frames [from, to) of interleaved data, in random chunks, RW or MMAP */
static int play(snd_pcm_t *pcm, const uint8_t *data, size_t fbytes, size_t from, size_t to,
		snd_pcm_access_t access)
{
	while (from < to) {
		size_t n = 1 + rnd() % 700;

		if (n > to - from)
			n = to - from;
		if (access == SND_PCM_ACCESS_RW_INTERLEAVED) {
			snd_pcm_sframes_t w = snd_pcm_writei(pcm, data + from * fbytes, n);

			if (w < 0)
				return w;
			from += w;
		} else if (access == SND_PCM_ACCESS_RW_NONINTERLEAVED) {
			size_t half = fbytes / 2, i;
			uint8_t *l = malloc(n * half), *r = malloc(n * half);
			void *bufs[2] = { l, r };
			snd_pcm_sframes_t w;

			for (i = 0; i < n; i++) {
				memcpy(l + i * half, data + (from + i) * fbytes, half);
				memcpy(r + i * half, data + (from + i) * fbytes + half, half);
			}
			w = snd_pcm_writen(pcm, bufs, n);
			free(l);
			free(r);
			if (w < 0)
				return w;
			from += w;
		} else {
			const snd_pcm_channel_area_t *areas;
			snd_pcm_uframes_t off, frames = n, i;
			snd_pcm_sframes_t avail = snd_pcm_avail_update(pcm);
			size_t half = fbytes / 2;
			int err;

			if (avail < 0)
				return avail;
			if (avail == 0) {
				if ((err = snd_pcm_wait(pcm, 1000)) < 0)
					return err;
				continue;
			}
			if ((err = snd_pcm_mmap_begin(pcm, &areas, &off, &frames)) < 0)
				return err;
			for (i = 0; i < frames; i++) {
				uint8_t *l = (uint8_t *)areas[0].addr +
					     (areas[0].first + (off + i) * areas[0].step) / 8;
				uint8_t *r = (uint8_t *)areas[1].addr +
					     (areas[1].first + (off + i) * areas[1].step) / 8;

				memcpy(l, data + (from + i) * fbytes, half);
				memcpy(r, data + (from + i) * fbytes + half, half);
			}
			if (snd_pcm_mmap_commit(pcm, off, frames) != (snd_pcm_sframes_t)frames)
				return -EIO;
			from += frames;
			if (snd_pcm_state(pcm) == SND_PCM_STATE_PREPARED &&
			    (err = snd_pcm_start(pcm)) < 0)
				return err;
		}
	}
	return 0;
}

/* a fresh capture file, handed to the file PCM as an O_APPEND descriptor */
static void capture_reset(void)
{
	static int fd = -1;
	char num[16];

	if (fd >= 0)
		close(fd);
	fd = open(capture, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
	snprintf(num, sizeof(num), "%d", fd);
	setenv("RS6_TEST_CAPTURE_FD", num, 1);
}

/* the plugin's dump says whether it holds its card PCM */
static int attached(snd_pcm_t *pcm)
{
	snd_output_t *out;
	char *text;
	int ret;

	snd_output_buffer_open(&out);
	snd_pcm_dump(pcm, out);
	snd_output_buffer_string(out, &text);
	ret = strstr(text, ", attached,") != NULL;
	snd_output_close(out);
	return ret;
}

static uint8_t *slurp(size_t *len)
{
	FILE *f = fopen(capture, "rb");
	uint8_t *buf;
	long n;

	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	fseek(f, 0, SEEK_SET);
	buf = malloc(n + 1);
	*len = fread(buf, 1, n, f);
	fclose(f);
	return buf;
}

static uint32_t expect_a(enum iec958_in_fmt fmt, const uint8_t *p)
{
	switch (fmt) {
	case IEC958_IN_S16:
		return ((uint32_t)(int32_t)(int16_t)(p[0] | p[1] << 8) << 8) & 0xffffff;
	case IEC958_IN_S24:
		return (p[0] | p[1] << 8 | (uint32_t)p[2] << 16) & 0xffffff;
	default:
		return (uint32_t)(p[0] | p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24) >> 8;
	}
}

/*
 * Play frames of random audio with one stop/prepare (and a pause) in the middle, then drain.
 * The capture must be: the audio, then silence to a card period boundary.
 */
static void test_stream(const char *dev, int fi, unsigned int rate, int stock,
			snd_pcm_access_t access)
{
	const size_t width = fi == 0 ? 2 : 4, fbytes = 2 * width, frames = 192 * 9 + 101;
	enum iec958_in_fmt fmt = enc_fmt[fi];
	uint8_t *data = malloc(frames * fbytes), *cap = NULL, cs[IEC958_CS_BYTES];
	uint32_t *ref = NULL;
	snd_pcm_t *pcm = NULL;
	struct bmc_dec d;
	struct iec958_enc e;
	size_t i, len = 0, total, split = 192 * 4 + 7;
	snd_pcm_uframes_t period = 64 + rnd() % 2000;

	for (i = 0; i < frames * fbytes; i++)
		data[i] = rnd();
	if (fi == 1)	/* S24_LE: the container's top byte is ignored, keep it sign-extended */
		for (i = 0; i < frames * 2; i++)
			data[i * 4 + 3] = data[i * 4 + 2] & 0x80 ? 0xff : 0;

	capture_reset();
	TRY(snd_pcm_open(&pcm, dev, SND_PCM_STREAM_PLAYBACK, 0));
	TRY(set_params(pcm, formats[fi], rate, access, period, 2 + rnd() % 6));
	TRY(play(pcm, data, fbytes, 0, split / 2, access));
	if (snd_pcm_state(pcm) == SND_PCM_STATE_PREPARED)
		TRY(snd_pcm_start(pcm));
	TRY(snd_pcm_pause(pcm, 1));
	TRY(snd_pcm_pause(pcm, 0));
	TRY(play(pcm, data, fbytes, split / 2, split, access));
	/*
	 * drop closes the card PCM, prepare and the next data open it again; nothing is lost
	 * here because the null card PCM consumed it all at once, and the encoder carries on
	 */
	TRY(snd_pcm_drop(pcm));
	TRY(snd_pcm_prepare(pcm));
	TRY(play(pcm, data, fbytes, split, frames, access));
	TRY(snd_pcm_drain(pcm));
	snd_pcm_close(pcm);
	pcm = NULL;

	cap = slurp(&len);
	CHECK(cap && len % 16 == 0, "%s %u: capture size %zu", dev, rate, len);
	if (!cap)
		goto out;
	total = len / 16;
	/* drain pads to a whole card period, counted from the card PCM's last prepare */
	CHECK(total == frames + (SLAVE_PERIOD - 2 * (frames - split) % SLAVE_PERIOD) % SLAVE_PERIOD / 2,
	      "%s fmt %d %u: %zu frames captured for %zu (card period %d)", dev, fi, rate, total,
	      frames, SLAVE_PERIOD);

	/* the encoder library on the same input plus the silence must give the same bytes */
	iec958_cs_build(cs, stock ? IEC958_CS_STOCK : IEC958_CS_CONSUMER, rate, fmt);
	iec958_init(&e, cs);
	if (total < frames)
		goto out;
	ref = malloc(total * 16);
	iec958_encode(&e, fmt, data, data + width, fbytes, frames, ref);
	if (total > frames)
		iec958_encode_silence(&e, total - frames, ref + frames * 4);
	for (i = 0; i < total * 4; i++) {
		uint32_t w = cap[4 * i] | cap[4 * i + 1] << 8 | cap[4 * i + 2] << 16 |
			     (uint32_t)cap[4 * i + 3] << 24;

		if (w != ref[i]) {
			CHECK(0, "%s fmt %d %u: word %zu = %08x, encoder %08x", dev, fi, rate, i, w, ref[i]);
			break;
		}
	}

	bmc_dec_init(&d);
	for (i = 0; i < total; i++) {
		uint32_t w[4];
		struct bmc_sub l, r;
		int k;

		for (k = 0; k < 4; k++)
			w[k] = cap[16 * i + 4 * k] | cap[16 * i + 4 * k + 1] << 8 |
			       cap[16 * i + 4 * k + 2] << 16 | (uint32_t)cap[16 * i + 4 * k + 3] << 24;
		if (bmc_dec_frame(&d, w, &l, &r) < 0) {
			CHECK(0, "%s fmt %d %u: %s", dev, fi, rate, d.err);
			break;
		}
		if (i < frames ? (l.a != expect_a(fmt, data + i * fbytes) ||
				  r.a != expect_a(fmt, data + i * fbytes + width)) : (l.a || r.a)) {
			CHECK(0, "%s fmt %d %u: frame %zu decodes to %06x %06x", dev, fi, rate, i, l.a, r.a);
			break;
		}
	}
	CHECK(d.blocks >= 9 && !memcmp(d.last_cs[0], cs, sizeof(cs)) &&
	      !memcmp(d.last_cs[1], cs, sizeof(cs)), "%s %u: channel status", dev, rate);
out:
	if (pcm)
		snd_pcm_close(pcm);
	free(data);
	free(cap);
	free(ref);
}

/* the card PCM cannot be opened: the plugin keeps time from the clock and discards */
static void test_detached(void)
{
	snd_pcm_t *pcm = NULL;
	const unsigned int rate = 48000;
	const size_t frames = rate / 2;
	int16_t *data = calloc(frames, 4);
	snd_pcm_sframes_t delay, rewound = 0;
	double t0, t1, t2;

	TRY(snd_pcm_open(&pcm, "rs6dead", SND_PCM_STREAM_PLAYBACK, 0));
	TRY(set_params(pcm, SND_PCM_FORMAT_S16_LE, rate, SND_PCM_ACCESS_RW_INTERLEAVED, 480, 4));
	t0 = now();
	TRY(play(pcm, (uint8_t *)data, 4, 0, frames, SND_PCM_ACCESS_RW_INTERLEAVED));
	t1 = now();
	TRY(snd_pcm_delay(pcm, &delay));
	CHECK(delay >= 0 && delay <= 1920, "detached delay %ld", (long)delay);
	/* a rewind (PipeWire resync): the card PCM cannot take it back, the counts stay sane */
	{
		snd_pcm_sframes_t can = snd_pcm_rewindable(pcm), done, avail;

		done = can > 0 ? snd_pcm_rewind(pcm, can / 2) : 0;
		CHECK(done >= 0, "rewind %ld of %ld", (long)done, (long)can);
		rewound = done;
		TRY(play(pcm, (uint8_t *)data, 4, 0, done > 0 ? done : 0, SND_PCM_ACCESS_RW_INTERLEAVED));
		avail = snd_pcm_avail(pcm);
		TRY(snd_pcm_delay(pcm, &delay));
		CHECK(avail >= 0 && avail <= 1920 && delay >= 0 && delay <= 1920,
		      "after rewind of %ld: avail %ld delay %ld", (long)done, (long)avail, (long)delay);
	}
	TRY(snd_pcm_drain(pcm));
	t2 = now();
	/* 0.5 s of audio through a 40 ms buffer: the writes take about 0.46 s */
	CHECK(t1 - t0 > 0.40 && t1 - t0 < 0.65, "detached writes took %.3f s", t1 - t0);
	CHECK(t2 - t0 > 0.45 && t2 - t0 < 0.75, "detached drain ended after %.3f s", t2 - t0);
	printf("detached: 0.5 s written in %.3f s, rewound %ld frames, drained at %.3f s\n",
	       t1 - t0, (long)rewound, t2 - t0);
out:
	if (pcm)
		snd_pcm_close(pcm);
	free(data);
}

/* configuration only, as a sound server probes: the card PCM must stay closed */
static void test_probe(void)
{
	snd_pcm_t *pcm = NULL;
	static int32_t zero[2 * 1024];

	capture_reset();
	TRY(snd_pcm_open(&pcm, "rs6test", SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK));
	TRY(set_params(pcm, SND_PCM_FORMAT_S32_LE, 96000, SND_PCM_ACCESS_MMAP_INTERLEAVED, 1024, 4));
	TRY(snd_pcm_prepare(pcm));
	CHECK(!attached(pcm), "card PCM opened during a configuration probe");
	/* the first data opens it, a stop closes it again (the other output may want it) */
	CHECK(snd_pcm_mmap_writei(pcm, zero, 1024) == 1024, "first write");
	CHECK(attached(pcm), "card PCM not opened by the first data");
	TRY(snd_pcm_drop(pcm));
	CHECK(!attached(pcm), "card PCM still open after a stop");
	/* rates outside the 8 S/PDIF rates are refused */
	snd_pcm_close(pcm);
	pcm = NULL;
	TRY(snd_pcm_open(&pcm, "rs6test", SND_PCM_STREAM_PLAYBACK, 0));
	CHECK(set_params(pcm, SND_PCM_FORMAT_S16_LE, 32000, SND_PCM_ACCESS_RW_INTERLEAVED, 512, 4) < 0,
	      "32 kHz accepted");
out:
	if (pcm)
		snd_pcm_close(pcm);
}

int main(void)
{
	static const snd_pcm_access_t access[] = {
		SND_PCM_ACCESS_RW_INTERLEAVED, SND_PCM_ACCESS_MMAP_INTERLEAVED,
		SND_PCM_ACCESS_RW_NONINTERLEAVED, SND_PCM_ACCESS_MMAP_NONINTERLEAVED,
	};
	unsigned int r, f, s, n = 0;

	capture = getenv("RS6_TEST_CAPTURE");
	if (!capture) {
		fprintf(stderr, "RS6_TEST_CAPTURE not set\n");
		return 2;
	}
	test_probe();
	for (r = 0; r < 8; r++)
		for (f = 0; f < 3; f++)
			for (s = 0; s < 2; s++, n++)
				test_stream(s ? "rs6test_stock" : "rs6test", f, rates[r], s,
					    access[n % 4]);
	test_detached();
	if (failures) {
		printf("%d failure(s)\n", failures);
		return 1;
	}
	printf("plugin: %u streams bit-exact through alsa-lib (8 rates x 3 formats x 2 channel "
	       "status modes, RW/MMAP, interleaved/not), detached clock ok\n", n);
	return 0;
}
