.PHONY: build run clean ghostty ghostty-linux setup setup-linux release test app sign notarize dmg dist lint format

UNAME := $(shell uname -s)

# ── Configuration ────────────────────────────────────────────────────────────

APP_NAME     := Exterm
BUNDLE_ID    := com.exterm.app
VERSION      := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Exterm/App/Info.plist 2>/dev/null || echo "0.1.0")
BUILD_DIR    := .build
APP_BUNDLE   := $(BUILD_DIR)/$(APP_NAME).app
DMG_NAME     := $(APP_NAME)-$(VERSION).dmg

# Signing (set via environment or CI secrets)
SIGNING_IDENTITY ?=
APPLE_ID         ?=
APPLE_TEAM_ID    ?=
APPLE_PASSWORD   ?=

# ── GhosttyKit (macOS) ──────────────────────────────────────────────────────

# Initialize Ghostty submodule and build GhosttyKit xcframework (macOS)
ghostty:
	@if [ ! -f Vendor/ghostty/build.zig ]; then \
		echo "==> Initializing Ghostty submodule..."; \
		git submodule update --init --depth 1 Vendor/ghostty; \
	fi
	@if [ ! -f Vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a ]; then \
		echo "==> Building GhosttyKit..."; \
		cd Vendor/ghostty && zig build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast; \
	else \
		echo "==> GhosttyKit already built"; \
	fi

# ── Ghostty GTK (Linux) ─────────────────────────────────────────────────────

# Build Ghostty GTK executable for Linux
ghostty-linux:
	@if [ ! -f Vendor/ghostty/build.zig ]; then \
		echo "==> Initializing Ghostty submodule..."; \
		git submodule update --init --depth 1 Vendor/ghostty; \
	fi
	@if [ ! -f Vendor/ghostty/zig-out/bin/ghostty ]; then \
		echo "==> Building Ghostty GTK..."; \
		cd Vendor/ghostty && zig build -Dapp-runtime=gtk -Doptimize=ReleaseFast; \
	else \
		echo "==> Ghostty GTK already built"; \
	fi

# ── Build ────────────────────────────────────────────────────────────────────

# Full setup (auto-detects platform)
ifeq ($(UNAME),Darwin)
setup: ghostty build
else
setup: setup-linux
endif

# Linux setup: build Exterm with GTK4 sidebar + VTE terminal
setup-linux: build-linux

# Build Exterm (macOS — requires GhosttyKit)
build:
	swift build
	@# Bundle Ghostty resources next to the executable so shell integration works
	@for dir in .build/debug .build/arm64-apple-macosx/debug; do \
		if [ -d "$$dir" ]; then \
			mkdir -p "$$dir/ghostty-resources"; \
			rsync -a --delete Vendor/ghostty/zig-out/share/ghostty/ "$$dir/ghostty-resources/ghostty/"; \
			rsync -a --delete Vendor/ghostty/zig-out/share/terminfo/ "$$dir/ghostty-resources/terminfo/"; \
		fi; \
	done
	@echo "==> Ghostty resources bundled"

# Build Exterm for Linux (GTK4 + VTE terminal with sidebar)
build-linux:
	swift build
	@echo "==> Linux build complete"

# Build and run (auto-detects platform)
run: build
	.build/debug/Exterm

# Release build
ifeq ($(UNAME),Darwin)
release:
	swift build -c release
	@for dir in .build/release .build/arm64-apple-macosx/release; do \
		if [ -d "$$dir" ]; then \
			mkdir -p "$$dir/ghostty-resources"; \
			rsync -a --delete Vendor/ghostty/zig-out/share/ghostty/ "$$dir/ghostty-resources/ghostty/"; \
			rsync -a --delete Vendor/ghostty/zig-out/share/terminfo/ "$$dir/ghostty-resources/terminfo/"; \
		fi; \
	done
	@echo "==> Release build complete"
else
release:
	swift build -c release
	@echo "==> Release build complete"
endif

# Run tests (macOS only — tests depend on AppKit types)
test:
	swift test

# ── App Bundle (macOS) ───────────────────────────────────────────────────────

# Find the release binary (SPM may use different output dirs)
RELEASE_BIN = $(shell \
	if [ -f .build/release/Exterm ]; then echo .build/release/Exterm; \
	elif [ -f .build/arm64-apple-macosx/release/Exterm ]; then echo .build/arm64-apple-macosx/release/Exterm; \
	fi)

# Create macOS .app bundle from release build
app: release
	@echo "==> Creating $(APP_NAME).app bundle..."
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(RELEASE_BIN)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Exterm/App/Info.plist "$(APP_BUNDLE)/Contents/"
	@rsync -a Vendor/ghostty/zig-out/share/ghostty/ "$(APP_BUNDLE)/Contents/Resources/ghostty/"
	@rsync -a Vendor/ghostty/zig-out/share/terminfo/ "$(APP_BUNDLE)/Contents/Resources/terminfo/"
	@if [ -f assets/AppIcon.icns ]; then \
		cp assets/AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/"; \
	fi
	@echo "==> $(APP_BUNDLE) created"

