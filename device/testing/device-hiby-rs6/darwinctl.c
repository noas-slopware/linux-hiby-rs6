// SPDX-License-Identifier: MIT
/*
 * darwinctl: pick the HiBy RS6 DAC filter (hm100 "Darwin" FPGA) from the command line.
 *
 * Built-in filters are the "Digital Filter" items of the hm100 driver (the stock kernel's
 * four coefficient sets, plus the stock names that have none). Darwin filters are .flt files
 * (256 int32 taps, 1024 bytes, as stock's filter_path): loading one goes into "FIR Custom",
 * which also selects the driver's "custom" item. The loaded taps and their name are kept in
 * the state directory so that `darwinctl restore` (darwinctl-restore.service, after
 * alsa-restore has put "Digital Filter" back) can load them again after a reboot.
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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define FIR_BYTES	1024
#define MAX_PRESETS	256
#define STATE_DIR	"/var/lib/hiby-rs6/darwin"	/* DARWINCTL_STATE overrides it */

struct preset {
	char label[128];	/* filter.json "title", else the file name */
	char stem[128];		/* file name without .flt */
	char path[PATH_MAX];
};

static struct preset presets[MAX_PRESETS];
static int npresets;

static snd_ctl_t *ctl;
static snd_ctl_elem_id_t *id_filter, *id_fir, *id_nos;
static char filter_names[16][64];
static int nfilters, custom_idx = -1;

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

static int open_dac(void)
{
	int card = -1;

	while (snd_card_next(&card) >= 0 && card >= 0) {
		snd_ctl_elem_list_t *list;
		snd_ctl_elem_info_t *info;
		char hw[16];
		int i, found;

		snprintf(hw, sizeof(hw), "hw:%d", card);
		if (snd_ctl_open(&ctl, hw, 0) < 0)
			continue;
		snd_ctl_elem_list_malloc(&list);
		if (snd_ctl_elem_list(ctl, list) < 0 ||
		    snd_ctl_elem_list_alloc_space(list, snd_ctl_elem_list_get_count(list)) < 0 ||
		    snd_ctl_elem_list(ctl, list) < 0) {
			snd_ctl_elem_list_free(list);
			snd_ctl_close(ctl);
			continue;
		}
		found = !find_elem(list, "NOS Switch", &id_nos) &&
			!find_elem(list, "Digital Filter", &id_filter) &&
			!find_elem(list, "FIR Custom", &id_fir);
		snd_ctl_elem_list_free_space(list);
		snd_ctl_elem_list_free(list);
		if (!found) {
			snd_ctl_close(ctl);
			continue;
		}
		snd_ctl_elem_info_malloc(&info);
		snd_ctl_elem_info_set_id(info, id_filter);
		if (snd_ctl_elem_info(ctl, info) < 0) {
			snd_ctl_elem_info_free(info);
			snd_ctl_close(ctl);
			return -EIO;
		}
		nfilters = snd_ctl_elem_info_get_items(info);
		if (nfilters > 16)
			nfilters = 16;
		for (i = 0; i < nfilters; i++) {
			snd_ctl_elem_info_set_item(info, i);
			snd_ctl_elem_info(ctl, info);
			snprintf(filter_names[i], sizeof(filter_names[i]), "%s",
				 snd_ctl_elem_info_get_item_name(info));
			if (!strcmp(filter_names[i], "custom"))
				custom_idx = i;
		}
		snd_ctl_elem_info_free(info);
		return 0;
	}
	return -ENODEV;
}

static int get_filter(void)
{
	snd_ctl_elem_value_t *v;
	int r;

	snd_ctl_elem_value_alloca(&v);
	snd_ctl_elem_value_set_id(v, id_filter);
	r = snd_ctl_elem_read(ctl, v);
	return r < 0 ? r : (int)snd_ctl_elem_value_get_enumerated(v, 0);
}

static int set_filter(int idx)
{
	snd_ctl_elem_value_t *v;

	snd_ctl_elem_value_alloca(&v);
	snd_ctl_elem_value_set_id(v, id_filter);
	snd_ctl_elem_value_set_enumerated(v, 0, idx);
	return snd_ctl_elem_write(ctl, v);
}

static int get_nos(void)
{
	snd_ctl_elem_value_t *v;
	int r;

	snd_ctl_elem_value_alloca(&v);
	snd_ctl_elem_value_set_id(v, id_nos);
	r = snd_ctl_elem_read(ctl, v);
	return r < 0 ? r : snd_ctl_elem_value_get_boolean(v, 0);
}

static int set_nos(int on)
{
	snd_ctl_elem_value_t *v;

	snd_ctl_elem_value_alloca(&v);
	snd_ctl_elem_value_set_id(v, id_nos);
	snd_ctl_elem_value_set_boolean(v, 0, on);
	return snd_ctl_elem_write(ctl, v);
}

