// SPDX-License-Identifier: MIT
/*
 * Touch boost for the HiBy RS6, the "input boost" Android kernels and HALs do: while a finger
 * is on the screen (and briefly after), raise the minimum CPU frequency of every cpufreq policy
 * and the minimum GPU frequency, so scrolling and animations don't wait for schedutil/devfreq
 * to ramp up from idle clocks. Writes happen only on boost on/off transitions.
 *
 * Plain Linux interfaces only (evdev, cpufreq and devfreq sysfs): libc-agnostic.
 *
 * It also moves the active session's processes onto the big cores: EAS keeps light, bursty UI
 * work (scrolling) on the A53s. On a touch every thread of every process in the seat's active user
 * session (logind's ACTIVE_UID in /run/systemd/seats/seat0 -> user.slice/user-<uid>.slice, which
 * holds the compositor and every app, whatever the desktop) is pinned to the CPUs with the highest
 * cpu_capacity, and back to all CPUs WINDOW_HOLD_MS after the last touch.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define HOLD_MS		300	/* keep the boost this long after the last touch event */
#define CPU_PCT		60	/* boost floor: first available frequency >= this % of max */
#define GPU_MIN_HZ	"465000000"
#define GPU_BASE_HZ	"266000000"	/* the floor 90-hiby-rs6-perf.rules sets */
#define MAX_FDS		8
#define MAX_KNOBS	8
#define WINDOW_HOLD_MS	5000	/* keep the active window on the big cores this long after a touch */

struct knob {
	char path[1024];
	char base[32];		/* floor to restore after a boost */
	char boost[32];
};

static struct knob knobs[MAX_KNOBS];
static int nknobs;
static volatile sig_atomic_t stop;
static const char *sysfs = "/sys";	/* RS6_TOUCHBOOST_SYSFS overrides it, for testing */

static int read_str(const char *path, char *buf, size_t len)
{
	FILE *f = fopen(path, "r");

	if (!f)
		return -1;
	if (!fgets(buf, len, f)) {
		fclose(f);
		return -1;
	}
	fclose(f);
	buf[strcspn(buf, "\n")] = 0;
	return 0;
}

static void write_str(const char *path, const char *val)
{
	int fd = open(path, O_WRONLY | O_TRUNC | O_CLOEXEC);

	if (fd < 0)
		return;
	if (write(fd, val, strlen(val)) < 0)
		fprintf(stderr, "rs6-touchboost: %s <- %s: %s\n", path, val, strerror(errno));
	close(fd);
}

static void add_cpu_policy(const char *dir)
{
	char path[1024], avail[512], max[32], *tok, *save = NULL;
	unsigned long want, best = 0, f;
	struct knob *k;

	if (nknobs >= MAX_KNOBS)
		return;
	snprintf(path, sizeof(path), "%s/cpuinfo_max_freq", dir);
	if (read_str(path, max, sizeof(max)))
		return;
	want = strtoul(max, NULL, 10) * CPU_PCT / 100;
	snprintf(path, sizeof(path), "%s/scaling_available_frequencies", dir);
	if (read_str(path, avail, sizeof(avail)))
		return;
	for (tok = strtok_r(avail, " ", &save); tok; tok = strtok_r(NULL, " ", &save)) {
		f = strtoul(tok, NULL, 10);
		if (f >= want && (!best || f < best))
			best = f;
	}
	if (!best)
		return;
	k = &knobs[nknobs];
	snprintf(k->path, sizeof(k->path), "%s/scaling_min_freq", dir);
	snprintf(k->boost, sizeof(k->boost), "%lu", best);
	snprintf(path, sizeof(path), "%s/cpuinfo_min_freq", dir);
	if (read_str(path, k->base, sizeof(k->base)))
		return;
	nknobs++;
}

static void find_knobs(void)
{
	struct dirent *de;
	char dir[768], base[512];
	DIR *d;

	snprintf(base, sizeof(base), "%s/devices/system/cpu/cpufreq", sysfs);
	d = opendir(base);

	if (d) {
		while ((de = readdir(d))) {
			if (strncmp(de->d_name, "policy", 6))
				continue;
			snprintf(dir, sizeof(dir), "%s/%s", base, de->d_name);
			add_cpu_policy(dir);
		}
		closedir(d);
	}
	/* Adreno devfreq: name ends in ".gpu" (5000000.gpu on SDM660) */
	snprintf(base, sizeof(base), "%s/class/devfreq", sysfs);
	d = opendir(base);
	if (d) {
		while ((de = readdir(d)) && nknobs < MAX_KNOBS) {
			size_t n = strlen(de->d_name);

			if (n < 4 || strcmp(de->d_name + n - 4, ".gpu"))
				continue;
			snprintf(knobs[nknobs].path, sizeof(knobs[nknobs].path),
				 "%s/%s/min_freq", base, de->d_name);
			snprintf(knobs[nknobs].boost, sizeof(knobs[nknobs].boost), "%s", GPU_MIN_HZ);
			snprintf(knobs[nknobs].base, sizeof(knobs[nknobs].base), "%s", GPU_BASE_HZ);
			nknobs++;
		}
		closedir(d);
	}
}

