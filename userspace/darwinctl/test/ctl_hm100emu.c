// SPDX-License-Identifier: MIT
/*
 * ALSA control plugin "hm100emu": the emulated hm100 mixer of hm100-emu.py as an ALSA control
 * device, for testing darwinctl (and what runs it) on a PC through alsa-lib's own control API:
 * element list, info, value reads and writes, TLV writes, events and poll descriptors. Every
 * client talks to the one daemon, which holds the state and sends the events.
 *
 * Config: ctl.name { type hm100emu  socket STR }
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <alsa/asoundlib.h>
#include <alsa/control_external.h>

#define MAX_CTLS	32
#define MAX_ITEMS	16

struct ctl_def {
	char name[64];
	int type, count, nitems;
	unsigned int access;
	long min, max;
	char items[MAX_ITEMS][64];
};

struct emu {
	snd_ctl_ext_t ext;
	int cmd;			/* requests */
	int ev;				/* events: the poll descriptor */
	char evbuf[4096];
	size_t evlen;
	int nctls;
	struct ctl_def ctls[MAX_CTLS];
};

static int connect_to(const char *path)
{
	struct sockaddr_un a = { .sun_family = AF_UNIX };
	int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);

	if (fd < 0)
		return -errno;
	snprintf(a.sun_path, sizeof(a.sun_path), "%s", path);
	if (connect(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
		int e = errno;

		close(fd);
		return -e;
	}
	return fd;
}

static int send_all(int fd, const char *buf, size_t len)
{
	while (len) {
		ssize_t n = write(fd, buf, len);

		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			return -EPIPE;
		buf += n;
		len -= n;
	}
	return 0;
}

/* one reply line (blocking); ok: 0 and the rest in out; err: -errno */
static int read_line(int fd, char *out, size_t len)
{
	size_t n = 0;
	char c;

	for (;;) {
		ssize_t r = read(fd, &c, 1);

		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -ENODEV;
		if (c == '\n')
			break;
		if (n + 1 < len)
			out[n++] = c;
	}
	out[n] = 0;
	return 0;
}

static int request(struct emu *e, const char *req, char *out, size_t len)
{
	char line[8192];
	int r = send_all(e->cmd, req, strlen(req));

	if (!r)
		r = read_line(e->cmd, line, sizeof(line));
	if (r)
		return r;
	if (!strncmp(line, "err ", 4))
		return -atoi(line + 4);
	if (strncmp(line, "ok", 2))
		return -EIO;
	if (out)
		snprintf(out, len, "%s", line[2] ? line + 3 : "");
	return 0;
}

static int emu_elem_count(snd_ctl_ext_t *ext)
{
	return ((struct emu *)ext->private_data)->nctls;
}

static int emu_elem_list(snd_ctl_ext_t *ext, unsigned int offset, snd_ctl_elem_id_t *id)
{
	struct emu *e = ext->private_data;

	if (offset >= (unsigned int)e->nctls)
		return -EINVAL;
	snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_MIXER);
	snd_ctl_elem_id_set_name(id, e->ctls[offset].name);
	return 0;
}

static snd_ctl_ext_key_t emu_find_elem(snd_ctl_ext_t *ext, const snd_ctl_elem_id_t *id)
{
	struct emu *e = ext->private_data;
	unsigned int numid = snd_ctl_elem_id_get_numid(id);
	int i;

	if (numid > 0 && numid <= (unsigned int)e->nctls)
		return numid - 1;
	for (i = 0; i < e->nctls; i++)
		if (!strcmp(e->ctls[i].name, snd_ctl_elem_id_get_name(id)))
			return i;
	return SND_CTL_EXT_KEY_NOT_FOUND;
}

static int emu_get_attribute(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, int *type, unsigned int *acc,
			     unsigned int *count)
{
	struct ctl_def *c = &((struct emu *)ext->private_data)->ctls[key];

	*type = c->type;
	*acc = c->access;
	*count = c->count;
	return 0;
}

static int emu_get_integer_info(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, long *imin, long *imax,
				long *istep)
{
	struct ctl_def *c = &((struct emu *)ext->private_data)->ctls[key];

	*imin = c->min;
	*imax = c->max;
	*istep = 0;
	return 0;
}

static int emu_get_enumerated_info(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, unsigned int *items)
{
	*items = ((struct emu *)ext->private_data)->ctls[key].nitems;
	return 0;
}

static int emu_get_enumerated_name(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, unsigned int item,
				   char *name, size_t len)
{
	struct ctl_def *c = &((struct emu *)ext->private_data)->ctls[key];

	if (item >= (unsigned int)c->nitems)
		return -EINVAL;
	snprintf(name, len, "%s", c->items[item]);
	return 0;
}

