#!/bin/bash
# Быстрый прогон одного набора EditorToolbarLiveTests для итеративной отладки.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
DEPLOY="26.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ZIG_BIN="${QUICKSHOT_ZIG:-$(command -v zig || true)}"
if [ -z "$ZIG_BIN" ] && [ -x "$HOME/.native/toolchains/zig-0.16.0/zig" ]; then
  ZIG_BIN="$HOME/.native/toolchains/zig-0.16.0/zig"
fi

NATIVE_UI_LIB="$PWD/NativeQuickShotUI/zig-out/lib/libquickshot-native-ui.a"
if [ ! -f "$NATIVE_UI_LIB" ]; then
  (cd NativeQuickShotUI && PATH="$(dirname "$ZIG_BIN"):$PATH" "$ZIG_BIN" build lib -Doptimize=ReleaseFast)
fi

OUT="$(mktemp -t quickshot-toolbar-live-tests)"
xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  -framework ImageIO \
  Tests/HubWindowTestSupport.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/TrayHoverRegion.swift \
  Sources/CaptureSequence.swift \
  Sources/Clipboard.swift \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationCanvas.swift \
  Sources/AnnotationRenderer.swift \
  Sources/AnnotationHandle.swift \
  Sources/AnnotationToolModel.swift \
  Sources/AnnotationToolbar.swift \
  Sources/NativeHubView.swift \
  Sources/HubTooltip.swift \
  Sources/WindowCaptureProtection.swift \
  Sources/HubWindow.swift \
  Sources/AnnotationCanvasView.swift \
  Tests/EditorToolbarLiveTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$OUT"

"$OUT"
