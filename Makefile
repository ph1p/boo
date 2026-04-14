.PHONY: build run clean ghostty ghostty-linux ironmark monaco setup setup-linux release test app sign notarize dmg dist lint format

UNAME := $(shell uname -s)

# ── Configuration ────────────────────────────────────────────────────────────

APP_NAME     := Boo
BUNDLE_ID    := com.boo.app
VERSION      := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Boo/App/Info.plist 2>/dev/null || echo "0.1.0")
BUILD_DIR    := .build
APP_BUNDLE   := $(BUILD_DIR)/$(APP_NAME).app
DMG_NAME     := $(APP_NAME)-$(VERSION).dmg

# Signing (set via environment or CI secrets)
SIGNING_IDENTITY ?=
APPLE_ID         ?=
APPLE_TEAM_ID    ?=
APPLE_PASSWORD   ?=

# ── GhosttyKit (macOS) ──────────────────────────────────────────────────────

# Xcode 26 beta ships macOS SDK .tbd stubs with only arm64e (no arm64), which
# breaks zig 0.15's linker. The CLT macOS SDK still includes arm64. This
# wrapper intercepts `xcrun --sdk macosx --show-sdk-path` to return the CLT
# SDK while letting all other xcrun calls (iOS SDK, metal, etc.) pass through.
XCRUN_WRAPPER_DIR := $(BUILD_DIR)/xcrun-wrapper

$(XCRUN_WRAPPER_DIR)/xcrun:
	@mkdir -p $(XCRUN_WRAPPER_DIR)
	@CLT_SDK=$$(DEVELOPER_DIR=/Library/Developer/CommandLineTools xcrun --sdk macosx --show-sdk-path 2>/dev/null); \
	XCODE_SDK=$$(xcrun --sdk macosx --show-sdk-path 2>/dev/null); \
	XCODE_TBD="$$XCODE_SDK/usr/lib/libSystem.B.tbd"; \
	NEED_WRAPPER=false; \
	if [ -n "$$CLT_SDK" ] && [ "$$CLT_SDK" != "$$XCODE_SDK" ] && [ -f "$$XCODE_TBD" ]; then \
		TOP_TARGETS=$$(head -4 "$$XCODE_TBD" | grep '^targets:'); \
		if echo "$$TOP_TARGETS" | grep -q 'arm64e-macos' && \
		   ! echo "$$TOP_TARGETS" | grep -qE '[ ,]arm64-macos[ ,\]]'; then \
			NEED_WRAPPER=true; \
		fi; \
	fi; \
	if $$NEED_WRAPPER; then \
		echo "==> Xcode macOS SDK missing arm64 stubs; using CLT SDK for zig"; \
		printf '#!/bin/bash\n\
sdk_is_macosx=false; has_show_sdk_path=false\n\
for arg in "$$@"; do\n\
  case "$$arg" in macosx) sdk_is_macosx=true ;; --show-sdk-path) has_show_sdk_path=true ;; esac\n\
done\n\
if $$sdk_is_macosx && $$has_show_sdk_path; then echo "%s"; exit 0; fi\n\
exec /usr/bin/xcrun "$$@"\n' "$$CLT_SDK" > $(XCRUN_WRAPPER_DIR)/xcrun; \
	else \
		printf '#!/bin/bash\nexec /usr/bin/xcrun "$$@"\n' > $(XCRUN_WRAPPER_DIR)/xcrun; \
	fi
	@chmod +x $(XCRUN_WRAPPER_DIR)/xcrun

# Initialize Ghostty submodule and build GhosttyKit xcframework (macOS)
ghostty: $(XCRUN_WRAPPER_DIR)/xcrun
	@if [ ! -f Vendor/ghostty/build.zig ]; then \
		echo "==> Initializing Ghostty submodule..."; \
		git submodule update --init --depth 1 Vendor/ghostty; \
	fi
	@if [ ! -f Vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a ]; then \
		echo "==> Building GhosttyKit..."; \
		cd Vendor/ghostty && PATH="$(CURDIR)/$(XCRUN_WRAPPER_DIR):$$PATH" zig build -Demit-xcframework=true -Dxcframework-target=native -Demit-macos-app=false -Doptimize=ReleaseFast; \
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

# ── Ironmark (macOS) ────────────────────────────────────────────────────────

