// SPDX-License-Identifier: MIT
/*
 * darwinctl: the HiBy RS6 DAC (hm100 "Darwin" FPGA, snd-soc-hiby-hm100) from the command line.
 * Every control of the driver but the playback volume (that one is PipeWire's): NOS, Output and
 * the read-only Output Target, Gain, Digital Filter and the Darwin filters, Pregain, LR Balance,
 * Idle Power Off Seconds, DSD Mode and DSD Compensate. Every value shown is read back from ALSA.
 *
 * Built-in filters are the "Digital Filter" items of the hm100 driver (the stock kernel's
 * four coefficient sets, plus the stock names that have none). Darwin filters are .flt files
 * (256 int32 taps, 1024 bytes, as stock's filter_path): loading one goes into "FIR Custom",
 * which also selects the driver's "custom" item. The loaded taps and their name are kept in
 * the state directory so that `darwinctl restore` (darwinctl-restore.service, after
 * alsa-restore has put "Digital Filter" back) can load them again after a reboot.
 *
 * `darwinctl status --json` prints the whole state as one JSON object; `darwinctl monitor`
 * prints it once and again after every change (ALSA control events, the card going and
 * coming), one object per line, for the DMS plugin. It sleeps in poll(): no timers.
 *
 * Plain alsa-lib, no other dependencies: libc-agnostic.
 */
#define _GNU_SOURCE
#include <alsa/asoundlib.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>

#define FIR_BYTES	1024
#define MAX_PRESETS	256
#define MAX_ITEMS	16
#define STATE_DIR	"/var/lib/hiby-rs6/darwin"	/* DARWINCTL_STATE overrides it */

struct preset {
	char label[128];	/* filter.json "title", else the file name */
	char stem[128];		/* file name without .flt */
	char path[PATH_MAX];
};

static struct preset presets[MAX_PRESETS];
static int npresets;

/*
 * The hm100 controls darwinctl uses, by their driver names. The first three make the card
 * (the driver's first version had them); the others can be missing on an older kernel, and
 * then their commands say so and the JSON has null for them.
 */
enum { C_NOS, C_FILTER, C_FIR, C_OUTPUT, C_TARGET, C_GAIN, C_PREGAIN, C_BALANCE, C_IDLE,
       C_DSD_MODE, C_DSD_COMP, NCTL };

static const struct {
	const char *name;
	snd_ctl_elem_type_t type;
} defs[NCTL] = {
	[C_NOS]		= { "NOS Switch", SND_CTL_ELEM_TYPE_BOOLEAN },
	[C_FILTER]	= { "Digital Filter", SND_CTL_ELEM_TYPE_ENUMERATED },
	[C_FIR]		= { "FIR Custom", SND_CTL_ELEM_TYPE_BYTES },
	[C_OUTPUT]	= { "Output", SND_CTL_ELEM_TYPE_ENUMERATED },
	[C_TARGET]	= { "Output Target", SND_CTL_ELEM_TYPE_ENUMERATED },	/* read-only */
	[C_GAIN]	= { "Gain", SND_CTL_ELEM_TYPE_ENUMERATED },
	[C_PREGAIN]	= { "Pregain", SND_CTL_ELEM_TYPE_INTEGER },		/* 0.1 dB */
	[C_BALANCE]	= { "LR Balance", SND_CTL_ELEM_TYPE_INTEGER },		/* 0.5 dB, < 0 raises L */
	[C_IDLE]	= { "Idle Power Off Seconds", SND_CTL_ELEM_TYPE_INTEGER },	/* 0 = never */
	[C_DSD_MODE]	= { "DSD Mode", SND_CTL_ELEM_TYPE_ENUMERATED },
	[C_DSD_COMP]	= { "DSD Compensate", SND_CTL_ELEM_TYPE_INTEGER },	/* 0.5 dB, DSD only */
};

struct elem {
	snd_ctl_elem_id_t *id;	/* NULL: the driver has no such control */
	unsigned int numid;
	long min, max;
	int nitems;
	char items[MAX_ITEMS][64];	/* the driver's item names */
	char labels[MAX_ITEMS][64];	/* as people read them */
};

static snd_ctl_t *ctl;
static char ctl_name[64];
static struct elem elems[NCTL];
static int custom_idx = -1;

/* the driver's names for the filters (its custom one is the Darwin filter) */
#define nfilters	(elems[C_FILTER].nitems)
#define filter_names	(elems[C_FILTER].items)

static const char *state_dir(void)
{
	const char *s = getenv("DARWINCTL_STATE");

	return s && *s ? s : STATE_DIR;
}

/* sharp_roll_off == sharp-roll-off == Sharp Roll Off; "Darwin 3" == darwin-3 */
static int same_name(const char *a, const char *b)
{
	for (; *a && *b; a++, b++) {
		char x = (*a == '-' || *a == ' ') ? '_' : tolower((unsigned char)*a);
		char y = (*b == '-' || *b == ' ') ? '_' : tolower((unsigned char)*b);

		if (x != y)
			return 0;
	}
	return !*a && !*b;
}

/*
 * presets: <data dir>/hiby-rs6/darwin/, the user's directory first. A filter.json in stock
 * Settings' format ({"list":[{"title":..., "path":".../<file>.flt"}, ...]}) gives the order and
 * the names; .flt files it doesn't list follow by file name.
 */
static void add_preset(const char *dir, const char *file, const char *label)
{
	struct preset *p = &presets[npresets];
	size_t len = strlen(file);
	struct stat st;
	int j;

	if (npresets >= MAX_PRESETS || len <= 4 || strcmp(file + len - 4, ".flt") || strchr(file, '/') ||
	    len - 4 >= sizeof(p->stem))
		return;
	snprintf(p->stem, sizeof(p->stem), "%.*s", (int)(len - 4), file);
	snprintf(p->label, sizeof(p->label), "%s", label && *label ? label : p->stem);
	if (snprintf(p->path, sizeof(p->path), "%s/%s", dir, file) >= (int)sizeof(p->path) ||
	    stat(p->path, &st) || !S_ISREG(st.st_mode) || st.st_size != FIR_BYTES)
		return;
	for (j = 0; j < npresets; j++)	/* an earlier (user) entry wins */
		if (same_name(presets[j].label, p->label) || !strcmp(presets[j].stem, p->stem))
			return;
	npresets++;
}

