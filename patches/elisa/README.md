# Elisa patches

Upstream project: Elisa, https://kde.org/applications/multimedia/org.kde.elisa

Apply to: **26.08.2** (the version the `elisa` package on the `pmos` branch builds). Upstream license: LGPL-3.0-or-later.

Elisa as a DAP player on the RS6: a Subsonic/OpenSubsonic/Navidrome music source, a bit-perfect output setting, and fixes for mobile drawers, cover decoding at the requested size, high-DPI sourceSize, a cover response race and search-field filtering.

Patches (in order):

- `0001-Add-a-Subsonic-OpenSubsonic-Navidrome-music-source.patch`
- `0002-Add-a-bit-perfect-output-setting.patch`
- `0003-Open-mobile-drawers-after-the-tap.patch`
- `0004-Decode-embedded-covers-at-the-requested-size.patch`
- `0005-Do-not-scale-cover-sourceSize-by-the-device-pixel-ratio-twice.patch`
- `0006-Emit-finished-of-embedded-cover-responses-on-the-pixmap-reader-thread.patch`
- `0007-Filter-the-views-on-the-text-the-search-field-shows.patch`

Authors: Noa Himesaka <himesaka@noa.codes>.

The patches are `git format-patch` output against the upstream release; apply with `patch -p1` or `git am`.
They are licensed like the project they patch.
