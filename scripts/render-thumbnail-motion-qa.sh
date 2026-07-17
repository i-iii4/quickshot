#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
DEPLOY="26.0"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -t quickshot-thumbnail-motion-matrix)"
PNG="${1:-/tmp/quickshot-thumbnail-motion.png}"
trap 'rm -f "$OUT"' EXIT

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -framework AppKit \
  -framework QuartzCore \
  Sources/MotionCurves.swift \
  Sources/ThumbnailMotion.swift \
  Tests/ThumbnailMotionVisualMatrix.swift \
  -o "$OUT"

"$OUT" "$PNG"