/* the string value of "key" between b and e; JSON escapes \" \\ \/ handled */
static int json_str(const char *b, const char *e, const char *key, char *out, size_t len)
{
	size_t kl = strlen(key), n = 0;
	const char *q;

	for (q = b; q + kl + 2 < e; q++) {
		if (q[0] != '"' || strncmp(q + 1, key, kl) || q[kl + 1] != '"')
			continue;
		q += kl + 2;
		while (q < e && (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r' || *q == ':'))
			q++;
		if (q >= e || *q != '"')
			return -1;
		for (q++; q < e && *q != '"'; q++) {
			if (*q == '\\' && q + 1 < e)
				q++;
			if (n + 1 < len)
				out[n++] = *q;
		}
		out[n] = 0;
		return 0;
	}
	return -1;
}

static void scan_filter_json(const char *dir)
{
	char path[PATH_MAX], title[128], fpath[PATH_MAX], *buf, *o, *c;
	FILE *f;
	size_t n;

	snprintf(path, sizeof(path), "%s/filter.json", dir);
	f = fopen(path, "re");
	if (!f)
		return;
	buf = calloc(1, 256 * 1024);
	n = buf ? fread(buf, 1, 256 * 1024 - 1, f) : 0;
	fclose(f);
	for (o = n ? strchr(buf, '[') : NULL; o && (o = strchr(o, '{')); o = c + 1) {
		const char *file;

		c = strchr(o, '}');
		if (!c)
			break;
		if (json_str(o, c, "path", fpath, sizeof(fpath)))
			continue;
		if (json_str(o, c, "title", title, sizeof(title)))
			title[0] = 0;
		file = strrchr(fpath, '/');
		add_preset(dir, file ? file + 1 : fpath, title);
	}
	free(buf);
}

static void scan_dir(const char *dir)
{
	struct dirent **ents;
	int n, i;

	scan_filter_json(dir);
	n = scandir(dir, &ents, NULL, alphasort);
	if (n < 0)
		return;
	for (i = 0; i < n; i++) {
		add_preset(dir, ents[i]->d_name, NULL);
		free(ents[i]);
	}
	free(ents);
}

static void scan_presets(void)
{
	const char *env = getenv("DARWINCTL_PRESETS"), *home = getenv("HOME");
	const char *dh = getenv("XDG_DATA_HOME"), *dd = getenv("XDG_DATA_DIRS");
	char dir[PATH_MAX], *copy, *tok, *save = NULL;

	if (env && *env) {	/* tests: exactly this directory */
		scan_dir(env);
		return;
	}
	if (dh && *dh)
		snprintf(dir, sizeof(dir), "%s/hiby-rs6/darwin", dh);
	else
		snprintf(dir, sizeof(dir), "%s/.local/share/hiby-rs6/darwin", home ? home : "");
	scan_dir(dir);
	copy = strdup(dd && *dd ? dd : "/usr/local/share:/usr/share");
	for (tok = copy ? strtok_r(copy, ":", &save) : NULL; tok; tok = strtok_r(NULL, ":", &save)) {
		snprintf(dir, sizeof(dir), "%s/hiby-rs6/darwin", tok);
		scan_dir(dir);
	}
	free(copy);
}

static const struct preset *find_preset(const char *name)
{
	int i;

	for (i = 0; i < npresets; i++)
		if (same_name(presets[i].label, name) || same_name(presets[i].stem, name))
			return &presets[i];
	return NULL;
}

/* ---- names as people read them ---- */

/* the stock output_select names, as the old RS6 DAC app labelled them (and the KCM does) */
static const char *const output_labels[][2] = {
	{ "Auto", "Auto" },
	{ "Lineout", "3.5 mm line out" },
	{ "Headset", "3.5 mm" },
	{ "Balance", "4.4 mm balanced" },
	{ "BalanceLo", "4.4 mm balanced line out" },
	{ "Spdif", "S/PDIF" },
};

/* stock Settings' "DSD filter": Darwin Default is the DSD design, Darwin 1 the PCM one */
static const char *const dsd_mode_labels[][2] = {
	{ "mdsd", "Darwin Default" },
	{ "dsd", "Darwin 1" },
};

static void make_label(int c, const char *item, char *out, size_t len)
{
	size_t i;

	if (c == C_OUTPUT || c == C_TARGET) {
		for (i = 0; i < sizeof(output_labels) / sizeof(output_labels[0]); i++)
			if (!strcmp(item, output_labels[i][0])) {
				snprintf(out, len, "%s", output_labels[i][1]);
				return;
			}
	} else if (c == C_DSD_MODE) {
		for (i = 0; i < sizeof(dsd_mode_labels) / sizeof(dsd_mode_labels[0]); i++)
			if (!strcmp(item, dsd_mode_labels[i][0])) {
				snprintf(out, len, "%s", dsd_mode_labels[i][1]);
				return;
			}
	} else if (c == C_FILTER) {
		/* "short_delay_sharp_roll_off" -> "Short delay sharp roll off", as the KCM shows it */
		if (!strcmp(item, "custom")) {
			snprintf(out, len, "Darwin filter");
			return;
		}
		for (i = 0; item[i] && i + 1 < len; i++)
			out[i] = item[i] == '_' ? ' ' : i ? tolower((unsigned char)item[i]) :
				 toupper((unsigned char)item[i]);
		out[i] = 0;
		return;
	}
	snprintf(out, len, "%s", item);
}

/* ---- ALSA: the card with the hm100 "NOS Switch" ---- */

static int find_elem(snd_ctl_elem_list_t *list, const char *name, snd_ctl_elem_id_t **out)
{
	unsigned int i;

	for (i = 0; i < snd_ctl_elem_list_get_used(list); i++) {
		if (strcmp(snd_ctl_elem_list_get_name(list, i), name))
			continue;
		snd_ctl_elem_id_malloc(out);
		snd_ctl_elem_list_get_id(list, i, *out);
		return 0;
	}
	return -ENOENT;
}

static void drop_elem(int c)
{
	if (elems[c].id)
		snd_ctl_elem_id_free(elems[c].id);
	memset(&elems[c], 0, sizeof(elems[c]));
}

static void close_dac(void)
{
	int c;

	for (c = 0; c < NCTL; c++)
		drop_elem(c);
	custom_idx = -1;
	if (ctl)
		snd_ctl_close(ctl);
	ctl = NULL;
}

/* type, range and items of one control; a control of an unexpected type counts as missing */
static int read_info(int c)
{
	struct elem *e = &elems[c];
	snd_ctl_elem_info_t *info;
	int i, r;

	snd_ctl_elem_info_alloca(&info);
	snd_ctl_elem_info_set_id(info, e->id);
	r = snd_ctl_elem_info(ctl, info);
	if (r < 0)
		return r;
	if (snd_ctl_elem_info_get_type(info) != defs[c].type)
		return -EINVAL;
	e->numid = snd_ctl_elem_info_get_numid(info);
	if (defs[c].type == SND_CTL_ELEM_TYPE_INTEGER) {
		e->min = snd_ctl_elem_info_get_min(info);
		e->max = snd_ctl_elem_info_get_max(info);
	} else if (defs[c].type == SND_CTL_ELEM_TYPE_BOOLEAN) {
		e->min = 0;
		e->max = 1;
	}
	if (defs[c].type != SND_CTL_ELEM_TYPE_ENUMERATED)
		return 0;
	e->nitems = snd_ctl_elem_info_get_items(info);
	if (e->nitems > MAX_ITEMS)
		e->nitems = MAX_ITEMS;
	for (i = 0; i < e->nitems; i++) {
		snd_ctl_elem_info_set_item(info, i);
		r = snd_ctl_elem_info(ctl, info);
		if (r < 0)
			return r;
		snprintf(e->items[i], sizeof(e->items[i]), "%s", snd_ctl_elem_info_get_item_name(info));
		make_label(c, e->items[i], e->labels[i], sizeof(e->labels[i]));
		if (c == C_FILTER && !strcmp(e->items[i], "custom"))
			custom_idx = i;
	}
	return 0;
}

static int try_open(const char *name, int mode)
{
	snd_ctl_elem_list_t *list;
	int c;

	if (snd_ctl_open(&ctl, name, mode) < 0) {
		ctl = NULL;
		return -ENODEV;
	}
	snd_ctl_elem_list_malloc(&list);
	if (snd_ctl_elem_list(ctl, list) < 0 ||
	    snd_ctl_elem_list_alloc_space(list, snd_ctl_elem_list_get_count(list)) < 0 ||
	    snd_ctl_elem_list(ctl, list) < 0) {
		snd_ctl_elem_list_free(list);
		close_dac();
		return -ENODEV;
	}
	for (c = 0; c < NCTL; c++)
		find_elem(list, defs[c].name, &elems[c].id);
	snd_ctl_elem_list_free_space(list);
	snd_ctl_elem_list_free(list);
	if (!elems[C_NOS].id || !elems[C_FILTER].id || !elems[C_FIR].id) {
		close_dac();
		return -ENODEV;
	}
	for (c = 0; c < NCTL; c++) {
		if (!elems[c].id || !read_info(c))
			continue;
		if (c <= C_FIR) {	/* the card is there, but its filter controls are not usable */
			close_dac();
			return -EIO;
		}
		drop_elem(c);
	}
	snprintf(ctl_name, sizeof(ctl_name), "%s", name);
	return 0;
}

/* DARWINCTL_CTL names the control device (tests: the emulated hm100), else every hw: card */
static int open_dac(int mode)
{
	const char *env = getenv("DARWINCTL_CTL");
	int card = -1, r;

	if (env && *env)
		return try_open(env, mode);
	while (snd_card_next(&card) >= 0 && card >= 0) {
		char hw[16];

		snprintf(hw, sizeof(hw), "hw:%d", card);
		r = try_open(hw, mode);
		if (r != -ENODEV)
			return r;
	}
	return -ENODEV;
}

/* a boolean, enumerated or integer control's (first) value */
static int get_ctl(int c, long *val)
{
	snd_ctl_elem_value_t *v;
	int r;

	if (!elems[c].id)
		return -ENOENT;
	snd_ctl_elem_value_alloca(&v);
	snd_ctl_elem_value_set_id(v, elems[c].id);
	r = snd_ctl_elem_read(ctl, v);
	if (r < 0)
		return r;
	switch (defs[c].type) {
	case SND_CTL_ELEM_TYPE_BOOLEAN:
		*val = snd_ctl_elem_value_get_boolean(v, 0);
		break;
	case SND_CTL_ELEM_TYPE_ENUMERATED:
		*val = snd_ctl_elem_value_get_enumerated(v, 0);
		break;
	default:
		*val = snd_ctl_elem_value_get_integer(v, 0);
		break;
	}
	return 0;
}

static int set_ctl(int c, long val)
{
	snd_ctl_elem_value_t *v;

	if (!elems[c].id)
		return -ENOENT;
	snd_ctl_elem_value_alloca(&v);
	snd_ctl_elem_value_set_id(v, elems[c].id);
	switch (defs[c].type) {
	case SND_CTL_ELEM_TYPE_BOOLEAN:
		snd_ctl_elem_value_set_boolean(v, 0, val);
		break;
	case SND_CTL_ELEM_TYPE_ENUMERATED:
		snd_ctl_elem_value_set_enumerated(v, 0, val);
		break;
	default:
		snd_ctl_elem_value_set_integer(v, 0, val);
		break;
	}
	return snd_ctl_elem_write(ctl, v);
}

static int get_filter(void)
{
	long v;
	int r = get_ctl(C_FILTER, &v);

	return r < 0 ? r : (int)v;
}

static int set_filter(int idx)
{
	return set_ctl(C_FILTER, idx);
}

/* snd_ctl_elem_tlv_write() container: type (unused by the driver), length in bytes, taps */
static int write_fir(const unsigned char *taps)
{
	unsigned int tlv[2 + FIR_BYTES / sizeof(unsigned int)];

	tlv[0] = 0;
	tlv[1] = FIR_BYTES;
	memcpy(tlv + 2, taps, FIR_BYTES);
	return snd_ctl_elem_tlv_write(ctl, elems[C_FIR].id, tlv);
}

/* ---- state ---- */

static int read_file(const char *path, unsigned char *buf, size_t len)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	struct stat st;
	ssize_t n;

	if (fd < 0)
		return -errno;
	if (fstat(fd, &st) || (size_t)st.st_size != len) {
		close(fd);
		return -EINVAL;
	}
	n = read(fd, buf, len);
	close(fd);
	return n == (ssize_t)len ? 0 : -EIO;
}

static int write_atomic(const char *dir, const char *file, const void *buf, size_t len)
{
	char tmp[PATH_MAX], dst[PATH_MAX];
	int fd, ok;

	snprintf(dst, sizeof(dst), "%s/%s", dir, file);
	snprintf(tmp, sizeof(tmp), "%s/.%s.tmp", dir, file);
	fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0664);
	if (fd < 0)
		return -errno;
	ok = write(fd, buf, len) == (ssize_t)len && !fsync(fd);
	close(fd);
	if (!ok || rename(tmp, dst)) {
		unlink(tmp);
		return -EIO;
	}
	return 0;
}

