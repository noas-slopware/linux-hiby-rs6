// SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
// SPDX-License-Identifier: MIT

#include "dac-control.h"

#include <QFile>
#include <QProcess>
#include <QHash>
#include <QLoggingCategory>
#include <QSocketNotifier>
#include <QTimer>

#include <alsa/asoundlib.h>

#include <cerrno>
#include <cstring>
#include <memory>
#include <vector>

Q_LOGGING_CATEGORY(RS6DAC, "codes.noa.rs6dac", QtInfoMsg)

namespace
{
// snd-soc-hiby-hm100 control names, in DacControl::Id order
constexpr const char *kNames[] = {
    "NOS Switch", "Output", "Gain", "Digital Filter", "Pregain", "LR Balance", "Idle Power Off Seconds", "FIR Custom",
};
constexpr snd_ctl_elem_type_t kTypes[] = {
    SND_CTL_ELEM_TYPE_BOOLEAN,
    SND_CTL_ELEM_TYPE_ENUMERATED,
    SND_CTL_ELEM_TYPE_ENUMERATED,
    SND_CTL_ELEM_TYPE_ENUMERATED,
    SND_CTL_ELEM_TYPE_INTEGER,
    SND_CTL_ELEM_TYPE_INTEGER,
    SND_CTL_ELEM_TYPE_INTEGER,
    SND_CTL_ELEM_TYPE_BYTES,
};
constexpr int kRetryMs = 2000;

// the stock output_select names, as the old RS6 DAC app labelled them
QString outputLabel(const QString &raw)
{
    static const QHash<QString, QString> labels = {
        {QStringLiteral("Auto"), QStringLiteral("Auto")},
        {QStringLiteral("Lineout"), QStringLiteral("3.5 mm line out")},
        {QStringLiteral("Headset"), QStringLiteral("3.5 mm")},
        {QStringLiteral("Balance"), QStringLiteral("4.4 mm balanced")},
        {QStringLiteral("BalanceLo"), QStringLiteral("4.4 mm balanced line out")},
    };
    return labels.value(raw, raw);
}

// "short_delay_sharp_roll_off" -> "Short delay sharp roll off" (Python's str.capitalize())
QString prettyFilterName(QString raw)
{
    raw.replace(QLatin1Char('_'), QLatin1Char(' '));
    return raw.left(1).toUpper() + raw.mid(1).toLower();
}

template<typename T, void (*Free)(T *)>
struct AlsaFree {
    void operator()(T *p) const
    {
        Free(p);
    }
};
using InfoPtr = std::unique_ptr<snd_ctl_elem_info_t, AlsaFree<snd_ctl_elem_info_t, snd_ctl_elem_info_free>>;
using ValuePtr = std::unique_ptr<snd_ctl_elem_value_t, AlsaFree<snd_ctl_elem_value_t, snd_ctl_elem_value_free>>;
using EventPtr = std::unique_ptr<snd_ctl_event_t, AlsaFree<snd_ctl_event_t, snd_ctl_event_free>>;

InfoPtr newInfo()
{
    snd_ctl_elem_info_t *p = nullptr;
    snd_ctl_elem_info_malloc(&p);
    return InfoPtr(p);
}

ValuePtr newValue()
{
    snd_ctl_elem_value_t *p = nullptr;
    snd_ctl_elem_value_malloc(&p);
    return ValuePtr(p);
}

QString alsaError(int err)
{
    return QString::fromLocal8Bit(snd_strerror(err));
}
} // namespace

DacControl::DacControl(QObject *parent)
    : QObject(parent)
    , m_retry(new QTimer(this))
{
    // The card can show up after the shell (the hm100 loads its FPGA image at probe) or go away
    // on a rebind: poll for it while it is missing.
    m_retry->setInterval(kRetryMs);
    connect(m_retry, &QTimer::timeout, this, [this] {
        if (tryOpen())
            m_retry->stop();
    });
    if (!tryOpen())
        m_retry->start();
}

DacControl::~DacControl()
{
    if (m_handle)
        snd_ctl_close(m_handle);
}