/* the kernel: snd_ctl_elem_read/write check READ/WRITE access (ctl_ext leaves it to us) */
static int read_values(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, long *v)
{
	struct emu *e = ext->private_data;
	char req[32], out[256], *p, *end;
	int i, r;

	if (!(e->ctls[key].access & SND_CTL_EXT_ACCESS_READ))
		return -EPERM;
	snprintf(req, sizeof(req), "get %lu\n", (unsigned long)key);
	r = request(e, req, out, sizeof(out));
	if (r)
		return r;
	for (i = 0, p = out; i < e->ctls[key].count && i < 128; i++, p = end) {
		v[i] = strtol(p, &end, 10);
		if (end == p)
			return -EIO;
	}
	return 0;
}

static int write_values(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, const long *v)
{
	struct emu *e = ext->private_data;
	char req[512];
	int i, n, r;

	if (!(e->ctls[key].access & SND_CTL_EXT_ACCESS_WRITE))
		return -EPERM;
	n = snprintf(req, sizeof(req), "put %lu", (unsigned long)key);
	for (i = 0; i < e->ctls[key].count && i < 32; i++)
		n += snprintf(req + n, sizeof(req) - n, " %ld", v[i]);
	snprintf(req + n, sizeof(req) - n, "\n");
	r = request(e, req, NULL, 0);
	return r < 0 ? r : 0;
}

static int emu_read_integer(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, long *value)
{
	return read_values(ext, key, value);
}

static int emu_write_integer(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, long *value)
{
	return write_values(ext, key, value);
}

static int emu_read_enumerated(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, unsigned int *items)
{
	long v[1];
	int r = read_values(ext, key, v);

	if (!r)
		items[0] = v[0];
	return r;
}

static int emu_write_enumerated(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, unsigned int *items)
{
	long v[1] = { items[0] };

	return write_values(ext, key, v);
}

/* FIR Custom: the whole container (type, length, data) both ways, as the bytes TLV callback */
static int emu_tlv(snd_ctl_ext_t *ext, snd_ctl_ext_key_t key, int op_flag, unsigned int numid,
		   unsigned int *tlv, unsigned int tlv_size)
{
	struct emu *e = ext->private_data;
	char *req, *out;
	size_t i, n;
	int r;

	(void)numid;
	if (op_flag < 0)
		return -ENXIO;
	req = malloc(2 * tlv_size + 64);
	out = malloc(2 * tlv_size + 64);
	if (!req || !out) {
		free(req);
		free(out);
		return -ENOMEM;
	}
	if (op_flag > 0) {
		const unsigned char *b = (const unsigned char *)tlv;

		n = sprintf(req, "tlvw %lu ", (unsigned long)key);
		for (i = 0; i < tlv_size; i++)
			n += sprintf(req + n, "%02x", b[i]);
		strcpy(req + n, "\n");
		r = request(e, req, NULL, 0);
	} else {
		sprintf(req, "tlvr %lu %u\n", (unsigned long)key, tlv_size);
		r = request(e, req, out, 2 * tlv_size + 64);
		for (i = 0; !r && i < tlv_size && out[2 * i] && out[2 * i + 1]; i++) {
			unsigned int x;

			sscanf(out + 2 * i, "%2x", &x);
			((unsigned char *)tlv)[i] = x;
		}
	}
	free(req);
	free(out);
	return r < 0 ? r : 0;
}

static void emu_subscribe_events(snd_ctl_ext_t *ext, int subscribe)
{
	struct emu *e = ext->private_data;

	if (!subscribe)
		e->evlen = 0;	/* the kernel drops the queue on unsubscribe */
}

/* one queued "event <i> <mask>" line: 1, nothing queued: -EAGAIN, daemon gone: -ENODEV */
static int emu_read_event(snd_ctl_ext_t *ext, snd_ctl_elem_id_t *id, unsigned int *event_mask)
{
	struct emu *e = ext->private_data;

	for (;;) {
		char *nl = memchr(e->evbuf, '\n', e->evlen);
		ssize_t n;

		if (nl) {
			unsigned int i, mask;
			int ok;

			*nl = 0;
			ok = sscanf(e->evbuf, "event %u %u", &i, &mask) == 2 && i < (unsigned int)e->nctls;
			e->evlen -= nl + 1 - e->evbuf;
			memmove(e->evbuf, nl + 1, e->evlen);
			if (!ok || !ext->subscribed)
				continue;	/* "ok" of the subscribe request */
			snd_ctl_elem_id_set_numid(id, i + 1);
			snd_ctl_elem_id_set_interface(id, SND_CTL_ELEM_IFACE_MIXER);
			snd_ctl_elem_id_set_name(id, e->ctls[i].name);
			*event_mask = mask;
			return 1;
		}
		if (e->evlen >= sizeof(e->evbuf))
			e->evlen = 0;
		n = read(e->ev, e->evbuf + e->evlen, sizeof(e->evbuf) - e->evlen);
		if (n < 0 && errno == EINTR)
			continue;
		if (n < 0 && errno == EAGAIN)
			return -EAGAIN;
		if (n <= 0)
			return -ENODEV;
		e->evlen += n;
	}
}