# Build ironmark static library for markdown rendering
ironmark:
	@if [ ! -f Vendor/ironmark/Cargo.toml ]; then \
		echo "==> Initializing ironmark submodule..."; \
		git submodule update --init --depth 1 Vendor/ironmark; \
	fi
	@if [ ! -f Vendor/ironmark/macos-arm64/libironmark.a ]; then \
		echo "==> Building ironmark..."; \
		cd Vendor/ironmark && \
			MACOSX_DEPLOYMENT_TARGET=13.0 RUSTFLAGS="-C link-arg=-mmacosx-version-min=13.0" \
			cargo build --release --target aarch64-apple-darwin && \
			mkdir -p macos-arm64 && \
			cp target/aarch64-apple-darwin/release/libironmark.a macos-arm64/; \
	else \
		echo "==> ironmark already built"; \
	fi

# Build bundled Monaco editor assets with Vite
monaco:
	cd Boo/Resources/MonacoSource && CI=true pnpm install --frozen-lockfile && pnpm build

monaco-lint:
	cd Boo/Resources/MonacoSource && CI=true pnpm install --frozen-lockfile && pnpm lint

monaco-format:
	cd Boo/Resources/MonacoSource && CI=true pnpm install --frozen-lockfile && pnpm format

# ── Build ────────────────────────────────────────────────────────────────────

# Full setup (auto-detects platform)
ifeq ($(UNAME),Darwin)
setup: ghostty ironmark build
else
setup: setup-linux
endif

# Linux setup: build Boo with GTK4 sidebar + VTE terminal
setup-linux: build-linux

# Build Boo (macOS — requires GhosttyKit)
build: monaco
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

# Build Boo for Linux (GTK4 + VTE terminal with sidebar)
build-linux: monaco
	swift build
	@echo "==> Linux build complete"

# Build and run (auto-detects platform)
run: build
	.build/debug/BooApp

# Release build
ifeq ($(UNAME),Darwin)
release: monaco
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
release: monaco
	swift build -c release
	@echo "==> Release build complete"
endif

# Run tests (macOS only — tests depend on AppKit types)
test: monaco
	swift test --disable-swift-testing

# ── App Bundle (macOS) ───────────────────────────────────────────────────────

# Find the release binary (SPM may use different output dirs)
RELEASE_BIN = $(shell \
	if [ -f .build/release/BooApp ]; then echo .build/release/BooApp; \
	elif [ -f .build/arm64-apple-macosx/release/BooApp ]; then echo .build/arm64-apple-macosx/release/BooApp; \
	fi)

# Create macOS .app bundle from release build
app: release
	@echo "==> Creating $(APP_NAME).app bundle..."
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(RELEASE_BIN)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Boo/App/Info.plist "$(APP_BUNDLE)/Contents/"
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
	@mkdir -p "$(BUILD_DIR)/boo-$(VERSION)-linux"
	@cp .build/release/BooApp "$(BUILD_DIR)/boo-$(VERSION)-linux/boo"
	@if [ -f CLinuxGTK/boo.css ]; then \
		cp CLinuxGTK/boo.css "$(BUILD_DIR)/boo-$(VERSION)-linux/"; \
	fi
	@cd "$(BUILD_DIR)" && tar czf "boo-$(VERSION)-linux-$$(uname -m).tar.gz" "boo-$(VERSION)-linux/"
	@rm -rf "$(BUILD_DIR)/boo-$(VERSION)-linux"
	@echo "==> $(BUILD_DIR)/boo-$(VERSION)-linux-$$(uname -m).tar.gz created"

# ── Code Signing (macOS) ────────────────────────────────────────────────────

sign:
	@if [ -z "$(SIGNING_IDENTITY)" ]; then \
		echo "ERROR: SIGNING_IDENTITY not set. Export it or pass via make sign SIGNING_IDENTITY='...'"; \
		exit 1; \
	fi
	@echo "==> Signing $(APP_BUNDLE)..."
	codesign --force --options runtime --sign "$(SIGNING_IDENTITY)" \
		--entitlements Boo/App/Boo.entitlements \
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
	$(MAKE) monaco-lint
	swift-format lint --strict --recursive Boo/ BooApp/ Tests/

format:
	$(MAKE) monaco-format
	swift-format format --in-place --recursive Boo/ BooApp/ Tests/

# ── Cleanup ──────────────────────────────────────────────────────────────────

clean:
	swift package clean
	rm -rf .build

clean-ghostty:
	rm -rf Vendor/ghostty/macos/GhosttyKit.xcframework
	rm -rf Vendor/ghostty/.zig-cache Vendor/ghostty/zig-out
