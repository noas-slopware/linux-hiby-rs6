// SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
// SPDX-License-Identifier: MIT
//
// DacControl: the HiBy RS6 hm100 DAC controls (snd-soc-hiby-hm100) for QML.
// One singleton per QML engine owns the ALSA control handle; every value shown is read
// back from ALSA, and control events keep all users (KCM, quick setting, alsamixer,
// jack auto-switching in the driver) in sync.

#pragma once

#include <QList>
#include <QObject>
#include <QQmlEngine>
#include <QStringList>
#include <QUrl>

typedef struct _snd_ctl snd_ctl_t;
class QSocketNotifier;
class QTimer;

class DacControl : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(bool available READ available NOTIFY availableChanged)

    Q_PROPERTY(bool nos READ nos WRITE setNos NOTIFY nosChanged)

    Q_PROPERTY(int output READ output WRITE setOutput NOTIFY outputChanged)
    Q_PROPERTY(QStringList outputNames READ outputNames NOTIFY outputNamesChanged)

    Q_PROPERTY(int gain READ gain WRITE setGain NOTIFY gainChanged)
    Q_PROPERTY(QStringList gainNames READ gainNames NOTIFY gainNamesChanged)

    Q_PROPERTY(int filter READ filter WRITE setFilter NOTIFY filterChanged)
    Q_PROPERTY(QStringList filterNames READ filterNames NOTIFY filterNamesChanged)
    // the driver's "custom" item: the Darwin filter (.flt) that darwinctl loaded
    Q_PROPERTY(int darwinFilterIndex READ darwinFilterIndex NOTIFY filterNamesChanged)
    // the Darwin filters darwinctl knows (stock Settings' order and titles), and the active one
    Q_PROPERTY(QStringList darwinNames READ darwinNames NOTIFY darwinChanged)
    Q_PROPERTY(int darwin READ darwin NOTIFY darwinChanged)
    // what the filter is called right now: the built-in name or the Darwin filter's
    Q_PROPERTY(QString filterLabel READ filterLabel NOTIFY darwinChanged)

    // 0.1 dB units
    Q_PROPERTY(int pregain READ pregain WRITE setPregain NOTIFY pregainChanged)
    Q_PROPERTY(int pregainMin READ pregainMin NOTIFY rangesChanged)
    Q_PROPERTY(int pregainMax READ pregainMax NOTIFY rangesChanged)

    // 0.5 dB units; < 0 raises the left channel, > 0 the right one
    Q_PROPERTY(int lrBalance READ lrBalance WRITE setLrBalance NOTIFY lrBalanceChanged)
    Q_PROPERTY(int lrBalanceMin READ lrBalanceMin NOTIFY rangesChanged)
    Q_PROPERTY(int lrBalanceMax READ lrBalanceMax NOTIFY rangesChanged)

    // seconds without a stream before the analog chain powers off, 0 = never
    Q_PROPERTY(int idleOffSeconds READ idleOffSeconds WRITE setIdleOffSeconds NOTIFY idleOffSecondsChanged)
    Q_PROPERTY(int idleOffSecondsMin READ idleOffSecondsMin NOTIFY rangesChanged)
    Q_PROPERTY(int idleOffSecondsMax READ idleOffSecondsMax NOTIFY rangesChanged)

    // last ALSA error from a write or a filter load, empty after a successful one
    Q_PROPERTY(QString errorString READ errorString NOTIFY errorStringChanged)

public:
    explicit DacControl(QObject *parent = nullptr);
    ~DacControl() override;

    bool available() const { return m_handle != nullptr; }

    bool nos() const { return m_elems[Nos].value != 0; }
    int output() const { return m_elems[Output].value; }
    QStringList outputNames() const { return m_elems[Output].labels; }
    int gain() const { return m_elems[Gain].value; }
    QStringList gainNames() const { return m_elems[Gain].labels; }
    int filter() const { return m_elems[Filter].value; }
    QStringList filterNames() const { return m_elems[Filter].labels; }
    int darwinFilterIndex() const { return m_customIndex; }
    QStringList darwinNames() const { return m_darwinNames; }
    int darwin() const { return m_darwinActive; }
    QString filterLabel() const;
    int pregain() const { return m_elems[Pregain].value; }
    int pregainMin() const { return m_elems[Pregain].min; }
    int pregainMax() const { return m_elems[Pregain].max; }
    int lrBalance() const { return m_elems[LrBalance].value; }
    int lrBalanceMin() const { return m_elems[LrBalance].min; }
    int lrBalanceMax() const { return m_elems[LrBalance].max; }
    int idleOffSeconds() const { return m_elems[IdleOff].value; }
    int idleOffSecondsMin() const { return m_elems[IdleOff].min; }
    int idleOffSecondsMax() const { return m_elems[IdleOff].max; }
    QString errorString() const { return m_error; }

    void setNos(bool on);
    void setOutput(int index);
    void setGain(int index);
    void setFilter(int index);
    void setPregain(int value);
    void setLrBalance(int value);
    void setIdleOffSeconds(int value);

    // Darwin filters go through darwinctl, which also keeps them for the next boot.
    // Load a .flt (256 int32 taps, 1024 bytes). Returns true on success, else errorString says why.
    Q_INVOKABLE bool loadFir(const QUrl &url);
    // Select darwinNames[index].
    Q_INVOKABLE bool setDarwin(int index);

Q_SIGNALS:
    void availableChanged();
    void nosChanged();
    void outputChanged();
    void outputNamesChanged();
    void gainChanged();
    void gainNamesChanged();
    void filterChanged();
    void filterNamesChanged();
    void pregainChanged();
    void lrBalanceChanged();
    void idleOffSecondsChanged();
    void rangesChanged();
    void errorStringChanged();
    void darwinChanged();

private:
    enum Id { Nos, Output, Gain, Filter, Pregain, LrBalance, IdleOff, Fir, Count };

    struct Elem {
        unsigned int numid = 0;
        int min = 0;
        int max = 0;
        int value = 0;
        QStringList labels;
    };

    bool tryOpen();
    void close();
    void onEvents();
    bool readInfo(Id id);
    void readValue(Id id);
    void write(Id id, int value);
    void setError(const QString &error);
    void emitValue(Id id);
    void emitInfo(Id id);
    bool darwinctl(const QStringList &args, QString *output = nullptr);
    void refreshDarwin();

    snd_ctl_t *m_handle = nullptr;
    QList<QSocketNotifier *> m_notifiers;
    QTimer *m_retry = nullptr;
    Elem m_elems[Count];
    QString m_error;
    int m_customIndex = -1;
    QStringList m_darwinNames;
    QStringList m_darwinPaths; // "" for a loaded file that is not one of the filters
    int m_darwinActive = -1;
};
