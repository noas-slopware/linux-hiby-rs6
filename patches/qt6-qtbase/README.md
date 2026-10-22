# Qt 6 base patches

Upstream project: Qt 6 base, https://qt.io/

Apply to: **6.11.1** (the version the `qt6-qtbase` package on the `pmos` branch builds). Upstream license: LGPL-2.1-only AND LGPL-3.0-only AND GPL-3.0-only AND Qt-GPL-exception-1.0.

Only the RS6 patch is kept here: forget the cached QBindingStatus on thread exit (a musl thread_local double free that crashed Elisa on exit). The package on the `pmos` branch also carries Alpine's own patches (lfs64, dns-resolver, symlinks, wayland deadlock), which are not duplicated here.

Patches (in order):

- `0003-QThreadData-forget-cached-QBindingStatus-on-thread-exit.patch`

Authors: Noa Himesaka <himesaka@noa.codes>.

The patches are `git format-patch` output against the upstream release; apply with `patch -p1` or `git am`.
They are licensed like the project they patch.
