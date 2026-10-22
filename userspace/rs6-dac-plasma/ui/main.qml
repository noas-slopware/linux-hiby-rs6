// SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
// SPDX-License-Identifier: MIT

import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.kirigamiaddons.formcard as FormCard

import codes.noa.rs6dac

KCM.SimpleKCM {
    id: root

    leftPadding: 0
    rightPadding: 0
    topPadding: 0
    bottomPadding: 0

    // what the last .flt load did, shown under the Custom filter row
    property string firStatus: ""

    // 0.1 dB (Pregain) and 0.5 dB (LR Balance) steps as text, and back
    function dbText(db, locale) {
        return (db > 0 ? "+" : "") + Number(db).toLocaleString(locale, "f", 1) + " dB";
    }
    function dbValue(text, locale) {
        const t = text.replace(/dB/i, "").replace("+", "").trim();
        const v = Number.fromLocaleString(locale, t);
        return isNaN(v) ? 0 : v;
    }

    ColumnLayout {
        spacing: 0

        Kirigami.PlaceholderMessage {
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.gridUnit * 2
            visible: !DacControl.available
            icon.name: "audio-card"
            text: i18n("RS6 DAC not found")
            explanation: i18n("The hm100 DAC controls of the RS6 sound card are not there. They come back on their own once the card shows up.")
        }

        ColumnLayout {
            spacing: 0
            Layout.fillWidth: true
            visible: DacControl.available

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                Layout.margins: Kirigami.Units.largeSpacing
                type: Kirigami.MessageType.Error
                visible: DacControl.errorString !== ""
                text: DacControl.errorString
            }

            FormCard.FormHeader {
                title: i18n("Output")
            }

            FormCard.FormCard {
                FormCard.FormComboBoxDelegate {
                    id: outputCombo
                    text: i18n("Output")
                    description: DacControl.output === 0 ? i18n("Auto follows the plugged jack.") : ""
                    model: DacControl.outputNames
                    currentIndex: DacControl.output
                    onActivated: index => {
                        DacControl.output = index;
                        outputCombo.currentIndex = Qt.binding(() => DacControl.output);
                    }
                }

                FormCard.FormDelegateSeparator { above: outputCombo; below: gainCombo }

                FormCard.FormComboBoxDelegate {
                    id: gainCombo
                    text: i18n("Gain")
                    description: i18n("For the 3.5 mm and 4.4 mm headphone outputs.")
                    model: DacControl.gainNames
                    currentIndex: DacControl.gain
                    onActivated: index => {
                        DacControl.gain = index;
                        gainCombo.currentIndex = Qt.binding(() => DacControl.gain);
                    }
                }
            }

            FormCard.FormHeader {
                title: i18n("DAC")
            }

            FormCard.FormCard {
                FormCard.FormSwitchDelegate {
                    id: nosSwitch
                    text: i18n("NOS")
                    description: i18n("Non-oversampling: bypass the FPGA oversampling filter.")
                    checked: DacControl.nos
                    onToggled: {
                        DacControl.nos = nosSwitch.checked;
                        nosSwitch.checked = Qt.binding(() => DacControl.nos);
                    }
                }

                FormCard.FormDelegateSeparator { above: nosSwitch; below: filterCombo }

                FormCard.FormComboBoxDelegate {
                    id: filterCombo
                    text: i18n("Digital filter")
                    description: DacControl.nos ? i18n("Not used while NOS is on.") : ""
                    model: DacControl.filterNames
                    currentIndex: DacControl.filter
                    onActivated: index => {
                        DacControl.filter = index;
                        filterCombo.currentIndex = Qt.binding(() => DacControl.filter);
                    }
                }

                FormCard.FormDelegateSeparator {
                    visible: darwinCombo.visible
                    above: filterCombo
                    below: darwinCombo
                }

                FormCard.FormComboBoxDelegate {
                    id: darwinCombo
                    visible: DacControl.filter === DacControl.darwinFilterIndex && DacControl.darwinNames.length > 0
                    text: i18n("Darwin filter")
                    description: i18n("HiBy's FIR filters, as stock Settings lists them. Also: darwinctl.")
                    model: DacControl.darwinNames
                    currentIndex: DacControl.darwin
                    onActivated: index => {
                        DacControl.setDarwin(index);
                        darwinCombo.currentIndex = Qt.binding(() => DacControl.darwin);
                    }
                }

                FormCard.FormDelegateSeparator { above: darwinCombo.visible ? darwinCombo : filterCombo; below: firButton }

                FormCard.FormButtonDelegate {
                    id: firButton
                    text: i18n("Load a Darwin filter file")
                    description: root.firStatus !== "" ? root.firStatus : i18n("A .flt file (256 taps, 1024 bytes). It stays selected after a reboot.")
                    icon.name: "document-open"
                    onClicked: firDialog.open()
                }

                FormCard.FormDelegateSeparator { above: firButton; below: hdrSwitch }

                FormCard.FormSwitchDelegate {
                    id: hdrSwitch
                    text: i18n("HDR")
                    description: i18n("Not available yet: the stock HDR upsampler lives in the closed HAL.")
                    checked: false
                    enabled: false
                }
            }

            FormCard.FormHeader {
                title: i18n("Level")
            }

            FormCard.FormCard {
                FormCard.FormSpinBoxDelegate {
                    id: pregainSpin
                    label: i18n("Pregain")
                    description: i18n("For the 3.5 mm and 4.4 mm headphone outputs. The line outs stay at a fixed level.")
                    from: DacControl.pregainMin
                    to: DacControl.pregainMax
                    stepSize: 5
                    value: DacControl.pregain
                    textFromValue: (value, locale) => root.dbText(value / 10, locale)
                    valueFromText: (text, locale) => Math.round(root.dbValue(text, locale) * 10)
                    validator: RegularExpressionValidator {
                        regularExpression: /[+-]?\d{0,3}([.,]\d?)?\s*(dB)?/i
                    }
                    onValueModified: {
                        DacControl.pregain = pregainSpin.value;
                        pregainSpin.value = Qt.binding(() => DacControl.pregain);
                    }
                }

                FormCard.FormDelegateSeparator { above: pregainSpin; below: balanceSpin }

                FormCard.FormSpinBoxDelegate {
                    id: balanceSpin
                    label: i18n("L/R balance")
                    description: i18n("Raises one channel in 0.5 dB steps, on the headphone outputs.")
                    from: DacControl.lrBalanceMin
                    to: DacControl.lrBalanceMax
                    stepSize: 1
                    value: DacControl.lrBalance
                    // the driver raises the left channel below 0 and the right one above 0
                    textFromValue: (value, locale) => value === 0 ? i18n("Center")
                        : (value < 0 ? i18nc("left channel raised by", "L %1", root.dbText(-value / 2, locale))
                                     : i18nc("right channel raised by", "R %1", root.dbText(value / 2, locale)))
                    valueFromText: (text, locale) => {
                        const t = text.trim();
                        if (t === "" || t.toLowerCase() === i18n("Center").toLowerCase()) {
                            return 0;
                        }
                        const side = t.charAt(0).toUpperCase();
                        const db = Math.abs(root.dbValue(t.replace(/^[LR]\s*/i, ""), locale));
                        return Math.round(db * 2) * (side === "L" ? -1 : 1);
                    }
                    validator: RegularExpressionValidator {
                        regularExpression: /.{0,24}/
                    }
                    onValueModified: {
                        DacControl.lrBalance = balanceSpin.value;
                        balanceSpin.value = Qt.binding(() => DacControl.lrBalance);
                    }
                }
            }

            FormCard.FormHeader {
                title: i18n("Power")
            }

            FormCard.FormCard {
                FormCard.FormSpinBoxDelegate {
                    id: idleSpin
                    label: i18n("Idle power off")
                    description: i18n("Powers the DAC and amps off after this long without playback. 0 keeps them on.")
                    from: DacControl.idleOffSecondsMin
                    to: DacControl.idleOffSecondsMax
                    stepSize: 10
                    value: DacControl.idleOffSeconds
                    textFromValue: (value, locale) => value === 0 ? i18n("Never") : i18np("%1 second", "%1 seconds", value)
                    valueFromText: (text, locale) => {
                        const v = parseInt(text, 10);
                        return isNaN(v) ? 0 : v;
                    }
                    validator: RegularExpressionValidator {
                        regularExpression: /.{0,24}/
                    }
                    onValueModified: {
                        DacControl.idleOffSeconds = idleSpin.value;
                        idleSpin.value = Qt.binding(() => DacControl.idleOffSeconds);
                    }
                }
            }
        }
    }

    data: [
        FileDialog {
            id: firDialog
            title: i18n("Custom filter")
            fileMode: FileDialog.OpenFile
            nameFilters: [i18n("Filters (*.flt)"), i18n("All files (*)")]
            onAccepted: {
                const name = selectedFile.toString().split("/").pop();
                root.firStatus = DacControl.loadFir(selectedFile)
                    ? i18n("Loaded %1.", decodeURIComponent(name))
                    : DacControl.errorString;
            }
        }
    ]
}