# ── Linux Packaging ─────────────────────────────────────────────────────────

# Create a tar.gz archive for Linux distribution
tarball: release
	@echo "==> Creating Linux tarball..."
	@mkdir -p "$(BUILD_DIR)/exterm-$(VERSION)-linux"
	@cp .build/release/Exterm "$(BUILD_DIR)/exterm-$(VERSION)-linux/exterm"
	@if [ -f CLinuxGTK/exterm.css ]; then \
		cp CLinuxGTK/exterm.css "$(BUILD_DIR)/exterm-$(VERSION)-linux/"; \
	fi
	@cd "$(BUILD_DIR)" && tar czf "exterm-$(VERSION)-linux-$$(uname -m).tar.gz" "exterm-$(VERSION)-linux/"
	@rm -rf "$(BUILD_DIR)/exterm-$(VERSION)-linux"
	@echo "==> $(BUILD_DIR)/exterm-$(VERSION)-linux-$$(uname -m).tar.gz created"

# ── Code Signing (macOS) ────────────────────────────────────────────────────

sign:
	@if [ -z "$(SIGNING_IDENTITY)" ]; then \
		echo "ERROR: SIGNING_IDENTITY not set. Export it or pass via make sign SIGNING_IDENTITY='...'"; \
		exit 1; \
	fi
	@echo "==> Signing $(APP_BUNDLE)..."
	codesign --force --options runtime --sign "$(SIGNING_IDENTITY)" \
		--entitlements Exterm/App/Exterm.entitlements \
		"$(APP_BUNDLE)"
	@echo "==> Signed"

# ── Notarization (macOS) ────────────────────────────────────────────────────

notarize:
	@if [ -z "$(APPLE_ID)" ] || [ -z "$(APPLE_TEAM_ID)" ] || [ -z "$(APPLE_PASSWORD)" ]; then \
		echo "ERROR: Set APPLE_ID, APPLE_TEAM_ID, and APPLE_PASSWORD"; \
		exit 1; \
	fi
	@echo "==> Submitting for notarization..."
	@ditto -c -k --keepParent "$(APP_BUNDLE)" "$(BUILD_DIR)/$(APP_NAME)-notarize.zip"
	xcrun notarytool submit "$(BUILD_DIR)/$(APP_NAME)-notarize.zip" \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(APPLE_TEAM_ID)" \
		--password "$(APPLE_PASSWORD)" \
		--wait
	xcrun stapler staple "$(APP_BUNDLE)"
	@rm -f "$(BUILD_DIR)/$(APP_NAME)-notarize.zip"
	@echo "==> Notarized and stapled"

# ── DMG Packaging (macOS) ───────────────────────────────────────────────────

dmg: app
	@echo "==> Creating $(DMG_NAME)..."
	@rm -f "$(BUILD_DIR)/$(DMG_NAME)"
	@mkdir -p "$(BUILD_DIR)/dmg-staging"
	@cp -R "$(APP_BUNDLE)" "$(BUILD_DIR)/dmg-staging/"
	@ln -sf /Applications "$(BUILD_DIR)/dmg-staging/Applications"
	@hdiutil create -volname "$(APP_NAME)" \
		-srcfolder "$(BUILD_DIR)/dmg-staging" \
		-ov -format UDZO \
		"$(BUILD_DIR)/$(DMG_NAME)"
	@rm -rf "$(BUILD_DIR)/dmg-staging"
	@echo "==> $(BUILD_DIR)/$(DMG_NAME) created"

# Full macOS distribution pipeline
dist: app
	@if [ -n "$(SIGNING_IDENTITY)" ]; then \
		$(MAKE) sign; \
	else \
		echo "==> Skipping signing (SIGNING_IDENTITY not set)"; \
	fi
	@if [ -n "$(APPLE_ID)" ] && [ -n "$(APPLE_TEAM_ID)" ] && [ -n "$(APPLE_PASSWORD)" ]; then \
		$(MAKE) notarize; \
	else \
		echo "==> Skipping notarization (Apple credentials not set)"; \
	fi
	$(MAKE) dmg

# ── Lint & Format ────────────────────────────────────────────────────────────

lint:
	swift-format lint --strict --recursive Exterm/ Tests/

format:
	swift-format format --in-place --recursive Exterm/ Tests/

# ── Cleanup ──────────────────────────────────────────────────────────────────

clean:
	swift package clean
	rm -rf .build

clean-ghostty:
	rm -rf Vendor/ghostty/macos/GhosttyKit.xcframework
	rm -rf Vendor/ghostty/.zig-cache Vendor/ghostty/zig-out
