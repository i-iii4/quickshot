#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
DEPLOY="26.0"
                                        # Без --sdk macosx xcrun отдаёт SDK из CommandLineTools,
                                        # который может быть новее Swift-компилятора Xcode.
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ZIG_BIN="${QUICKSHOT_ZIG:-$(command -v zig || true)}"
if [ -z "$ZIG_BIN" ] && [ -x "$HOME/.native/toolchains/zig-0.16.0/zig" ]; then
  ZIG_BIN="$HOME/.native/toolchains/zig-0.16.0/zig"
fi
if [ -z "$ZIG_BIN" ]; then
  echo "error: zig is required to build NativeQuickShotUI tests; set QUICKSHOT_ZIG or install Zig 0.16" >&2
  exit 1
fi

NATIVE_DESIGN_SYSTEM_DIR="$("$PWD/scripts/resolve-native-ui-dependency.sh")"
NATIVE_DESIGN_SYSTEM_ZIG="$ZIG_BIN" \
  "$NATIVE_DESIGN_SYSTEM_DIR/scripts/check.sh" "$PWD/NativeQuickShotUI/src/hub.native"

"$PWD/scripts/test-atomic-replace.sh"

NATIVE_UI_LIB="$PWD/NativeQuickShotUI/zig-out/lib/libquickshot-native-ui.a"
OUT="$(mktemp -t quickshot-hub-tests)"
SURFACE_OUT="$(mktemp -t quickshot-native-surface-tests)"
TRAY_POINTER_OUT="$(mktemp -t quickshot-tray-pointer-tests)"
TRAY_HOVER_OUT="$(mktemp -t quickshot-tray-hover-region-tests)"
LIBRARY_MODEL_OUT="$(mktemp -t quickshot-screenshot-library-tests)"
ANNOTATION_DOC_OUT="$(mktemp -t quickshot-annotation-document-tests)"
ANNOTATION_CANVAS_OUT="$(mktemp -t quickshot-annotation-canvas-tests)"
ANNOTATION_HANDLE_OUT="$(mktemp -t quickshot-annotation-handle-tests)"
ANNOTATION_RENDER_OUT="$(mktemp -t quickshot-annotation-render-tests)"
ANNOTATION_SESSION_OUT="$(mktemp -t quickshot-annotation-session-tests)"
TRAY_SCROLL_OUT="$(mktemp -t quickshot-tray-scroll-tests)"
SENSITIVE_OUT="$(mktemp -t quickshot-sensitive-tests)"
TOOLBAR_LIVE_OUT="$(mktemp -t quickshot-toolbar-live-tests)"
TRANSFORM_OUT="$(mktemp -t quickshot-editor-transform-tests)"
SCROLL_LAYOUT_OUT="$(mktemp -t quickshot-tray-scroll-layout-tests)"
SCENARIO_OUT="$(mktemp -t quickshot-scenario-tests)"
SESSION_EDITOR_OUT="$(mktemp -t quickshot-editor-session-tests)"
STORAGE_LIFECYCLE_OUT="$(mktemp -t quickshot-storage-lifecycle-tests)"
REMAINING_OUT="$(mktemp -t quickshot-remaining-tests)"
THUMBNAIL_LAYOUT_OUT="$(mktemp -t quickshot-thumbnail-layout-tests)"
THUMBNAIL_MOTION_OUT="$(mktemp -t quickshot-thumbnail-motion-tests)"
THUMBNAIL_COLLECTION_OUT="$(mktemp -t quickshot-thumbnail-collection-tests)"
HUB_LIVE_OUT="$(mktemp -t quickshot-hub-live-tests)"
THUMBNAIL_LIVE_OUT="$(mktemp -t quickshot-thumbnail-live-tests)"
TRAY_LIVE_SCROLL_OUT="$(mktemp -t quickshot-tray-live-scroll-tests)"
DRAWING_OUT="$(mktemp -t quickshot-editor-drawing-tests)"
HISTORY_OUT="$(mktemp -t quickshot-editor-history-tests)"
SELECTION_OUT="$(mktemp -t quickshot-selection-tests)"
CURSOR_LEASE_OUT="$(mktemp -t quickshot-cursor-lease-tests)"
PRESENTATION_OUT="$(mktemp -t quickshot-selection-presentation-tests)"
DIRECT_CAPTURE_OUT="$(mktemp -t quickshot-direct-capture-tests)"
CAPTURE_HOT_PATH_OUT="$(mktemp -t quickshot-capture-hot-path-tests)"
CAPTURE_GESTURE_OUT="$(mktemp -t quickshot-capture-gesture-tests)"
CAPTURE_SEQUENCE_OUT="$(mktemp -t quickshot-capture-sequence-tests)"
CAPTURE_ARTIFACT_OUT="$(mktemp -t quickshot-capture-artifact-tests)"
WINDOW_PROTECTION_OUT="$(mktemp -t quickshot-window-protection-tests)"
THUMBNAIL_MODEL_OUT="$(mktemp -t quickshot-thumbnail-model-tests)"
trap 'rm -f "$OUT" "$SURFACE_OUT" "$TRAY_POINTER_OUT" "$TRAY_HOVER_OUT" "$LIBRARY_MODEL_OUT" "$ANNOTATION_DOC_OUT" "$ANNOTATION_CANVAS_OUT" "$ANNOTATION_HANDLE_OUT" "$ANNOTATION_RENDER_OUT" "$ANNOTATION_SESSION_OUT" "$TRAY_SCROLL_OUT" "$SENSITIVE_OUT" "$TOOLBAR_LIVE_OUT" "$TRANSFORM_OUT" "$SCROLL_LAYOUT_OUT" "$SCENARIO_OUT" "$SESSION_EDITOR_OUT" "$STORAGE_LIFECYCLE_OUT" "$REMAINING_OUT" "$THUMBNAIL_LAYOUT_OUT" "$THUMBNAIL_MOTION_OUT" "$THUMBNAIL_COLLECTION_OUT" "$HUB_LIVE_OUT" "$THUMBNAIL_LIVE_OUT" "$TRAY_LIVE_SCROLL_OUT" "$DRAWING_OUT" "$HISTORY_OUT" "$SELECTION_OUT" "$CURSOR_LEASE_OUT" "$PRESENTATION_OUT" "$DIRECT_CAPTURE_OUT" "$CAPTURE_HOT_PATH_OUT" "$CAPTURE_GESTURE_OUT" "$CAPTURE_SEQUENCE_OUT" "$CAPTURE_ARTIFACT_OUT" "$WINDOW_PROTECTION_OUT" "$THUMBNAIL_MODEL_OUT"' EXIT

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  Sources/CaptureGestureBuffer.swift \
  Tests/CaptureGestureBufferTests.swift \
  -o "$CAPTURE_GESTURE_OUT"

