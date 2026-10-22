# Plasma Mobile patches

Upstream project: Plasma Mobile, https://www.plasma-mobile.org/

Apply to: **6.8.1** (the version the `plasma-mobile` package on the `pmos` branch builds). Upstream license: GPL-2.0-or-later AND LGPL-2.1-or-later.

Brightness slider: watch the D-Bus bus name, not the interface name, so the slider appears when the service starts late. Overlays (volume OSD, volume popup, notification popup layer, applet overlay) release their scene graph and graphics while hidden, and Qt Quick texture atlases are capped at 1024x1024 (`QSG_ATLAS_WIDTH`/`HEIGHT` in `startplasmamobile`), which cuts the shell's GPU memory on the RS6.

Patches (in order):

- `0001-screenbrightnessplugin-Watch-the-bus-name-not-the-interface-name.patch`
- `0002-mobileshell-release-overlay-graphics-while-hidden-sm.patch`

Authors: Noa Himesaka <himesaka@noa.codes>.

The patches are `git format-patch` output against the upstream release; apply with `patch -p1` or `git am`.
They are licensed like the project they patch.
