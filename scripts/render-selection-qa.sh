#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-/tmp/quickshot-selection-tool-preview.png}"
ARCH="$(uname -m)"
DEPLOY="26.0"
SDK="$(xcrun --show-sdk-path)"
BIN="$(mktemp -t quickshot-selection-qa)"
trap 'rm -f "$BIN"' EXIT

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  Sources/Overlay.swift \
  Tests/SelectionToolVisualMatrix.swift \
  -o "$BIN"

"$BIN" "$OUT"
