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
 * Adreno 512, so ffvpx would claim VP8/VP9 and decode them in software. Hide ffvpx's VP8/VP9
 * decoders (not its encoders) whenever the system libavcodec has a decoder for the codec, so
 * Firefox's own fallback moves on to the system FFmpeg and its *_v4l2m2m wrappers.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
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
 * ffvpx need not be the system's major, so each library's VP8/VP9 ids are learnt from its own
 * codec names.
 */
static int vpx_index(const char *name)
{
	if (!name)
		return -1;
	if (!strcmp(name, "vp8") || !strcmp(name, "libvpx"))
		return 0;
	if (!strcmp(name, "vp9") || !strcmp(name, "libvpx-vp9"))
		return 1;
	return -1;
}

/* VP8 (0) / VP9 (1) codec ids of ffvpx, or AV_CODEC_ID_NONE */
static enum AVCodecID ffvpx_vpx_id(int k)
{
	static int learnt;
	static enum AVCodecID ids[2];
	const AVCodec *c;
	void *it = NULL;
	int i;

	pthread_mutex_lock(&lock);
	if (!learnt) {
		while ((c = ffvpx_iterate(&it)))
			if ((i = vpx_index(c->name)) >= 0 && ids[i] == AV_CODEC_ID_NONE)
				ids[i] = c->id;
		learnt = 1;
	}
	pthread_mutex_unlock(&lock);
	return ids[k];
}

/* does the system libavcodec decode VP8 (0) / VP9 (1), natively or through V4L2? */
static int system_decodes(int k)
{
	static const char *const names[2][2] = { { "vp8", "vp8_v4l2m2m" }, { "vp9", "vp9_v4l2m2m" } };
	static int known[2], answer[2];
	const AVCodec *c;
	void *it = NULL;
	int found = 0;

	if (!sys_iterate || !sys_is_decoder)
		return 0;
	pthread_mutex_lock(&lock);
	if (!known[k]) {
		while ((c = sys_iterate(&it)))
			if (c->name && sys_is_decoder(c) &&
			    (!strcmp(c->name, names[k][0]) || !strcmp(c->name, names[k][1]))) {
				found = 1;
				break;
			}
		answer[k] = found;
		known[k] = 1;
	}
	found = answer[k];
	pthread_mutex_unlock(&lock);
	return found;
}

static int hide_in_ffvpx(const AVCodec *c)
{
	int k;

	if (!ffvpx_iterate || !ffvpx_is_decoder || !ffvpx_is_decoder(c))
		return 0;
	for (k = 0; k < 2; k++)
		if (c->id != AV_CODEC_ID_NONE && c->id == ffvpx_vpx_id(k))
			return system_decodes(k);
	return 0;
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
