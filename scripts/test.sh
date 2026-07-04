#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
DEPLOY="26.0"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -t quickshot-hub-tests)"
SELECTION_OUT="$(mktemp -t quickshot-selection-tests)"
trap 'rm -f "$OUT" "$SELECTION_OUT"' EXIT

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -D TESTING \
  -framework AppKit \
  Tests/HubWindowTestSupport.swift \
  Sources/HubWindow.swift \
  Tests/HubWindowBehaviorTests.swift \
  -o "$OUT"

"$OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  Sources/Overlay.swift \
  Tests/SelectionToolBehaviorTests.swift \
  -o "$SELECTION_OUT"

"$SELECTION_OUT"

if output="$(rg -n "beginLiveSelection" Sources/CaptureController.swift)"; then
  echo "$output"
  echo "Capture flow regression: CaptureController must not show live overlay before frozen backdrop." >&2
  exit 1
fi

if output="$(rg -n "captureFull\\(|SCScreenshotManager|falling back|one-shot" Sources/CaptureController.swift)"; then
  echo "$output"
  echo "Capture flow regression: CaptureController hotkey path must not use one-shot screenshot fallback." >&2
  exit 1
fi

rg -q "beginFrozenSelection" Sources/CaptureController.swift
rg -q "ScreenFrameCache" Sources/CaptureController.swift
rg -F -q "SCContentFilter(display: scDisplay, excludingApplications: excludedApps, exceptingWindows: [])" Sources/ScreenFrameCache.swift
rg -F -q "config.showsCursor = false" Sources/ScreenFrameCache.swift
test -f PRODUCT_CONTRACT.md