"$CAPTURE_GESTURE_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  Sources/CaptureSequence.swift \
  Tests/CaptureSequenceTests.swift \
  -o "$CAPTURE_SEQUENCE_OUT"

"$CAPTURE_SEQUENCE_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  -framework ImageIO \
  Sources/CaptureSequence.swift \
  Sources/Clipboard.swift \
  Sources/CaptureArtifact.swift \
  Tests/CaptureArtifactTests.swift \
  -o "$CAPTURE_ARTIFACT_OUT"

"$CAPTURE_ARTIFACT_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  Sources/WindowCaptureProtection.swift \
  Tests/WindowCaptureProtectionTests.swift \
  -o "$WINDOW_PROTECTION_OUT"

"$WINDOW_PROTECTION_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  Sources/CaptureSequence.swift \
  Sources/ThumbnailCollectionModel.swift \
  Tests/ThumbnailCollectionModelTests.swift \
  -o "$THUMBNAIL_MODEL_OUT"

"$THUMBNAIL_MODEL_OUT"

# Pixel timing is a product contract, so exercise the same optimized Native SDK
# renderer that ships in QuickShot instead of measuring the debug reference path.
(cd NativeQuickShotUI && PATH="$(dirname "$ZIG_BIN"):$PATH" "$ZIG_BIN" build lib -Doptimize=ReleaseFast)
"$PWD/scripts/normalize-native-static-library.sh" "$NATIVE_UI_LIB"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  Tests/HubWindowTestSupport.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/TrayHoverRegion.swift \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationToolModel.swift \
  Sources/AnnotationToolbar.swift \
  Sources/NativeHubView.swift \
  Sources/HubTooltip.swift \
  Sources/WindowCaptureProtection.swift \
  Sources/HubWindow.swift \
  Tests/HubWindowBehaviorTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$OUT"

"$OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  Tests/HubWindowTestSupport.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/TrayHoverRegion.swift \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationToolModel.swift \
  Sources/AnnotationToolbar.swift \
  Sources/NativeHubView.swift \
  Sources/HubTooltip.swift \
  Sources/WindowCaptureProtection.swift \
  Sources/HubWindow.swift \
  Tests/NativeSurfaceBehaviorTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$SURFACE_OUT"

"$SURFACE_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  Sources/TrayHostContentView.swift \
  Tests/TrayPointerRoutingTests.swift \
  -o "$TRAY_POINTER_OUT"

"$TRAY_POINTER_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  Sources/TrayHoverRegion.swift \
  Tests/TrayHoverRegionTests.swift \
  -o "$TRAY_HOVER_OUT"

"$TRAY_HOVER_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  Sources/ScreenshotLibraryModel.swift \
  Tests/ScreenshotLibraryModelTests.swift \
  -o "$LIBRARY_MODEL_OUT"

"$LIBRARY_MODEL_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  Sources/AnnotationDocument.swift \
  Tests/AnnotationDocumentTests.swift \
  -o "$ANNOTATION_DOC_OUT"

"$ANNOTATION_DOC_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  Sources/AnnotationCanvas.swift \
  Tests/AnnotationCanvasTests.swift \
  -o "$ANNOTATION_CANVAS_OUT"

"$ANNOTATION_CANVAS_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationHandle.swift \
  Tests/AnnotationHandleTests.swift \
  -o "$ANNOTATION_HANDLE_OUT"

"$ANNOTATION_HANDLE_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationRenderer.swift \
  Tests/AnnotationRendererTests.swift \
  -o "$ANNOTATION_RENDER_OUT"

"$ANNOTATION_RENDER_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  -framework ImageIO \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationToolModel.swift \
  Sources/AnnotationSession.swift \
  Sources/Clipboard.swift \
  Sources/CaptureSequence.swift \
  Tests/AnnotationSessionTests.swift \
  -o "$ANNOTATION_SESSION_OUT"

"$ANNOTATION_SESSION_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  Sources/TrayScrollModel.swift \
  Tests/TrayScrollModelTests.swift \
  -o "$TRAY_SCROLL_OUT"

"$TRAY_SCROLL_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework Vision \
  Sources/SensitiveDataDetector.swift \
  Tests/SensitiveDataTests.swift \
  -o "$SENSITIVE_OUT"

"$SENSITIVE_OUT"

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
  -o "$TOOLBAR_LIVE_OUT"

"$TOOLBAR_LIVE_OUT"

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
  Tests/EditorTransformTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$TRANSFORM_OUT"

"$TRANSFORM_OUT"

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
  Tests/EditorDrawingTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$DRAWING_OUT"

"$DRAWING_OUT"

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
  Tests/EditorHistoryTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$HISTORY_OUT"

"$HISTORY_OUT"

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
  Tests/EndToEndScenarioTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$SCENARIO_OUT"

"$SCENARIO_OUT"

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
  -framework Vision \
  Tests/HubWindowTestSupport.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/TrayHoverRegion.swift \
  Sources/CaptureSequence.swift \
  Sources/Clipboard.swift \
  Sources/CaptureArtifact.swift \
  Sources/ScreenshotLibraryModel.swift \
  Sources/ScreenshotLibrary.swift \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationCanvas.swift \
  Sources/AnnotationRenderer.swift \
  Sources/AnnotationHandle.swift \
  Sources/AnnotationToolModel.swift \
  Sources/AnnotationToolbar.swift \
  Sources/EditorSettings.swift \
  Sources/SensitiveDataDetector.swift \
  Sources/NativeHubView.swift \
  Sources/HubTooltip.swift \
  Sources/WindowCaptureProtection.swift \
  Sources/HubWindow.swift \
  Sources/AnnotationCanvasView.swift \
  Sources/AnnotationEditor.swift \
  Tests/EditorSessionTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$SESSION_EDITOR_OUT"

"$SESSION_EDITOR_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  -framework ImageIO \
  Sources/CaptureSequence.swift \
  Sources/Clipboard.swift \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationSession.swift \
  Sources/AnnotationStateStore.swift \
  Sources/ScreenshotLibraryModel.swift \
  Sources/ScreenshotLibrary.swift \
  Sources/AnnotationToolModel.swift \
  Tests/StorageLifecycleTests.swift \
  -o "$STORAGE_LIFECYCLE_OUT"

