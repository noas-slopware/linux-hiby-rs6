// SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
// SPDX-License-Identifier: MIT

import org.kde.plasma.private.mobileshell.quicksettingsplugin as QS

import codes.noa.rs6dac

// Tap: portrait <-> landscape (the RS6 has no accelerometer for auto-rotation).
QS.QuickSetting {
    text: i18n("Rotate")
    icon: "object-rotate-right"
    available: DisplayRotation.available
    enabled: DisplayRotation.landscape
    status: DisplayRotation.landscape ? i18n("Landscape") : i18n("Portrait")
    settingsCommand: "plasma-open-settings kcm_kscreen"

    function toggle() {
        DisplayRotation.toggle();
    }
}
