# SPDX-License-Identifier: MIT
# DARWIN, the DMS plugin for the HiBy RS6 DAC: QML only, darwinctl (hiby-rs6-audio) does the work
PLUGINDIR ?= /etc/xdg/quickshell/dms-plugins/Darwin

PLUGIN_FILES = $(wildcard plugin/Darwin/*.qml plugin/Darwin/plugin.json)

all:

install:
	install -d $(DESTDIR)$(PLUGINDIR)
	install -m644 $(PLUGIN_FILES) $(DESTDIR)$(PLUGINDIR)/

.PHONY: all install
