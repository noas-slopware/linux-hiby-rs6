// SPDX-License-Identifier: MIT
// HiBy RS6: report the active window's process to rs6-activewindow, so rs6-touchboost can boost
// that process onto the big cores while the screen is touched.
function report(w) {
    if (w && w.pid > 0)
        callDBus("org.hibyrs6.ActiveWindow", "/org/hibyrs6/ActiveWindow",
                 "org.hibyrs6.ActiveWindow", "Set", w.pid);
}
workspace.windowActivated.connect(report);
report(workspace.activeWindow);
