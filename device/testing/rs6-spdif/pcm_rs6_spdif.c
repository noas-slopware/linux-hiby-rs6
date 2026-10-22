// SPDX-License-Identifier: MIT
/*
 * ALSA PCM plugin "rs6_spdif": plays PCM on the HiBy RS6 coaxial S/PDIF output.
 *
 * The RS6 DAC FPGA only forwards the I2S data line to its S/PDIF pin; the stock HAL did the
 * IEC 60958 biphase-mark coding in software, and so does this plugin (contract:
 * docs/spdif-dsd.md 9.1). Applications open it at the audio rate fs (S16_LE, S24_LE or S32_LE,
 * stereo); it opens the card's playback PCM at S32_LE, 2 channels, 2 x fs and writes four
 * BMC words per audio frame. Bit-perfect: no resampling, no dither, no volume. S32 input
 * loses bits 7:0 because a subframe carries 24 bits.
 *
 * The kernel latches "this stream is S/PDIF cells" when the PCM opens, from the read-only
 * "Output Target" control (9.4). So the plugin opens the card PCM only while Output Target
 * reads Spdif, re-reads it after the open, and closes the card PCM as soon as the target
 * changes (a jack plugged in), leaving the device to the analog output. While it has no card
 * PCM ("detached": target elsewhere, or the device still busy) it keeps time on
 * CLOCK_MONOTONIC and discards the data, and it reattaches when it can, so neither aplay nor
 * PipeWire sees an error. The card PCM is opened at the first data, never while an
 * application only probes the configuration.
 *
 * Config:
 *   pcm.name { type rs6_spdif
 *     card STR|INT          card of the RS6 DAC (default "HiByRS6")
 *     device INT            playback PCM (default 0)
 *     slave STR             override the card PCM (default "hw:CARD=<card>,DEV=<device>")
 *     ctl STR               override the Output Target control device (default
 *                           "hw:CARD=<card>"); "" disables the checks (tests only: the
 *                           output is then never protected from a switch)
 *     channel_status STR    "consumer" (default: IEC 60958-3 rate, word length, copy
 *                           permitted) or "stock" (V = U = C = 0, as the stock HAL)
 *   }
 */
#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

#include <alsa/asoundlib.h>
#include <alsa/pcm_external.h>

#include "iec958.h"
#include "rs6-target.h"

/* q6asm-dai (RS6 FE): period and buffer in steps of 480 frames, 2..8 periods of <= 64 KiB */
#define SLAVE_PERIOD_MAX	8192	/* 64 KiB of S32 stereo */
#define SLAVE_PERIOD		960	/* 480 audio frames: ~11 ms at 44.1k, 1.25 ms at 384k */
#define SLAVE_PERIODS		8
#define RETRY_NS		100000000ULL	/* reattach attempts while detached */
#define NS			1000000000ULL

struct rs6 {
	snd_pcm_ioplug_t io;
	pthread_mutex_t lock;

	char *slave_name;
	char *ctl_name;			/* NULL: no Output Target checks */
	enum iec958_cs_mode cs_mode;

	struct rs6_target tgt;
	bool have_tgt;
	bool target_spdif;		/* last value read */

	snd_pcm_t *slave;		/* NULL while detached */
	struct pollfd slave_pfd[4];
	int slave_nfds;
	int epfd, tfd;

	/* stream configuration (hw_params) */
	bool configured;
	enum iec958_in_fmt fmt;
	unsigned int fs;
	struct iec958_enc enc;
	snd_pcm_uframes_t boundary, avail_min;
	snd_pcm_uframes_t sp, sb;	/* slave period and buffer, slave frames */

	/* encoded slave frames (2 words each) not yet accepted by the card PCM */
	uint32_t *stage;
	size_t stage_cap, stage_head, stage_len;

	/* positions, in audio frames since prepare unless noted */
	uint64_t appl;			/* frames the application handed over */
	uint64_t last_hw;		/* last position reported (monotonic) */
	uint64_t written_s;		/* slave frames written to the card PCM since its prepare */
	uint64_t hw_s_seen;		/* slave hw position at the last change ... */
	uint64_t t_seen;		/* ... and when it was seen, for interpolation */
	bool xrun;

	/* detached clock */
	uint64_t vhw;			/* virtual position at clk_ns */
	uint64_t clk_ns;
	bool clk_running;
	uint64_t next_try;
	int why;			/* last detach reason logged, to log changes only */
};

enum { WHY_NONE, WHY_TARGET, WHY_BUSY, WHY_ERROR };

static uint64_t now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * NS + ts.tv_nsec;
}

/* frames at rate in el nanoseconds, without overflow */
static uint64_t frames_in(uint64_t el, unsigned int rate)
{
	return el / NS * rate + el % NS * rate / NS;
}

static void note(struct rs6 *r, int why, const char *fmt, int err)
{
	if (r->why == why)
		return;
	r->why = why;
	if (why == WHY_NONE)
		return;
	SNDERR(fmt, err ? snd_strerror(err) : "");
}

