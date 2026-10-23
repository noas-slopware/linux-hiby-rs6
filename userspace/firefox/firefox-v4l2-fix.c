// SPDX-License-Identifier: MIT
/*
 * LD_PRELOAD shim so Firefox can keep the HiBy RS6 Venus V4L2 decoder (system FFmpeg
 * *_v4l2m2m wrappers), with stock Firefox and stock FFmpeg.
 *
 * Firefox resolves every libavcodec function through NSPR's PR_FindSymbol(). For the
 * system libavcodec only (never Firefox's bundled ffvpx), hand back wrappers that fix the
 * (built against the system FFmpeg headers; links nothing but libc, so it is cheap to load)
 * three things breaking V4L2 decode with Firefox:
 *  - Upstream FFmpeg's V4L2 M2M decoder has no DRM PRIME output, which Firefox's V4L2-DRM
 *    path needs: export the capture buffers as DMA-BUFs and describe the frames with them
 *    (see to_drm_prime below), with 32 capture buffers instead of 20.
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
 * Adreno 512, and no pref keeps ffvpx out of it, so ffvpx would claim VP8/VP9 and (Firefox 158)
 * H.264/HEVC and decode them in software. Hide every ffvpx video decoder (not its encoders, not
 * audio, not the FFT WebAudio uses), so Firefox's own fallback always moves on to the system
 * FFmpeg and its *_v4l2m2m wrappers.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <linux/videodev2.h>

#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext_drm.h>

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
static iterate_fn ffvpx_iterate;
static is_decoder_fn ffvpx_is_decoder;
static find_decoder_fn ffvpx_find_decoder;

typedef int (*dict_set_fn)(AVDictionary **, const char *, const char *, int);
typedef AVDictionaryEntry *(*dict_get_fn)(const AVDictionary *, const char *,
					  const AVDictionaryEntry *, int);
typedef void (*dict_free_fn)(AVDictionary **);
static dict_set_fn av_dict_set_fn;
static dict_get_fn av_dict_get_fn;
static dict_free_fn av_dict_free_fn;

#define MAX_CTX 16
static struct {
	AVCodecContext *ctx;
	int64_t duration;
	int drm;	/* the caller asked for DRM PRIME frames (Firefox's V4L2-DRM path) */
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
		v4l2_ctx[free_slot].drm = 0;
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

/*
 * DRM PRIME output for the stock *_v4l2m2m decoders. Upstream FFmpeg's V4L2 M2M decoder only
 * returns frames in system memory (NV12 here) and never calls get_format, while Firefox's
 * V4L2-DRM path (InitV4L2Decoder, CreateImageV4L2) only takes AV_PIX_FMT_DRM_PRIME frames with
 * an AVDRMFrameDescriptor: it got Venus' first frame, could not import it and fell back to
 * software decoding. The capture buffers are V4L2 MMAP buffers, so export each one once as a
 * DMA-BUF (VIDIOC_EXPBUF, what the LibreELEC/RPi v4l2-drmprime patches do inside FFmpeg) and
 * describe the frame with it: no copies. The decoder's own VIDIOC_QUERYBUF and mmap calls say
 * which V4L2 buffer and plane a frame's data lives in.
 */
#define MAX_MAP 128
static struct {
	int fd;		/* V4L2 device fd, -1: free */
	unsigned int type, index, plane;
	uint32_t mem_offset, length;
	uint8_t *addr;	/* where FFmpeg mapped it, NULL until mmap */
	int dmabuf;	/* exported DMA-BUF, -1 until first use */
} map[MAX_MAP];
static int nmaps;	/* entries in use or once used, so the fast paths skip the table when 0 */
static pthread_mutex_t map_lock = PTHREAD_MUTEX_INITIALIZER;

typedef int (*ioctl_fn)(int, unsigned long, ...);
typedef void *(*mmap_fn)(void *, size_t, int, int, int, off_t);
typedef int (*munmap_fn)(void *, size_t);
typedef int (*close_fd_fn)(int);
static ioctl_fn real_ioctl;
static mmap_fn real_mmap;
static munmap_fn real_munmap;
static close_fd_fn real_close_fd;

