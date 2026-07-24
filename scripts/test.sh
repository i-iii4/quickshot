#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
DEPLOY="26.0"
SDK="$(xcrun --show-sdk-path)"
ZIG_BIN="${QUICKSHOT_ZIG:-$(command -v zig || true)}"
if [ -z "$ZIG_BIN" ] && [ -x "$HOME/.native/toolchains/zig-0.16.0/zig" ]; then
  ZIG_BIN="$HOME/.native/toolchains/zig-0.16.0/zig"
fi
if [ -z "$ZIG_BIN" ]; then
  echo "error: zig is required to build NativeQuickShotUI tests; set QUICKSHOT_ZIG or install Zig 0.16" >&2
  exit 1
fi

NATIVE_DESIGN_SYSTEM_DIR="${NATIVE_DESIGN_SYSTEM_DIR:-$PWD/../native-ui-design-system}"
if [ ! -x "$NATIVE_DESIGN_SYSTEM_DIR/scripts/check.sh" ]; then
  echo "error: Native UI Design System not found at $NATIVE_DESIGN_SYSTEM_DIR" >&2
  exit 1
fi
NATIVE_DESIGN_SYSTEM_ZIG="$ZIG_BIN" \
  "$NATIVE_DESIGN_SYSTEM_DIR/scripts/check.sh" "$PWD/NativeQuickShotUI/src/hub.native"

NATIVE_UI_LIB="$PWD/NativeQuickShotUI/zig-out/lib/libquickshot-native-ui.a"
OUT="$(mktemp -t quickshot-hub-tests)"
SURFACE_OUT="$(mktemp -t quickshot-native-surface-tests)"
STATUS_LAYOUT_OUT="$(mktemp -t quickshot-status-menu-layout-tests)"
TRAY_POINTER_OUT="$(mktemp -t quickshot-tray-pointer-tests)"
THUMBNAIL_LAYOUT_OUT="$(mktemp -t quickshot-thumbnail-layout-tests)"
THUMBNAIL_MOTION_OUT="$(mktemp -t quickshot-thumbnail-motion-tests)"
THUMBNAIL_COLLECTION_OUT="$(mktemp -t quickshot-thumbnail-collection-tests)"
HUB_LIVE_OUT="$(mktemp -t quickshot-hub-live-tests)"
THUMBNAIL_LIVE_OUT="$(mktemp -t quickshot-thumbnail-live-tests)"
SELECTION_OUT="$(mktemp -t quickshot-selection-tests)"
CURSOR_LEASE_OUT="$(mktemp -t quickshot-cursor-lease-tests)"
PRESENTATION_OUT="$(mktemp -t quickshot-selection-presentation-tests)"
DIRECT_CAPTURE_OUT="$(mktemp -t quickshot-direct-capture-tests)"
CAPTURE_HOT_PATH_OUT="$(mktemp -t quickshot-capture-hot-path-tests)"
CAPTURE_GESTURE_OUT="$(mktemp -t quickshot-capture-gesture-tests)"
trap 'rm -f "$OUT" "$SURFACE_OUT" "$STATUS_LAYOUT_OUT" "$TRAY_POINTER_OUT" "$THUMBNAIL_LAYOUT_OUT" "$THUMBNAIL_MOTION_OUT" "$THUMBNAIL_COLLECTION_OUT" "$HUB_LIVE_OUT" "$THUMBNAIL_LIVE_OUT" "$SELECTION_OUT" "$CURSOR_LEASE_OUT" "$PRESENTATION_OUT" "$DIRECT_CAPTURE_OUT" "$CAPTURE_HOT_PATH_OUT" "$CAPTURE_GESTURE_OUT"' EXIT

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  Sources/CaptureGestureBuffer.swift \
  Tests/CaptureGestureBufferTests.swift \
  -o "$CAPTURE_GESTURE_OUT"

"$CAPTURE_GESTURE_OUT"

# Pixel timing is a product contract, so exercise the same optimized Native SDK
# renderer that ships in QuickShot instead of measuring the debug reference path.
(cd NativeQuickShotUI && PATH="$(dirname "$ZIG_BIN"):$PATH" "$ZIG_BIN" build lib -Doptimize=ReleaseFast)

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  Tests/HubWindowTestSupport.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/NativeHubView.swift \
  Sources/HubWindow.swift \
  Tests/HubWindowBehaviorTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$OUT"