"$STORAGE_LIFECYCLE_OUT"

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
  -framework Vision \
  Tests/HubWindowTestSupport.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/TrayHoverRegion.swift \
  Sources/CaptureSequence.swift \
  Sources/Clipboard.swift \
  Sources/CaptureArtifact.swift \
  Sources/ScreenshotLibraryModel.swift \
  Sources/ScreenshotLibrary.swift \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationSession.swift \
  Sources/AnnotationStateStore.swift \
  Sources/AnnotationCanvas.swift \
  Sources/AnnotationRenderer.swift \
  Sources/AnnotationHandle.swift \
  Sources/AnnotationToolModel.swift \
  Sources/AnnotationToolbar.swift \
  Sources/EditorSettings.swift \
  Sources/EditorPreferences.swift \
  Sources/TrayScrollModel.swift \
  Sources/SensitiveDataDetector.swift \
  Sources/NativeHubView.swift \
  Sources/HubTooltip.swift \
  Sources/WindowCaptureProtection.swift \
  Sources/HubWindow.swift \
  Sources/AnnotationCanvasView.swift \
  Sources/AnnotationEditor.swift \
  Tests/RemainingRequirementsTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$REMAINING_OUT"

"$REMAINING_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  Sources/ThumbnailLayout.swift \
  Sources/TrayScrollModel.swift \
  Tests/TrayScrollLayoutTests.swift \
  -o "$SCROLL_LAYOUT_OUT"

"$SCROLL_LAYOUT_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  Sources/ThumbnailLayout.swift \
  Sources/TrayScrollModel.swift \
  Tests/ThumbnailLayoutTests.swift \
  -o "$THUMBNAIL_LAYOUT_OUT"

"$THUMBNAIL_LAYOUT_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  Sources/MotionCurves.swift \
  Sources/ThumbnailMotion.swift \
  Tests/ThumbnailMotionTests.swift \
  -o "$THUMBNAIL_MOTION_OUT"

"$THUMBNAIL_MOTION_OUT"

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
  -framework QuartzCore \
  Sources/CaptureWindowLevels.swift \
  Sources/WindowCaptureProtection.swift \
  Sources/Theme.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/TrayHoverRegion.swift \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationToolModel.swift \
  Sources/AnnotationToolbar.swift \
  Sources/NativeHubView.swift \
  Sources/HubTooltip.swift \
  Sources/CaptureSequence.swift \
  Sources/ThumbnailCollectionModel.swift \
  Sources/Clipboard.swift \
  Sources/CaptureArtifact.swift \
  Sources/CardSizing.swift \
  Sources/TrayHostContentView.swift \
  Sources/HubWindow.swift \
  Sources/PinnedWindow.swift \
  Sources/ThumbnailMotion.swift \
  Sources/ThumbnailWindow.swift \
  Sources/ThumbnailLayout.swift \
  Sources/ScreenshotLibraryModel.swift \
  Sources/ScreenshotLibrary.swift \
  Sources/AnnotationCanvas.swift \
  Sources/AnnotationRenderer.swift \
  Sources/AnnotationHandle.swift \
  Sources/AnnotationCanvasView.swift \
  Sources/AnnotationSession.swift \
  Sources/AnnotationStateStore.swift \
  Sources/EditorSettings.swift \
  Sources/EditorPreferences.swift \
  Sources/EditedBadge.swift \
  Sources/SensitiveDataDetector.swift \
  Sources/AnnotationEditor.swift \
  Sources/SettingsWindow.swift \
  Sources/TrayScrollModel.swift \
  Sources/ThumbnailManager.swift \
  Tests/ThumbnailCollectionBehaviorTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$THUMBNAIL_COLLECTION_OUT"

"$THUMBNAIL_COLLECTION_OUT"

if [ "${QUICKSHOT_RUN_LIVE_UI_TESTS:-0}" = "1" ]; then
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
	  -framework QuartzCore \
  Sources/TrayHostContentView.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/TrayHoverRegion.swift \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationToolModel.swift \
  Sources/AnnotationToolbar.swift \
  Sources/NativeHubView.swift \
  Sources/HubTooltip.swift \
  Sources/WindowCaptureProtection.swift \
  Tests/HubWindowLiveClickTests.swift \
  Sources/HubWindow.swift \
  "$NATIVE_UI_LIB" \
    -o "$HUB_LIVE_OUT"

  "$HUB_LIVE_OUT"

  xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  -framework QuartzCore \
  Sources/CaptureWindowLevels.swift \
  Sources/WindowCaptureProtection.swift \
  Sources/Theme.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/TrayHoverRegion.swift \
	  Sources/NativeHubView.swift \
  Sources/HubTooltip.swift \
	  Sources/CaptureSequence.swift \
	  Sources/ThumbnailCollectionModel.swift \
	  Sources/Clipboard.swift \
	  Sources/CaptureArtifact.swift \
  Sources/CardSizing.swift \
  Sources/TrayHostContentView.swift \
  Sources/HubWindow.swift \
  Sources/PinnedWindow.swift \
  Sources/ThumbnailMotion.swift \
  Sources/ThumbnailWindow.swift \
  Sources/ThumbnailLayout.swift \
  Sources/ScreenshotLibraryModel.swift \
  Sources/ScreenshotLibrary.swift \
  Sources/AnnotationCanvas.swift \
  Sources/AnnotationRenderer.swift \
  Sources/AnnotationHandle.swift \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationToolModel.swift \
  Sources/AnnotationToolbar.swift \
  Sources/AnnotationCanvasView.swift \
  Sources/AnnotationSession.swift \
  Sources/AnnotationStateStore.swift \
  Sources/EditorSettings.swift \
  Sources/EditorPreferences.swift \
  Sources/EditedBadge.swift \
  Sources/SensitiveDataDetector.swift \
  Sources/AnnotationEditor.swift \
  Sources/SettingsWindow.swift \
  Sources/TrayScrollModel.swift \
  Sources/ThumbnailManager.swift \
  Tests/ThumbnailWindowLiveClickTests.swift \
  "$NATIVE_UI_LIB" \
    -o "$THUMBNAIL_LIVE_OUT"

  "$THUMBNAIL_LIVE_OUT"

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
	  -framework QuartzCore \
  Sources/TrayHostContentView.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/TrayHoverRegion.swift \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationToolModel.swift \
  Sources/AnnotationToolbar.swift \
  Sources/NativeHubView.swift \
  Sources/HubTooltip.swift \
  Sources/WindowCaptureProtection.swift \
  Tests/HubWindowLiveClickTests.swift \
  Sources/HubWindow.swift \
  "$NATIVE_UI_LIB" \
    -o "$HUB_LIVE_OUT"

  "$HUB_LIVE_OUT"

  xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  -framework QuartzCore \
  Sources/CaptureWindowLevels.swift \
  Sources/WindowCaptureProtection.swift \
  Sources/Theme.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/TrayHoverRegion.swift \
	  Sources/NativeHubView.swift \
  Sources/HubTooltip.swift \
	  Sources/CaptureSequence.swift \
	  Sources/ThumbnailCollectionModel.swift \
	  Sources/Clipboard.swift \
	  Sources/CaptureArtifact.swift \
  Sources/CardSizing.swift \
  Sources/TrayHostContentView.swift \
  Sources/HubWindow.swift \
  Sources/PinnedWindow.swift \
  Sources/ThumbnailMotion.swift \
  Sources/ThumbnailWindow.swift \
  Sources/ThumbnailLayout.swift \
  Sources/ScreenshotLibraryModel.swift \
  Sources/ScreenshotLibrary.swift \
  Sources/AnnotationCanvas.swift \
  Sources/AnnotationRenderer.swift \
  Sources/AnnotationHandle.swift \
  Sources/AnnotationDocument.swift \
  Sources/AnnotationToolModel.swift \
  Sources/AnnotationToolbar.swift \
  Sources/AnnotationCanvasView.swift \
  Sources/AnnotationSession.swift \
  Sources/AnnotationStateStore.swift \
  Sources/EditorSettings.swift \
  Sources/EditorPreferences.swift \
  Sources/EditedBadge.swift \
  Sources/SensitiveDataDetector.swift \
  Sources/AnnotationEditor.swift \
  Sources/SettingsWindow.swift \
  Sources/TrayScrollModel.swift \
  Sources/ThumbnailManager.swift \
  Tests/TrayLiveScrollTests.swift \
  "$NATIVE_UI_LIB" \
    -o "$TRAY_LIVE_SCROLL_OUT"

  "$TRAY_LIVE_SCROLL_OUT"
