# Plasma Keyboard patches

Upstream project: Plasma Keyboard, https://invent.kde.org/plasma/plasma-keyboard

Apply to: **6.8.1** (the version the `plasma-keyboard` package on the `pmos` branch builds). Upstream license: (GPL-2.0-only OR GPL-3.0-only) AND (LGPL-2.1-only OR LGPL-3.0-only).

Korean syllable composition in the preedit (via libhangul) and content-type changes passed on to the Qt Virtual Keyboard.

Patches (in order):

- `0001-Compose-Korean-syllables-in-the-preedit.patch`
- `0002-Pass-content-type-changes-on-to-Qt-Virtual-Keyboard.patch`

Authors: Noa Himesaka <himesaka@noa.codes>.

The patches are `git format-patch` output against the upstream release; apply with `patch -p1` or `git am`.
They are licensed like the project they patch.
