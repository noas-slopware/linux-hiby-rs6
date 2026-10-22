// SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
// SPDX-License-Identifier: MIT

import org.kde.plasma.private.mobileshell.quicksettingsplugin as QS

import codes.noa.rs6dac

// Tap: next gain step (wraps). Long press: the RS6 DAC settings page.
QS.QuickSetting {
    text: i18n("Gain")
    icon: "audio-card"
    available: DacControl.available
    enabled: DacControl.available
    status: {
        const gain = DacControl.gainNames[DacControl.gain] ?? "";
        const output = DacControl.outputNames[DacControl.output] ?? "";
        return i18nc("gain · output", "%1 · %2", gain, output);
    }
    settingsCommand: "plasma-open-settings kcm_rs6dac"

    function toggle() {
        const count = DacControl.gainNames.length;
        if (count > 0) {
            DacControl.gain = (DacControl.gain + 1) % count;
        }
    }
}