else
  echo "Live UI tests skipped (set QUICKSHOT_RUN_LIVE_UI_TESTS=1 to run them)."
fi

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -D TESTING \
  -framework AppKit \
  -framework Carbon \
  -framework CoreGraphics \
  Sources/WindowCaptureProtection.swift \
  Sources/CursorLease.swift \
  Sources/CaptureGestureBuffer.swift \
  Sources/SelectionPresentationCoordinator.swift \
  Sources/CaptureWindowLevels.swift \
  Sources/SessionEscapeHotKey.swift \
  Sources/Overlay.swift \
  Tests/SelectionToolBehaviorTests.swift \
  -o "$SELECTION_OUT"

"$SELECTION_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  -framework CoreGraphics \
  Sources/CursorLease.swift \
  Tests/CursorLeaseTests.swift \
  -o "$CURSOR_LEASE_OUT"

"$CURSOR_LEASE_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -framework AppKit \
  -framework CoreGraphics \
  Sources/CursorLease.swift \
  Sources/SelectionPresentationCoordinator.swift \
  Tests/SelectionPresentationCoordinatorTests.swift \
  -o "$PRESENTATION_OUT"

"$PRESENTATION_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -parse-as-library \
  -framework AppKit \
  -framework CoreGraphics \
  Sources/CaptureTypes.swift \
  Sources/CoordinateMath.swift \
  Sources/DirectScreenSnapshotProvider.swift \
  Tests/DirectScreenSnapshotProviderTests.swift \
  -o "$DIRECT_CAPTURE_OUT"

"$DIRECT_CAPTURE_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 6 \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -parse-as-library \
  Tests/CaptureHotPathStaticTests.swift \
  -o "$CAPTURE_HOT_PATH_OUT"

"$CAPTURE_HOT_PATH_OUT"

if test -f Sources/FreshRegionCapture.swift || test -f Sources/SystemCaptureSession.swift; then
  echo "Capture architecture regression: retired capture path returned." >&2
  exit 1
fi

if test -f Sources/ScreenFrameCache.swift || test -f Sources/ScreenFreezePipeline.swift; then
  echo "Capture architecture regression: stream/cache freezer must not return." >&2
  exit 1
fi

