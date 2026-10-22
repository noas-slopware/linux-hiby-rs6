# KIconThemes (KDE Frameworks) patches

Upstream project: KIconThemes (KDE Frameworks), https://community.kde.org/Frameworks

Apply to: **6.31.0** (the version the `kiconthemes` package on the `pmos` branch builds). Upstream license: LGPL-2.1-only.

KQuickIconProvider: requestedSize is in device pixels (fixes a large memory use in Elisa on a 2.75 scale output).

Patches (in order):

- `0001-KQuickIconProvider-requestedSize-is-in-device-pixels.patch`

Authors: Noa Himesaka <himesaka@noa.codes>.

The patches are `git format-patch` output against the upstream release; apply with `patch -p1` or `git am`.
They are licensed like the project they patch.
