// SPDX-License-Identifier: MIT
/*
 * LD_PRELOAD shim so Firefox can keep the HiBy RS6 Venus V4L2 decoder (system FFmpeg
 * *_v4l2m2m wrappers), with stock Firefox and stock FFmpeg.
 *
 * Firefox resolves every libavcodec function through NSPR's PR_FindSymbol(). For the
 * system libavcodec only (never Firefox's bundled ffvpx), hand back wrappers that fix the
 * (built against the system FFmpeg headers; links nothing but libc, so it is cheap to load)
 * two things breaking V4L2 decode with Firefox:
 *  - Firefox sets neither pkt_timebase nor time_base, so FFmpeg's V4L2 code rescales by
 *    0/1: every input timestamp becomes 0, every output pts AV_NOPTS_VALUE. Firefox's
 *    timestamps are microseconds, so set pkt_timebase = 1/1000000 before opening.
 *  - The V4L2 wrapper returns frames with pkt_dts = AV_NOPTS_VALUE and duration 0, and
 *    Firefox takes the frame timecode from pkt_dts and the duration from the frame.
 *    A stateful M2M decoder outputs in presentation order, so dts = pts; the duration is
 *    carried over from the packets fed in.
 *
 * Firefox 156+ only puts the system FFmpeg ahead of its bundled ffvpx in the decoder process
 * when Vulkan video decoding is usable (PDMFactory::CreateRddPDMs), which it never is on the
 * Adreno 512, so ffvpx would claim its codecs and decode them in software. Firefox 158's ffvpx
 * has H.264 and HEVC besides VP8/VP9. Hide every ffvpx video decoder (not its encoders, not
 * audio) whose codec the system libavcodec has a *_v4l2m2m wrapper for, so Firefox's own
 * fallback always moves on to the system FFmpeg and Venus.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include <libavcodec/avcodec.h>

typedef void *(*find_symbol_fn)(void *lib, const char *name);
typedef int (*open2_fn)(AVCodecContext *, const AVCodec *, AVDictionary **);
typedef int (*send_fn)(AVCodecContext *, const AVPacket *);
typedef int (*recv_fn)(AVCodecContext *, AVFrame *);
typedef void (*free_fn)(AVCodecContext **);
typedef int (*close_fn)(AVCodecContext *);
typedef const AVCodec *(*iterate_fn)(void **);
typedef int (*is_decoder_fn)(const AVCodec *);
typedef const AVCodec *(*find_decoder_fn)(enum AVCodecID);

static open2_fn real_open2;
static send_fn real_send;
static recv_fn real_recv;
static free_fn real_free;
static close_fn real_close;
static iterate_fn sys_iterate, ffvpx_iterate;
static is_decoder_fn sys_is_decoder, ffvpx_is_decoder;
static find_decoder_fn ffvpx_find_decoder;

#define MAX_CTX 16
static struct {
	AVCodecContext *ctx;
	int64_t duration;
} v4l2_ctx[MAX_CTX];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static int slot(AVCodecContext *ctx, int add)
{
	int i, free_slot = -1;

	for (i = 0; i < MAX_CTX; i++) {
		if (v4l2_ctx[i].ctx == ctx)
			return i;
		if (!v4l2_ctx[i].ctx && free_slot < 0)
			free_slot = i;
	}
	if (add && free_slot >= 0) {
		v4l2_ctx[free_slot].ctx = ctx;
		v4l2_ctx[free_slot].duration = 0;
		return free_slot;
	}
	return -1;
}

/* contexts get freed and their addresses reused for software decoders: forget them */
static void forget(AVCodecContext *ctx)
{
	int i;

	pthread_mutex_lock(&lock);
	i = slot(ctx, 0);
	if (i >= 0)
		v4l2_ctx[i].ctx = NULL;
	pthread_mutex_unlock(&lock);
}

static int is_v4l2(const AVCodec *codec)
{
	size_t n;

	if (!codec || !codec->name)
		return 0;
	n = strlen(codec->name);
	return n > 8 && !strcmp(codec->name + n - 8, "_v4l2m2m");
}

static int wrap_open2(AVCodecContext *ctx, const AVCodec *codec, AVDictionary **opts)
{
	forget(ctx);
	if (is_v4l2(codec ? codec : ctx->codec)) {
		if (!ctx->pkt_timebase.num && !ctx->time_base.num)
			ctx->pkt_timebase = (AVRational){ 1, 1000000 };
		pthread_mutex_lock(&lock);
		slot(ctx, 1);
		pthread_mutex_unlock(&lock);
	}
	return real_open2(ctx, codec, opts);
}

static int wrap_send(AVCodecContext *ctx, const AVPacket *pkt)
{
	if (pkt && pkt->duration > 0) {
		int i;

		pthread_mutex_lock(&lock);
		i = slot(ctx, 0);
		if (i >= 0)
			v4l2_ctx[i].duration = pkt->duration;
		pthread_mutex_unlock(&lock);
	}
	return real_send(ctx, pkt);
}

static int wrap_recv(AVCodecContext *ctx, AVFrame *frame)
{
	int ret = real_recv(ctx, frame);
	int i;

	if (ret < 0)
		return ret;
	pthread_mutex_lock(&lock);
	i = slot(ctx, 0);
	if (i >= 0) {
		if (frame->pkt_dts == AV_NOPTS_VALUE)
			frame->pkt_dts = frame->pts;
		if (frame->duration <= 0)
			frame->duration = v4l2_ctx[i].duration;
	}
	pthread_mutex_unlock(&lock);
	return ret;
}