"$OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  Tests/HubWindowTestSupport.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/NativeHubView.swift \
  Sources/HubWindow.swift \
  Tests/NativeSurfaceBehaviorTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$SURFACE_OUT"

"$SURFACE_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -framework AppKit \
  Sources/StatusMenuLayout.swift \
  Tests/StatusMenuLayoutTests.swift \
  -o "$STATUS_LAYOUT_OUT"

"$STATUS_LAYOUT_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -framework AppKit \
  Sources/TrayHostContentView.swift \
  Tests/TrayPointerRoutingTests.swift \
  -o "$TRAY_POINTER_OUT"

"$TRAY_POINTER_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -framework AppKit \
  Sources/ThumbnailLayout.swift \
  Tests/ThumbnailLayoutTests.swift \
  -o "$THUMBNAIL_LAYOUT_OUT"

"$THUMBNAIL_LAYOUT_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -framework AppKit \
  Sources/MotionCurves.swift \
  Sources/ThumbnailMotion.swift \
  Tests/ThumbnailMotionTests.swift \
  -o "$THUMBNAIL_MOTION_OUT"

"$THUMBNAIL_MOTION_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  -framework QuartzCore \
  Sources/CaptureWindowLevels.swift \
  Sources/WindowCaptureProtection.swift \
  Sources/Theme.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/NativeHubView.swift \
  Sources/Clipboard.swift \
  Sources/CardSizing.swift \
  Sources/TrayHostContentView.swift \
  Sources/HubWindow.swift \
  Sources/PinnedWindow.swift \
  Sources/ThumbnailMotion.swift \
  Sources/ThumbnailWindow.swift \
  Sources/ThumbnailLayout.swift \
  Sources/ThumbnailManager.swift \
  Tests/ThumbnailCollectionBehaviorTests.swift \
  "$NATIVE_UI_LIB" \
  -o "$THUMBNAIL_COLLECTION_OUT"

"$THUMBNAIL_COLLECTION_OUT"

if [ "${QUICKSHOT_RUN_LIVE_UI_TESTS:-0}" = "1" ]; then
  xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  -framework QuartzCore \
  Sources/TrayHostContentView.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/NativeHubView.swift \
  Tests/HubWindowLiveClickTests.swift \
  Sources/HubWindow.swift \
  "$NATIVE_UI_LIB" \
    -o "$HUB_LIVE_OUT"

  "$HUB_LIVE_OUT"

  xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  -framework QuartzCore \
  Sources/CaptureWindowLevels.swift \
  Sources/WindowCaptureProtection.swift \
  Sources/Theme.swift \
  Sources/MotionCurves.swift \
  Sources/NativeSDKBridge.swift \
  Sources/NativeHubView.swift \
  Sources/Clipboard.swift \
  Sources/CardSizing.swift \
  Sources/TrayHostContentView.swift \
  Sources/HubWindow.swift \
  Sources/PinnedWindow.swift \
  Sources/ThumbnailMotion.swift \
  Sources/ThumbnailWindow.swift \
  Sources/ThumbnailLayout.swift \
  Sources/ThumbnailManager.swift \
  Tests/ThumbnailWindowLiveClickTests.swift \
  "$NATIVE_UI_LIB" \
    -o "$THUMBNAIL_LIVE_OUT"

  "$THUMBNAIL_LIVE_OUT"
else
  echo "Live UI tests skipped (set QUICKSHOT_RUN_LIVE_UI_TESTS=1 to run them)."
fi

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
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
  -swift-version 5 \
  -framework AppKit \
  -framework CoreGraphics \
  Sources/CursorLease.swift \
  Tests/CursorLeaseTests.swift \
  -o "$CURSOR_LEASE_OUT"

