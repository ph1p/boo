#!/bin/bash
set -euo pipefail

VERSION="${1:?usage: prepare-release.sh <version>}"

/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString ${VERSION}" Boo/App/Info.plist
/usr/libexec/PlistBuddy -c "Set CFBundleVersion ${VERSION}" Boo/App/Info.plist

make release app

if [ -n "${SIGNING_IDENTITY:-}" ]; then
  make sign
else
  codesign --force --deep --sign - .build/Boo.app
fi

if [ -n "${APPLE_ID:-}" ]; then
  make notarize
fi

make zip-from-app

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  bash scripts/update-appcast.sh "${VERSION}"
else
  echo "==> Skipping Sparkle appcast generation (SPARKLE_PRIVATE_KEY not set)"
fi