/*
 * The floors to go back to are fixed, not read back: devfreq's min_freq (and cpufreq's
 * scaling_min_freq) show the effective floor, which includes kernel PM QoS requests such as
 * msm's GPU wait-boost (msm_gpu_devfreq.c boost_freq). Saving that at the start of a touch
 * and writing it back on release pinned the GPU at 647 MHz.
 */

static char boosted_cg[700];	/* cgroup dir we pinned to the big cores, "" if none */

/* logind's active user on seat0, -1 if none */
static long active_uid(void)
{
	char line[128];
	long uid = -1;
	FILE *f = fopen("/run/systemd/seats/seat0", "r");

	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f))
		if (!strncmp(line, "ACTIVE_UID=", 11))
			uid = strtol(line + 11, NULL, 10);
	fclose(f);
	return uid;
}

static cpu_set_t big_cpus, all_cpus;

/* big = the CPUs with the highest cpu_capacity, all = every online CPU */
static void find_cpus(void)
{
	char p[128], buf[32];
	long cap[CPU_SETSIZE], max = 0;
	int c;

	CPU_ZERO(&big_cpus);
	CPU_ZERO(&all_cpus);
	for (c = 0; c < CPU_SETSIZE; c++) {
		snprintf(p, sizeof(p), "%s/devices/system/cpu/cpu%d/cpu_capacity", sysfs, c);
		cap[c] = read_str(p, buf, sizeof(buf)) < 0 ? -1 : strtol(buf, NULL, 10);
		if (cap[c] > max)
			max = cap[c];
		if (cap[c] >= 0)
			CPU_SET(c, &all_cpus);
	}
	for (c = 0; c < CPU_SETSIZE; c++)
		if (cap[c] == max && max > 0)
			CPU_SET(c, &big_cpus);
}

/* pin every thread of every process in cgroup dir cg to set */
static void pin_cgroup(const char *cg, const cpu_set_t *set)
{
	char path[800], line[32];
	FILE *f;

	snprintf(path, sizeof(path), "%s/cgroup.procs", cg);
	f = fopen(path, "r");
	if (!f)
		return;
	while (fgets(line, sizeof(line), f)) {
		struct dirent *de;
		DIR *d;

		snprintf(path, sizeof(path), "/proc/%ld/task", strtol(line, NULL, 10));
		d = opendir(path);
		if (!d)
			continue;
		while ((de = readdir(d)))
			if (de->d_name[0] != '.')
				sched_setaffinity((pid_t)strtol(de->d_name, NULL, 10), sizeof(*set), set);
		closedir(d);
	}
	fclose(f);
	/* and every child cgroup (the session's scopes and services) */
	{
		struct dirent *de;
		DIR *d = opendir(cg);

		if (!d)
			return;
		while ((de = readdir(d)))
			if (de->d_type == DT_DIR && de->d_name[0] != '.') {
				snprintf(path, sizeof(path), "%s/%s", cg, de->d_name);
				pin_cgroup(path, set);
			}
		closedir(d);
	}
}

/* move the active session to the big cores (on) or back to all CPUs (off) */
static void boost_window(int on)
{
	char path[700];
	long uid;

	if (!on) {
		if (boosted_cg[0])
			pin_cgroup(boosted_cg, &all_cpus);
		boosted_cg[0] = 0;
		return;
	}
	uid = active_uid();
	if (uid < 0 || !CPU_COUNT(&big_cpus) || CPU_EQUAL(&big_cpus, &all_cpus))
		return;
	snprintf(path, sizeof(path), "/sys/fs/cgroup/user.slice/user-%ld.slice", uid);
	if (boosted_cg[0] && strcmp(boosted_cg, path))
		pin_cgroup(boosted_cg, &all_cpus);	/* another user took the seat */
	pin_cgroup(path, &big_cpus);		/* again on every touch: picks up new threads */
	snprintf(boosted_cg, sizeof(boosted_cg), "%s", path);
}

static void boost(int on)
{
	int i;

	for (i = 0; i < nknobs; i++)
		write_str(knobs[i].path, on ? knobs[i].boost : knobs[i].base);
}

static int is_touchscreen(int fd)
{
	unsigned long abs[(ABS_MAX + 8 * sizeof(long)) / (8 * sizeof(long))] = { 0 };
	unsigned long props[(INPUT_PROP_MAX + 8 * sizeof(long)) / (8 * sizeof(long))] = { 0 };
	const int bits = 8 * sizeof(long);

	if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(abs)), abs) < 0)
		return 0;
	if (!(abs[ABS_MT_POSITION_X / bits] & (1UL << (ABS_MT_POSITION_X % bits))))
		return 0;
	if (ioctl(fd, EVIOCGPROP(sizeof(props)), props) >= 0 &&
	    (props[INPUT_PROP_DIRECT / bits] & (1UL << (INPUT_PROP_DIRECT % bits))))
		return 1;
	return 0;
}