/* snd_ctl_elem_tlv_write() container: type (unused by the driver), length in bytes, taps */
static int write_fir(const unsigned char *taps)
{
	unsigned int tlv[2 + FIR_BYTES / sizeof(unsigned int)];

	tlv[0] = 0;
	tlv[1] = FIR_BYTES;
	memcpy(tlv + 2, taps, FIR_BYTES);
	return snd_ctl_elem_tlv_write(ctl, id_fir, tlv);
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

static void save_state(const unsigned char *taps, const char *name)
{
	char line[160];
	int r;

	snprintf(line, sizeof(line), "%s\n", name);
	r = write_atomic(state_dir(), "filter.flt", taps, FIR_BYTES);
	if (!r)
		r = write_atomic(state_dir(), "name", line, strlen(line));
	if (r)
		fprintf(stderr, "darwinctl: loaded, but not kept for the next boot (%s: %s)\n",
			state_dir(), strerror(-r));
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
	return 0;
}

static int cmd_status(void)
{
	int cur = get_filter(), nos = get_nos();
	char name[128];

	if (cur < 0 || nos < 0) {
		fprintf(stderr, "darwinctl: cannot read the DAC controls: %s\n", snd_strerror(cur < 0 ? cur : nos));
		return 1;
	}
	saved_name(name, sizeof(name));
	if (cur == custom_idx)
		printf("filter: %s (Darwin)\n", name[0] ? name : "custom");
	else
		printf("filter: %s\n", filter_names[cur]);
	printf("NOS: %s%s\n", nos ? "on" : "off", nos ? " (the filter is bypassed)" : "");
	return 0;
}

static int load_flt(const char *path, const char *name)
{
	unsigned char taps[FIR_BYTES];
	int r = read_file(path, taps, sizeof(taps));

	if (r) {
		fprintf(stderr, "darwinctl: %s: %s\n", path,
			r == -EINVAL ? "not a filter (a .flt has 1024 bytes, 256 taps)" : strerror(-r));
		return 1;
	}
	r = write_fir(taps);
	if (r < 0) {
		fprintf(stderr, "darwinctl: loading %s failed: %s\n", name, snd_strerror(r));
		return 1;
	}
	save_state(taps, name);
	return 0;
}

static int cmd_set(const char *arg)
{
	const struct preset *p;
	char name[128];
	int i;

	for (i = 0; i < nfilters; i++) {
		if (i == custom_idx || !same_name(arg, filter_names[i]))
			continue;
		i = set_filter(i);
		if (i < 0) {
			fprintf(stderr, "darwinctl: %s\n", snd_strerror(i));
			return 1;
		}
		return 0;
	}
	if (custom_idx >= 0 && same_name(arg, "custom")) {
		char path[PATH_MAX];

		/* back to the last Darwin filter: the saved taps, else whatever the driver holds */
		snprintf(path, sizeof(path), "%s/filter.flt", state_dir());
		saved_name(name, sizeof(name));
		if (!access(path, R_OK))
			return load_flt(path, name[0] ? name : "custom");
		i = set_filter(custom_idx);
		return i < 0;
	}
	p = find_preset(arg);
	if (p)
		return load_flt(p->path, p->label);
	if (!access(arg, R_OK))
		return load_flt(arg, base_name(arg, name, sizeof(name)));
	fprintf(stderr, "darwinctl: no filter called '%s' (see darwinctl list)\n", arg);
	return 1;
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

static void usage(FILE *f)
{
	fprintf(f,
		"usage: darwinctl [status]           active filter and NOS\n"
		"       darwinctl list [--porcelain]  built-in and Darwin filters, * = active\n"
		"       darwinctl set <filter>        built-in name, Darwin filter name, a .flt file, or\n"
		"                                    custom (the last Darwin filter again)\n"
		"       darwinctl nos on|off          non-oversampling (bypasses the filter)\n"
		"       darwinctl restore             load the saved Darwin filter again (boot)\n"
		"Darwin filters: ~/.local/share/hiby-rs6/darwin, /usr/share/hiby-rs6/darwin (*.flt; a\n"
		"filter.json in stock Settings' format sets their order and names)\n");
}

int main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : "status";
	int r;

	if (!strcmp(cmd, "-h") || !strcmp(cmd, "--help") || !strcmp(cmd, "help")) {
		usage(stdout);
		return 0;
	}
	scan_presets();
	r = open_dac();
	if (r < 0) {
		ctl = NULL;
		fprintf(stderr, "darwinctl: no RS6 DAC (hm100 controls) found\n");
		if (!strcmp(cmd, "list") && (argc == 2 || (argc == 3 && !strcmp(argv[2], "--porcelain"))))
			return cmd_list(argc == 3);
		return !strcmp(cmd, "restore") ? 0 : 1;	/* a boot without the card is not an error */
	}
	if (!strcmp(cmd, "status") && argc <= 2)
		return cmd_status();
	if (!strcmp(cmd, "list") && (argc == 2 || (argc == 3 && !strcmp(argv[2], "--porcelain"))))
		return cmd_list(argc == 3);
	if (!strcmp(cmd, "set") && argc == 3)
		return cmd_set(argv[2]);
	if (!strcmp(cmd, "nos") && argc == 3 && (!strcmp(argv[2], "on") || !strcmp(argv[2], "off"))) {
		r = set_nos(!strcmp(argv[2], "on"));
		if (r < 0)
			fprintf(stderr, "darwinctl: %s\n", snd_strerror(r));
		return r < 0;
	}
	if (!strcmp(cmd, "restore") && argc == 2)
		return cmd_restore();
	usage(stderr);
	return 2;
}