static void saved_name(char *name, size_t len)
{
	char path[PATH_MAX];
	FILE *f;

	name[0] = 0;
	snprintf(path, sizeof(path), "%s/name", state_dir());
	f = fopen(path, "re");
	if (!f)
		return;
	if (fgets(name, len, f))
		name[strcspn(name, "\n")] = 0;
	fclose(f);
}

static int save_state(const unsigned char *taps, const char *name)
{
	char line[160];
	int r;

	snprintf(line, sizeof(line), "%s\n", name);
	r = write_atomic(state_dir(), "filter.flt", taps, FIR_BYTES);
	if (!r)
		r = write_atomic(state_dir(), "name", line, strlen(line));
	return r;
}

/* ---- the whole state: status, status --json, monitor ---- */

struct state {
	long v[NCTL];
	int ok[NCTL];			/* read back */
	char name[128];			/* the saved Darwin filter's name */
	const struct preset *darwin;	/* the saved one among the Darwin filters */
};

static void read_state(struct state *s)
{
	int c;

	memset(s, 0, sizeof(*s));
	for (c = 0; c < NCTL; c++)
		if (c != C_FIR)
			s->ok[c] = elems[c].id && !get_ctl(c, &s->v[c]);
	saved_name(s->name, sizeof(s->name));
	/* as in list: a preset is the active one when the saved name is its title */
	s->darwin = s->name[0] ? find_preset(s->name) : NULL;
	if (s->darwin && strcmp(s->darwin->label, s->name))
		s->darwin = NULL;
}

