#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${QUICKSHOT_ALLOW_SCREEN_CAPTURE_TEST:-0}" != "1" ]; then
  cat >&2 <<'EOF'
This release gate takes one direct CoreGraphics snapshot to verify that
NSWindow.sharingType = .none excludes QuickShot windows on this macOS build.
Run it intentionally with QUICKSHOT_ALLOW_SCREEN_CAPTURE_TEST=1.
EOF
  exit 2
fi

SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -t quickshot-window-protection-test)"
trap 'rm -f "$OUT"' EXIT

xcrun swiftc \
  -sdk "$SDK" \
  -target "$(uname -m)-apple-macos26.0" \
  -swift-version 5 \
  -parse-as-library \
  -framework AppKit \
  -framework CoreGraphics \
  Sources/CaptureTypes.swift \
  Sources/CoordinateMath.swift \
  Sources/DirectScreenSnapshotProvider.swift \
  Sources/WindowCaptureProtection.swift \
  Tests/WindowCaptureProtectionCompatibilityTests.swift \
  -o "$OUT"

"$OUT"
