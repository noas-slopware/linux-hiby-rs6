// SPDX-License-Identifier: MIT
/*
 * rs6-vt-lock: lock VT switching (VT_LOCKSWITCH), or unlock it with "unlock".
 *
 * The RS6 runs one graphical session on tty1 and has no use for the other VTs. With the lock
 * held, VT_ACTIVATE from anyone (logind included) fails, so nothing can move the panel off
 * the session onto a text console.
 */
#include <fcntl.h>
#include <linux/vt.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	int unlock = argc > 1 && !strcmp(argv[1], "unlock");
	int fd = open("/dev/tty0", O_RDWR | O_CLOEXEC);

	if (fd < 0) {
		perror("/dev/tty0");
		return 1;
	}
	if (ioctl(fd, unlock ? VT_UNLOCKSWITCH : VT_LOCKSWITCH, 0) < 0) {
		perror(unlock ? "VT_UNLOCKSWITCH" : "VT_LOCKSWITCH");
		return 1;
	}
	close(fd);
	return 0;
}
