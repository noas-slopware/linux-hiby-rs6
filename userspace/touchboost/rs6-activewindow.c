// SPDX-License-Identifier: MIT
/*
 * rs6-activewindow: tells rs6-touchboost which process owns the active window, so a touch
 * boosts that process onto the big cores. The KWin script hiby-rs6-boost calls
 * org.hibyrs6.ActiveWindow.Set(u pid) on the session bus whenever a window is activated; this
 * writes the pid to $XDG_RUNTIME_DIR/hiby-rs6/active-pid (atomically), where the root
 * rs6-touchboost reads it. Started by D-Bus activation (systemd user unit).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <systemd/sd-bus.h>

static char dir[512], path[600], tmp[620];

static int method_set(sd_bus_message *m, void *userdata, sd_bus_error *err)
{
	uint32_t pid;
	FILE *f;
	int r;

	(void)userdata;
	(void)err;
	r = sd_bus_message_read(m, "u", &pid);
	if (r < 0)
		return r;
	f = fopen(tmp, "w");
	if (f) {
		fprintf(f, "%u\n", pid);
		if (fclose(f) == 0)
			rename(tmp, path);
	}
	return sd_bus_reply_method_return(m, NULL);
}

static const sd_bus_vtable vtable[] = {
	SD_BUS_VTABLE_START(0),
	SD_BUS_METHOD("Set", "u", "", method_set, SD_BUS_VTABLE_UNPRIVILEGED),
	SD_BUS_VTABLE_END
};

int main(void)
{
	const char *rt = getenv("XDG_RUNTIME_DIR");
	sd_bus *bus = NULL;
	int r;

	if (!rt) {
		fprintf(stderr, "rs6-activewindow: no XDG_RUNTIME_DIR\n");
		return 1;
	}
	snprintf(dir, sizeof(dir), "%s/hiby-rs6", rt);
	snprintf(path, sizeof(path), "%s/active-pid", dir);
	snprintf(tmp, sizeof(tmp), "%s/active-pid.new", dir);
	if (mkdir(dir, 0755) < 0 && errno != EEXIST) {
		perror("rs6-activewindow: mkdir");
		return 1;
	}
	r = sd_bus_open_user(&bus);
	if (r >= 0)
		r = sd_bus_add_object_vtable(bus, NULL, "/org/hibyrs6/ActiveWindow", "org.hibyrs6.ActiveWindow", vtable, NULL);
	if (r >= 0)
		r = sd_bus_request_name(bus, "org.hibyrs6.ActiveWindow", 0);
	if (r < 0) {
		fprintf(stderr, "rs6-activewindow: %s\n", strerror(-r));
		return 1;
	}
	for (;;) {
		r = sd_bus_process(bus, NULL);
		if (r < 0)
			break;
		if (r > 0)
			continue;
		r = sd_bus_wait(bus, (uint64_t)-1);
		if (r < 0)
			break;
	}
	sd_bus_unref(bus);
	return r < 0 ? 1 : 0;
}
