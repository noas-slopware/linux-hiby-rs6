// SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
// SPDX-License-Identifier: MIT
//
// One card of the DARWIN popout: a title, then its rows.

import QtQuick
import qs.Common
import qs.DCommon.Widgets

StyledRect {
    id: section

    property string title: ""
    default property alias rows: body.data

    width: parent ? parent.width : 0
    implicitHeight: body.implicitHeight + Theme.spacingL * 2
    radius: Theme.cornerRadius
    color: Theme.cardSurface

    Column {
        id: body
        x: Theme.spacingL
        y: Theme.spacingL
        width: parent.width - Theme.spacingL * 2
        spacing: Theme.spacingM

        StyledText {
            text: section.title
            visible: text !== ""
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.primary
        }
    }
}