static const char *item_name(const struct state *s, int c)
{
	return s->ok[c] && s->v[c] >= 0 && s->v[c] < elems[c].nitems ? elems[c].items[s->v[c]] : "?";
}

static const char *item_label(const struct state *s, int c)
{
	return s->ok[c] && s->v[c] >= 0 && s->v[c] < elems[c].nitems ? elems[c].labels[s->v[c]] : "?";
}

/* tenths of a dB: "+3.5 dB", "0.0 dB", "-95.5 dB" */
static const char *db_text(long tenths, char *out, size_t len)
{
	long a = tenths < 0 ? -tenths : tenths;

	snprintf(out, len, "%s%ld.%ld dB", tenths < 0 ? "-" : tenths > 0 ? "+" : "", a / 10, a % 10);
	return out;
}

/* LR Balance: 0.5 dB steps, < 0 raises the left channel, > 0 the right one */
static const char *balance_text(long v, char *out, size_t len)
{
	char db[32];

	if (!v)
		snprintf(out, len, "center");
	else
		snprintf(out, len, "%c %s", v < 0 ? 'L' : 'R', db_text((v < 0 ? -v : v) * 5, db, sizeof(db)));
	return out;
}

static const char *idle_text(long v, char *out, size_t len)
{
	if (!v)
		snprintf(out, len, "never");
	else
		snprintf(out, len, "%ld s", v);
	return out;
}

static void json_string(FILE *f, const char *s)
{
	fputc('"', f);
	for (; *s; s++) {
		unsigned char ch = *s;

		if (ch == '"' || ch == '\\')
			fprintf(f, "\\%c", ch);
		else if (ch == '\n')
			fputs("\\n", f);
		else if (ch == '\t')
			fputs("\\t", f);
		else if (ch < 0x20)
			fprintf(f, "\\u%04x", ch);
		else
			fputc(ch, f);
	}
	fputc('"', f);
}

static void json_tenths(FILE *f, long tenths)
{
	long a = tenths < 0 ? -tenths : tenths;

	fprintf(f, "%s%ld.%ld", tenths < 0 ? "-" : "", a / 10, a % 10);
}

/* "key":{index,name,label} or null, then "items":[{name,label}, ...] */
static void json_enum(FILE *f, const struct state *s, const char *key, const char *items, int c)
{
	int i;

	fprintf(f, ",\"%s\":", key);
	if (!s->ok[c]) {
		fputs("null", f);
	} else {
		fprintf(f, "{\"index\":%ld,\"name\":", s->v[c]);
		json_string(f, item_name(s, c));
		fputs(",\"label\":", f);
		json_string(f, item_label(s, c));
		fputc('}', f);
	}
	fprintf(f, ",\"%s\":[", items);
	for (i = 0; s->ok[c] && i < elems[c].nitems; i++) {
		fputs(i ? ",{\"name\":" : "{\"name\":", f);
		json_string(f, elems[c].items[i]);
		fputs(",\"label\":", f);
		json_string(f, elems[c].labels[i]);
		fputc('}', f);
	}
	fputc(']', f);
}

/* an integer control: {value,min,max} (+ db, with tenths of a dB per unit) or null */
static void json_int(FILE *f, const struct state *s, const char *key, int c, int tenths)
{
	fprintf(f, ",\"%s\":", key);
	if (!s->ok[c]) {
		fputs("null", f);
		return;
	}
	fprintf(f, "{\"value\":%ld,\"min\":%ld,\"max\":%ld", s->v[c], elems[c].min, elems[c].max);
	if (tenths) {
		fputs(",\"db\":", f);
		json_tenths(f, s->v[c] * tenths);
	}
	fputc('}', f);
}

static void json_state(FILE *f, const struct state *s)
{
	int custom = s->ok[C_FILTER] && s->v[C_FILTER] == custom_idx, i;
	const char *dname = s->darwin ? s->darwin->label : s->name[0] ? s->name : "custom";

	fputs("{\"available\":true,\"card\":", f);
	json_string(f, ctl_name);
	fprintf(f, ",\"nos\":%s", s->ok[C_NOS] ? (s->v[C_NOS] ? "true" : "false") : "null");
	json_enum(f, s, "output", "outputs", C_OUTPUT);
	json_enum(f, s, "target", "targets", C_TARGET);
	json_enum(f, s, "gain", "gains", C_GAIN);

	/* filter: the built-in one, or the Darwin filter (custom) under its own name */
	fputs(",\"filter\":", f);
	if (!s->ok[C_FILTER]) {
		fputs("null", f);
	} else {
		fprintf(f, "{\"index\":%ld,\"name\":", s->v[C_FILTER]);
		json_string(f, item_name(s, C_FILTER));
		fputs(",\"label\":", f);
		json_string(f, custom ? dname : item_label(s, C_FILTER));
		fprintf(f, ",\"darwin\":%s}", custom ? "true" : "false");
	}
	fprintf(f, ",\"custom_index\":%d,\"filters\":[", custom_idx);
	for (i = 0; i < nfilters; i++) {
		fputs(i ? ",{\"name\":" : "{\"name\":", f);
		json_string(f, filter_names[i]);
		fputs(",\"label\":", f);
		json_string(f, elems[C_FILTER].labels[i]);
		fputc('}', f);
	}
	/*
	 * darwin: the Darwin filter that custom is (the saved one), active while custom is
	 * selected; index into darwin_filters, -1 for a loaded file that is none of them
	 */
	fputs("],\"darwin\":", f);
	if (!s->name[0] && !custom) {
		fputs("null", f);
	} else {
		fprintf(f, "{\"active\":%s,\"index\":%d,\"title\":", custom ? "true" : "false",
			s->darwin ? (int)(s->darwin - presets) : -1);
		json_string(f, dname);
		fputs(",\"path\":", f);
		if (s->darwin)
			json_string(f, s->darwin->path);
		else
			fputs("null", f);
		fputc('}', f);
	}
	fputs(",\"darwin_filters\":[", f);
	for (i = 0; i < npresets; i++) {
		fputs(i ? ",{\"title\":" : "{\"title\":", f);
		json_string(f, presets[i].label);
		fputs(",\"name\":", f);
		json_string(f, presets[i].stem);
		fputs(",\"path\":", f);
		json_string(f, presets[i].path);
		fputc('}', f);
	}
	fputc(']', f);
	json_int(f, s, "pregain", C_PREGAIN, 1);
	json_int(f, s, "balance", C_BALANCE, 5);
	json_int(f, s, "idle_off", C_IDLE, 0);
	json_enum(f, s, "dsd_mode", "dsd_modes", C_DSD_MODE);
	json_int(f, s, "dsd_compensate", C_DSD_COMP, 5);
	fputs("}\n", f);
}

