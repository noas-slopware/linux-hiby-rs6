// SPDX-License-Identifier: MIT
/*
 * Touch boost for the HiBy RS6, the "input boost" Android kernels and HALs do: while a finger
 * is on the screen (and briefly after), raise the minimum CPU frequency of every cpufreq policy
 * and the minimum GPU frequency, so scrolling and animations don't wait for schedutil/devfreq
 * to ramp up from idle clocks. Writes happen only on boost on/off transitions.
 *
 * Plain Linux interfaces only (evdev, cpufreq and devfreq sysfs): libc-agnostic.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define HOLD_MS		300	/* keep the boost this long after the last touch event */
#define CPU_PCT		60	/* boost floor: first available frequency >= this % of max */
#define GPU_MIN_HZ	"465000000"
#define GPU_BASE_HZ	"266000000"	/* the floor 90-hiby-rs6-perf.rules sets */
#define MAX_FDS		8
#define MAX_KNOBS	8

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
	int nfd = 0, boosted = 0, i, ino;
	long last = 0;

	if (getenv("RS6_TOUCHBOOST_SYSFS"))
		sysfs = getenv("RS6_TOUCHBOOST_SYSFS");
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);

	find_knobs();
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
		int timeout = boosted ? (int)(last + HOLD_MS - now_ms()) : -1;
		int r, n = nfd;

		if (boosted && timeout <= 0) {
			boost(0);
			boosted = 0;
			continue;
		}
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
		}
	}
	if (boosted)
		boost(0);
	return 0;
}
