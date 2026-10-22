// SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
// SPDX-License-Identifier: MIT
#include "display-rotation.h"

#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>

using namespace Qt::StringLiterals;

/* libkscreen rotation values as kscreen-doctor -j prints them */
static constexpr int RotNone = 1, RotLeft = 2, RotRight = 8;

DisplayRotation::DisplayRotation(QObject *parent)
    : QObject(parent)
{
    refresh();
}

void DisplayRotation::refresh()
{
    if (m_query)
        return;
    m_query = new QProcess(this);
    connect(m_query, &QProcess::finished, this, [this] {
        parse(m_query->readAllStandardOutput());
        m_query->deleteLater();
        m_query = nullptr;
    });
    connect(m_query, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
        if (m_query->state() == QProcess::NotRunning) {
            m_query->deleteLater();
            m_query = nullptr;
        }
    });
    m_query->start(u"kscreen-doctor"_s, {u"-j"_s});
}

void DisplayRotation::parse(const QByteArray &json)
{
    const auto outputs = QJsonDocument::fromJson(json).object().value("outputs"_L1).toArray();
    QString name;
    bool landscape = false;

    /* the built-in panel: prefer an enabled DSI/eDP output, else the first enabled one */
    for (const auto &v : outputs) {
        const auto o = v.toObject();
        if (!o.value("enabled"_L1).toBool() || !o.value("connected"_L1).toBool(true))
            continue;
        const QString n = o.value("name"_L1).toString();
        const int rot = o.value("rotation"_L1).toInt(RotNone);
        if (name.isEmpty() || n.startsWith("DSI"_L1) || n.startsWith("eDP"_L1)) {
            name = n;
            landscape = rot == RotRight || rot == RotLeft;
        }
        if (n.startsWith("DSI"_L1) || n.startsWith("eDP"_L1))
            break;
    }
    if (name != m_output || landscape != m_landscape) {
        m_output = name;
        m_landscape = landscape;
        Q_EMIT changed();
    }
}

void DisplayRotation::toggle()
{
    if (m_output.isEmpty())
        return;
    const QString rot = m_landscape ? u"normal"_s : u"right"_s;
    auto *p = new QProcess(this);
    connect(p, &QProcess::finished, this, [this, p] {
        p->deleteLater();
        refresh();
    });
    p->start(u"kscreen-doctor"_s, {u"output.%1.rotation.%2"_s.arg(m_output, rot)});
    /* reflect the change right away; refresh() corrects it if kscreen refused */
    m_landscape = !m_landscape;
    Q_EMIT changed();
}