/* ---- commands ---- */

static const char *base_name(const char *path, char *out, size_t len)
{
	const char *b = strrchr(path, '/');
	size_t n;

	b = b ? b + 1 : path;
	n = strlen(b);
	if (n > 4 && !strcmp(b + n - 4, ".flt"))
		n -= 4;
	snprintf(out, len, "%.*s", (int)n, b);
	return out;
}

/* the Darwin filters (and a loaded file that is none of them), * = active */
static void list_darwin(int porcelain, int cur, const char *name)
{
	int i;

	for (i = 0; i < npresets; i++) {
		const struct preset *p = &presets[i];
		int on = (ctl && cur == custom_idx) && !strcmp(name, p->label);

		if (porcelain)
			printf("preset\t%s\t%s\t%d\t%s\n", p->path, p->label, on, p->stem);
		else if (strcmp(p->label, p->stem))
			printf("%c %-16s %s\n", on ? '*' : ' ', p->label, p->stem);
		else
			printf("%c %s\n", on ? '*' : ' ', p->label);
	}
	if ((ctl && cur == custom_idx) && !find_preset(name)) {
		if (porcelain)
			printf("file\t-\t%s\t1\n", name[0] ? name : "custom");
		else
			printf("* %s (loaded file)\n", name[0] ? name : "custom");
	}
}

static int cmd_list(int porcelain)
{
	int cur = ctl ? get_filter() : -1, i;	/* without the DAC: just the filters there are */
	char name[128];

	saved_name(name, sizeof(name));
	for (i = 0; i < nfilters; i++) {
		if (i == custom_idx)
			continue;
		if (porcelain)
			printf("builtin\t%d\t%s\t%d\n", i, filter_names[i], i == cur);
		else
			printf("%c %s\n", i == cur ? '*' : ' ', filter_names[i]);
	}
	if (!porcelain && npresets)
		printf("Darwin filters:\n");
	list_darwin(porcelain, cur, name);
	return 0;
}

static int cmd_status(int json)
{
	struct state s;
	char a[64];
	long v;

	read_state(&s);
	if (!s.ok[C_FILTER] || !s.ok[C_NOS]) {
		int r = get_ctl(s.ok[C_FILTER] ? C_NOS : C_FILTER, &v);

		fprintf(stderr, "darwinctl: cannot read the DAC controls: %s\n", snd_strerror(r < 0 ? r : -EIO));
		return 1;
	}
	if (json) {
		json_state(stdout, &s);
		return 0;
	}
	if (s.v[C_FILTER] == custom_idx)
		printf("filter: %s (Darwin)\n", s.name[0] ? s.name : "custom");
	else
		printf("filter: %s\n", item_name(&s, C_FILTER));
	printf("NOS: %s%s\n", s.v[C_NOS] ? "on" : "off", s.v[C_NOS] ? " (the filter is bypassed)" : "");
	if (s.ok[C_OUTPUT] && s.ok[C_TARGET] && s.v[C_OUTPUT] == 0)
		printf("output: %s, now %s\n", item_label(&s, C_OUTPUT), item_label(&s, C_TARGET));
	else if (s.ok[C_OUTPUT])
		printf("output: %s\n", item_label(&s, C_OUTPUT));
	if (s.ok[C_GAIN])
		printf("gain: %s\n", item_label(&s, C_GAIN));
	if (s.ok[C_PREGAIN])
		printf("pregain: %s\n", db_text(s.v[C_PREGAIN], a, sizeof(a)));
	if (s.ok[C_BALANCE])
		printf("balance: %s\n", balance_text(s.v[C_BALANCE], a, sizeof(a)));
	if (s.ok[C_IDLE])
		printf("idle power off: %s\n", idle_text(s.v[C_IDLE], a, sizeof(a)));
	if (s.ok[C_DSD_MODE])
		printf("DSD filter: %s (%s)\n", item_label(&s, C_DSD_MODE), item_name(&s, C_DSD_MODE));
	if (s.ok[C_DSD_COMP])
		printf("DSD compensate: %s\n", db_text(s.v[C_DSD_COMP] * 5, a, sizeof(a)));
	return 0;
}

/*
 * The state goes first, so that whoever reacts to the "FIR Custom" event (darwinctl monitor)
 * already reads the new name; if the driver refuses the taps, the old state comes back.
 */
static int load_flt(const char *path, const char *name)
{
	unsigned char taps[FIR_BYTES], old[FIR_BYTES];
	char oldname[128], file[PATH_MAX];
	int r = read_file(path, taps, sizeof(taps)), had, saved;

	if (r) {
		fprintf(stderr, "darwinctl: %s: %s\n", path,
			r == -EINVAL ? "not a filter (a .flt has 1024 bytes, 256 taps)" : strerror(-r));
		return 1;
	}
	snprintf(file, sizeof(file), "%s/filter.flt", state_dir());
	had = !read_file(file, old, sizeof(old));
	saved_name(oldname, sizeof(oldname));
	saved = save_state(taps, name);
	r = write_fir(taps);
	if (r < 0) {
		fprintf(stderr, "darwinctl: loading %s failed: %s\n", name, snd_strerror(r));
		if (!saved && had) {
			save_state(old, oldname[0] ? oldname : "custom");
		} else if (!saved) {
			unlink(file);
			snprintf(file, sizeof(file), "%s/name", state_dir());
			unlink(file);
		}
		return 1;
	}
	if (saved)
		fprintf(stderr, "darwinctl: loaded, but not kept for the next boot (%s: %s)\n",
			state_dir(), strerror(-saved));
	return 0;
}

/* back to the last Darwin filter: the saved taps, else whatever the driver holds */
static int select_custom(void)
{
	char path[PATH_MAX], name[128];
	int r;

	snprintf(path, sizeof(path), "%s/filter.flt", state_dir());
	saved_name(name, sizeof(name));
	if (!access(path, R_OK))
		return load_flt(path, name[0] ? name : "custom");
	r = set_filter(custom_idx);
	return r < 0;
}

