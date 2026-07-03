#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
DEPLOY="26.0"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -t quickshot-hub-visual-matrix)"
PNG="${1:-/tmp/quickshot-hub-matrix-preview.png}"
trap 'rm -f "$OUT"' EXIT

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -D TESTING \
  -framework AppKit \
  Tests/HubWindowTestSupport.swift \
  Sources/HubWindow.swift \
  Tests/HubWindowVisualMatrix.swift \
  -o "$OUT"

"$OUT" "$PNG"
