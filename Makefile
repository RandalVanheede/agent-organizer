APP_NAME := Agent Organizer
EXECUTABLE := AgentOrganizer
BUNDLE_ID := randalv.agent-organizer
CONFIG := release
BUILD_BIN_DIR := $(shell swift build -c $(CONFIG) --show-bin-path)
# Staged outside build/ in a `.noindex` dir so Spotlight never lists a second
# copy next to /Applications; build/ only ever holds the .dmg.
APP_DIR := .build/app.noindex/$(APP_NAME).app
# Stable self-signed identity (scripts/make-signing-identity.sh). macOS ties
# notification/TCC permission to the code signature; an ad-hoc signature
# changes every build, so notifications are refused. Falls back to ad-hoc.
# Stamped into the bundle's Info.plist. VERSION defaults to the latest tag;
# scripts/release.sh passes the new one. CFBundleVersion = commit count, which
# is what Sparkle compares, so it only ever goes up.
VERSION ?= $(or $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//'),0.0.0)
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 0)
GIT_COMMIT ?= $(shell git rev-parse --short HEAD 2>/dev/null)$(shell git diff --quiet HEAD 2>/dev/null || echo -dirty)
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -q '"Agent Organizer Dev"' && echo "Agent Organizer Dev" || echo "-")

.DEFAULT_GOAL := dmg

.PHONY: build bundle run install clean tmux icon identity dmg release

identity:
	scripts/make-signing-identity.sh

tmux:
	scripts/build-tmux.sh

icon:
	swift scripts/make-icon.swift Resources/AppIcon.iconset

build:
	swift build -c $(CONFIG)

bundle: build
	rm -rf "$(APP_DIR)" "build/$(APP_NAME).app"
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	mkdir -p "$(APP_DIR)/Contents/Resources"
	cp "$(BUILD_BIN_DIR)/$(EXECUTABLE)" "$(APP_DIR)/Contents/MacOS/$(EXECUTABLE)"
	cp Resources/Info.plist "$(APP_DIR)/Contents/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(BUILD_NUMBER)" \
		-c "Add :AOGitCommit string $(GIT_COMMIT)" "$(APP_DIR)/Contents/Info.plist"
	mkdir -p "$(APP_DIR)/Contents/Frameworks"
	ditto "$(BUILD_BIN_DIR)/Sparkle.framework" "$(APP_DIR)/Contents/Frameworks/Sparkle.framework"
	install_name_tool -add_rpath @executable_path/../Frameworks "$(APP_DIR)/Contents/MacOS/$(EXECUTABLE)"
	cp Resources/tmux.conf "$(APP_DIR)/Contents/Resources/tmux.conf"
	cp Resources/ao-hook.sh "$(APP_DIR)/Contents/Resources/ao-hook.sh"
	cp -R Resources/fonts "$(APP_DIR)/Contents/Resources/fonts"
	@if [ -x Resources/bin/tmux ]; then \
		mkdir -p "$(APP_DIR)/Contents/Resources/bin"; \
		cp Resources/bin/tmux "$(APP_DIR)/Contents/Resources/bin/tmux"; \
	else \
		echo "note: Resources/bin/tmux missing; run scripts/build-tmux.sh to bundle tmux"; \
	fi
	@if [ -d Resources/AppIcon.iconset ]; then \
		iconutil -c icns Resources/AppIcon.iconset -o "$(APP_DIR)/Contents/Resources/AppIcon.icns"; \
	fi
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then echo "note: signing ad-hoc; run scripts/make-signing-identity.sh for working notifications"; fi
	codesign --force --deep --sign "$(SIGN_IDENTITY)" "$(APP_DIR)"
	@echo "Built $(APP_DIR) (signed: $(SIGN_IDENTITY))"

run: bundle
	open "$(APP_DIR)"

install: bundle
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_DIR)" "/Applications/"
	@echo "Installed to /Applications/$(APP_NAME).app"

DMG_NAME := $(APP_NAME).dmg
DMG_DIR := .build/dmg-staging.noindex

dmg: bundle
	rm -rf "$(DMG_DIR)" "build/$(DMG_NAME)"
	mkdir -p "$(DMG_DIR)" build
	cp -R "$(APP_DIR)" "$(DMG_DIR)/"
	ln -s /Applications "$(DMG_DIR)/Applications"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_DIR)" \
		-ov -format UDZO "build/$(DMG_NAME)"
	rm -rf "$(DMG_DIR)"
	@if [ "$(SIGN_IDENTITY)" != "-" ]; then \
		codesign --force --sign "$(SIGN_IDENTITY)" "build/$(DMG_NAME)"; \
	fi
	@echo "Created build/$(DMG_NAME)"

# make release VERSION=1.1.0 — see scripts/release.sh.
release:
	scripts/release.sh "$(VERSION)"

clean:
	rm -rf .build build