static bool running(struct rs6 *r)
{
	return r->io.state == SND_PCM_STATE_RUNNING || r->io.state == SND_PCM_STATE_DRAINING;
}

/* ---- detached clock ---- */

static uint64_t vhw_now(struct rs6 *r)
{
	uint64_t v = r->vhw;

	if (r->clk_running && r->fs)
		v += frames_in(now_ns() - r->clk_ns, r->fs);
	return v < r->appl ? v : r->appl;	/* never an underrun while nothing plays */
}

static void clock_set(struct rs6 *r, bool run)
{
	r->vhw = vhw_now(r);
	r->clk_ns = now_ns();
	r->clk_running = run;
}

static void timer_arm(struct rs6 *r, bool on)
{
	struct itimerspec its = { 0 };
	uint64_t period = 0;

	if (on && r->fs && r->io.period_size)
		period = (uint64_t)r->io.period_size * NS / r->fs;
	if (on && period < 1000000)
		period = 1000000;
	if (on) {
		its.it_value.tv_sec = period / NS;
		its.it_value.tv_nsec = period % NS;
		its.it_interval = its.it_value;
	}
	timerfd_settime(r->tfd, 0, &its, NULL);
}

/* ---- staging ring (slave frames, 2 words each) ---- */

#define SCRATCH_FRAMES	256

static void stage_put(struct rs6 *r, const uint32_t *w, size_t n)
{
	while (n) {
		size_t tail = (r->stage_head + r->stage_len) % r->stage_cap;
		size_t c = r->stage_cap - tail;

		if (c > r->stage_cap - r->stage_len)
			c = r->stage_cap - r->stage_len;
		if (c > n)
			c = n;
		if (!c)
			return;		/* cannot happen: sized for twice the buffer plus padding */
		memcpy(r->stage + tail * 2, w, c * 2 * sizeof(uint32_t));
		r->stage_len += c;
		w += c * 2;
		n -= c;
	}
}

static void stage_silence(struct rs6 *r, size_t frames)
{
	uint32_t buf[SCRATCH_FRAMES * IEC958_WORDS_PER_FRAME];

	while (frames) {
		size_t n = frames < SCRATCH_FRAMES ? frames : SCRATCH_FRAMES;

		iec958_encode_silence(&r->enc, n, buf);
		stage_put(r, buf, 2 * n);
		frames -= n;
	}
}

static void stage_audio(struct rs6 *r, const uint8_t *l, const uint8_t *rt, size_t step,
			size_t frames)
{
	uint32_t buf[SCRATCH_FRAMES * IEC958_WORDS_PER_FRAME];

	while (frames) {
		size_t n = frames < SCRATCH_FRAMES ? frames : SCRATCH_FRAMES;

		iec958_encode(&r->enc, r->fmt, l, rt, step, n, buf);
		stage_put(r, buf, 2 * n);
		l += n * step;
		rt += n * step;
		frames -= n;
	}
}

static int stage_flush(struct rs6 *r)
{
	while (r->stage_len) {
		size_t n = r->stage_cap - r->stage_head;
		snd_pcm_sframes_t w;

		if (n > r->stage_len)
			n = r->stage_len;
		w = snd_pcm_writei(r->slave, r->stage + r->stage_head * 2, n);
		if (w == -EAGAIN || w == 0)
			return 0;
		if (w < 0)
			return w;
		r->stage_head = (r->stage_head + w) % r->stage_cap;
		r->stage_len -= w;
		r->written_s += w;
	}
	return 0;
}

/* ---- card PCM ---- */

/*
 * Started by us only; an empty buffer is an underrun. The card PCM wakes poll() when the
 * application could write avail_min frames, so a card buffer larger than the application's
 * does not keep the descriptor ready (a busy poll loop).
 */
static int slave_sw(struct rs6 *r, snd_pcm_t *s)
{
	snd_pcm_sw_params_t *sw;
	snd_pcm_uframes_t bound, am = r->avail_min ? r->avail_min : 1, room;
	int64_t need;
	int err;

	snd_pcm_sw_params_alloca(&sw);
	room = r->io.buffer_size > am ? r->io.buffer_size - am : 0;
	need = (int64_t)r->sb - 2 * (int64_t)room;
	if (need < 1)
		need = 1;
	if ((err = snd_pcm_sw_params_current(s, sw)) < 0 ||
	    (err = snd_pcm_sw_params_get_boundary(sw, &bound)) < 0 ||
	    (err = snd_pcm_sw_params_set_start_threshold(s, sw, bound)) < 0 ||
	    (err = snd_pcm_sw_params_set_stop_threshold(s, sw, r->sb)) < 0 ||
	    (err = snd_pcm_sw_params_set_avail_min(s, sw, need)) < 0 ||
	    (err = snd_pcm_sw_params(s, sw)) < 0)
		return err;
	return 0;
}

