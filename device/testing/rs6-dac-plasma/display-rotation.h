// SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
// SPDX-License-Identifier: MIT
#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QString>

class QProcess;

/* Manual portrait/landscape switch for the built-in panel, through kscreen-doctor (libkscreen),
 * for devices without a usable accelerometer. */
class DisplayRotation : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(bool available READ available NOTIFY changed)
    Q_PROPERTY(bool landscape READ landscape NOTIFY changed)

public:
    explicit DisplayRotation(QObject *parent = nullptr);

    bool available() const { return !m_output.isEmpty(); }
    bool landscape() const { return m_landscape; }

    Q_INVOKABLE void toggle();
    Q_INVOKABLE void refresh();

Q_SIGNALS:
    void changed();

private:
    void parse(const QByteArray &json);

    QString m_output;
    bool m_landscape = false;
    QProcess *m_query = nullptr;
};
