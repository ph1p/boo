.PHONY: build run clean ghostty setup

# Build GhosttyKit xcframework (only needed once or after Ghostty updates)
ghostty:
	@if [ ! -d Vendor/ghostty ]; then \
		echo "==> Cloning Ghostty..."; \
		mkdir -p Vendor; \
		git clone --depth 1 https://github.com/ghostty-org/ghostty.git Vendor/ghostty; \
	fi
	@if [ ! -f Vendor/ghostty/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a ]; then \
		echo "==> Building GhosttyKit..."; \
		cd Vendor/ghostty && zig build -Demit-xcframework=true -Dxcframework-target=native -Doptimize=ReleaseFast; \
	else \
		echo "==> GhosttyKit already built"; \
	fi

# Full setup: clone Ghostty + build xcframework + build Exterm
setup: ghostty build

# Build Exterm (requires GhosttyKit to be built first)
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

# Build and run
run: build
	.build/debug/Exterm

# Release build
release:
	swift build -c release
	@for dir in .build/release .build/arm64-apple-macosx/release; do \
		if [ -d "$$dir" ]; then \
			mkdir -p "$$dir/ghostty-resources"; \
			rsync -a --delete Vendor/ghostty/zig-out/share/ghostty/ "$$dir/ghostty-resources/ghostty/"; \
			rsync -a --delete Vendor/ghostty/zig-out/share/terminfo/ "$$dir/ghostty-resources/terminfo/"; \
		fi; \
	done
	@echo "==> Ghostty resources bundled"

# Run tests
test:
	swift test

# Clean everything
clean:
	swift package clean
	rm -rf .build

# Clean GhosttyKit build artifacts
clean-ghostty:
	rm -rf Vendor/ghostty/macos/GhosttyKit.xcframework
	rm -rf Vendor/ghostty/.zig-cache Vendor/ghostty/zig-out