/* 1 when arg is a built-in filter (or custom), with the exit status in *ret */
static int set_builtin(const char *arg, int *ret)
{
	int i, r;

	for (i = 0; i < nfilters; i++) {
		if (i == custom_idx || !(same_name(arg, filter_names[i]) ||
					 same_name(arg, elems[C_FILTER].labels[i])))
			continue;
		r = set_filter(i);
		if (r < 0)
			fprintf(stderr, "darwinctl: %s\n", snd_strerror(r));
		*ret = r < 0;
		return 1;
	}
	if (custom_idx >= 0 && same_name(arg, "custom")) {
		*ret = select_custom();
		return 1;
	}
	return 0;
}

/* a Darwin filter by name, or a .flt file; -1: neither */
static int set_darwin(const char *arg)
{
	const struct preset *p = find_preset(arg);
	char name[128];

	if (p)
		return load_flt(p->path, p->label);
	if (!access(arg, R_OK))
		return load_flt(arg, base_name(arg, name, sizeof(name)));
	return -1;
}

static int cmd_set(const char *arg)
{
	int r;

	if (set_builtin(arg, &r))
		return r;
	r = set_darwin(arg);
	if (r >= 0)
		return r;
	fprintf(stderr, "darwinctl: no filter called '%s' (see darwinctl list)\n", arg);
	return 1;
}

/* filter: the built-in ones (custom: the Darwin filter) */
static int cmd_filter(const char *arg)
{
	char name[128];
	int cur, i, r;

	if (arg) {
		if (set_builtin(arg, &r))
			return r;
		fprintf(stderr, "darwinctl: no built-in filter called '%s' (see darwinctl filter;"
			" Darwin filters: darwinctl darwin)\n", arg);
		return 1;
	}
	cur = get_filter();
	saved_name(name, sizeof(name));
	for (i = 0; i < nfilters; i++)
		printf("%c %-26s %s%s%s\n", i == cur ? '*' : ' ', filter_names[i], elems[C_FILTER].labels[i],
		       i == custom_idx && name[0] ? ": " : "", i == custom_idx ? name : "");
	return 0;
}

/* darwin: the Darwin filters; with a name or a .flt file: load it */
static int cmd_darwin(const char *arg)
{
	char name[128];
	int r;

	if (custom_idx < 0) {
		fprintf(stderr, "darwinctl: this driver has no Darwin filter (no \"custom\" filter)\n");
		return 1;
	}
	if (arg) {
		if (same_name(arg, "custom"))
			return select_custom();
		r = set_darwin(arg);
		if (r >= 0)
			return r;
		fprintf(stderr, "darwinctl: no Darwin filter or .flt file called '%s' (see darwinctl darwin)\n",
			arg);
		return 1;
	}
	saved_name(name, sizeof(name));
	list_darwin(0, get_filter(), name);
	return 0;
}

static int need(int c)
{
	if (elems[c].id)
		return 0;
	fprintf(stderr, "darwinctl: this driver has no \"%s\" control\n", defs[c].name);
	return 1;
}

static int read_checked(int c, long *v)
{
	int r = get_ctl(c, v);

	if (r < 0)
		fprintf(stderr, "darwinctl: %s: %s\n", defs[c].name, snd_strerror(r));
	return r < 0;
}

static int write_checked(int c, long v)
{
	int r = set_ctl(c, v);

	if (r < 0)
		fprintf(stderr, "darwinctl: %s: %s\n", defs[c].name, snd_strerror(r));
	return r < 0;
}

/* an enumerated control: list it (* = current), or select an item by name, label or index */
static int cmd_enum(int c, const char *arg)
{
	struct elem *e = &elems[c];
	char *end;
	long cur;
	int i;

	if (need(c))
		return 1;
	if (!arg) {
		if (read_checked(c, &cur))
			return 1;
		for (i = 0; i < e->nitems; i++) {
			if (strcmp(e->items[i], e->labels[i]))
				printf("%c %-10s %s\n", i == cur ? '*' : ' ', e->items[i], e->labels[i]);
			else
				printf("%c %s\n", i == cur ? '*' : ' ', e->items[i]);
		}
		return 0;
	}
	for (i = 0; i < e->nitems; i++)
		if (same_name(arg, e->items[i]) || same_name(arg, e->labels[i]))
			return write_checked(c, i);
	i = strtol(arg, &end, 10);
	if (*arg && !*end && i >= 0 && i < e->nitems)
		return write_checked(c, i);
	fprintf(stderr, "darwinctl: %s has no '%s':", defs[c].name, arg);
	for (i = 0; i < e->nitems; i++)
		fprintf(stderr, " %s", e->items[i]);
	fputc('\n', stderr);
	return 1;
}

/* "-3.5", "+2", "1,5 dB" -> tenths of a dB, rounded to steps of step tenths */
static int parse_db(const char *s, int step, long *out)
{
	long whole = 0, frac = 0, div = 1, t;
	int neg = 0, digits = 0;

	while (isspace((unsigned char)*s))
		s++;
	if (*s == '+' || *s == '-')
		neg = *s++ == '-';
	for (; isdigit((unsigned char)*s); s++, digits++)
		if (whole < 100000)
			whole = whole * 10 + (*s - '0');
	if (*s == '.' || *s == ',')
		for (s++; isdigit((unsigned char)*s); s++, digits++)
			if (div < 1000) {
				frac = frac * 10 + (*s - '0');
				div *= 10;
			}
	while (isspace((unsigned char)*s))
		s++;
	if (!strncasecmp(s, "db", 2))
		s += 2;
	if (!digits || *s)
		return -EINVAL;
	t = whole * 100 + frac * 100 / div;		/* hundredths, then halves away from zero */
	t = (t + step * 5) / (step * 10) * step;
	*out = neg ? -t : t;
	return 0;
}

/* pregain [dB], 0.1 dB steps */
static int cmd_pregain(const char *arg)
{
	char a[32], b[32];
	long v;

	if (need(C_PREGAIN))
		return 1;
	if (!arg) {
		if (read_checked(C_PREGAIN, &v))
			return 1;
		printf("%s\n", db_text(v, a, sizeof(a)));
		return 0;
	}
	if (parse_db(arg, 1, &v)) {
		fprintf(stderr, "darwinctl: pregain in dB, e.g. -3.5\n");
		return 1;
	}
	if (v < elems[C_PREGAIN].min || v > elems[C_PREGAIN].max) {
		fprintf(stderr, "darwinctl: pregain goes from %s to %s\n",
			db_text(elems[C_PREGAIN].min, a, sizeof(a)), db_text(elems[C_PREGAIN].max, b, sizeof(b)));
		return 1;
	}
	return write_checked(C_PREGAIN, v);
}

