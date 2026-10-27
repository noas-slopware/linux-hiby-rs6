// SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
// SPDX-License-Identifier: MIT
//
// The DARWIN popout: every hm100 control, as the Plasma KCM has them (Output, Gain, NOS, the
// built-in and the Darwin filters, a .flt file, Pregain, L/R balance, idle power off) and the
// DSD ones. Finger-sized for the RS6 (480x853 at scale 2.25); it scrolls when the screen is
// shorter than the popout.

import QtQuick
import qs.Common
import qs.DCommon.Widgets

Item {
    id: panel

    required property var darwin
    property var closePopout: null
    readonly property var dac: darwin.dac
    readonly property bool ok: darwin.available
    readonly property int chipHeight: 44

    // the popout is this + its padding, and never taller than the screen
    implicitWidth: parent ? parent.width : 428
    implicitHeight: Math.min(content.implicitHeight, Math.max(320, (panel.Screen.height || 853) - 140))

    function dbText(tenths) {
        return (tenths > 0 ? "+" : "") + (tenths / 10).toFixed(1) + " dB";
    }
    function balanceText(steps) {
        if (steps === 0)
            return "Center";
        return (steps < 0 ? "Left " : "Right ") + dbText(Math.abs(steps) * 5);
    }
    function idleText(s) {
        if (s === 0)
            return "Never";
        if (s % 60 === 0)
            return s / 60 + (s === 60 ? " minute" : " minutes");
        return s + " seconds";
    }
    function labels(items) {
        return (items || []).map(i => i.label);
    }
    function indexOfName(items, name) {
        return (items || []).findIndex(i => i.name === name);
    }

    DFlickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true

        Column {
            id: content
            width: flick.width
            spacing: Theme.spacingM

            // ---- header ----
            Row {
                width: parent.width
                spacing: Theme.spacingM

                DIcon {
                    name: "graphic_eq"
                    size: Theme.iconSizeLarge
                    color: Theme.primary
                    anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Theme.iconSizeLarge - Theme.spacingM
                    spacing: Theme.spacingXXS

                    StyledText {
                        text: "DARWIN"
                        font.pixelSize: Theme.fontSizeXLarge
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        text: {
                            if (!panel.ok)
                                return "The RS6 DAC";
                            const out = panel.dac.output.name === "Auto" && panel.dac.target
                                ? "Auto: " + panel.dac.target.label : panel.dac.output.label;
                            return out + " · " + (panel.dac.nos ? "NOS" : panel.dac.filter.label);
                        }
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }
            }

            // ---- messages ----
            StyledRect {
                width: parent.width
                visible: !panel.ok
                implicitHeight: missing.implicitHeight + Theme.spacingL * 2
                radius: Theme.cornerRadius
                color: Theme.cardSurface

                StyledText {
                    id: missing
                    x: Theme.spacingL
                    y: Theme.spacingL
                    width: parent.width - Theme.spacingL * 2
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                    text: panel.darwin.monitorFailed
                        ? "darwinctl does not run. It comes with the hiby-rs6-audio package."
                        : "The hm100 DAC controls of the RS6 sound card are not there. They come back on their own once the card shows up."
                }
            }

            StyledRect {
                width: parent.width
                visible: panel.darwin.errorText !== ""
                implicitHeight: errorRow.implicitHeight + Theme.spacingM * 2
                radius: Theme.cornerRadius
                color: Theme.withAlpha(Theme.error, 0.12)

                Row {
                    id: errorRow
                    x: Theme.spacingM
                    y: Theme.spacingM
                    width: parent.width - Theme.spacingM * 2
                    spacing: Theme.spacingS

                    DIcon {
                        name: "error"
                        size: Theme.iconSizeMedium
                        color: Theme.error
                    }

                    StyledText {
                        width: parent.width - Theme.iconSizeMedium - Theme.spacingS
                        text: panel.darwin.errorText
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.error
                    }
                }
            }

            // ---- output ----
            DarwinSection {
                title: "Output"
                visible: panel.ok && !!panel.dac.output

                DFilterChips {
                    id: outputChips
                    width: parent.width
                    chipHeight: panel.chipHeight
                    model: panel.labels(panel.dac.outputs)
                    currentIndex: panel.dac.output ? panel.dac.output.index : -1
                    onSelectionChanged: index => {
                        panel.darwin.setOutput(panel.dac.outputs[index].name);
                        outputChips.currentIndex = Qt.binding(() => panel.dac.output ? panel.dac.output.index : -1);
                    }
                }

                StyledText {
                    width: parent.width
                    visible: !!panel.dac.target
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    text: !panel.dac.target ? "" : panel.dac.output.name === "Auto"
                        ? "Auto follows the plugged jack. Now: " + panel.dac.target.label + "."
                        : "Plays on " + panel.dac.target.label + ", whatever is plugged in."
                }

                StyledText {
                    text: "Gain"
                    visible: !!panel.dac.gain
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                }

                DButtonGroup {
                    id: gainGroup
                    visible: !!panel.dac.gain
                    width: parent.width
                    fillWidth: true
                    maximumWidth: parent.width
                    buttonHeight: panel.chipHeight
                    model: panel.labels(panel.dac.gains)
                    currentIndex: panel.dac.gain ? panel.dac.gain.index : -1
                    onSelectionChanged: (index, selected) => {
                        if (selected)
                            panel.darwin.setGain(panel.dac.gains[index].name);
                    }
                }

                StyledText {
                    width: parent.width
                    visible: !!panel.dac.gain
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    text: "For the 3.5 mm and 4.4 mm headphone outputs."
                }
            }

            // ---- filters ----
            DarwinSection {
                title: "Filter"
                visible: panel.ok

                DToggle {
                    width: parent.width
                    text: "NOS"
                    description: "Non-oversampling: skips the FPGA's oversampling filter."
                    checked: panel.dac.nos === true
                    onToggled: on => panel.darwin.setNos(on)
                }

                StyledText {
                    width: parent.width
                    visible: panel.dac.nos === true
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    text: "The filters below are not used while NOS is on."
                }

                StyledText {
                    text: "Digital filter"
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                }

                // the built-in ones: every Digital Filter item but custom (that is the Darwin filter)
                DFilterChips {
                    id: filterChips
                    readonly property var items: (panel.dac.filters || []).filter((f, i) => i !== panel.dac.custom_index)
                    width: parent.width
                    chipHeight: panel.chipHeight
                    model: items.map(f => f.label)
                    currentIndex: panel.dac.filter && !panel.dac.filter.darwin ? panel.indexOfName(items, panel.dac.filter.name) : -1
                    onSelectionChanged: index => {
                        panel.darwin.setFilter(items[index].name);
                        filterChips.currentIndex = Qt.binding(() => panel.dac.filter && !panel.dac.filter.darwin
                            ? panel.indexOfName(filterChips.items, panel.dac.filter.name) : -1);
                    }
                }

                StyledText {
                    text: "Darwin filters"
                    visible: panel.dac.custom_index >= 0
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                }

                // stock Settings' Darwin filters by their titles, and a loaded file that is none of them
                DFilterChips {
                    id: darwinChips
                    readonly property bool loadedFile: !!panel.dac.darwin && panel.dac.darwin.index < 0
                    readonly property var titles: (panel.dac.darwin_filters || []).map(f => f.title)
                        .concat(loadedFile ? [panel.dac.darwin.title + " (file)"] : [])
                    function current() {
                        if (!panel.dac.darwin || !panel.dac.darwin.active)
                            return -1;
                        return panel.dac.darwin.index >= 0 ? panel.dac.darwin.index : titles.length - 1;
                    }
                    visible: panel.dac.custom_index >= 0
                    width: parent.width
                    chipHeight: panel.chipHeight
                    model: titles
                    currentIndex: current()
                    onSelectionChanged: index => {
                        if (index < panel.dac.darwin_filters.length)
                            panel.darwin.setDarwin(panel.dac.darwin_filters[index].title);
                        else
                            panel.darwin.setFilter("custom");   // the loaded file again
                        darwinChips.currentIndex = Qt.binding(() => darwinChips.current());
                    }
                }

                DButton {
                    visible: panel.dac.custom_index >= 0
                    text: "Load a .flt file"
                    iconName: "file_open"
                    buttonHeight: panel.chipHeight
                    onClicked: panel.darwin.openFileBrowser()
                }

                StyledText {
                    width: parent.width
                    visible: panel.dac.custom_index >= 0
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    text: "HiBy's FIR filters, as stock Settings lists them, or a .flt file of your own (256 taps, 1024 bytes). The Darwin filter stays selected after a reboot."
                }
            }

            // ---- level ----
            DarwinSection {
                title: "Level"
                visible: panel.ok && (!!panel.dac.pregain || !!panel.dac.balance)

                DarwinStepper {
                    visible: !!panel.dac.pregain
                    label: "Pregain"
                    valueText: panel.dac.pregain ? panel.dbText(panel.darwin.wanted("pregain", panel.dac.pregain.value)) : ""
                    decreaseTip: "-0.1 dB"
                    increaseTip: "+0.1 dB"
                    canDecrease: !!panel.dac.pregain && panel.darwin.wanted("pregain", panel.dac.pregain.value) > panel.dac.pregain.min
                    canIncrease: !!panel.dac.pregain && panel.darwin.wanted("pregain", panel.dac.pregain.value) < panel.dac.pregain.max
                    onDecrease: panel.darwin.setPregain(panel.darwin.wanted("pregain", panel.dac.pregain.value) - 1)
                    onIncrease: panel.darwin.setPregain(panel.darwin.wanted("pregain", panel.dac.pregain.value) + 1)
                }

                DSlider {
                    id: pregainSlider
                    visible: !!panel.dac.pregain
                    width: parent.width
                    minimum: panel.dac.pregain ? panel.dac.pregain.min : 0
                    maximum: panel.dac.pregain ? panel.dac.pregain.max : 1
                    step: 5
                    decimals: 1
                    unit: " dB"
                    showValue: false
                    value: panel.dac.pregain ? panel.dac.pregain.value : 0
                    // a tap or a drag sets value itself: follow the driver again once it is over
                    function follow() {
                        pregainSlider.value = Qt.binding(() => panel.dac.pregain ? panel.dac.pregain.value : 0);
                    }
                    onSliderValueChanged: v => {
                        panel.darwin.setPregain(v);
                        if (!pregainSlider.isDragging)
                            follow();
                    }
                    onSliderDragFinished: v => {
                        panel.darwin.setPregain(v);
                        follow();
                    }
                }

                StyledText {
                    width: parent.width
                    visible: !!panel.dac.pregain
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    text: "For the 3.5 mm and 4.4 mm headphone outputs. The line outs stay at a fixed level."
                }

                DarwinStepper {
                    visible: !!panel.dac.balance
                    label: "L/R balance"
                    valueText: panel.dac.balance ? panel.balanceText(panel.darwin.wanted("balance", panel.dac.balance.value)) : ""
                    decreaseIcon: "chevron_left"
                    increaseIcon: "chevron_right"
                    decreaseTip: "Towards the left"
                    increaseTip: "Towards the right"
                    note: "Raises one channel in 0.5 dB steps, on the headphone outputs."
                    canDecrease: !!panel.dac.balance && panel.darwin.wanted("balance", panel.dac.balance.value) > panel.dac.balance.min
                    canIncrease: !!panel.dac.balance && panel.darwin.wanted("balance", panel.dac.balance.value) < panel.dac.balance.max
                    onDecrease: panel.darwin.setBalance(panel.darwin.wanted("balance", panel.dac.balance.value) - 1)
                    onIncrease: panel.darwin.setBalance(panel.darwin.wanted("balance", panel.dac.balance.value) + 1)
                }

                // always there (disabled when centered): nothing below moves under the finger
                DButton {
                    visible: !!panel.dac.balance
                    enabled: !!panel.dac.balance && panel.darwin.wanted("balance", panel.dac.balance.value) !== 0
                    text: "Center"
                    iconName: "align_horizontal_center"
                    buttonHeight: panel.chipHeight
                    onClicked: panel.darwin.setBalance(0)
                }
            }

            // ---- power ----
            DarwinSection {
                title: "Power"
                visible: panel.ok && !!panel.dac.idle_off

                DarwinStepper {
                    label: "Idle power off"
                    valueText: panel.dac.idle_off ? panel.idleText(panel.darwin.wanted("idle", panel.dac.idle_off.value)) : ""
                    decreaseTip: "-10 seconds"
                    increaseTip: "+10 seconds"
                    note: "Powers the DAC and amps off after this long without playback."
                    canDecrease: !!panel.dac.idle_off && panel.darwin.wanted("idle", panel.dac.idle_off.value) > panel.dac.idle_off.min
                    canIncrease: !!panel.dac.idle_off && panel.darwin.wanted("idle", panel.dac.idle_off.value) < panel.dac.idle_off.max
                    onDecrease: panel.darwin.setIdleOff(panel.darwin.wanted("idle", panel.dac.idle_off.value) - 10)
                    onIncrease: panel.darwin.setIdleOff(panel.darwin.wanted("idle", panel.dac.idle_off.value) + 10)
                }

                DFilterChips {
                    id: idleChips
                    readonly property var seconds: [0, 60, 300, 900, 3600]
                    width: parent.width
                    chipHeight: panel.chipHeight
                    model: ["Never", "1 min", "5 min", "15 min", "1 h"]
                    currentIndex: panel.dac.idle_off ? seconds.indexOf(panel.dac.idle_off.value) : -1
                    onSelectionChanged: index => {
                        panel.darwin.setIdleOff(seconds[index]);
                        idleChips.currentIndex = Qt.binding(() => panel.dac.idle_off ? idleChips.seconds.indexOf(panel.dac.idle_off.value) : -1);
                    }
                }
            }

            // ---- DSD ----
            DarwinSection {
                title: "DSD"
                visible: panel.ok && (!!panel.dac.dsd_mode || !!panel.dac.dsd_compensate)

                StyledText {
                    text: "DSD filter"
                    visible: !!panel.dac.dsd_mode
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                }

                DButtonGroup {
                    visible: !!panel.dac.dsd_mode
                    width: parent.width
                    fillWidth: true
                    maximumWidth: parent.width
                    buttonHeight: panel.chipHeight
                    model: panel.labels(panel.dac.dsd_modes)
                    currentIndex: panel.dac.dsd_mode ? panel.dac.dsd_mode.index : -1
                    onSelectionChanged: (index, selected) => {
                        if (selected)
                            panel.darwin.setDsdMode(panel.dac.dsd_modes[index].name);
                    }
                }

                StyledText {
                    width: parent.width
                    visible: !!panel.dac.dsd_mode
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    text: "Native DSD: Darwin Default plays it on the FPGA's DSD design, Darwin 1 on the PCM one. It applies from the next track."
                }

                DarwinStepper {
                    visible: !!panel.dac.dsd_compensate
                    label: "DSD level"
                    valueText: panel.dac.dsd_compensate ? panel.dbText(panel.darwin.wanted("dsdcomp", panel.dac.dsd_compensate.value) * 5) : ""
                    decreaseTip: "-0.5 dB"
                    increaseTip: "+0.5 dB"
                    note: "Added on DSD streams, on the headphone outputs."
                    canDecrease: !!panel.dac.dsd_compensate && panel.darwin.wanted("dsdcomp", panel.dac.dsd_compensate.value) > panel.dac.dsd_compensate.min
                    canIncrease: !!panel.dac.dsd_compensate && panel.darwin.wanted("dsdcomp", panel.dac.dsd_compensate.value) < panel.dac.dsd_compensate.max
                    onDecrease: panel.darwin.setDsdCompensate(panel.darwin.wanted("dsdcomp", panel.dac.dsd_compensate.value) - 1)
                    onIncrease: panel.darwin.setDsdCompensate(panel.darwin.wanted("dsdcomp", panel.dac.dsd_compensate.value) + 1)
                }
            }
        }
    }
}
