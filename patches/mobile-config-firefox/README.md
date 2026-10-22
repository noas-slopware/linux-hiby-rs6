# mobile-config-firefox patches

Upstream project: mobile-config-firefox, https://gitlab.postmarketos.org/postmarketOS/mobile-config-firefox

Apply to: **5.5.0** (the version the `mobile-config-firefox` package on the `pmos` branch builds). Upstream license: GPL-3.0-or-later.

Make the postmarketOS Firefox mobile config usable on the RS6 (432 CSS px wide landscape-ish window at 2.5 dppx): extension popups wider than the window are zoomed to fit, and the toolbar, URL editing, home page and tab UI follow Firefox for Android (Fenix) on narrow windows, on Firefox 154 and 158.

Patches (in order):

- `0001-popups-Fit-extension-popups-that-are-wider-than-the-window.patch`
- `0002-Match-Firefox-for-Android-Fenix-on-narrow-windows.patch`
- `0003-popups-Measure-extension-popups-with-the-mobile-view.patch`
- `0004-Match-Fenix-toolbar-URL-editing-and-home-on-Firefox-154-and-158.patch`

Authors: Noa Himesaka <himesaka@noa.codes>.

The patches are `git format-patch` output against the upstream release; apply with `patch -p1` or `git am`.
They are licensed like the project they patch.