static void resolve_libc(void)
{
	if (!real_ioctl) {
		real_mmap = (mmap_fn)dlsym(RTLD_NEXT, "mmap");
		real_munmap = (munmap_fn)dlsym(RTLD_NEXT, "munmap");
		real_close_fd = (close_fd_fn)dlsym(RTLD_NEXT, "close");
		real_ioctl = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl");
	}
}

static int is_capture(unsigned int type)
{
	return type == V4L2_BUF_TYPE_VIDEO_CAPTURE || type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
}

/* map_lock held: drop every buffer of this fd (and type, unless 0) */
static void drop_buffers(int fd, unsigned int type)
{
	int i;

	for (i = 0; i < nmaps; i++)
		if (map[i].fd == fd && (!type || map[i].type == type)) {
			if (map[i].dmabuf >= 0)
				real_close_fd(map[i].dmabuf);
			map[i].fd = -1;
		}
}

/* map_lock held */
static void add_buffer(int fd, unsigned int type, unsigned int index, unsigned int plane,
		       uint32_t mem_offset, uint32_t length)
{
	int i, free_i = -1;

	for (i = 0; i < nmaps; i++) {
		if (map[i].fd == fd && map[i].type == type && map[i].index == index &&
		    map[i].plane == plane) {
			free_i = i;
			break;
		}
		if (map[i].fd < 0 && free_i < 0)
			free_i = i;
	}
	if (free_i < 0) {
		if (nmaps == MAX_MAP)
			return;
		free_i = nmaps++;
	} else if (map[free_i].fd == fd && map[free_i].dmabuf >= 0) {
		real_close_fd(map[free_i].dmabuf);
	}
	map[free_i].fd = fd;
	map[free_i].type = type;
	map[free_i].index = index;
	map[free_i].plane = plane;
	map[free_i].mem_offset = mem_offset;
	map[free_i].length = length;
	map[free_i].addr = NULL;
	map[free_i].dmabuf = -1;
}

int ioctl(int fd, unsigned long req, ...)
{
	va_list ap;
	void *arg;
	int ret;

	va_start(ap, req);
	arg = va_arg(ap, void *);
	va_end(ap);
	resolve_libc();
	ret = real_ioctl(fd, req, arg);
	if (ret < 0 || !arg)
		return ret;

	if (req == VIDIOC_QUERYBUF) {
		struct v4l2_buffer *b = arg;
		unsigned int p;

		if (!is_capture(b->type) || b->memory != V4L2_MEMORY_MMAP)
			return ret;
		pthread_mutex_lock(&map_lock);
		if (b->type == V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE) {
			for (p = 0; p < b->length && b->m.planes; p++)
				add_buffer(fd, b->type, b->index, p, b->m.planes[p].m.mem_offset,
					   b->m.planes[p].length);
		} else {
			add_buffer(fd, b->type, b->index, 0, b->m.offset, b->length);
		}
		pthread_mutex_unlock(&map_lock);
	} else if (req == VIDIOC_REQBUFS) {
		struct v4l2_requestbuffers *r = arg;

		if (nmaps && is_capture(r->type)) {
			pthread_mutex_lock(&map_lock);
			drop_buffers(fd, r->type);
			pthread_mutex_unlock(&map_lock);
		}
	}
	return ret;
}

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	void *ret;
	int i;

	resolve_libc();
	ret = real_mmap(addr, len, prot, flags, fd, off);
	if (ret == MAP_FAILED || fd < 0 || !nmaps)
		return ret;
	pthread_mutex_lock(&map_lock);
	for (i = 0; i < nmaps; i++)
		if (map[i].fd == fd && map[i].mem_offset == (uint32_t)off) {
			map[i].addr = ret;
			break;
		}
	pthread_mutex_unlock(&map_lock);
	return ret;
}