"$CURSOR_LEASE_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
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
  -swift-version 5 \
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
  -swift-version 5 \
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
rg -q "capture clipboard copied" Sources/CaptureController.swift
rg -q "capture image handoff started" Sources/CaptureController.swift
rg -q "capture delivery outcome=completed" Sources/CaptureController.swift
rg -F -q "Clipboard.prepareImage(cgImage: image)" Sources/CaptureController.swift
rg -q "struct PreparedImage" Sources/Clipboard.swift
rg -q "import ImageIO" Sources/Clipboard.swift
rg -F -q "prepareImages(cgImages: [CGImage])" Sources/Clipboard.swift
rg -F -q "pasteboardItem(preparedImage" Sources/Clipboard.swift
if output="$(rg -n "copy\\(cgImage:|copyAll\\(cgImages:" Sources/Clipboard.swift)"; then
  echo "$output"
  echo "Clipboard architecture regression: Clipboard must not expose synchronous image-copy convenience APIs." >&2
  exit 1
fi
rg -q "cachedClipboardPayload" Sources/ThumbnailManager.swift
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
rg -F -q "guard !self.mouseOverTray() else { return }" Sources/ThumbnailManager.swift
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
if output="$(awk 'index($0, "func add(image:") { active = 1 } active { print } index($0, "func remove(") { exit }' Sources/ThumbnailManager.swift | rg -n "\bexpand\(\)")"; then
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
rg -q "prepareClipboardPayload" Sources/ThumbnailWindow.swift
rg -q "prepareClipboardPayload" Sources/PinnedWindow.swift
if output="$(rg -n "NSBitmapImageRep\\(cgImage:|tiffRepresentation|Clipboard\\.copy\\(cgImage:" Sources/ThumbnailManager.swift Sources/ThumbnailWindow.swift Sources/PinnedWindow.swift)"; then
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
rg -q "endOutcome = \"completed\"" Sources/CaptureController.swift
rg -q "endOutcome = \"cancelled\"" Sources/CaptureController.swift
rg -q "endOutcome = \"shutdown\"" Sources/CaptureController.swift
rg -q "endOutcome = \"ignored-small-selection\"" Sources/CaptureController.swift
rg -F -q "capture.shutdown()" Sources/AppDelegate.swift
rg -F -q "func shutdown()" Sources/CaptureController.swift
rg -F -q "private var prewarmTask: Task<Void, Never>?" Sources/CaptureController.swift
rg -F -q "private var prewarmID = UUID()" Sources/CaptureController.swift
rg -F -q "prewarmTask?.cancel()" Sources/CaptureController.swift
rg -F -q "prewarmTask = Task.detached" Sources/CaptureController.swift
rg -F -q "provider.prepare(quartzBounds: preparationBounds)" Sources/CaptureController.swift
rg -F -q "func prepare(quartzBounds: CGRect)" Sources/DirectScreenSnapshotProvider.swift
rg -F -q "DirectCaptureLane.shared.sync" Sources/DirectScreenSnapshotProvider.swift
rg -F -q "self.prewarmID == prewarmID" Sources/CaptureController.swift
rg -F -q "prewarmTask = nil" Sources/CaptureController.swift
rg -F -q "selectionSession?.shutdown()" Sources/CaptureController.swift
rg -F -q "private var finishingSessions: [UUID: CaptureSession] = [:]" Sources/CaptureController.swift
rg -F -q "finishingSessions[id] = session" Sources/CaptureController.swift
rg -q "window.sharingType = .none" Sources/WindowCaptureProtection.swift
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
if output="$(rg -n "NSMenu\\b|NSMenuItem\\b|NSSegmentedControl|NSButton|DesignSystemButton|DesignSystemButtonGroup" Sources/StatusItemController.swift)"; then
  echo "$output"
  echo "Status menu regression: visible menu controls must use Native SDK-rendered buttons, not AppKit menu controls." >&2
  exit 1
fi
rg -F -q "NativeHubShellView(frame: .zero)" Sources/HubWindow.swift
rg -F -q "NativeThumbnailControlsView(frame: .zero)" Sources/ThumbnailWindow.swift
rg -F -q "NativePinnedCopyButtonView(frame: .zero)" Sources/PinnedWindow.swift
rg -F -q "NativeSettingsContentView(frame:" Sources/SettingsWindow.swift
rg -F -q "NativeStatusMenuContentView(frame:" Sources/StatusItemController.swift
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
rg -F -q '<panel width="800" height="40" background="surface" radius="xl" label="QuickShot hub bubble"></panel>' NativeQuickShotUI/src/hub.native
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