/* open every direct-touch evdev under /dev/input that isn't watched yet */
static void scan_touchscreens(struct pollfd *pfd, int *nfd, char seen[][256])
{
	struct dirent *de;
	DIR *d = opendir("/dev/input");

	if (!d)
		return;
	while ((de = readdir(d)) && *nfd < MAX_FDS) {
		char path[300];
		int fd, i, dup = 0;

		if (strncmp(de->d_name, "event", 5))
			continue;
		for (i = 0; i < *nfd; i++)
			if (!strcmp(seen[i], de->d_name))
				dup = 1;
		if (dup)
			continue;
		snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
		fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
		if (fd < 0)
			continue;
		if (is_touchscreen(fd)) {
			pfd[*nfd].fd = fd;
			pfd[*nfd].events = POLLIN;
			snprintf(seen[*nfd], sizeof(seen[0]), "%s", de->d_name);
			(*nfd)++;
			fprintf(stderr, "rs6-touchboost: watching %s\n", path);
		} else {
			close(fd);
		}
	}
	closedir(d);
}

static long now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000L + ts.tv_nsec / 1000000;
}

static void on_signal(int sig)
{
	(void)sig;
	stop = 1;
}

int main(void)
{
	struct pollfd pfd[MAX_FDS + 1];
	char seen[MAX_FDS][256];
	struct input_event ev[64];
	int nfd = 0, boosted = 0, pinned = 0, i, ino;
	long last = 0, lastpin = 0;

	if (getenv("RS6_TOUCHBOOST_SYSFS"))
		sysfs = getenv("RS6_TOUCHBOOST_SYSFS");
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);

	find_knobs();
	find_cpus();
	if (!nknobs) {
		fprintf(stderr, "rs6-touchboost: no cpufreq/devfreq knobs; nothing to do\n");
		return 1;
	}
	for (i = 0; i < nknobs; i++)
		fprintf(stderr, "rs6-touchboost: %s boost %s\n", knobs[i].path, knobs[i].boost);

	/* the touchscreen driver is a module and may bind after we start: watch /dev/input */
	ino = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	if (ino >= 0 && inotify_add_watch(ino, "/dev/input", IN_CREATE | IN_ATTRIB) < 0) {
		close(ino);
		ino = -1;
	}
	scan_touchscreens(pfd, &nfd, seen);
	if (!nfd)
		fprintf(stderr, "rs6-touchboost: no touchscreen yet, waiting for one\n");

	while (!stop) {
		long now = now_ms();
		int timeout = -1, r, n = nfd;

		if (boosted && now >= last + HOLD_MS) {
			boost(0);
			boosted = 0;
		}
		if (pinned && now >= last + WINDOW_HOLD_MS) {
			boost_window(0);
			pinned = 0;
		}
		if (boosted)
			timeout = (int)(last + HOLD_MS - now);
		else if (pinned)
			timeout = (int)(last + WINDOW_HOLD_MS - now);
		if (ino >= 0) {
			pfd[n].fd = ino;
			pfd[n++].events = POLLIN;
		}
		if (!n) {
			fprintf(stderr, "rs6-touchboost: no touchscreen and no inotify\n");
			break;
		}
		r = poll(pfd, n, timeout);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		if (ino >= 0 && (pfd[nfd].revents & POLLIN)) {
			char buf[4096];

			while (read(ino, buf, sizeof(buf)) > 0)
				;
			scan_touchscreens(pfd, &nfd, seen);
		}
		for (i = 0; i < nfd; i++) {
			if (pfd[i].revents & (POLLHUP | POLLERR | POLLNVAL)) {
				/* device gone (module unbound): drop it, a rescan picks it up again */
				fprintf(stderr, "rs6-touchboost: /dev/input/%s gone\n", seen[i]);
				close(pfd[i].fd);
				pfd[i] = pfd[nfd - 1];
				memcpy(seen[i], seen[nfd - 1], sizeof(seen[0]));
				nfd--;
				i--;
				continue;
			}
			if (!(pfd[i].revents & POLLIN))
				continue;
			while (read(pfd[i].fd, ev, sizeof(ev)) > 0)
				;
			last = now_ms();
			if (!boosted) {
				boost(1);
				boosted = 1;
			}
			if (!pinned || last - lastpin >= 1000) {
				boost_window(1);	/* again at most once a second: picks up new threads */
				pinned = 1;
				lastpin = last;
			}
		}
	}
	if (boosted)
		boost(0);
	if (pinned)
		boost_window(0);
	return 0;
}