bool DacControl::tryOpen()
{
    int card = -1;
    while (snd_card_next(&card) >= 0 && card >= 0) {
        const QByteArray name = "hw:" + QByteArray::number(card);
        snd_ctl_t *handle = nullptr;
        if (snd_ctl_open(&handle, name.constData(), SND_CTL_NONBLOCK) < 0)
            continue;

        // the hm100 card is the one with "NOS Switch"
        auto info = newInfo();
        snd_ctl_elem_info_set_interface(info.get(), SND_CTL_ELEM_IFACE_MIXER);
        snd_ctl_elem_info_set_name(info.get(), kNames[Nos]);
        if (snd_ctl_elem_info(handle, info.get()) < 0) {
            snd_ctl_close(handle);
            continue;
        }

        m_handle = handle;
        bool ok = true;
        for (int id = 0; id < Count && ok; ++id)
            ok = readInfo(Id(id));
        if (!ok) {
            snd_ctl_close(m_handle);
            m_handle = nullptr;
            continue;
        }

        int err = snd_ctl_subscribe_events(m_handle, 1);
        if (err < 0) {
            qCWarning(RS6DAC) << name << "cannot subscribe to control events:" << alsaError(err);
            snd_ctl_close(m_handle);
            m_handle = nullptr;
            return false;
        }

        const int nfds = snd_ctl_poll_descriptors_count(m_handle);
        std::vector<pollfd> fds(nfds > 0 ? nfds : 0);
        if (nfds <= 0 || snd_ctl_poll_descriptors(m_handle, fds.data(), nfds) != nfds) {
            qCWarning(RS6DAC) << name << "has no control poll descriptors";
            snd_ctl_close(m_handle);
            m_handle = nullptr;
            return false;
        }
        for (const pollfd &fd : fds) {
            auto *notifier = new QSocketNotifier(fd.fd, QSocketNotifier::Read, this);
            connect(notifier, &QSocketNotifier::activated, this, &DacControl::onEvents);
            m_notifiers.append(notifier);
        }

        for (int id = 0; id < Fir; ++id)
            readValue(Id(id));
        qCInfo(RS6DAC) << "using" << name;
        for (int id = 0; id < Fir; ++id)
            emitValue(Id(id)); // the first read may equal the defaults
        Q_EMIT rangesChanged();
        Q_EMIT outputNamesChanged();
        Q_EMIT gainNamesChanged();
        Q_EMIT filterNamesChanged();
        refreshDarwin();
        Q_EMIT availableChanged();
        return true;
    }
    return false;
}

void DacControl::close()
{
    for (QSocketNotifier *notifier : std::as_const(m_notifiers)) {
        notifier->setEnabled(false);
        notifier->deleteLater(); // close() can run inside the notifier's own activated()
    }
    m_notifiers.clear();
    if (m_handle) {
        snd_ctl_close(m_handle);
        m_handle = nullptr;
    }
    for (Elem &e : m_elems)
        e = Elem();
    Q_EMIT availableChanged();
    for (int id = 0; id < Fir; ++id) {
        emitValue(Id(id));
        emitInfo(Id(id));
    }
    m_retry->start();
}

bool DacControl::readInfo(Id id)
{
    Elem &e = m_elems[id];
    auto info = newInfo();
    snd_ctl_elem_info_set_interface(info.get(), SND_CTL_ELEM_IFACE_MIXER);
    snd_ctl_elem_info_set_name(info.get(), kNames[id]);
    int err = snd_ctl_elem_info(m_handle, info.get());
    if (err < 0) {
        qCWarning(RS6DAC) << "control" << kNames[id] << "missing:" << alsaError(err);
        return false;
    }
    if (snd_ctl_elem_info_get_type(info.get()) != kTypes[id]) {
        qCWarning(RS6DAC) << "control" << kNames[id] << "has an unexpected type" << snd_ctl_elem_info_get_type(info.get());
        return false;
    }
    e.numid = snd_ctl_elem_info_get_numid(info.get());

    switch (kTypes[id]) {
    case SND_CTL_ELEM_TYPE_ENUMERATED: {
        QStringList labels;
        const unsigned int items = snd_ctl_elem_info_get_items(info.get());
        for (unsigned int i = 0; i < items; ++i) {
            snd_ctl_elem_info_set_item(info.get(), i);
            err = snd_ctl_elem_info(m_handle, info.get());
            if (err < 0) {
                qCWarning(RS6DAC) << "control" << kNames[id] << "item" << i << ":" << alsaError(err);
                return false;
            }
            const QString raw = QString::fromUtf8(snd_ctl_elem_info_get_item_name(info.get()));
            if (id == Filter && raw == QLatin1String("custom")) {
                m_customIndex = int(i);
                labels.append(QStringLiteral("Darwin filter"));
                continue;
            }
            labels.append(id == Output ? outputLabel(raw) : id == Filter ? prettyFilterName(raw) : raw);
        }
        e.labels = labels;
        break;
    }
    case SND_CTL_ELEM_TYPE_INTEGER:
        e.min = int(snd_ctl_elem_info_get_min(info.get()));
        e.max = int(snd_ctl_elem_info_get_max(info.get()));
        break;
    case SND_CTL_ELEM_TYPE_BOOLEAN:
        e.min = 0;
        e.max = 1;
        break;
    default:
        break;
    }
    return true;
}

