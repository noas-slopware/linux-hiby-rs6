// HiBy RS6 Firefox defaults (user prefs still override these)
// 432 CSS px wide at 1080 px (KWin's 2.75 would leave 392): more room for pages and
// extension popups. Popups wider than that get zoomed to fit (mobile-config-firefox r1).
pref("layout.css.devPixelsPerPx", "2.5");
// Venus decodes H.264/HEVC/VP8/VP9 but not AV1: have YouTube send VP9
pref("media.av1.enabled", false);
// Firefox <= 155: puts the system FFmpeg (with the V4L2 wrapper decoders) ahead of the
// bundled ffvpx in the decoder process, so VP8/VP9 reach Venus instead of ffvpx software.
// 156+ also wants usable Vulkan video decoding, which the Adreno 512 lacks; there the
// firefox-v4l2-fix.so shim hides ffvpx's VP8/VP9 decoders instead.
pref("media.hardware-video-decoding-vulkan.enabled", true);
