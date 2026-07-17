#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
DEPLOY="26.0"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -t quickshot-odometer-visual-matrix)"
PNG="${1:-/tmp/quickshot-odometer-matrix.png}"
trap 'rm -f "$OUT"' EXIT

ZIG_BIN="${QUICKSHOT_ZIG:-$(command -v zig || true)}"
if [ -z "$ZIG_BIN" ] && [ -x "$HOME/.native/toolchains/zig-0.16.0/zig" ]; then
  ZIG_BIN="$HOME/.native/toolchains/zig-0.16.0/zig"
fi
if [ -z "$ZIG_BIN" ]; then
  echo "error: zig is required; set QUICKSHOT_ZIG or install Zig 0.16" >&2
  exit 1
fi

(cd NativeQuickShotUI && PATH="$(dirname "$ZIG_BIN"):$PATH" "$ZIG_BIN" build lib -Doptimize=ReleaseFast)
NATIVE_UI_LIB="$PWD/NativeQuickShotUI/zig-out/lib/libquickshot-native-ui.a"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  -framework QuartzCore \
  Tests/HubWindowTestSupport.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/NativeHubView.swift \
  Sources/HubWindow.swift \
  Tests/HubOdometerVisualMatrix.swift \
  "$NATIVE_UI_LIB" \
  -o "$OUT"

"$OUT" "$PNG"
