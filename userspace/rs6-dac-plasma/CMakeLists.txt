# SPDX-FileCopyrightText: 2026 Noa Himesaka <himesaka@noa.codes>
# SPDX-License-Identifier: MIT

cmake_minimum_required(VERSION 3.22)
project(rs6-dac-plasma VERSION 1.0 LANGUAGES CXX)

set(QT_MIN_VERSION 6.8.0)
set(KF_MIN_VERSION 6.10.0)

find_package(ECM ${KF_MIN_VERSION} REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)
include(ECMQmlModule)

find_package(Qt6 ${QT_MIN_VERSION} REQUIRED COMPONENTS Core Qml Quick)
find_package(KF6 ${KF_MIN_VERSION} REQUIRED COMPONENTS CoreAddons KCMUtils)
find_package(ALSA REQUIRED)

# codes.noa.rs6dac: the DacControl singleton (KCM + DAC tile) and DisplayRotation (rotate tile)
ecm_add_qml_module(rs6dacplugin URI "codes.noa.rs6dac" GENERATE_PLUGIN_SOURCE)
target_sources(rs6dacplugin PRIVATE dac-control.cpp dac-control.h display-rotation.cpp display-rotation.h)
target_link_libraries(rs6dacplugin PRIVATE Qt::Core Qt::Qml ALSA::ALSA)
ecm_finalize_qml_module(rs6dacplugin)

# System Settings module (ui/main.qml)
kcmutils_add_qml_kcm(kcm_rs6dac SOURCES kcm.cpp)
target_link_libraries(kcm_rs6dac PRIVATE Qt::Quick KF6::CoreAddons KF6::KCMUtilsQuick)

# Plasma Mobile quick setting (KPackage/GenericQML)
install(DIRECTORY quicksetting/ DESTINATION ${KDE_INSTALL_DATADIR}/plasma/quicksettings/codes.noa.quicksetting.rs6dac)
install(DIRECTORY rotate/ DESTINATION ${KDE_INSTALL_DATADIR}/plasma/quicksettings/codes.noa.quicksetting.rotate)