void *mmap64(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	return mmap(addr, len, prot, flags, fd, off);
}

int munmap(void *addr, size_t len)
{
	int i;

	resolve_libc();
	if (nmaps) {
		pthread_mutex_lock(&map_lock);
		for (i = 0; i < nmaps; i++)
			if (map[i].fd >= 0 && map[i].addr == addr)
				map[i].addr = NULL;
		pthread_mutex_unlock(&map_lock);
	}
	return real_munmap(addr, len);
}

int close(int fd)
{
	resolve_libc();
	if (nmaps) {
		pthread_mutex_lock(&map_lock);
		drop_buffers(fd, 0);
		pthread_mutex_unlock(&map_lock);
	}
	return real_close_fd(fd);
}

/* map_lock held: the capture plane holding p, exported as a DMA-BUF; -1 if none */
static int find_plane(const uint8_t *p, uint32_t *offset, uint32_t *size)
{
	struct v4l2_exportbuffer eb;
	int i;

	for (i = 0; i < nmaps; i++) {
		if (map[i].fd < 0 || !map[i].addr || p < map[i].addr ||
		    p >= map[i].addr + map[i].length)
			continue;
		if (map[i].dmabuf < 0) {
			memset(&eb, 0, sizeof(eb));
			eb.type = map[i].type;
			eb.index = map[i].index;
			eb.plane = map[i].plane;
			eb.flags = O_RDONLY | O_CLOEXEC;
			if (real_ioctl(map[i].fd, VIDIOC_EXPBUF, &eb) < 0)
				return -1;
			map[i].dmabuf = eb.fd;
		}
		*offset = p - map[i].addr;
		*size = map[i].length;
		return map[i].dmabuf;
	}
	return -1;
}

typedef AVBufferRef *(*buffer_alloc_fn)(size_t);
static buffer_alloc_fn av_buffer_allocz_fn;

#define FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))

/* turn a V4L2 NV12 frame into a DRM PRIME one in place; 0 on success */
static int to_drm_prime(AVFrame *frame)
{
	AVDRMFrameDescriptor *desc;
	AVBufferRef *ref;
	uint32_t off[2], size[2];
	int fd[2], slot_i, i;

	if (frame->format != AV_PIX_FMT_NV12 || !av_buffer_allocz_fn)
		return -1;
	for (slot_i = 1; slot_i < AV_NUM_DATA_POINTERS && frame->buf[slot_i]; slot_i++)
		;
	if (slot_i == AV_NUM_DATA_POINTERS)
		return -1;

	pthread_mutex_lock(&map_lock);
	for (i = 0; i < 2; i++)
		fd[i] = find_plane(frame->data[i], &off[i], &size[i]);
	pthread_mutex_unlock(&map_lock);
	if (fd[0] < 0 || fd[1] < 0)
		return -1;

	ref = av_buffer_allocz_fn(sizeof(*desc));
	if (!ref)
		return -1;
	desc = (AVDRMFrameDescriptor *)ref->data;
	desc->nb_objects = fd[1] == fd[0] ? 1 : 2;
	for (i = 0; i < desc->nb_objects; i++) {
		desc->objects[i].fd = fd[i];
		desc->objects[i].size = size[i];
		desc->objects[i].format_modifier = 0;	/* DRM_FORMAT_MOD_LINEAR */
	}
	desc->nb_layers = 1;
	desc->layers[0].format = FOURCC('N', 'V', '1', '2');
	desc->layers[0].nb_planes = 2;
	for (i = 0; i < 2; i++) {
		desc->layers[0].planes[i].object_index = desc->nb_objects == 1 ? 0 : i;
		desc->layers[0].planes[i].offset = off[i];
		desc->layers[0].planes[i].pitch = frame->linesize[i];
	}

	/* buf[0] stays: it holds the V4L2 buffer until whoever displays the frame lets go */
	frame->buf[slot_i] = ref;
	for (i = 0; i < AV_NUM_DATA_POINTERS; i++) {
		frame->data[i] = NULL;
		frame->linesize[i] = 0;
	}
	frame->data[0] = (uint8_t *)desc;
	frame->format = AV_PIX_FMT_DRM_PRIME;
	return 0;
}