/* dsd-compensate [dB], 0.5 dB steps */
static int cmd_dsd_comp(const char *arg)
{
	char a[32], b[32];
	long v;

	if (need(C_DSD_COMP))
		return 1;
	if (!arg) {
		if (read_checked(C_DSD_COMP, &v))
			return 1;
		printf("%s\n", db_text(v * 5, a, sizeof(a)));
		return 0;
	}
	if (parse_db(arg, 5, &v)) {
		fprintf(stderr, "darwinctl: DSD compensate in dB (0.5 dB steps), e.g. +3\n");
		return 1;
	}
	v /= 5;
	if (v < elems[C_DSD_COMP].min || v > elems[C_DSD_COMP].max) {
		fprintf(stderr, "darwinctl: DSD compensate goes from %s to %s\n",
			db_text(elems[C_DSD_COMP].min * 5, a, sizeof(a)),
			db_text(elems[C_DSD_COMP].max * 5, b, sizeof(b)));
		return 1;
	}
	return write_checked(C_DSD_COMP, v);
}

/* balance [center | L<dB> | R<dB> | signed dB, < 0 raises the left channel], 0.5 dB steps */
static int cmd_balance(const char *arg)
{
	int side = 0;
	char a[32];
	long v;

	if (need(C_BALANCE))
		return 1;
	if (!arg) {
		if (read_checked(C_BALANCE, &v))
			return 1;
		printf("%s\n", balance_text(v, a, sizeof(a)));
		return 0;
	}
	if (same_name(arg, "center") || same_name(arg, "centre") || same_name(arg, "c")) {
		v = 0;
	} else {
		if (!strncasecmp(arg, "left", 4) || !strncasecmp(arg, "right", 5)) {
			side = tolower((unsigned char)*arg) == 'l' ? -1 : 1;
			arg += side < 0 ? 4 : 5;
		} else if (*arg && strchr("LlRr", *arg)) {
			side = tolower((unsigned char)*arg) == 'l' ? -1 : 1;
			arg++;
		}
		if (parse_db(arg, 5, &v) || (side && v < 0)) {
			fprintf(stderr, "darwinctl: balance: center, L<dB> or R<dB> (0.5 dB steps), e.g. L1.5\n");
			return 1;
		}
		v = (side ? side * v : v) / 5;
	}
	if (v < elems[C_BALANCE].min || v > elems[C_BALANCE].max) {
		fprintf(stderr, "darwinctl: balance goes up to %s on either side\n",
			db_text(elems[C_BALANCE].max * 5, a, sizeof(a)));
		return 1;
	}
	return write_checked(C_BALANCE, v);
}

/* idle-off [seconds | never] */
static int cmd_idle(const char *arg)
{
	char a[32], *end;
	long v;

	if (need(C_IDLE))
		return 1;
	if (!arg) {
		if (read_checked(C_IDLE, &v))
			return 1;
		printf("%s\n", idle_text(v, a, sizeof(a)));
		return 0;
	}
	if (same_name(arg, "never") || same_name(arg, "off")) {
		v = 0;
	} else {
		v = strtol(arg, &end, 10);
		if (end == arg || (*end && strcmp(end, "s")))
			v = -1;
	}
	if (v < elems[C_IDLE].min || v > elems[C_IDLE].max) {
		fprintf(stderr, "darwinctl: idle power off: %ld to %ld seconds, or never\n",
			elems[C_IDLE].min ? elems[C_IDLE].min : 1, elems[C_IDLE].max);
		return 1;
	}
	return write_checked(C_IDLE, v);
}

static int cmd_nos(const char *arg)
{
	long v;
	int r;

	if (!arg) {
		if (read_checked(C_NOS, &v))
			return 1;
		printf("%s\n", v ? "on" : "off");
		return 0;
	}
	r = set_ctl(C_NOS, !strcmp(arg, "on"));
	if (r < 0)
		fprintf(stderr, "darwinctl: %s\n", snd_strerror(r));
	return r < 0;
}

/* boot: alsactl restored "Digital Filter"; if that is custom, put the saved taps back */
static int cmd_restore(void)
{
	unsigned char taps[FIR_BYTES];
	char path[PATH_MAX];
	int r;

	if (custom_idx < 0 || get_filter() != custom_idx)
		return 0;
	snprintf(path, sizeof(path), "%s/filter.flt", state_dir());
	if (read_file(path, taps, sizeof(taps)))
		return 0;	/* nothing saved: keep the driver's default set */
	r = write_fir(taps);
	if (r < 0) {
		fprintf(stderr, "darwinctl: restoring the saved filter failed: %s\n", snd_strerror(r));
		return 1;
	}
	return 0;
}

/* ---- monitor ---- */

/*
 * inotify: /dev/snd for the card (a controlC* node, then its permissions from udev), /dev until
 * /dev/snd exists. The Darwin filter's name needs no watch: load_flt saves it before the taps
 * go in, so it is there when the "FIR Custom" event comes.
 */
static int wd_snd = -1, wd_dev = -1;

static void watch_dirs(int in)
{
	if (wd_snd < 0)
		wd_snd = inotify_add_watch(in, "/dev/snd", IN_CREATE | IN_ATTRIB | IN_MOVED_TO);
	if (wd_snd < 0 && wd_dev < 0)
		wd_dev = inotify_add_watch(in, "/dev", IN_CREATE | IN_MOVED_TO | IN_ONLYDIR);
	if (wd_snd >= 0 && wd_dev >= 0) {
		inotify_rm_watch(in, wd_dev);
		wd_dev = -1;
	}
}

static void read_inotify(int in)
{
	char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
	ssize_t n;

	while ((n = read(in, buf, sizeof(buf))) > 0) {
		char *p;

		for (p = buf; p < buf + n;) {
			struct inotify_event *ev = (struct inotify_event *)p;

			if (ev->mask & IN_IGNORED) {	/* the directory went away */
				if (ev->wd == wd_snd)
					wd_snd = -1;
				if (ev->wd == wd_dev)
					wd_dev = -1;
			}
			p += sizeof(*ev) + ev->len;
		}
	}
}

/* the state as one line, if it is not the line printed last */
static void print_state(void)
{
	static char *last;
	struct state s;
	char *buf = NULL;
	size_t len = 0;
	FILE *f = open_memstream(&buf, &len);

	if (!f)
		return;
	if (ctl) {
		read_state(&s);
		json_state(f, &s);
	} else {
		fputs("{\"available\":false}\n", f);
	}
	fclose(f);
	if (last && !strcmp(last, buf)) {
		free(buf);
		return;
	}
	fputs(buf, stdout);
	fflush(stdout);
	free(last);
	last = buf;
}

/* all queued control events: 0 none of ours, 1 one of ours changed, -1 the card is gone */
static int read_ctl_events(void)
{
	snd_ctl_event_t *ev;
	int mine = 0, r, c;

	snd_ctl_event_alloca(&ev);
	while ((r = snd_ctl_read(ctl, ev)) > 0) {
		unsigned int numid, mask;

		if (snd_ctl_event_get_type(ev) != SND_CTL_EVENT_ELEM)
			continue;
		numid = snd_ctl_event_elem_get_numid(ev);
		mask = snd_ctl_event_elem_get_mask(ev);
		for (c = 0; c < NCTL; c++)
			if (elems[c].id && elems[c].numid == numid)
				break;
		if (c == NCTL)
			continue;	/* not ours (e.g. the playback volume) */
		if (mask == SND_CTL_EVENT_MASK_REMOVE)
			return -1;
		if ((mask & SND_CTL_EVENT_MASK_INFO) && read_info(c))
			return -1;
		mine = 1;
	}
	return r < 0 && r != -EAGAIN ? -1 : mine;
}