if output="$(rg -n "import ScreenCaptureKit|SCScreenshotManager|SCStream\\(|/usr/sbin/screencapture" Sources build.sh)"; then
  echo "$output"
  echo "Capture architecture regression: production must use only the direct snapshot provider." >&2
  exit 1
fi

rg -F -q "CGWindowListCreateImage" Sources/DirectScreenSnapshotProvider.swift
if rg -F -q "withThrowingTaskGroup" Sources/DirectScreenSnapshotProvider.swift; then
  echo "Capture architecture regression: compositor requests must stay serialized." >&2
  exit 1
fi
rg -F -q "for display in displays" Sources/DirectScreenSnapshotProvider.swift
rg -F -q "Task.checkCancellation()" Sources/DirectScreenSnapshotProvider.swift
rg -F -q "FrozenSnapshotBatch(sessionID: sessionID" Sources/DirectScreenSnapshotProvider.swift
rg -F -q "beginFrozenSelection" Sources/CaptureController.swift
rg -F -q "beginFrozenSelection" Sources/Overlay.swift
rg -F -q "BackdropView" Sources/Overlay.swift
rg -F -q "window.displayIfNeeded()" Sources/Overlay.swift
rg -F -q "shot.crop(globalSelection: selection)" Sources/CaptureController.swift
rg -F -q "capture direct snapshot pending" Sources/CaptureController.swift
rg -F -q "capture frozen ready" Sources/CaptureController.swift
rg -F -q "mouseUpToCardMs" Sources/CaptureController.swift
if output="$(rg -n "beginLiveSelection|installFrozenBackdrops|PendingSelection|HiddenAppWindows|hideVisibleApplicationWindows" Sources/CaptureController.swift Sources/Overlay.swift)"; then
  echo "$output"
  echo "Capture architecture regression: live/hybrid selection must not return." >&2
  exit 1
fi
rg -q "capture overlay ready" Sources/CaptureController.swift
rg -q "innerOverlayColor" Sources/Overlay.swift
rg -q "currentRect.fill()" Sources/Overlay.swift
if output="$(rg -n "bounds\\.fill\\(\\)|black\\.withAlphaComponent\\(0\\.30\\)" Sources/Overlay.swift)"; then
  echo "$output"
  echo "Overlay regression: selection must not draw a full-screen outside dim." >&2
  exit 1
fi
rg -F -q "window.isReleasedWhenClosed = false" Sources/Overlay.swift
rg -F -q "guard !isDismissed else { return }" Sources/Overlay.swift
rg -F -q "window.close()" Sources/Overlay.swift
rg -F -q "styleMask: [.borderless]" Sources/Overlay.swift
rg -F -q "override var canBecomeKey: Bool { true }" Sources/Overlay.swift
rg -F -q "NSApp.activate(ignoringOtherApps: true)" Sources/SelectionPresentationCoordinator.swift
rg -F -q "isApplicationActive()" Sources/SelectionPresentationCoordinator.swift
rg -F -q "NSApp.yieldActivation(to: source)" Sources/Overlay.swift
rg -F -q "NSCursor.hide()" Sources/CursorLease.swift
rg -F -q "NSCursor.unhide()" Sources/CursorLease.swift
if output="$(rg -n "NSCursor\.(hide|unhide)|CGDisplay(Hide|Show)Cursor" Sources/Overlay.swift Sources/SelectionPresentationCoordinator.swift)"; then
  echo "$output"
  echo "Cursor ownership regression: suppression escaped the single lease." >&2
  exit 1
fi
rg -F -q "trayHostIgnoresMouseEvents" Sources/ThumbnailManager.swift
rg -F -q "host.ignoresMouseEvents = ignores" Sources/ThumbnailManager.swift
rg -F -q "NSEvent.addGlobalMonitorForEvents" Sources/ThumbnailManager.swift
rg -F -q "NSEvent.addLocalMonitorForEvents" Sources/ThumbnailManager.swift
rg -F -q "RegisterEventHotKey(UInt32(kVK_Escape)" Sources/SessionEscapeHotKey.swift
rg -F -q "Task.detached(priority: .userInitiated)" Sources/CaptureController.swift
rg -q "CaptureError.captureStackUnavailable" Sources/CaptureController.swift
rg -q "capture stack unavailable" Sources/CaptureController.swift
rg -q "presentCaptureStackFailureNotice" Sources/CaptureController.swift
rg -q "didNotifyCaptureStackFailure" Sources/CaptureController.swift
rg -F -q "NSApp.requestUserAttention(.informationalRequest)" Sources/CaptureController.swift
rg -F -q "captureStackUnavailable(String)" Sources/CaptureTypes.swift
rg -q "capture clipboard copied" Sources/CaptureArtifact.swift
rg -q "capture image handoff started" Sources/CaptureController.swift
rg -q "capture delivery outcome=completed" Sources/CaptureArtifact.swift
rg -F -q "artifactStore.admit(sequence: sequence, image: image)" Sources/CaptureController.swift
rg -F -q "preparationTask" Sources/CaptureArtifact.swift
rg -q "struct PreparedImage" Sources/Clipboard.swift
rg -q "import ImageIO" Sources/Clipboard.swift
rg -F -q "prepareImage(cgImage: CGImage, fileURL: URL? = nil)" Sources/Clipboard.swift
rg -F -q "pasteboardItem(preparedImage" Sources/Clipboard.swift
if output="$(rg -n "copy\\(cgImage:|copyAll\\(cgImages:" Sources/Clipboard.swift)"; then
  echo "$output"
  echo "Clipboard architecture regression: Clipboard must not expose synchronous image-copy convenience APIs." >&2
  exit 1
fi
rg -F -q "artifactStore.copy(t.artifact)" Sources/ThumbnailManager.swift
rg -F -q "thumbnailLayout(screenFrame:" Sources/ThumbnailManager.swift
rg -F -q "thumbnailLayoutShowingNewest" Sources/ThumbnailManager.swift
rg -F -q "func scrollTray(with event: NSEvent)" Sources/ThumbnailManager.swift
rg -F -q "for item in hidden { item.hide() }" Sources/ThumbnailManager.swift
rg -F -q "container.layer?.transform = transform" Sources/ThumbnailWindow.swift
rg -F -q "TrayProgressAnimator(hostView: hostContent)" Sources/ThumbnailManager.swift
rg -F -q "collectionAnimator = CollectionProgressAnimator(hostView: hostContent)" Sources/ThumbnailManager.swift
rg -F -q "thumbnailTrayVisualState(progress:" Sources/ThumbnailWindow.swift
rg -F -q "prepareReflow(from:" Sources/ThumbnailManager.swift
rg -F -q "setCountTransitionProgress(progress)" Sources/ThumbnailManager.swift
rg -F -q "collapsedPeekHold" Sources/ThumbnailManager.swift
rg -F -q "hub.onHoverChanged" Sources/ThumbnailManager.swift
rg -F -q "hub.setTrayHoverActive(true)" Sources/ThumbnailManager.swift
rg -F -q "hub.setTrayHoverActive(false)" Sources/ThumbnailManager.swift
rg -F -q "thumbnailHoverChanged" Sources/ThumbnailManager.swift
rg -F -q "TrayAnim.hoverExitGrace" Sources/ThumbnailManager.swift
rg -F -q "guard !self.mouseInsideHoverIsland() else { return }" Sources/ThumbnailManager.swift
rg -F -q "trayHoverRegionContains(toLocal(NSEvent.mouseLocation)" Sources/ThumbnailManager.swift
rg -F -q "item.interactiveFramesInHost" Sources/ThumbnailManager.swift
rg -F -q "outer.insetBy(dx: band, dy: band)" Sources/ThumbnailWindow.swift
rg -F -q "hub.updatePointer(at: toLocal(NSEvent.mouseLocation))" Sources/ThumbnailManager.swift
rg -F -q "self.hoverExitGeneration == generation" Sources/ThumbnailManager.swift
rg -F -q "self.collapsedPeekGeneration == generation" Sources/ThumbnailManager.swift
rg -F -q "container.onHoverChanged" Sources/ThumbnailWindow.swift
rg -F -q "thumbnailAxisLockedOrigin" Sources/ThumbnailManager.swift
rg -U -q 'inserted\.hide\(\)\n\s*runCollectionMotion' Sources/ThumbnailManager.swift
rg -F -q "class NativeOdometerView" Sources/NativeHubView.swift
rg -F -q "odometerView.debugClips" Sources/NativeHubView.swift
if output="$(rg -n "outgoingCountView|compactCountClipView|outgoingCountMaskLayer" Sources/NativeHubView.swift)"; then
  echo "$output"
  echo "Odometer regression: full Native button renders must not return as rolling layers." >&2
  exit 1
fi
if ! rg -U -q 'if hidden \{\n\s*container\.interactionsEnabled = false\n\s*container\.isHidden = true\n\s*return' Sources/ThumbnailWindow.swift; then
  echo "Thumbnail regression: hidden collection completion must terminate before restoring resting alpha." >&2
  exit 1
fi
if output="$(awk 'index($0, "func add(artifact:") { active = 1 } active { print } index($0, "func remove(") { exit }' Sources/ThumbnailManager.swift | rg -n "\bexpand\(\)")"; then
  echo "$output"
  echo "Collapsed capture regression: adding a screenshot must not auto-expand the tray." >&2
  exit 1
fi
rg -F -q "hub.setTrayCollapseProgress(progress)" Sources/ThumbnailManager.swift
if output="$(rg -n "\bdissolve\(|\bemerge\(|TrayAnim\.(stagger|maxStagger|delay)|contentProgress|contentAnimator|class FrameAnimator" Sources)"; then
  echo "$output"
  echo "Motion architecture regression: tray collapse must keep one coordinator and one master progress." >&2
  exit 1
fi
if output="$(awk 'index($0, "func collapse()") { active = 1 } active { print } index($0, "func expand()") { exit }' Sources/ThumbnailManager.swift | rg -n "setCollapsed\(")"; then
  echo "$output"
  echo "Thumbnail controls regression: collapse must not hide card controls before fade completion." >&2
  exit 1
fi
if output="$(rg -n "startFrame\.(minX|minY|width|height)|target\.(minX|minY|width|height).*\* e" Sources/ThumbnailWindow.swift)"; then
  echo "$output"
  echo "Thumbnail motion regression: collapse/expand must not resize layout frames per display tick." >&2
  exit 1
fi
if output="$(rg -n "items\.reversed\(\)" Sources/ThumbnailManager.swift)"; then
  echo "$output"
  echo "Thumbnail layout regression: newest screenshots must append into free slots without reflowing existing cards." >&2
  exit 1
fi
rg -q "preparedImageIfReady" Sources/CaptureArtifact.swift
if output="$(rg -n "NSBitmapImageRep\\(cgImage:|tiffRepresentation|Clipboard\\.(copy|prepareImage)\\(cgImage:" Sources/CaptureController.swift Sources/ThumbnailManager.swift Sources/ThumbnailWindow.swift Sources/PinnedWindow.swift)"; then
  echo "$output"
  echo "Clipboard architecture regression: card and pinned copy/drag paths must use prepared Clipboard payloads." >&2
  exit 1
fi
rg -q "capture end outcome=" Sources/CaptureController.swift
rg -F -q "Task.detached(priority: .userInitiated)" Sources/CaptureController.swift
rg -F -q "startSnapshotTask(displays: displays)" Sources/CaptureController.swift
rg -F -q "startCropTask(shot: shot" Sources/CaptureController.swift
rg -F -q "snapshotTask?.cancel()" Sources/CaptureController.swift
rg -F -q "cropTask?.cancel()" Sources/CaptureController.swift
rg -q "deliveryDisplayID" Sources/CaptureController.swift
if output="$(awk 'index($0, "private func selectionCompleted(") { in_body = 1 } in_body { print } index($0, "private func startCropTask") { exit }' Sources/CaptureController.swift | rg -n "SCScreenshotManager|captureImage|CGWindowListCreateImage|Process\\(")"; then
  echo "$output"
  echo "Capture completion regression: mouse-up must only hand off the frozen image." >&2
  exit 1
fi
rg -q "endOutcome = \\.completed" Sources/CaptureController.swift
rg -q "endOutcome = \\.cancelled" Sources/CaptureController.swift
rg -q "endOutcome = \\.shutdown" Sources/CaptureController.swift
rg -q "endOutcome = \\.ignoredSmallSelection" Sources/CaptureController.swift
rg -F -q "capture.shutdown()" Sources/AppDelegate.swift
rg -F -q "func shutdown()" Sources/CaptureController.swift
rg -F -q "private var prewarmTask: Task<Void, Never>?" Sources/CaptureController.swift
rg -F -q "private var prewarmID = UUID()" Sources/CaptureController.swift
rg -F -q "prewarmTask?.cancel()" Sources/CaptureController.swift
rg -F -q "prewarmTask = Task.detached" Sources/CaptureController.swift
if output="$(rg -n "provider\\.prepare\\(|func prepare\\(quartzBounds:" Sources/CaptureController.swift Sources/DirectScreenSnapshotProvider.swift)"; then
  echo "$output"
  echo "Capture prewarm regression: availability checks must not capture pixels." >&2
  exit 1
fi
rg -F -q "pixels=false" Sources/CaptureController.swift
rg -F -q "DirectCaptureLane.shared.sync" Sources/DirectScreenSnapshotProvider.swift
rg -F -q "self.prewarmID == prewarmID" Sources/CaptureController.swift
rg -F -q "prewarmTask = nil" Sources/CaptureController.swift
rg -F -q "selectionSession?.shutdown()" Sources/CaptureController.swift
rg -F -q "private var finishingSessions: [UUID: CaptureSession] = [:]" Sources/CaptureController.swift
rg -F -q "finishingSessions[id] = session" Sources/CaptureController.swift
rg -q "window.sharingType = .none" Sources/WindowCaptureProtection.swift
rg -F -q "try WindowCaptureProtection.auditOnScreenWindows()" Sources/CaptureController.swift
rg -F -q "throw WindowCaptureProtectionError.auditUnavailable" Sources/WindowCaptureProtection.swift
rg -q "WindowCaptureProtection.excludeFromScreenCapture" Sources/Overlay.swift
rg -q "WindowCaptureProtection.excludeFromScreenCapture" Sources/ThumbnailManager.swift
rg -q "WindowCaptureProtection.excludeFromScreenCapture" Sources/PinnedWindow.swift
rg -q "WindowCaptureProtection.excludeFromScreenCapture" Sources/SettingsWindow.swift
rg -F -q "thumbnails.beginCapturePresentation(sessionID: session.id)" Sources/CaptureController.swift
rg -F -q "thumbnails.endCapturePresentation(sessionID: id)" Sources/CaptureController.swift
rg -F -q "CaptureWindowLevels.protectedInterface" Sources/ThumbnailManager.swift
if output="$(rg -n "ScreenFrameCache|CachedFrame|validatedAt|preparedFrozenScreens|capture cache old frame accepted" Sources README.md PRODUCT_CONTRACT.md)"; then
  echo "$output"
  echo "Capture architecture regression: old stale-cache vocabulary must not remain in active contracts or code." >&2
  exit 1
fi
if output="$(rg -n "GlassButton|DesignSystemButton|DesignSystemButtonGroup" Sources/ThumbnailWindow.swift Sources/PinnedWindow.swift Sources/HubWindow.swift)"; then
  echo "$output"
  echo "Native controls regression: floating controls must use Native SDK controls, not AppKit button replicas." >&2
  exit 1
fi
if output="$(rg -n "NSImage\\(systemSymbolName|GlassButton|bezelStyle = \\.glass" Sources/HubWindow.swift Sources/ThumbnailWindow.swift Sources/PinnedWindow.swift)"; then
  echo "$output"
  echo "Design-system regression: floating controls must use Native SDK-rendered icons and buttons." >&2
  exit 1
fi
if output="$(rg -n "NSSegmentedControl|NSButton|DesignSystemButton|DesignSystemButtonGroup" Sources/SettingsWindow.swift)"; then
  echo "$output"
  echo "Settings UI regression: settings controls must use Native SDK-rendered button-group, not AppKit controls." >&2
  exit 1
fi
if output="$(rg -n "NSSegmentedControl|NSButton\\b|DesignSystemButton|DesignSystemButtonGroup" Sources/StatusItemController.swift)"; then
  echo "$output"
  echo "Status item regression: the menu bar entry uses a system NSMenu; custom control replicas are prohibited." >&2
  exit 1
fi
rg -F -q "NativeHubShellView(frame: .zero)" Sources/HubWindow.swift
rg -F -q "NativeThumbnailControlsView(frame: .zero)" Sources/ThumbnailWindow.swift
rg -F -q "NativePinnedCopyButtonView(frame: .zero)" Sources/PinnedWindow.swift
rg -F -q "NativeSettingsContentView(frame:" Sources/SettingsWindow.swift
# Меню строки меню — системное NSMenu, а не собственная поверхность:
# клавиатура, VoiceOver и позиционирование приходят от системы.
rg -F -q "statusItem.menu = makeMenu()" Sources/StatusItemController.swift
rg -F -q "NSMenuDelegate" Sources/StatusItemController.swift
if output="$(rg -n "NativeStatusMenuContentView|status_menu" Sources NativeQuickShotUI/src 2>/dev/null)"; then
  echo "$output"
  echo "Status-menu regression: the menu bar menu must stay a system NSMenu." >&2
  exit 1
fi
rg -F -q "native_sdk_app_create" Sources/NativeSDKBridge.swift
rg -F -q "native_sdk_app_touch" Sources/NativeSDKBridge.swift
rg -F -q "quickshot_native_ui_pointer_move" Sources/NativeSDKBridge.swift
rg -F -q "quickshot_native_ui_take_action" Sources/NativeSDKBridge.swift
rg -F -q "quickshot_native_ui_set_appearance" Sources/NativeSDKBridge.swift
rg -F -q -- "-Doptimize=ReleaseFast" build.sh
if output="$(rg -n 'size="icon"' NativeQuickShotUI/src/hub.native)"; then
  echo "$output"
  echo "Design-system regression: icon-only controls must remain on the shared House sm register." >&2
  exit 1
fi
rg -F -q "<button-group" NativeQuickShotUI/src/hub.native
rg -F -q "<button size=\"sm\"" NativeQuickShotUI/src/hub.native
rg -F -q '<panel width="{bubbleWidth}" height="40" background="surface" radius="xl" label="QuickShot hub bubble"></panel>' NativeQuickShotUI/src/hub.native
rg -F -q '<row gap="8" cross="center" padding="6" label="QuickShot hub commands">' NativeQuickShotUI/src/hub.native
rg -F -q 'variant="secondary"' NativeQuickShotUI/src/hub.native
if output="$(rg -n 'variant="primary"' NativeQuickShotUI/src/hub.native)"; then
  echo "$output"
  echo "House Dark regression: floating neutral commands must not return to the light primary variant." >&2
  exit 1
fi
rg -F -q ".pack = .house" NativeQuickShotUI/src/main.zig
rg -F -q ".color_scheme = .dark" NativeQuickShotUI/src/main.zig
rg -F -q '.theme = "house"' NativeQuickShotUI/app.zon
rg -F -q "command_surface_prefix = \"surface:\"" NativeQuickShotUI/src/main.zig
rg -F -q "setSurface(.thumbnail)" Sources/NativeHubView.swift
rg -F -q "setSurface(.pinned)" Sources/NativeHubView.swift
rg -F -q "setSurface(.settings)" Sources/NativeHubView.swift
rg -F -q "targetProgress" Sources/NativeHubView.swift
rg -F -q "addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged])" Sources/NativeHubView.swift
rg -F -q "stopHoverMonitoring()" Sources/NativeHubView.swift
# Команды хаба — иконки без текста; имя показывает системный тултип по ховеру.
rg -F -q 'icon="x" label="Close" on-press="delete"></button>' NativeQuickShotUI/src/hub.native
rg -F -q 'icon="download" label="Save As" on-press="save_as"></button>' NativeQuickShotUI/src/hub.native
rg -F -q 'icon="copy" label="Copy All" on-press="copy_all"></button>' NativeQuickShotUI/src/hub.native
# Системный help tag не срабатывает у неактивного accessory-приложения:
# ярлык рисует QuickShot, окно исключено из захвата и прозрачно для мыши.
rg -F -q "HubTooltipWindow" Sources/HubTooltip.swift
rg -F -q "WindowCaptureProtection.excludeFromScreenCapture(panel)" Sources/HubTooltip.swift
rg -F -q "panel.ignoresMouseEvents = true" Sources/HubTooltip.swift
rg -F -q "handleTooltipInteraction" Sources/NativeHubView.swift
# Холодная задержка — именованный токен, тёплое перенацеливание мгновенно,
# семантика кнопок на пути каждого движения мыши кэшируется.
rg -F -q "TrayHover.tooltipDelay" Sources/NativeHubView.swift
rg -F -q "let warm = tooltip.isVisible" Sources/NativeHubView.swift
rg -F -q "cachedButtonNodes" Sources/NativeHubView.swift
# Библиотека снимков не связана с арендами доставки: файл переживает закрытие
# трея (ST-9) и удаление карточки (ST-10), уборка удаляет мимо корзины (ST-6).
# Объектная модель: история снимками, жест — один шаг, выделение в состоянии.
rg -F -q "func beginGesture()" Sources/AnnotationDocument.swift
# Редактор не трогает оверлей захвата (X-1) и живёт в собственном окне,
# исключённом из захвата; плашка рисуется непрозрачной (E-1).
rg -F -q "WindowCaptureProtection.excludeFromScreenCapture(window)" Sources/AnnotationEditor.swift
rg -F -q "AnnotationPalette.redaction" Sources/AnnotationRenderer.swift
# Жизненный цикл Edited: состояние живёт до закрытия трея, выдача берёт
# изменённую версию, бейдж не накапливается.
rg -F -q "func discardAll()" Sources/AnnotationSession.swift
rg -F -q "editedImages.preparedImage(for: t.artifact.id)" Sources/ThumbnailManager.swift
rg -F -q "sessions.discardAll()" Sources/ThumbnailManager.swift
# Прокрутка непрерывная, а не пошаговая; сворачивание требует намерения.
rg -F -q "scrollModel.scrolled(by: -delta, rubberBand: hasPhases)" Sources/ThumbnailManager.swift
rg -F -q "collapseThreshold" Sources/TrayScrollModel.swift
rg -F -q "func handleHubSwipe" Sources/ThumbnailManager.swift
# Прокрутка доходит до координат карточек, а не живёт только в модели.
rg -F -q "thumbnailScrollLayout(screenFrame:" Sources/ThumbnailManager.swift
# Кадрирование и поворот существуют и применяются к результату.
rg -F -q "func rotateQuarterTurn" Sources/AnnotationCanvasView.swift
rg -F -q "private func applyCrop" Sources/AnnotationCanvasView.swift
# Служебное состояние без обязательств совместимости (ED-17).
rg -F -q "private static let version = 1" Sources/AnnotationStateStore.swift
rg -F -q "stateStore.load(for: t.artifact.id)" Sources/ThumbnailManager.swift
rg -F -q 'on-press="tool_crop"' NativeQuickShotUI/src/hub.native
rg -F -q 'on-press="editor_rotate"' NativeQuickShotUI/src/hub.native
# Подписи короче трёх символов нечитаемы без легенды: запрещены в разметке.
if output="$(rg -n '>[A-Za-z0-9]{1,2}</button>' NativeQuickShotUI/src/hub.native)"; then
  echo "$output"
  echo "Label regression: control labels must be self-explanatory, not one-letter codes." >&2
  exit 1
fi
# Находки не скрываются молча, а проверка Луна отсекает не-карты.
rg -F -q "Hide All" Sources/AnnotationEditor.swift
rg -F -q "passesLuhn" Sources/SensitiveDataDetector.swift
# Интерфейс целиком на английском (N-1).
if output="$(rg -n '"[^"]*[а-яА-Я][^"]*"' Sources/*.swift | rg -v NSLog)"; then
  echo "$output"
  echo "Language regression: the interface is English-only (N-1)." >&2
  exit 1
fi
if output="$(rg -n "shiftViewport\(by: step\)" Sources/ThumbnailManager.swift)"; then
  echo "$output"
  echo "Tray regression: scrolling must be continuous, not stepwise (TR-2)." >&2
  exit 1
fi
if output="$(rg -n "CaptureSession|SelectionPresentationCoordinator|DirectScreenSnapshotProvider" Sources/AnnotationEditor.swift Sources/AnnotationCanvasView.swift)"; then
  echo "$output"
  echo "Editor regression: annotation must not reach into the capture overlay (X-1)." >&2
  exit 1
fi
rg -F -q "var selection: Set<UUID>" Sources/AnnotationDocument.swift
rg -F -q "func store(pngData:" Sources/ScreenshotLibrary.swift
rg -F -q "fileManager.removeItem(at: url)" Sources/ScreenshotLibrary.swift
rg -F -q "isScreenshotOwnedByQuickShot" Sources/ScreenshotLibrary.swift
rg -F -q "library.store(pngData: png" Sources/CaptureController.swift
if output="$(rg -n "trashItem|recycle" Sources/ScreenshotLibrary.swift)"; then
  echo "$output"
  echo "Retention regression: expired screenshots must be deleted, not moved to the Trash (ST-6)." >&2
  exit 1
fi
# Панель капсулы рендерится в фактическую ширину ряда: фикс срезанного штриха.
rg -F -q 'width="{bubbleWidth}"' NativeQuickShotUI/src/hub.native
rg -F -q "setBubbleWidth(width)" Sources/NativeHubView.swift
if output="$(rg -n 'on-press="(delete|save_as|copy_all)">[A-Za-z]' NativeQuickShotUI/src/hub.native)"; then
  echo "$output"
  echo "Hub regression: action commands must stay icon-only; names live in tooltips." >&2
  exit 1
fi
test -f PRODUCT_CONTRACT.md
test -x scripts/verify-capture-observed.sh
test -x scripts/probe-screen-capture-stack.sh
for script in scripts/verify-capture-runtime.sh scripts/verify-capture-selection-output.sh scripts/verify-capture-cold-start.sh; do
  rg -q "QUICKSHOT_ALLOW_SYNTHETIC_INPUT" "$script"
  rg -q "verify-capture-observed.sh" "$script"
done
if output="$(rg -n "CGEvent|cghidEventTap|postMouse|postKey|send_hotkey" scripts/verify-capture-observed.sh scripts/probe-screen-capture-stack.sh)"; then
  echo "$output"
  echo "Verification regression: log-only/probe scripts must not post synthetic input." >&2
  exit 1
fi
rg -q "capture trigger accepted" scripts/verify-capture-observed.sh
rg -q "capture direct batch ready" scripts/verify-capture-observed.sh
rg -q "capture frozen ready" scripts/verify-capture-observed.sh
rg -q "capture overlay ready" scripts/verify-capture-observed.sh
rg -q "capture crop complete" scripts/verify-capture-observed.sh
rg -q "overlay activation completed" scripts/verify-capture-observed.sh
rg -q "phase=trigger" scripts/verify-capture-observed.sh
rg -q "REQUIRE_HOTKEY_EVENT" scripts/verify-capture-observed.sh
rg -q "REQUIRE_COMPLETED_SELECTION" scripts/verify-capture-observed.sh
rg -q "hotkey event received" scripts/verify-capture-observed.sh
rg -q "capture clipboard copied" scripts/verify-capture-observed.sh
rg -q "capture delivery outcome=completed" scripts/verify-capture-observed.sh
rg -q "capture end outcome=completed" scripts/verify-capture-observed.sh
rg -q "mouseUpToCardMs" scripts/verify-capture-observed.sh