void DacControl::readValue(Id id)
{
    Elem &e = m_elems[id];
    if (!m_handle || id == Fir)
        return;
    auto value = newValue();
    snd_ctl_elem_value_set_interface(value.get(), SND_CTL_ELEM_IFACE_MIXER);
    snd_ctl_elem_value_set_numid(value.get(), e.numid);
    const int err = snd_ctl_elem_read(m_handle, value.get());
    if (err < 0) {
        qCWarning(RS6DAC) << "reading" << kNames[id] << "failed:" << alsaError(err);
        return;
    }
    int v = 0;
    switch (kTypes[id]) {
    case SND_CTL_ELEM_TYPE_BOOLEAN:
        v = snd_ctl_elem_value_get_boolean(value.get(), 0) ? 1 : 0;
        break;
    case SND_CTL_ELEM_TYPE_ENUMERATED:
        v = int(snd_ctl_elem_value_get_enumerated(value.get(), 0));
        break;
    default:
        v = int(snd_ctl_elem_value_get_integer(value.get(), 0));
        break;
    }
    if (v != e.value) {
        e.value = v;
        emitValue(id);
        if (id == Filter) {
            refreshDarwin(); // a filter load elsewhere (darwinctl) also lands here
            Q_EMIT darwinChanged(); // filterLabel follows the filter too
        }
    }
}

void DacControl::write(Id id, int v)
{
    if (!m_handle) {
        setError(QStringLiteral("The RS6 DAC controls are not available."));
        return;
    }
    const Elem &e = m_elems[id];
    auto value = newValue();
    snd_ctl_elem_value_set_interface(value.get(), SND_CTL_ELEM_IFACE_MIXER);
    snd_ctl_elem_value_set_numid(value.get(), e.numid);
    switch (kTypes[id]) {
    case SND_CTL_ELEM_TYPE_BOOLEAN:
        snd_ctl_elem_value_set_boolean(value.get(), 0, v ? 1 : 0);
        break;
    case SND_CTL_ELEM_TYPE_ENUMERATED:
        snd_ctl_elem_value_set_enumerated(value.get(), 0, unsigned(v));
        break;
    default:
        snd_ctl_elem_value_set_integer(value.get(), 0, v);
        break;
    }
    const int err = snd_ctl_elem_write(m_handle, value.get());
    if (err < 0)
        setError(QStringLiteral("%1: %2").arg(QString::fromLatin1(kNames[id]), alsaError(err)));
    else
        setError(QString());
    readValue(id); // show what the driver took, not what was asked for
}

void DacControl::onEvents()
{
    if (!m_handle)
        return;
    snd_ctl_event_t *raw = nullptr;
    snd_ctl_event_malloc(&raw);
    EventPtr event(raw);
    bool lost = false;
    int err;
    while ((err = snd_ctl_read(m_handle, event.get())) > 0) {
        if (snd_ctl_event_get_type(event.get()) != SND_CTL_EVENT_ELEM)
            continue;
        const unsigned int numid = snd_ctl_event_elem_get_numid(event.get());
        const unsigned int mask = snd_ctl_event_elem_get_mask(event.get());
        int id = 0;
        while (id < Count && m_elems[id].numid != numid)
            ++id;
        if (id == Count)
            continue; // not ours (e.g. PipeWire's "Headphone Playback Volume")
        if (mask == SND_CTL_EVENT_MASK_REMOVE) {
            lost = true;
            break;
        }
        if (mask & SND_CTL_EVENT_MASK_INFO) {
            if (!readInfo(Id(id))) {
                lost = true;
                break;
            }
            emitInfo(Id(id));
        }
        if (mask & SND_CTL_EVENT_MASK_VALUE)
            readValue(Id(id));
    }
    if (err < 0 && err != -EAGAIN) {
        qCWarning(RS6DAC) << "control events:" << alsaError(err);
        lost = true;
    }
    if (lost) {
        qCInfo(RS6DAC) << "card went away, waiting for it to come back";
        close();
    }
}

