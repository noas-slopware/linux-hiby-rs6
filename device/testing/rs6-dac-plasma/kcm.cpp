// SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
// SPDX-License-Identifier: MIT
//
// RS6 DAC settings page. Everything lives in the codes.noa.rs6dac DacControl singleton and
// applies at once (ALSA controls), so the module has no state and no Apply/Defaults buttons.

#include <KPluginFactory>
#include <KQuickConfigModule>

class Rs6DacKcm : public KQuickConfigModule
{
    Q_OBJECT

public:
    Rs6DacKcm(QObject *parent, const KPluginMetaData &metaData)
        : KQuickConfigModule(parent, metaData)
    {
        setButtons({});
    }
};

K_PLUGIN_CLASS_WITH_JSON(Rs6DacKcm, "kcm_rs6dac.json")

#include "kcm.moc"