static int wrap_open2(AVCodecContext *ctx, const AVCodec *codec, AVDictionary **opts)
{
	static const enum AVPixelFormat offer[] = { AV_PIX_FMT_DRM_PRIME, AV_PIX_FMT_NV12, AV_PIX_FMT_NONE };
	AVDictionary *own = NULL;
	int drm = 0, i;

	forget(ctx);
	if (is_v4l2(codec ? codec : ctx->codec)) {
		if (!ctx->pkt_timebase.num && !ctx->time_base.num)
			ctx->pkt_timebase = (AVRational){ 1, 1000000 };
		/* what the patched FFmpeg asks at init: Firefox's V4L2-DRM path picks DRM PRIME */
		drm = ctx->get_format && ctx->get_format(ctx, offer) == AV_PIX_FMT_DRM_PRIME;
		/* DMA-BUF frames stay with the compositor for a while: 20 capture buffers run dry */
		if (drm && av_dict_set_fn && !(opts && *opts && av_dict_get_fn &&
					       av_dict_get_fn(*opts, "num_capture_buffers", NULL, 0)))
			av_dict_set_fn(opts ? opts : &own, "num_capture_buffers", "32", 0);
		pthread_mutex_lock(&lock);
		i = slot(ctx, 1);
		if (i >= 0)
			v4l2_ctx[i].drm = drm;
		pthread_mutex_unlock(&lock);
		if (own) {
			int ret = real_open2(ctx, codec, &own);

			if (av_dict_free_fn)
				av_dict_free_fn(&own);
			return ret;
		}
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
	int i, drm = 0;

	if (ret < 0)
		return ret;
	pthread_mutex_lock(&lock);
	i = slot(ctx, 0);
	if (i >= 0) {
		if (frame->pkt_dts == AV_NOPTS_VALUE)
			frame->pkt_dts = frame->pts;
		if (frame->duration <= 0)
			frame->duration = v4l2_ctx[i].duration;
		drm = v4l2_ctx[i].drm;
	}
	pthread_mutex_unlock(&lock);
	if (drm && to_drm_prime(frame) < 0)
		return AVERROR(EIO);
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

static int from_system_libavutil(void *fn)
{
	Dl_info info;

	return fn && dladdr(fn, &info) && info.dli_fname &&
	       strstr(info.dli_fname, "/libavutil.so.") && !strstr(info.dli_fname, "firefox");
}

/* the libavutil helpers the shim needs, from the same system libavutil Firefox uses */
static void resolve_libavutil(void *fn)
{
	Dl_info info;
	void *h;

	if (av_buffer_allocz_fn || !dladdr(fn, &info) ||
	    !(h = dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD)))
		return;
	av_dict_set_fn = (dict_set_fn)dlsym(h, "av_dict_set");
	av_dict_get_fn = (dict_get_fn)dlsym(h, "av_dict_get");
	av_dict_free_fn = (dict_free_fn)dlsym(h, "av_dict_free");
	av_buffer_allocz_fn = (buffer_alloc_fn)dlsym(h, "av_buffer_allocz");
	dlclose(h);
}

static int from_ffvpx(void *fn)
{
	Dl_info info;

	return fn && dladdr(fn, &info) && info.dli_fname && strstr(info.dli_fname, "/libmozavcodec.so");
}

/* ffvpx decodes no video at all: every video codec goes to the system FFmpeg */
static int hide_in_ffvpx(const AVCodec *c)
{
	return c && c->type == AVMEDIA_TYPE_VIDEO && ffvpx_is_decoder && ffvpx_is_decoder(c);
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
	if (!from_system_libavcodec(fn)) {
		if (from_system_libavutil(fn))
			resolve_libavutil(fn);
		return fn;
	}

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
