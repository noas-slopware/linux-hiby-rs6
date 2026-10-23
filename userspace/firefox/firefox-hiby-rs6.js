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

// Performance (ArchWiki Firefox/Tweaks, Betterfox Fastfox), for 4 GB of RAM and eMMC storage
// hardware WebRender everywhere, and hardware video decoding past the driver blocklist
pref("gfx.webrender.all", true);
pref("media.hardware-video-decoding.enabled", true);
pref("media.hardware-video-decoding.force-enabled", true);
// fewer content processes: less RAM, less swapping on 4 GB
pref("browser.preferences.defaultPerformanceSettings.enabled", false);
pref("dom.ipc.processCount", 4);
// no disk cache on eMMC; the memory cache sizes itself (-1)
pref("browser.cache.disk.enable", false);
pref("browser.cache.memory.enable", true);
pref("browser.cache.memory.capacity", -1);
// save the session every 10 min instead of every 15 s
pref("browser.sessionstore.interval", 600000);
// unload tabs idle for an hour when memory runs low
pref("browser.tabs.unloadOnLowMemory", true);
pref("browser.low_commit_space_threshold_percent", 100);
pref("browser.tabs.min_inactive_duration_before_unload", 3600000);
// Fastfox: bigger font and canvas caches, bigger image decode chunks
pref("gfx.content.skia-font-cache-size", 20);
pref("gfx.canvas.accelerated.cache-size", 512);
pref("image.mem.decode_bytes_at_a_time", 32768);
// Fastfox: more network buffers and connections, faster request start, longer DNS cache
pref("network.buffer.cache.size", 65535);
pref("network.buffer.cache.count", 48);
pref("network.http.max-connections", 1800);
pref("network.http.max-persistent-connections-per-server", 10);
pref("network.http.max-urgent-start-excessive-connections-per-host", 5);
pref("network.http.request.max-start-delay", 5);
pref("network.dnsCacheExpiration", 3600);
// Wayland native compositor: KWin composites Firefox's layers directly, less GPU copying
pref("gfx.webrender.compositor.force-enabled", true);
// no spare content process kept warm in the background (RAM, CPU at startup)
pref("dom.ipc.processPrelaunch.enabled", false);
// no local AI models or inference processes
pref("browser.ml.enable", false);
pref("browser.ml.chat.enabled", false);
pref("browser.ml.linkPreview.enabled", false);
pref("browser.tabs.groups.smart.enabled", false);
pref("extensions.ml.enabled", false);
// no background telemetry, studies, experiments or ping work
pref("datareporting.healthreport.uploadEnabled", false);
pref("datareporting.policy.dataSubmissionEnabled", false);
pref("toolkit.telemetry.enabled", false);
pref("toolkit.telemetry.unified", false);
pref("toolkit.telemetry.archive.enabled", false);
pref("app.normandy.enabled", false);
pref("app.shield.optoutstudies.enabled", false);
pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
pref("browser.newtabpage.activity-stream.telemetry", false);
