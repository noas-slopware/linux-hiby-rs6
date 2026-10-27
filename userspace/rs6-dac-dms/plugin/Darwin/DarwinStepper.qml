// SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
// SPDX-License-Identifier: MIT
//
// A value with finger-sized - and + buttons (held down, they repeat): label and value on the
// left, the buttons on the right, a short note below.

import QtQuick
import qs.Common
import qs.DCommon.Widgets

Item {
    id: stepper

    property string label: ""
    property string valueText: ""
    property string note: ""
    property string decreaseIcon: "remove"
    property string increaseIcon: "add"
    property string decreaseTip: ""
    property string increaseTip: ""
    property bool canDecrease: true
    property bool canIncrease: true
    readonly property int buttonSize: 44

    signal decrease
    signal increase

    width: parent ? parent.width : 0
    implicitHeight: Math.max(buttons.height, texts.implicitHeight)

    Column {
        id: texts
        anchors.left: parent.left
        anchors.right: buttons.left
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingXXS

        StyledText {
            width: parent.width
            text: stepper.label
            font.pixelSize: Theme.fontSizeMedium
            color: Theme.surfaceText
            elide: Text.ElideRight
        }

        StyledText {
            width: parent.width
            text: stepper.valueText
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Medium
            color: Theme.surfaceText
            elide: Text.ElideRight
        }

        StyledText {
            width: parent.width
            text: stepper.note
            visible: text !== ""
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
    }

    Row {
        id: buttons
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingS

        DActionButton {
            buttonSize: stepper.buttonSize
            iconName: stepper.decreaseIcon
            iconSize: Theme.iconSize
            iconColor: Theme.onSurface
            backgroundColor: Theme.chipSurface
            tooltipText: stepper.decreaseTip || null
            enabled: stepper.canDecrease
            autoRepeat: true
            autoRepeatDelay: 400
            autoRepeatInterval: 90
            onClicked: stepper.decrease()
        }

        DActionButton {
            buttonSize: stepper.buttonSize
            iconName: stepper.increaseIcon
            iconSize: Theme.iconSize
            iconColor: Theme.onSurface
            backgroundColor: Theme.chipSurface
            tooltipText: stepper.increaseTip || null
            enabled: stepper.canIncrease
            autoRepeat: true
            autoRepeatDelay: 400
            autoRepeatInterval: 90
            onClicked: stepper.increase()
        }
    }
}