bool DacControl::darwinctl(const QStringList &args, QString *output)
{
    QProcess p;
    p.start(QStringLiteral("darwinctl"), args);
    if (!p.waitForFinished(5000)) {
        p.kill();
        setError(QStringLiteral("darwinctl did not run: %1").arg(p.errorString()));
        return false;
    }
    if (p.exitStatus() != QProcess::NormalExit || p.exitCode() != 0) {
        const QString err = QString::fromLocal8Bit(p.readAllStandardError()).trimmed();
        setError(err.isEmpty() ? QStringLiteral("darwinctl %1 failed").arg(args.join(QLatin1Char(' '))) : err);
        return false;
    }
    if (output)
        *output = QString::fromUtf8(p.readAllStandardOutput());
    setError(QString());
    return true;
}

// darwinctl list --porcelain: "preset<TAB>path<TAB>title<TAB>active<TAB>file"
// and, for a loaded file that is not one of them, "file<TAB>-<TAB>name<TAB>1"
void DacControl::refreshDarwin()
{
    QStringList names, paths;
    int active = -1;
    QString out;
    if (m_handle && m_customIndex >= 0 && darwinctl({QStringLiteral("list"), QStringLiteral("--porcelain")}, &out)) {
        const QStringList lines = out.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
        for (const QString &line : lines) {
            const QStringList f = line.split(QLatin1Char('\t'));
            if (f.size() < 4 || (f[0] != QLatin1String("preset") && f[0] != QLatin1String("file")))
                continue;
            if (f[3] == QLatin1String("1"))
                active = int(names.size());
            names.append(f[0] == QLatin1String("file") ? QStringLiteral("%1 (file)").arg(f[2]) : f[2]);
            paths.append(f[0] == QLatin1String("file") ? QString() : f[1]);
        }
    }
    if (names == m_darwinNames && paths == m_darwinPaths && active == m_darwinActive)
        return;
    m_darwinNames = names;
    m_darwinPaths = paths;
    m_darwinActive = active;
    Q_EMIT darwinChanged();
}

QString DacControl::filterLabel() const
{
    const int v = m_elems[Filter].value;
    if (v == m_customIndex && m_darwinActive >= 0)
        return m_darwinNames.value(m_darwinActive);
    return m_elems[Filter].labels.value(v);
}

bool DacControl::loadFir(const QUrl &url)
{
    const QString path = url.isLocalFile() ? url.toLocalFile() : url.path();
    const bool ok = darwinctl({QStringLiteral("set"), path});
    readValue(Filter);
    refreshDarwin();
    return ok;
}

bool DacControl::setDarwin(int index)
{
    const QString path = m_darwinPaths.value(index);
    if (path.isEmpty())
        return false; // the loaded file is already the active one
    const bool ok = darwinctl({QStringLiteral("set"), path});
    readValue(Filter);
    refreshDarwin();
    return ok;
}

void DacControl::setError(const QString &error)
{
    if (error == m_error)
        return;
    m_error = error;
    if (!error.isEmpty())
        qCWarning(RS6DAC) << error;
    Q_EMIT errorStringChanged();
}

void DacControl::emitValue(Id id)
{
    switch (id) {
    case Nos:
        Q_EMIT nosChanged();
        break;
    case Output:
        Q_EMIT outputChanged();
        break;
    case Gain:
        Q_EMIT gainChanged();
        break;
    case Filter:
        Q_EMIT filterChanged();
        break;
    case Pregain:
        Q_EMIT pregainChanged();
        break;
    case LrBalance:
        Q_EMIT lrBalanceChanged();
        break;
    case IdleOff:
        Q_EMIT idleOffSecondsChanged();
        break;
    default:
        break;
    }
}

void DacControl::emitInfo(Id id)
{
    switch (id) {
    case Output:
        Q_EMIT outputNamesChanged();
        break;
    case Gain:
        Q_EMIT gainNamesChanged();
        break;
    case Filter:
        Q_EMIT filterNamesChanged();
        break;
    case Pregain:
    case LrBalance:
    case IdleOff:
        Q_EMIT rangesChanged();
        break;
    default:
        break;
    }
}

void DacControl::setNos(bool on)
{
    write(Nos, on ? 1 : 0);
}

void DacControl::setOutput(int index)
{
    write(Output, index);
}

void DacControl::setGain(int index)
{
    write(Gain, index);
}

void DacControl::setFilter(int index)
{
    if (index == m_customIndex) {
        // back to the last Darwin filter, from darwinctl's saved copy
        darwinctl({QStringLiteral("set"), QStringLiteral("custom")});
        readValue(Filter);
        refreshDarwin();
        return;
    }
    write(Filter, index);
}

void DacControl::setPregain(int value)
{
    write(Pregain, value);
}

void DacControl::setLrBalance(int value)
{
    write(LrBalance, value);
}

void DacControl::setIdleOffSeconds(int value)
{
    write(IdleOff, value);
}

#include "moc_dac-control.cpp"
