APP_NAME := Agent Organizer
EXECUTABLE := AgentOrganizer
BUNDLE_ID := randalv.agent-organizer
CONFIG := release
BUILD_BIN_DIR := $(shell swift build -c $(CONFIG) --show-bin-path)
APP_DIR := build/$(APP_NAME).app

.PHONY: build bundle run install clean tmux icon

tmux:
	scripts/build-tmux.sh

icon:
	swift scripts/make-icon.swift Resources/AppIcon.iconset

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf "$(APP_DIR)"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	cp "$(BUILD_BIN_DIR)/$(EXECUTABLE)" "$(APP_DIR)/Contents/MacOS/$(EXECUTABLE)"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	cp Resources/tmux.conf "$(APP_DIR)/Contents/Resources/tmux.conf"
	cp Resources/ao-hook.sh "$(APP_DIR)/Contents/Resources/ao-hook.sh"
	@if [ -x Resources/bin/tmux ]; then \
		mkdir -p "$(APP_DIR)/Contents/Resources/bin"; \
		cp Resources/bin/tmux "$(APP_DIR)/Contents/Resources/bin/tmux"; \
	else \
		echo "note: Resources/bin/tmux missing; run scripts/build-tmux.sh to bundle tmux"; \
	fi
	@if [ -d Resources/AppIcon.iconset ]; then \
		iconutil -c icns Resources/AppIcon.iconset -o "$(APP_DIR)/Contents/Resources/AppIcon.icns"; \
	fi
	codesign --force --deep --sign - "$(APP_DIR)" 2>/dev/null || true
	@echo "Built $(APP_DIR)"

run: bundle
	open "$(APP_DIR)"

install: bundle
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_DIR)" "/Applications/"
	@echo "Installed to /Applications/$(APP_NAME).app"

clean:
	rm -rf .build build
