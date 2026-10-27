// SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
// SPDX-License-Identifier: MIT
//
// DARWIN: the HiBy RS6 DAC (hm100) in the DMS bar. Everything goes through darwinctl: one
// `darwinctl monitor` for the state (a JSON line now and after every change, from ALSA control
// events: the jack auto-switch, alsamixer, other darwinctl users), short darwinctl runs for the
// writes. What the popout shows is always what the driver read back.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
import qs.Modals.FileBrowser
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "darwin"

    // the last line of darwinctl monitor; {} until the first one
    property var dac: ({})
    readonly property bool available: dac.available === true
    // what a darwinctl write said when it failed, empty after one that worked
    property string errorText: ""
    property bool monitorFailed: false

    // short names for the bar
    readonly property var outputShort: ({
            "Auto": "Auto",
            "Lineout": "3.5 LO",
            "Headset": "3.5",
            "Balance": "4.4",
            "BalanceLo": "4.4 LO",
            "Spdif": "S/PDIF"
        })
    // the filter as a short tag: the bar on the RS6 has room for about eight characters
    readonly property var filterShort: ({
            "sharp_roll_off": "SH",
            "slow_roll_off": "SL",
            "short_delay_sharp_roll_off": "SDS",
            "short_delay_slow_roll_off": "SDL",
            "super_sharp_roll_off": "SSH",
            "super_slow_roll_off": "SSL",
            "low_dispersion_short_delay": "LD"
        })
    // where the sound goes now: the Output setting, or for Auto the jack it resolved to
    readonly property string outputText: {
        if (!available || !dac.output)
            return "";
        const out = dac.output.name === "Auto" && dac.target ? dac.target.name : dac.output.name;
        return outputShort[out] ?? out;
    }
    // NOS, a Darwin filter as D<n> (Darwin Default: DD, a loaded file: FIR), else the built-in tag
    readonly property string filterText: {
        if (!available || !dac.filter)
            return "";
        if (dac.nos)
            return "NOS";
        if (dac.filter.darwin) {
            if (!dac.darwin || dac.darwin.index < 0)
                return "FIR";
            const m = dac.darwin.title.match(/^Darwin (\d+|Default)$/);
            return m ? (m[1] === "Default" ? "DD" : "D" + m[1]) : "FIR";
        }
        return filterShort[dac.filter.name] ?? dac.filter.label;
    }
    readonly property string pillText: available ? outputText + " · " + filterText : "No DAC"

    // ---- writes: one darwinctl at a time, the latest request per control wins ----
    property var pending: ({})
    property var pendingOrder: []
    // the value a stepper asked for until darwinctl took it (a held button runs ahead of the writes)
    property var want: ({})

    function wanted(key, current) {
        return want[key] !== undefined ? want[key] : current;
    }

    function setWant(key, value) {
        const w = Object.assign({}, want);
        w[key] = value;
        want = w;
    }

    function dropWant(key) {
        if (want[key] === undefined)
            return;
        const w = Object.assign({}, want);
        delete w[key];
        want = w;
    }

    // a wanted value is done once the driver reports it; a monitor line also ends one that
    // nothing is writing any more (failed, or changed again elsewhere)
    function settleWants(fromMonitor) {
        const now = {
            "pregain": dac.pregain?.value,
            "balance": dac.balance?.value,
            "idle": dac.idle_off?.value,
            "dsdcomp": dac.dsd_compensate?.value
        };
        for (const key in want) {
            const busy = pending[key] !== undefined || (writer.running && writer.what === key);
            if (!busy && (now[key] === want[key] || fromMonitor))
                dropWant(key);
        }
    }

    function run(key, args) {
        const p = Object.assign({}, pending);
        p[key] = args;
        pending = p;
        if (pendingOrder.indexOf(key) < 0)
            pendingOrder = pendingOrder.concat([key]);
        next();
    }

    function next() {
        if (writer.running || pendingOrder.length === 0)
            return;
        const key = pendingOrder[0];
        const args = pending[key];
        const p = Object.assign({}, pending);
        delete p[key];
        pending = p;
        pendingOrder = pendingOrder.slice(1);
        writer.what = key;
        writer.command = ["darwinctl"].concat(args);
        writer.running = true;
    }

    Process {
        id: writer
        property string what: ""
        stderr: StdioCollector {
            id: writerErr
        }
        onExited: (code, status) => {
            // darwinctl says why it failed, or (exit 0) that a Darwin filter is not kept for the next boot
            const err = writerErr.text.trim().replace(/^darwinctl: /, "");
            root.errorText = err !== "" ? err : (code === 0 ? "" : "darwinctl " + what + " failed.");
            if (code !== 0 && root.pending[what] === undefined)
                root.dropWant(what);
            else
                root.settleWants(false);
            root.next();
        }
    }

    function setNos(on) {
        run("nos", ["nos", on ? "on" : "off"]);
    }
    function setOutput(name) {
        run("output", ["output", name]);
    }
    function setGain(name) {
        run("gain", ["gain", name]);
    }
    function setFilter(name) {
        run("filter", ["filter", name]);
    }
    function setDarwin(title) {
        run("filter", ["darwin", title]);
    }
    function loadFlt(path) {
        run("filter", ["darwin", path]);
    }
    // tenths of a dB
    function setPregain(tenths) {
        const v = Math.max(dac.pregain.min, Math.min(dac.pregain.max, tenths));
        setWant("pregain", v);
        run("pregain", ["pregain", (v / 10).toFixed(1)]);
    }
    // 0.5 dB steps, < 0 raises the left channel
    function setBalance(steps) {
        const v = Math.max(dac.balance.min, Math.min(dac.balance.max, steps));
        setWant("balance", v);
        run("balance", ["balance", v === 0 ? "center" : (v < 0 ? "L" : "R") + (Math.abs(v) / 2).toFixed(1)]);
    }
    function setIdleOff(seconds) {
        const v = Math.max(dac.idle_off.min, Math.min(dac.idle_off.max, seconds));
        setWant("idle", v);
        run("idle", ["idle-off", v === 0 ? "never" : String(v)]);
    }
    function setDsdMode(name) {
        run("dsdmode", ["dsd-mode", name]);
    }
    function setDsdCompensate(steps) {
        const v = Math.max(dac.dsd_compensate.min, Math.min(dac.dsd_compensate.max, steps));
        setWant("dsdcomp", v);
        run("dsdcomp", ["dsd-compensate", (v / 2).toFixed(1)]);
    }
    function openFileBrowser() {
        closePopout();
        fileBrowser.open();
    }

    // ---- the state ----
    Process {
        id: monitor
        property int restarts: 0
        property bool spoke: false     // printed anything since the shell started
        command: ["darwinctl", "monitor"]
        running: true
        stdout: SplitParser {
            onRead: line => {
                try {
                    root.dac = JSON.parse(line);
                    root.settleWants(true);
                    monitor.spoke = true;
                    if (root.dac.available)
                        monitor.restarts = 0;
                } catch (e) {
                    console.warn("DARWIN: darwinctl monitor:", e, line);
                }
            }
        }
        // darwinctl monitor waits for the card itself and never ends on its own; if it does
        // (not installed, crashed), it gets three more tries, then the popout says so
        onExited: (code, status) => {
            root.dac = ({});
            if (restarts < 3) {
                restarts++;
                restartMonitor.start();
            } else {
                root.monitorFailed = !spoke;
            }
        }
    }

    Timer {
        id: restartMonitor
        interval: 2000
        onTriggered: monitor.running = true
    }

    FileBrowserModal {
        id: fileBrowser
        browserTitle: "Load a Darwin filter"
        bucket: "darwin"
        filters: ["*.flt"]
        startPath: Quickshell.env("HOME") || "/"
        onAccepted: paths => {
            if (paths && paths.length > 0)
                root.loadFlt(paths[0]);
        }
    }

    // `dms ipc call darwin toggle` (or qs ipc): the popout from a key binding
    IpcHandler {
        target: "darwin"

        function toggle(): string {
            root.triggerPopout();
            return "ok";
        }
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS

            DIcon {
                name: "graphic_eq"
                size: root.iconSize
                color: root.available ? Theme.widgetTextColor : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: root.pillText
                font.pixelSize: root.textSize
                color: root.available ? Theme.widgetTextColor : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXXS

            DIcon {
                name: "graphic_eq"
                size: root.iconSize
                color: root.available ? Theme.widgetTextColor : Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.outputText
                visible: root.available
                font.pixelSize: root.textSize * 0.8
                color: Theme.widgetTextColor
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    // as wide as it gets on the RS6 (480 logical px), with the popout's margins to the screen edges
    popoutWidth: Math.min(460, (parentScreen ? parentScreen.width : 480) - 48)

    popoutContent: Component {
        DarwinPanel {
            darwin: root
        }
    }
}
