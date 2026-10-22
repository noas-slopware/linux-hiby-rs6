# usb-moded-notify patches

Upstream project: usb-moded-notify, https://gitlab.postmarketos.org/postmarketOS/usb-moded-notify

Apply to: **0.4.2** (the version the `usb-moded-notify` package on the `pmos` branch builds). Upstream license: GPL-3.0-or-later.

Retry instead of crashing when the notification server fails.

Patches (in order):

- `0001-Retry-instead-of-crashing-when-the-notification-server-fails.patch`

Authors: Noa Himesaka <himesaka@noa.codes>.

The patches are `git format-patch` output against the upstream release; apply with `patch -p1` or `git am`.
They are licensed like the project they patch.