static void wrap_free(AVCodecContext **pctx)
{
	if (pctx && *pctx)
		forget(*pctx);
	real_free(pctx);
}

static int wrap_close(AVCodecContext *ctx)
{
	forget(ctx);
	return real_close(ctx);
}

static int from_system_libavcodec(void *fn)
{
	Dl_info info;

	return fn && dladdr(fn, &info) && info.dli_fname &&
	       strstr(info.dli_fname, "/libavcodec.so.") && !strstr(info.dli_fname, "firefox");
}

static int from_ffvpx(void *fn)
{
	Dl_info info;

	return fn && dladdr(fn, &info) && info.dli_fname && strstr(info.dli_fname, "/libmozavcodec.so");
}

/*
 * AVCodecID values differ between FFmpeg majors (VP9 is 167 in libavcodec 62, 166 in 63) and
 * ffvpx need not be the system's major, so codecs are matched by name, never by id.
 */
static const char *base_name(const char *name)
{
	if (!strcmp(name, "libvpx"))
		return "vp8";
	if (!strcmp(name, "libvpx-vp9"))
		return "vp9";
	return name;
}

/* does the system libavcodec have a <base>_v4l2m2m decoder? */
static int system_has_v4l2(const char *base)
{
	char want[64];
	const AVCodec *c;
	void *it = NULL;

	if (!sys_iterate || !sys_is_decoder)
		return 0;
	if ((size_t)snprintf(want, sizeof(want), "%s_v4l2m2m", base) >= sizeof(want))
		return 0;
	while ((c = sys_iterate(&it)))
		if (c->name && sys_is_decoder(c) && !strcmp(c->name, want))
			return 1;
	return 0;
}

#define MAX_SEEN 64
static struct {
	const AVCodec *codec;
	int hide;
} seen[MAX_SEEN];

/*
 * Hide every ffvpx video decoder (H.264, HEVC, VP8, VP9 in Firefox 158) the system FFmpeg can
 * hand to Venus, so Firefox always falls through to the system FFmpeg and hardware decoding.
 */
static int hide_in_ffvpx(const AVCodec *c)
{
	int i, hide;

	if (!c || !c->name || c->type != AVMEDIA_TYPE_VIDEO || !ffvpx_is_decoder ||
	    !ffvpx_is_decoder(c))
		return 0;
	pthread_mutex_lock(&lock);
	for (i = 0; i < MAX_SEEN && seen[i].codec; i++)
		if (seen[i].codec == c) {
			hide = seen[i].hide;
			pthread_mutex_unlock(&lock);
			return hide;
		}
	hide = system_has_v4l2(base_name(c->name));
	if (i < MAX_SEEN) {
		seen[i].codec = c;
		seen[i].hide = hide;
	}
	pthread_mutex_unlock(&lock);
	return hide;
}

static const AVCodec *wrap_ffvpx_iterate(void **opaque)
{
	const AVCodec *c;

	while ((c = ffvpx_iterate(opaque)) && hide_in_ffvpx(c))
		;
	return c;
}

static const AVCodec *wrap_ffvpx_find_decoder(enum AVCodecID id)
{
	const AVCodec *c = ffvpx_find_decoder(id);

	return c && hide_in_ffvpx(c) ? NULL : c;
}

void *PR_FindSymbol(void *lib, const char *name)
{
	static find_symbol_fn real_find;
	void *fn;

	if (!real_find)
		real_find = (find_symbol_fn)dlsym(RTLD_NEXT, "PR_FindSymbol");
	if (!real_find)
		return NULL;
	fn = real_find(lib, name);
	if (!fn || !name)
		return fn;
	if (from_ffvpx(fn)) {
		if (!strcmp(name, "av_codec_is_decoder"))
			ffvpx_is_decoder = (is_decoder_fn)fn;
		if (!strcmp(name, "av_codec_iterate")) {
			ffvpx_iterate = (iterate_fn)fn;
			return (void *)wrap_ffvpx_iterate;
		}
		if (!strcmp(name, "avcodec_find_decoder")) {
			ffvpx_find_decoder = (find_decoder_fn)fn;
			return (void *)wrap_ffvpx_find_decoder;
		}
		return fn;
	}
	if (!from_system_libavcodec(fn))
		return fn;

	if (!strcmp(name, "av_codec_iterate"))
		sys_iterate = (iterate_fn)fn;
	if (!strcmp(name, "av_codec_is_decoder"))
		sys_is_decoder = (is_decoder_fn)fn;

	if (!strcmp(name, "avcodec_open2")) {
		real_open2 = (open2_fn)fn;
		return (void *)wrap_open2;
	}
	if (!strcmp(name, "avcodec_send_packet")) {
		real_send = (send_fn)fn;
		return (void *)wrap_send;
	}
	if (!strcmp(name, "avcodec_receive_frame")) {
		real_recv = (recv_fn)fn;
		return (void *)wrap_recv;
	}
	if (!strcmp(name, "avcodec_free_context")) {
		real_free = (free_fn)fn;
		return (void *)wrap_free;
	}
	if (!strcmp(name, "avcodec_close")) {
		real_close = (close_fn)fn;
		return (void *)wrap_close;
	}
	return fn;
}