/*
 * One JSON line with the whole state now and after every change: control events of the hm100
 * controls (several at once, e.g. Output + Output Target, give one line), the card going away
 * ({"available":false}) and coming back. It waits in poll() for both.
 */
static int cmd_monitor(void)
{
	const char *fixed = getenv("DARWINCTL_CTL");
	int in = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	struct pollfd fds[16];

	if (in < 0) {
		fprintf(stderr, "darwinctl: inotify: %s\n", strerror(errno));
		return 1;
	}
	for (;;) {
		int n = 1, r;

		watch_dirs(in);		/* first, so that a card showing up now is not missed */
		if (!ctl && !open_dac(SND_CTL_NONBLOCK) && snd_ctl_subscribe_events(ctl, 1) < 0)
			close_dac();
		print_state();
		if (!ctl && fixed && *fixed)
			return 1;	/* a named control device has no hotplug to wait for */
		fds[0].fd = in;
		fds[0].events = POLLIN;
		if (ctl) {
			r = snd_ctl_poll_descriptors(ctl, fds + 1, 15);
			n += r > 0 ? r : 0;
		}
		while (poll(fds, n, -1) < 0)
			if (errno != EINTR)
				return 1;
		if (fds[0].revents)
			read_inotify(in);
		if (ctl && n > 1) {
			unsigned short rev = 0;

			snd_ctl_poll_descriptors_revents(ctl, fds + 1, n - 1, &rev);
			if ((rev & (POLLERR | POLLHUP | POLLNVAL)) || ((rev & POLLIN) && read_ctl_events() < 0))
				close_dac();
		}
	}
}

static void usage(FILE *f)
{
	fprintf(f,
		"usage: darwinctl [status] [--json]   everything (--json: as one JSON object)\n"
		"       darwinctl monitor             the JSON state now and after every change, a line each\n"
		"       darwinctl list [--porcelain]  built-in and Darwin filters, * = active\n"
		"       darwinctl set <filter>        built-in name, Darwin filter name, a .flt file, or\n"
		"                                    custom (the last Darwin filter again)\n"
		"       darwinctl filter [<name>]     built-in filters (custom: the last Darwin filter)\n"
		"       darwinctl darwin [<name>|<file.flt>]  Darwin filters: select or load one\n"
		"       darwinctl nos [on|off]        non-oversampling (bypasses the filter)\n"
		"       darwinctl output [<output>]   Auto (follows the jacks), Lineout, Headset, Balance,\n"
		"                                    BalanceLo, Spdif (or 3.5 mm, 4.4 mm balanced, ...)\n"
		"       darwinctl target              where the sound goes now (read-only)\n"
		"       darwinctl gain [low|middle|high]\n"
		"       darwinctl pregain [<dB>]      e.g. -3.5 (0.1 dB steps; headphone outputs)\n"
		"       darwinctl balance [center|L<dB>|R<dB>]  raise one channel (0.5 dB steps)\n"
		"       darwinctl idle-off [<s>|never]  power the DAC off after this long without playback\n"
		"       darwinctl dsd-mode [mdsd|dsd]   DSD filter: Darwin Default (mdsd) or Darwin 1 (dsd)\n"
		"       darwinctl dsd-compensate [<dB>] level on DSD streams (0.5 dB steps)\n"
		"       darwinctl restore             load the saved Darwin filter again (boot)\n"
		"Without a value, a command prints the current one (lists: * = current). Darwin filters:\n"
		"~/.local/share/hiby-rs6/darwin, /usr/share/hiby-rs6/darwin (*.flt; a filter.json in\n"
		"stock Settings' format sets their order and names)\n");
}

int main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : "status", *arg = argc > 2 ? argv[2] : NULL;
	int r;

	if (!strcmp(cmd, "-h") || !strcmp(cmd, "--help") || !strcmp(cmd, "help")) {
		usage(stdout);
		return 0;
	}
	if (!strcmp(cmd, "--json") && argc == 2) {	/* darwinctl --json: status --json */
		cmd = "status";
		arg = "--json";
	}
	scan_presets();
	if (!strcmp(cmd, "monitor") && argc == 2)
		return cmd_monitor();
	r = open_dac(0);
	if (r < 0) {
		ctl = NULL;
		if (!strcmp(cmd, "status") && arg && !strcmp(arg, "--json") && argc <= 3) {
			printf("{\"available\":false}\n");
			return 1;
		}
		fprintf(stderr, "darwinctl: no RS6 DAC (hm100 controls) found\n");
		if (!strcmp(cmd, "list") && (argc == 2 || (argc == 3 && !strcmp(argv[2], "--porcelain"))))
			return cmd_list(argc == 3);
		return !strcmp(cmd, "restore") ? 0 : 1;	/* a boot without the card is not an error */
	}
	if (argc > 3)
		goto bad;
	if (!strcmp(cmd, "status") && (!arg || !strcmp(arg, "--json")))
		return cmd_status(arg != NULL);
	if (!strcmp(cmd, "list") && (!arg || !strcmp(arg, "--porcelain")))
		return cmd_list(arg != NULL);
	if (!strcmp(cmd, "set") && arg)
		return cmd_set(arg);
	if (!strcmp(cmd, "filter"))
		return cmd_filter(arg);
	if (!strcmp(cmd, "darwin"))
		return cmd_darwin(arg);
	if (!strcmp(cmd, "nos") && (!arg || !strcmp(arg, "on") || !strcmp(arg, "off")))
		return cmd_nos(arg);
	if (!strcmp(cmd, "output"))
		return cmd_enum(C_OUTPUT, arg);
	if (!strcmp(cmd, "target") && !arg)
		return cmd_enum(C_TARGET, NULL);
	if (!strcmp(cmd, "gain"))
		return cmd_enum(C_GAIN, arg);
	if (!strcmp(cmd, "pregain"))
		return cmd_pregain(arg);
	if (!strcmp(cmd, "balance"))
		return cmd_balance(arg);
	if (!strcmp(cmd, "idle-off"))
		return cmd_idle(arg);
	if (!strcmp(cmd, "dsd-mode"))
		return cmd_enum(C_DSD_MODE, arg);
	if (!strcmp(cmd, "dsd-compensate"))
		return cmd_dsd_comp(arg);
	if (!strcmp(cmd, "restore") && !arg)
		return cmd_restore();
bad:
	usage(stderr);
	return 2;
}
