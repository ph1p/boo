#!/bin/bash
# Builds static libghostty-vt for the offline .cast -> MP4 exporter and
# prelinks it into one object that exports only the ghostty C API.
# Linking the raw archive next to GhosttyKit fails: both carry their own
# zig compiler_rt / ubsan runtime, so the private copies must stay hidden.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTTY="$ROOT/Vendor/ghostty"
OUT_DIR="$GHOSTTY/macos/GhosttyVT"
OUT_LIB="$OUT_DIR/libghostty-vt-boo.a"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Building libghostty-vt..."
(cd "$GHOSTTY" && zig build -Demit-lib-vt -Doptimize=ReleaseFast --prefix "$TMP/prefix")

mkdir -p "$TMP/objs"
(cd "$TMP/objs" && ar -x "$TMP/prefix/lib/libghostty-vt.a" && chmod 644 ./*.o)

# Public C API only; the simd/highway helpers also exist in GhosttyKit.
nm -gU "$TMP"/objs/*.o 2>/dev/null \
	| awk 'NF==3{print $3}' \
	| grep '^_ghostty_' \
	| grep -v '^_ghostty_simd_\|^_ghostty_hwy_' \
	| sort -u > "$TMP/exports.txt"

ld -r -arch arm64 -exported_symbols_list "$TMP/exports.txt" "$TMP"/objs/*.o -o "$TMP/ghostty-vt-boo.o"
mkdir -p "$OUT_DIR"
rm -f "$OUT_LIB"
ar rcs "$OUT_LIB" "$TMP/ghostty-vt-boo.o"
echo "==> Wrote $OUT_LIB ($(wc -l < "$TMP/exports.txt" | tr -d ' ') symbols)"