static int slave_setup(struct rs6 *r, snd_pcm_t *s)
{
	snd_pcm_hw_params_t *hw;
	snd_pcm_uframes_t p = SLAVE_PERIOD, b = SLAVE_PERIOD * SLAVE_PERIODS;
	int err;

	snd_pcm_hw_params_alloca(&hw);
	if ((err = snd_pcm_hw_params_any(s, hw)) < 0 ||
	    (err = snd_pcm_hw_params_set_access(s, hw, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0 ||
	    (err = snd_pcm_hw_params_set_format(s, hw, SND_PCM_FORMAT_S32_LE)) < 0 ||
	    (err = snd_pcm_hw_params_set_channels(s, hw, 2)) < 0 ||
	    (err = snd_pcm_hw_params_set_rate(s, hw, 2 * r->fs, 0)) < 0 ||
	    (err = snd_pcm_hw_params_set_period_size_near(s, hw, &p, NULL)) < 0 ||
	    (err = snd_pcm_hw_params_set_buffer_size_near(s, hw, &b)) < 0 ||
	    (err = snd_pcm_hw_params(s, hw)) < 0)
		return err;
	snd_pcm_hw_params_get_period_size(hw, &p, NULL);
	snd_pcm_hw_params_get_buffer_size(hw, &b);
	if (p > SLAVE_PERIOD_MAX)
		return -EINVAL;
	r->sp = p;
	r->sb = b;

	err = slave_sw(r, s);
	if (err < 0)
		return err;
	return snd_pcm_prepare(s);
}

static void epoll_slave(struct rs6 *r, bool add)
{
	int i;

	for (i = 0; i < r->slave_nfds; i++) {
		struct epoll_event ev = { 0 };

		ev.data.fd = r->slave_pfd[i].fd;
		if (r->slave_pfd[i].events & POLLOUT)
			ev.events |= EPOLLOUT;
		if (r->slave_pfd[i].events & POLLIN)
			ev.events |= EPOLLIN;
		epoll_ctl(r->epfd, add ? EPOLL_CTL_ADD : EPOLL_CTL_DEL, r->slave_pfd[i].fd, &ev);
	}
}

/* slave hw position, interpolated within a period while it runs (the q6 pointer moves per period) */
static int slave_hw(struct rs6 *r, uint64_t *hw_s)
{
	snd_pcm_sframes_t avail;
	snd_pcm_state_t st = snd_pcm_state(r->slave);
	uint64_t t = now_ns(), queued, hw, est;

	if (st == SND_PCM_STATE_XRUN || st == SND_PCM_STATE_SUSPENDED)
		return -EPIPE;
	if (st == SND_PCM_STATE_DISCONNECTED)
		return -ENODEV;
	avail = snd_pcm_avail(r->slave);
	if (avail < 0)
		return avail;
	queued = (snd_pcm_uframes_t)avail >= r->sb ? 0 : r->sb - avail;
	hw = queued > r->written_s ? 0 : r->written_s - queued;
	if (hw != r->hw_s_seen) {
		r->hw_s_seen = hw;
		r->t_seen = t;
	}
	est = hw;
	if (st == SND_PCM_STATE_RUNNING) {
		uint64_t d = frames_in(t - r->t_seen, 2 * r->fs);

		est += d < r->sp ? d : r->sp;
		if (est > r->written_s)
			est = r->written_s;
	}
	*hw_s = est;
	return 0;
}

/* where the application's data is played now, audio frames since prepare */
static int position(struct rs6 *r, uint64_t *hw)
{
	uint64_t pos;

	if (r->slave) {
		uint64_t hw_s = 0, delay_s;
		int err = slave_hw(r, &hw_s);

		if (err < 0)
			return err;
		delay_s = r->written_s - hw_s + r->stage_len;
		pos = delay_s / 2 >= r->appl ? 0 : r->appl - delay_s / 2;
	} else {
		pos = vhw_now(r);
	}
	/* after a rewind the application pointer is behind ours: never report past it */
	if (r->boundary) {
		uint64_t back = (r->appl % r->boundary + r->boundary - r->io.appl_ptr) % r->boundary;

		if (back <= r->io.buffer_size && pos > r->appl - back)
			pos = r->appl - back;
	}
	if (pos < r->last_hw)
		pos = r->last_hw;	/* padding and interpolation never move it back */
	r->last_hw = pos;
	*hw = pos;
	return 0;
}

static void detach(struct rs6 *r, int why, const char *msg, int err)
{
	uint64_t hw = r->last_hw;

	if (!r->slave)
		return;
	if (!r->xrun)
		position(r, &hw);
	r->vhw = hw;
	r->clk_ns = now_ns();
	r->clk_running = running(r);
	r->stage_len = 0;
	r->stage_head = 0;
	epoll_slave(r, false);
	snd_pcm_drop(r->slave);
	snd_pcm_close(r->slave);
	r->slave = NULL;
	r->slave_nfds = 0;
	timer_arm(r, running(r) || r->io.state == SND_PCM_STATE_PREPARED);
	note(r, why, msg, err);
}

/* true when the stream has something for the card PCM to do */
static bool wanted(struct rs6 *r)
{
	if (!r->configured)
		return false;
	return running(r) || (r->io.state == SND_PCM_STATE_PREPARED && r->appl) ||
	       r->io.state == SND_PCM_STATE_PAUSED;
}

static int attach(struct rs6 *r)
{
	snd_pcm_t *s;
	uint64_t pending;
	int err;

	if (r->slave || !r->configured || r->io.state == SND_PCM_STATE_PAUSED)
		return 0;
	if (r->have_tgt && !r->target_spdif)
		return -EAGAIN;
	if (now_ns() < r->next_try)
		return -EAGAIN;

	err = snd_pcm_open(&s, r->slave_name, SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK);
	if (err < 0) {
		r->next_try = now_ns() + RETRY_NS;
		note(r, err == -EBUSY ? WHY_BUSY : WHY_ERROR,
		     "rs6_spdif: card PCM not available (%s), coax output waits", err);
		return err;
	}
	/*
	 * The kernel latched the stream kind at the open: if the target moved in between,
	 * this stream would carry BMC cells to an analog output. Read it again.
	 */
	if (r->have_tgt) {
		rs6_target_events(&r->tgt);
		err = rs6_target_is_spdif(&r->tgt);
		r->target_spdif = err == 1;
		if (err != 1) {
			snd_pcm_close(s);
			return -EAGAIN;
		}
	}
	err = slave_setup(r, s);
	if (err < 0) {
		snd_pcm_close(s);
		r->next_try = now_ns() + 10 * RETRY_NS;
		note(r, WHY_ERROR, "rs6_spdif: cannot set up the card PCM: %s", err);
		return err;
	}
	r->slave = s;
	r->slave_nfds = snd_pcm_poll_descriptors(s, r->slave_pfd, 4);
	if (r->slave_nfds < 0)
		r->slave_nfds = 0;
	epoll_slave(r, true);
	timer_arm(r, false);
	r->written_s = 0;
	r->hw_s_seen = 0;
	r->t_seen = now_ns();
	r->stage_len = 0;
	r->stage_head = 0;

	/* what the application already handed over while detached plays as silence */
	pending = r->appl - vhw_now(r);
	r->clk_running = false;
	stage_silence(r, pending);
	if (running(r)) {
		/* the q6 FE sends whole periods only: give the DSP at least one */
		if (r->stage_len < r->sp)
			stage_silence(r, (r->sp - r->stage_len + 1) / 2);
		err = stage_flush(r);
		if (!err)
			err = snd_pcm_start(r->slave);
		if (err < 0) {
			detach(r, WHY_ERROR, "rs6_spdif: cannot start the card PCM: %s", err);
			return err;
		}
	}
	note(r, WHY_NONE, NULL, 0);
	return 0;
}

/* control events, reattach, push staged data; called from every entry point */
static void service(struct rs6 *r)
{
	if (r->have_tgt && rs6_target_events(&r->tgt)) {
		int v = rs6_target_is_spdif(&r->tgt);

		r->target_spdif = v == 1;
		if (!r->target_spdif)
			detach(r, WHY_TARGET, "rs6_spdif: Output Target is not Spdif%s, coax output paused", 0);
	}
	if (!r->slave && wanted(r))
		attach(r);
	if (r->slave && r->stage_len) {
		int err = stage_flush(r);

		if (err == -EPIPE)
			r->xrun = true;
		else if (err < 0)
			detach(r, WHY_ERROR, "rs6_spdif: card PCM write failed: %s", err);
	}
}

/* ---- ioplug callbacks ---- */

static snd_pcm_sframes_t rs6_pointer(snd_pcm_ioplug_t *io)
{
	struct rs6 *r = io->private_data;
	uint64_t hw;
	int err;

	pthread_mutex_lock(&r->lock);
	service(r);
	err = r->xrun ? -EPIPE : position(r, &hw);
	if (err == -ENODEV) {
		detach(r, WHY_ERROR, "rs6_spdif: card PCM gone: %s", err);
		err = position(r, &hw);
	}
	pthread_mutex_unlock(&r->lock);
	if (err < 0)
		return -EPIPE;
	return r->boundary ? (snd_pcm_sframes_t)(hw % r->boundary) : (snd_pcm_sframes_t)hw;
}

static snd_pcm_sframes_t rs6_transfer(snd_pcm_ioplug_t *io, const snd_pcm_channel_area_t *areas,
				      snd_pcm_uframes_t offset, snd_pcm_uframes_t size)
{
	struct rs6 *r = io->private_data;
	const uint8_t *l, *rt;
	size_t step;
	snd_pcm_uframes_t skip = 0;

	pthread_mutex_lock(&r->lock);
	service(r);
	if (!r->slave && r->configured && !r->xrun)
		attach(r);	/* first data of the stream */
	/*
	 * The card PCM cannot take data back. After snd_pcm_rewind() (PipeWire resyncing as a
	 * follower) the application writes frames again that were already encoded and sent:
	 * those stay as sent and the new copies are skipped. After snd_pcm_forward() the
	 * skipped frames play as silence. Either way the stream stays continuous and the
	 * plugin's count matches the application pointer again.
	 */
	if (r->boundary) {
		uint64_t mine = r->appl % r->boundary;
		uint64_t back = (mine + r->boundary - io->appl_ptr) % r->boundary;
		uint64_t ahead = (io->appl_ptr + r->boundary - mine) % r->boundary;

		if (back && back <= io->buffer_size) {
			skip = back < size ? back : size;
		} else if (ahead && ahead <= io->buffer_size) {
			if (r->slave)
				stage_silence(r, ahead);
			r->appl += ahead;
		}
	}
	if (r->slave && size > skip) {
		l = (const uint8_t *)areas[0].addr +
		    (areas[0].first + (offset + skip) * areas[0].step) / 8;
		rt = (const uint8_t *)areas[1].addr +
		     (areas[1].first + (offset + skip) * areas[1].step) / 8;
		step = areas[0].step / 8;
		stage_audio(r, l, rt, step, size - skip);
	}
	r->appl += size - skip;
	service(r);
	pthread_mutex_unlock(&r->lock);
	return size;
}

static int rs6_start(snd_pcm_ioplug_t *io)
{
	struct rs6 *r = io->private_data;
	int err = 0;

	pthread_mutex_lock(&r->lock);
	if (!r->slave)
		attach(r);
	if (r->slave) {
		err = stage_flush(r);
		if (!err && snd_pcm_state(r->slave) == SND_PCM_STATE_PREPARED)
			err = snd_pcm_start(r->slave);
		if (err == -EPIPE) {
			r->xrun = true;
			err = 0;
		} else if (err < 0) {
			detach(r, WHY_ERROR, "rs6_spdif: cannot start the card PCM: %s", err);
			err = 0;
		}
		r->t_seen = now_ns();
	}
	if (!r->slave) {
		r->clk_ns = now_ns();
		r->clk_running = true;
		timer_arm(r, true);
	}
	pthread_mutex_unlock(&r->lock);
	return err;
}

static void slave_close(struct rs6 *r)
{
	if (!r->slave)
		return;
	epoll_slave(r, false);
	snd_pcm_drop(r->slave);
	snd_pcm_close(r->slave);
	r->slave = NULL;
	r->slave_nfds = 0;
}

/*
 * Stopped, the stream needs no card PCM: close it, so the other output can open it at once.
 * PipeWire drops an idle sink and then calls nothing until it suspends it, so a jack plugged
 * in that window would otherwise find the device busy. prepare, the next data and start
 * open it again (cheap while the kernel's target stays powered).
 */
static int rs6_stop(snd_pcm_ioplug_t *io)
{
	struct rs6 *r = io->private_data;

	pthread_mutex_lock(&r->lock);
	slave_close(r);
	r->stage_len = 0;
	r->stage_head = 0;
	clock_set(r, false);
	timer_arm(r, false);
	pthread_mutex_unlock(&r->lock);
	return 0;
}

static int rs6_pause(snd_pcm_ioplug_t *io, int enable)
{
	struct rs6 *r = io->private_data;
	int err = 0;

	pthread_mutex_lock(&r->lock);
	if (r->slave) {
		err = snd_pcm_pause(r->slave, enable);
		r->t_seen = now_ns();
	} else {
		clock_set(r, !enable);
	}
	pthread_mutex_unlock(&r->lock);
	return err;
}

static int rs6_prepare(snd_pcm_ioplug_t *io)
{
	struct rs6 *r = io->private_data;
	int err = 0;

	pthread_mutex_lock(&r->lock);
	service(r);
	r->appl = 0;
	r->last_hw = 0;
	r->vhw = 0;
	r->clk_running = false;
	r->stage_len = 0;
	r->stage_head = 0;
	r->xrun = false;
	r->written_s = 0;
	r->hw_s_seen = 0;
	if (r->slave) {
		err = snd_pcm_prepare(r->slave);
		if (err < 0)
			detach(r, WHY_ERROR, "rs6_spdif: cannot prepare the card PCM: %s", err);
	}
	pthread_mutex_unlock(&r->lock);
	return 0;
}

/*
 * Plays out what was written, with silence up to a whole card PCM period (the q6 FE never
 * sends a partial period to the DSP). Blocks, also in non-blocking mode.
 */
static int rs6_drain(snd_pcm_ioplug_t *io)
{
	struct rs6 *r = io->private_data;
	int err = 0;

	pthread_mutex_lock(&r->lock);
	service(r);
	if (!r->slave && r->appl && r->have_tgt && r->target_spdif)
		attach(r);
	if (r->slave && !r->xrun) {
		uint64_t queued = r->written_s + r->stage_len, rem = queued % r->sp;

		if (rem)
			stage_silence(r, (r->sp - rem + 1) / 2);
		snd_pcm_nonblock(r->slave, 0);
		err = stage_flush(r);
		if (!err && snd_pcm_state(r->slave) == SND_PCM_STATE_PREPARED)
			err = snd_pcm_start(r->slave);
		if (!err)
			err = snd_pcm_drain(r->slave);
		if (r->slave)
			snd_pcm_nonblock(r->slave, 1);
		if (err == -EPIPE)
			err = 0;	/* ran dry at the end: drained */
	} else if (!r->slave) {
		uint64_t left = r->appl - vhw_now(r);

		pthread_mutex_unlock(&r->lock);
		if (left && r->fs) {
			struct timespec ts = {
				.tv_sec = left / r->fs,
				.tv_nsec = (left % r->fs) * NS / r->fs,
			};
			nanosleep(&ts, NULL);
		}
		return 0;
	}
	pthread_mutex_unlock(&r->lock);
	return err < 0 ? err : 0;
}

static int rs6_hw_params(snd_pcm_ioplug_t *io, snd_pcm_hw_params_t *params)
{
	struct rs6 *r = io->private_data;
	uint8_t cs[IEC958_CS_BYTES];
	size_t cap;
	int err;

	(void)params;
	pthread_mutex_lock(&r->lock);
	switch (io->format) {
	case SND_PCM_FORMAT_S16_LE:
		r->fmt = IEC958_IN_S16;
		break;
	case SND_PCM_FORMAT_S24_LE:
		r->fmt = IEC958_IN_S24;
		break;
	case SND_PCM_FORMAT_S32_LE:
		r->fmt = IEC958_IN_S32;
		break;
	default:
		pthread_mutex_unlock(&r->lock);
		return -EINVAL;
	}
	err = iec958_cs_build(cs, r->cs_mode, io->rate, r->fmt);
	if (err < 0) {
		pthread_mutex_unlock(&r->lock);
		return err;
	}
	/* a new stream configuration: the card PCM is set up again at the next data */
	slave_close(r);
	r->fs = io->rate;
	iec958_init(&r->enc, cs);

	/* twice the buffer (silence for a reattach) plus a period of padding, in slave frames */
	cap = 2 * (size_t)io->buffer_size + SLAVE_PERIOD_MAX + 4;
	if (cap > r->stage_cap) {
		uint32_t *p = realloc(r->stage, cap * 2 * sizeof(uint32_t));

		if (!p) {
			pthread_mutex_unlock(&r->lock);
			return -ENOMEM;
		}
		r->stage = p;
		r->stage_cap = cap;
	}
	r->stage_len = 0;
	r->stage_head = 0;
	r->sp = SLAVE_PERIOD;
	r->sb = SLAVE_PERIOD * SLAVE_PERIODS;
	r->configured = true;
	r->next_try = 0;
	pthread_mutex_unlock(&r->lock);
	return 0;
}

static int rs6_hw_free(snd_pcm_ioplug_t *io)
{
	struct rs6 *r = io->private_data;

	pthread_mutex_lock(&r->lock);
	slave_close(r);
	r->configured = false;
	timer_arm(r, false);
	pthread_mutex_unlock(&r->lock);
	return 0;
}

static int rs6_sw_params(snd_pcm_ioplug_t *io, snd_pcm_sw_params_t *params)
{
	struct rs6 *r = io->private_data;

	pthread_mutex_lock(&r->lock);
	snd_pcm_sw_params_get_boundary(params, &r->boundary);
	snd_pcm_sw_params_get_avail_min(params, &r->avail_min);
	if (r->slave)
		slave_sw(r, r->slave);
	pthread_mutex_unlock(&r->lock);
	return 0;
}

static int rs6_poll_revents(snd_pcm_ioplug_t *io, struct pollfd *pfd, unsigned int nfds,
			    unsigned short *revents)
{
	struct rs6 *r = io->private_data;
	uint64_t ticks, hw = 0;
	int err;

	(void)pfd;
	(void)nfds;
	pthread_mutex_lock(&r->lock);
	if (read(r->tfd, &ticks, sizeof(ticks)) < 0)
		ticks = 0;
	service(r);
	*revents = 0;
	err = r->xrun ? -EPIPE : position(r, &hw);
	if (err < 0) {
		*revents = POLLERR;
	} else if (io->state == SND_PCM_STATE_PREPARED || running(r)) {
		uint64_t pending = r->appl - hw;
		uint64_t avail = pending >= io->buffer_size ? 0 : io->buffer_size - pending;

		if (avail >= (r->avail_min ? r->avail_min : 1))
			*revents = POLLOUT;
	}
	pthread_mutex_unlock(&r->lock);
	return 0;
}

static int rs6_delay(snd_pcm_ioplug_t *io, snd_pcm_sframes_t *delayp)
{
	struct rs6 *r = io->private_data;
	uint64_t hw = 0;
	int err;

	pthread_mutex_lock(&r->lock);
	service(r);
	err = r->xrun ? -EPIPE : position(r, &hw);
	*delayp = err < 0 ? 0 : (snd_pcm_sframes_t)(r->appl - hw);
	pthread_mutex_unlock(&r->lock);
	return err < 0 ? err : 0;
}

static void rs6_dump(snd_pcm_ioplug_t *io, snd_output_t *out)
{
	struct rs6 *r = io->private_data;

	snd_output_printf(out, "HiBy RS6 S/PDIF encoder (card PCM %s, %s, channel status %s)\n",
			  r->slave_name, r->slave ? "attached" : "detached",
			  r->cs_mode == IEC958_CS_STOCK ? "stock" : "consumer");
	if (r->configured) {
		snd_output_printf(out, "Its setup is:\n");
		snd_pcm_dump_setup(io->pcm, out);
	}
	if (r->slave) {
		snd_output_printf(out, "Card PCM:\n");
		snd_pcm_dump(r->slave, out);
	}
}

static void rs6_free(struct rs6 *r)
{
	if (r->slave)
		snd_pcm_close(r->slave);
	if (r->have_tgt)
		rs6_target_close(&r->tgt);
	if (r->epfd >= 0)
		close(r->epfd);
	if (r->tfd >= 0)
		close(r->tfd);
	pthread_mutex_destroy(&r->lock);
	free(r->stage);
	free(r->slave_name);
	free(r->ctl_name);
	free(r);
}

static int rs6_close(snd_pcm_ioplug_t *io)
{
	rs6_free(io->private_data);
	return 0;
}

static const snd_pcm_ioplug_callback_t rs6_ops = {
	.start = rs6_start,
	.stop = rs6_stop,
	.pointer = rs6_pointer,
	.transfer = rs6_transfer,
	.close = rs6_close,
	.hw_params = rs6_hw_params,
	.hw_free = rs6_hw_free,
	.sw_params = rs6_sw_params,
	.prepare = rs6_prepare,
	.drain = rs6_drain,
	.pause = rs6_pause,
	.poll_revents = rs6_poll_revents,
	.delay = rs6_delay,
	.dump = rs6_dump,
};

static int set_constraints(struct rs6 *r)
{
	static const unsigned int access[] = {
		SND_PCM_ACCESS_MMAP_INTERLEAVED, SND_PCM_ACCESS_RW_INTERLEAVED,
		SND_PCM_ACCESS_MMAP_NONINTERLEAVED, SND_PCM_ACCESS_RW_NONINTERLEAVED,
	};
	static const unsigned int formats[] = {
		SND_PCM_FORMAT_S32_LE, SND_PCM_FORMAT_S24_LE, SND_PCM_FORMAT_S16_LE,
	};
	static const unsigned int rates[] = {
		44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000,
	};
	int err;

	if ((err = snd_pcm_ioplug_set_param_list(&r->io, SND_PCM_IOPLUG_HW_ACCESS, 4, access)) < 0 ||
	    (err = snd_pcm_ioplug_set_param_list(&r->io, SND_PCM_IOPLUG_HW_FORMAT, 3, formats)) < 0 ||
	    (err = snd_pcm_ioplug_set_param_minmax(&r->io, SND_PCM_IOPLUG_HW_CHANNELS, 2, 2)) < 0 ||
	    (err = snd_pcm_ioplug_set_param_list(&r->io, SND_PCM_IOPLUG_HW_RATE, 8, rates)) < 0 ||
	    (err = snd_pcm_ioplug_set_param_minmax(&r->io, SND_PCM_IOPLUG_HW_PERIOD_BYTES,
						   64, 256 * 1024)) < 0 ||
	    (err = snd_pcm_ioplug_set_param_minmax(&r->io, SND_PCM_IOPLUG_HW_BUFFER_BYTES,
						   128, 512 * 1024)) < 0 ||
	    (err = snd_pcm_ioplug_set_param_minmax(&r->io, SND_PCM_IOPLUG_HW_PERIODS, 2, 1024)) < 0)
		return err;
	return 0;
}

static int conf_string(snd_config_t *n, char **out)
{
	const char *s;
	long v;
	char buf[32];

	if (snd_config_get_string(n, &s) >= 0) {
		*out = strdup(s);
	} else if (snd_config_get_integer(n, &v) >= 0) {
		snprintf(buf, sizeof(buf), "%ld", v);
		*out = strdup(buf);
	} else {
		return -EINVAL;
	}
	return *out ? 0 : -ENOMEM;
}

SND_PCM_PLUGIN_DEFINE_FUNC(rs6_spdif)
{
	snd_config_iterator_t i, next;
	char *card = NULL, *slave = NULL, *ctl = NULL, *cs = NULL;
	long device = 0;
	bool ctl_set = false;
	struct rs6 *r;
	struct epoll_event ev = { .events = EPOLLIN };
	int err;

	(void)root;
	snd_config_for_each(i, next, conf) {
		snd_config_t *n = snd_config_iterator_entry(i);
		const char *id;

		if (snd_config_get_id(n, &id) < 0)
			continue;
		if (!strcmp(id, "comment") || !strcmp(id, "type") || !strcmp(id, "hint"))
			continue;
		if (!strcmp(id, "card")) {
			free(card);
			err = conf_string(n, &card);
		} else if (!strcmp(id, "device")) {
			err = snd_config_get_integer(n, &device);
		} else if (!strcmp(id, "slave")) {
			free(slave);
			err = conf_string(n, &slave);
		} else if (!strcmp(id, "ctl")) {
			free(ctl);
			err = conf_string(n, &ctl);
			ctl_set = true;
		} else if (!strcmp(id, "channel_status")) {
			free(cs);
			err = conf_string(n, &cs);
		} else {
			SNDERR("rs6_spdif: unknown field %s", id);
			err = -EINVAL;
		}
		if (err < 0) {
			SNDERR("rs6_spdif: invalid value for %s", id);
			goto out;
		}
	}
	if (stream != SND_PCM_STREAM_PLAYBACK) {
		SNDERR("rs6_spdif: playback only");
		err = -EINVAL;
		goto out;
	}

	r = calloc(1, sizeof(*r));
	if (!r) {
		err = -ENOMEM;
		goto out;
	}
	pthread_mutex_init(&r->lock, NULL);
	r->epfd = -1;
	r->tfd = -1;
	r->cs_mode = IEC958_CS_CONSUMER;
	if (cs && !strcmp(cs, "stock")) {
		r->cs_mode = IEC958_CS_STOCK;
	} else if (cs && strcmp(cs, "consumer")) {
		SNDERR("rs6_spdif: channel_status must be consumer or stock");
		err = -EINVAL;
		goto fail;
	}
	if (!card)
		card = strdup("HiByRS6");
	if (slave) {
		r->slave_name = slave;
		slave = NULL;
	} else if (asprintf(&r->slave_name, "hw:CARD=%s,DEV=%ld", card, device) < 0) {
		r->slave_name = NULL;
	}
	if (ctl_set && ctl && !*ctl) {
		r->ctl_name = NULL;
	} else if (ctl) {
		r->ctl_name = ctl;
		ctl = NULL;
	} else if (asprintf(&r->ctl_name, "hw:CARD=%s", card) < 0) {
		r->ctl_name = NULL;
		err = -ENOMEM;
		goto fail;
	}
	if (!r->slave_name) {
		err = -ENOMEM;
		goto fail;
	}

	r->epfd = epoll_create1(EPOLL_CLOEXEC);
	r->tfd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
	if (r->epfd < 0 || r->tfd < 0) {
		err = -errno;
		goto fail;
	}
	ev.data.fd = r->tfd;
	epoll_ctl(r->epfd, EPOLL_CTL_ADD, r->tfd, &ev);

	if (r->ctl_name) {
		err = rs6_target_open(&r->tgt, r->ctl_name);
		if (err < 0) {
			SNDERR("rs6_spdif: no \"%s\" control on %s (%s): the kernel cannot tell "
			       "whether the coax output is selected", RS6_TARGET_CTL_NAME, r->ctl_name,
			       snd_strerror(err));
			goto fail;
		}
		r->have_tgt = true;
		r->target_spdif = rs6_target_is_spdif(&r->tgt) == 1;
		ev.data.fd = rs6_target_fd(&r->tgt);
		epoll_ctl(r->epfd, EPOLL_CTL_ADD, ev.data.fd, &ev);
	}

	r->io.version = SND_PCM_IOPLUG_VERSION;
	r->io.name = "HiBy RS6 S/PDIF (IEC 60958 BMC encoder)";
	r->io.callback = &rs6_ops;
	r->io.private_data = r;
	r->io.mmap_rw = 0;
	r->io.poll_fd = r->epfd;
	r->io.poll_events = POLLIN;
	r->io.flags = SND_PCM_IOPLUG_FLAG_BOUNDARY_WA | SND_PCM_IOPLUG_FLAG_MONOTONIC;

	err = snd_pcm_ioplug_create(&r->io, name, stream, mode);
	if (err < 0)
		goto fail;
	err = set_constraints(r);
	if (err < 0) {
		snd_pcm_ioplug_delete(&r->io);	/* calls rs6_close */
		goto out;
	}
	*pcmp = r->io.pcm;
	err = 0;
	goto out;

fail:
	rs6_free(r);
out:
	free(card);
	free(slave);
	free(ctl);
	free(cs);
	return err;
}

SND_PCM_PLUGIN_SYMBOL(rs6_spdif);