static void emu_close(snd_ctl_ext_t *ext)
{
	struct emu *e = ext->private_data;

	close(e->cmd);
	close(e->ev);
	free(e);
}

static const snd_ctl_ext_callback_t emu_callback = {
	.close = emu_close,
	.elem_count = emu_elem_count,
	.elem_list = emu_elem_list,
	.find_elem = emu_find_elem,
	.get_attribute = emu_get_attribute,
	.get_integer_info = emu_get_integer_info,
	.get_enumerated_info = emu_get_enumerated_info,
	.get_enumerated_name = emu_get_enumerated_name,
	.read_integer = emu_read_integer,
	.read_enumerated = emu_read_enumerated,
	.write_integer = emu_write_integer,
	.write_enumerated = emu_write_enumerated,
	.subscribe_events = emu_subscribe_events,
	.read_event = emu_read_event,
};

static int load_controls(struct emu *e)
{
	static const char req[] = "list\n";
	char line[256];
	int r = send_all(e->cmd, req, strlen(req));

	while (!r && !(r = read_line(e->cmd, line, sizeof(line)))) {
		struct ctl_def *c;
		int i, k, n;

		if (!strcmp(line, "ok"))
			return 0;
		if (sscanf(line, "ctl %d %n", &i, &n) == 1 && i == e->nctls && i < MAX_CTLS) {
			c = &e->ctls[e->nctls++];
			if (sscanf(line + n, "%d %u %d %ld %ld %d %n", &c->type, &c->access, &c->count,
				   &c->min, &c->max, &c->nitems, &k) < 6)
				return -EIO;
			snprintf(c->name, sizeof(c->name), "%s", line + n + k);
		} else if (sscanf(line, "item %d %d %n", &i, &k, &n) == 2 && i < e->nctls &&
			   k < MAX_ITEMS) {
			snprintf(e->ctls[i].items[k], sizeof(e->ctls[i].items[k]), "%s", line + n);
		} else {
			return -EIO;
		}
	}
	return r;
}

SND_CTL_PLUGIN_DEFINE_FUNC(hm100emu)
{
	snd_config_iterator_t i, next;
	const char *path = NULL;
	struct emu *e;
	int r;

	snd_config_for_each(i, next, conf) {
		snd_config_t *n = snd_config_iterator_entry(i);
		const char *id;

		if (snd_config_get_id(n, &id) < 0)
			continue;
		if (!strcmp(id, "comment") || !strcmp(id, "type") || !strcmp(id, "hint"))
			continue;
		if (!strcmp(id, "socket")) {
			if (snd_config_get_string(n, &path) < 0)
				return -EINVAL;
			continue;
		}
		SNDERR("Unknown field %s", id);
		return -EINVAL;
	}
	if (!path) {
		SNDERR("hm100emu: no socket");
		return -EINVAL;
	}
	e = calloc(1, sizeof(*e));
	if (!e)
		return -ENOMEM;
	e->cmd = connect_to(path);
	e->ev = e->cmd < 0 ? -1 : connect_to(path);
	if (e->cmd < 0 || e->ev < 0) {
		r = e->cmd < 0 ? e->cmd : e->ev;
		goto fail;
	}
	r = load_controls(e);
	if (!r)
		r = send_all(e->ev, "subscribe\n", 10);
	if (r)
		goto fail;
	fcntl(e->ev, F_SETFL, fcntl(e->ev, F_GETFL) | O_NONBLOCK);

	e->ext.version = SND_CTL_EXT_VERSION;
	e->ext.card_idx = 0;
	snprintf(e->ext.id, sizeof(e->ext.id), "hm100emu");
	snprintf(e->ext.driver, sizeof(e->ext.driver), "hm100emu");
	snprintf(e->ext.name, sizeof(e->ext.name), "hm100 emulator");
	snprintf(e->ext.longname, sizeof(e->ext.longname), "hm100 emulator (%s)", path);
	snprintf(e->ext.mixername, sizeof(e->ext.mixername), "hm100");
	e->ext.poll_fd = e->ev;
	e->ext.callback = &emu_callback;
	e->ext.private_data = e;
	e->ext.tlv.c = emu_tlv;
	r = snd_ctl_ext_create(&e->ext, name, mode);
	if (r < 0)
		goto fail;
	*handlep = e->ext.handle;
	return 0;
fail:
	if (e->cmd >= 0)
		close(e->cmd);
	if (e->ev >= 0)
		close(e->ev);
	free(e);
	return r;
}

SND_CTL_PLUGIN_SYMBOL(hm100emu);
