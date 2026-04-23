#!/bin/bash
set -euo pipefail

VERSION="${1:?usage: update-appcast.sh <version>}"
REPOSITORY_SLUG="${GITHUB_REPOSITORY:-ph1p/boo}"
OWNER="${REPOSITORY_SLUG%%/*}"
REPO="${REPOSITORY_SLUG##*/}"

ARCHIVE_PATH=".build/Boo-${VERSION}.zip"
APPCAST_TOOL=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
OUTPUT_DIR=".build/updates"
OUTPUT_PATH="${OUTPUT_DIR}/appcast.xml"
SITE_URL="https://${OWNER}.github.io/${REPO}"
DOWNLOAD_PREFIX="https://github.com/${REPOSITORY_SLUG}/releases/download/v${VERSION}/"

if [ ! -f "${ARCHIVE_PATH}" ]; then
  echo "ZIP archive not found at ${ARCHIVE_PATH}" >&2
  exit 1
fi

if [ ! -x "${APPCAST_TOOL}" ]; then
  echo "Sparkle generate_appcast tool not found at ${APPCAST_TOOL}" >&2
  exit 1
fi

if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "SPARKLE_PRIVATE_KEY is required to generate appcast.xml" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/boo-appcast.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

mkdir -p "${OUTPUT_DIR}"
cp "${ARCHIVE_PATH}" "${WORK_DIR}/"

echo "${SPARKLE_PRIVATE_KEY}" | "${APPCAST_TOOL}" \
  --ed-key-file - \
  --download-url-prefix "${DOWNLOAD_PREFIX}" \
  --link "${SITE_URL}" \
  -o "${WORK_DIR}/appcast.xml" \
  "${WORK_DIR}"

cp "${WORK_DIR}/appcast.xml" "${OUTPUT_PATH}"
echo "==> Updated ${OUTPUT_PATH}"
