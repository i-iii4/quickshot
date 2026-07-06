#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
DEPLOY="26.0"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -t quickshot-hub-tests)"
HUB_LIVE_OUT="$(mktemp -t quickshot-hub-live-tests)"
THUMBNAIL_LIVE_OUT="$(mktemp -t quickshot-thumbnail-live-tests)"
FREEZE_OUT="$(mktemp -t quickshot-freeze-tests)"
SELECTION_OUT="$(mktemp -t quickshot-selection-tests)"
CAPTURE_HOT_PATH_OUT="$(mktemp -t quickshot-capture-hot-path-tests)"
trap 'rm -f "$OUT" "$HUB_LIVE_OUT" "$THUMBNAIL_LIVE_OUT" "$FREEZE_OUT" "$SELECTION_OUT" "$CAPTURE_HOT_PATH_OUT"' EXIT

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
  -framework QuartzCore \
  Sources/TrayHostContentView.swift \
  Tests/HubWindowLiveClickTests.swift \
  Sources/HubWindow.swift \
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
  Sources/WindowCaptureProtection.swift \
  Sources/Theme.swift \
  Sources/DSControls.swift \
  Sources/Clipboard.swift \
  Sources/CardSizing.swift \
  Sources/TrayHostContentView.swift \
  Sources/HubWindow.swift \
  Sources/PinnedWindow.swift \
  Sources/ThumbnailWindow.swift \
  Sources/ThumbnailManager.swift \
  Tests/ThumbnailWindowLiveClickTests.swift \
  -o "$THUMBNAIL_LIVE_OUT"

"$THUMBNAIL_LIVE_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  -framework CoreImage \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework ScreenCaptureKit \
  Sources/CaptureTypes.swift \
  Sources/CoordinateMath.swift \
  Sources/ScreenFreezePipeline.swift \
  Tests/ScreenFreezePipelineBehaviorTests.swift \
  -o "$FREEZE_OUT"

"$FREEZE_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -D TESTING \
  -framework AppKit \
  -framework CoreGraphics \
  Sources/WindowCaptureProtection.swift \
  Sources/Overlay.swift \
  Tests/SelectionToolBehaviorTests.swift \
  -o "$SELECTION_OUT"

"$SELECTION_OUT"

xcrun swiftc \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos${DEPLOY}" \
  -swift-version 5 \
  -parse-as-library \
  Tests/CaptureHotPathStaticTests.swift \
  -o "$CAPTURE_HOT_PATH_OUT"

"$CAPTURE_HOT_PATH_OUT"

if output="$(rg -n "if !CGPreflightScreenCaptureAccess\\(\\)" Sources/CaptureController.swift)"; then
  echo "$output"
  echo "Capture flow regression: hotkey path must use cached permission state after prewarm." >&2
  exit 1
fi

if test -f Sources/ScreenFrameCache.swift; then
  echo "Capture architecture regression: old ScreenFrameCache.swift must not coexist with ScreenFreezePipeline." >&2
  exit 1
fi

if output="$(rg -n "displayIfNeeded\\(" Sources/Overlay.swift)"; then
  echo "$output"
  echo "Overlay latency regression: overlay hot path must not force synchronous full-screen display before orderFront." >&2
  exit 1
fi

if output="$(rg -n "\\bRegionCapturer\\b|captureFull\\(" Sources)"; then
  echo "$output"
  echo "Capture architecture regression: legacy RegionCapturer/captureFull path must not return." >&2
  exit 1
fi

if output="$(rg -n "exclusionUnavailable|case failed\\(|cacheUnavailable" Sources/CaptureTypes.swift)"; then
  echo "$output"
  echo "Capture architecture regression: CaptureError must not keep legacy or internal cache timeout cases." >&2
  exit 1
fi

rg -q "ScreenFreezePipeline" Sources/CaptureController.swift
rg -q "captureFrozenScreens" Sources/ScreenFreezePipeline.swift
rg -F -q "SCStream(" Sources/ScreenFreezePipeline.swift
rg -q "SCStreamOutput" Sources/ScreenFreezePipeline.swift
rg -F -q "SCFrameStatus(rawValue: statusRawValue)" Sources/ScreenFreezePipeline.swift
rg -q "status == .complete" Sources/ScreenFreezePipeline.swift
rg -q "CMSampleBufferGetImageBuffer" Sources/ScreenFreezePipeline.swift
rg -q "frame.receivedAt >= acceptedAfter" Sources/ScreenFreezePipeline.swift
rg -q "freshFrameDeadlineNanoseconds" Sources/ScreenFreezePipeline.swift
rg -q "SCShareableContent.current" Sources/ScreenFreezePipeline.swift
rg -q "SCScreenshotManager\\.captureImage" Sources/ScreenFreezePipeline.swift
rg -q "capture stream fallback to one-shot" Sources/ScreenFreezePipeline.swift
rg -q "source=one-shot-fallback" Sources/ScreenFreezePipeline.swift
if output="$(awk 'index($0, "func captureFrozenScreens(") { in_body = 1 } in_body { print } index($0, "func shutdown()") { exit }' Sources/ScreenFreezePipeline.swift | rg -n "SCShareableContent\\.current|SCScreenshotManager\\.captureImage")"; then
  echo "$output"
  echo "Capture architecture regression: preferred stream path must not directly enumerate shareable content or call one-shot screenshots." >&2
  exit 1
fi
if output="$(rg -n "CaptureImageRace|captureTimeoutNanoseconds|prewarmTimeoutNanoseconds|excludingDesktopWindows\\(false, onScreenWindowsOnly: true\\)" Sources/ScreenFreezePipeline.swift)"; then
  echo "$output"
  echo "Capture architecture regression: stream-backed freeze must not keep old timeout/window-list wrappers." >&2
  exit 1
fi
if output="$(rg -n "latestActiveStreamFrame|latest-active-stream|freshness: \\.latestActiveStream|idleStopTask|streamIdleStopNanoseconds" Sources/ScreenFreezePipeline.swift)"; then
  echo "$output"
  echo "Capture architecture regression: persistent stream freezer must not accept stale latest stream frames or keep idle stop." >&2
  exit 1
fi
if output="$(rg -n "beginLiveSelection|beginOverlay\\(backdrops: \\[:\\]\\)|installFrozenBackdrops|PendingSelection|freezeFailure|finishFailedSelection|capture selection awaiting frozen frame" Sources/CaptureController.swift Sources/Overlay.swift)"; then
  echo "$output"
  echo "Capture architecture regression: CaptureController must not use the hybrid live-overlay-before-freeze path." >&2
  exit 1
fi
rg -q "beginFrozenSelection" Sources/CaptureController.swift
rg -q "let hiddenAt = CFAbsoluteTimeGetCurrent()" Sources/CaptureController.swift
rg -q "readyAfter: hiddenAt" Sources/CaptureController.swift
rg -q "requestedAt: startedAt" Sources/CaptureController.swift
rg -q "capture frozen ready" Sources/CaptureController.swift
rg -q "capture overlay ready" Sources/CaptureController.swift
rg -F -q "w.isReleasedWhenClosed = false" Sources/Overlay.swift
rg -F -q "guard !isDismissed else { return }" Sources/Overlay.swift
rg -F -q "w.close()" Sources/Overlay.swift
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
rg -q "prepareClipboardPayload" Sources/ThumbnailWindow.swift
rg -q "prepareClipboardPayload" Sources/PinnedWindow.swift
if output="$(rg -n "NSBitmapImageRep\\(cgImage:|tiffRepresentation|Clipboard\\.copy\\(cgImage:" Sources/ThumbnailManager.swift Sources/ThumbnailWindow.swift Sources/PinnedWindow.swift)"; then
  echo "$output"
  echo "Clipboard architecture regression: card and pinned copy/drag paths must use prepared Clipboard payloads." >&2
  exit 1
fi
rg -q "capture end outcome=" Sources/CaptureController.swift
rg -q "scheduleCropAndDelivery" Sources/CaptureController.swift
rg -F -q "DispatchQueue.global(qos: .userInitiated).async" Sources/CaptureController.swift
rg -F -q "shot.crop(globalSelection: selection)" Sources/CaptureController.swift
rg -q "capture crop failed" Sources/CaptureController.swift
rg -q "capture delivery outcome=crop-failed" Sources/CaptureController.swift
rg -q "deliveryDisplayID" Sources/CaptureController.swift
rg -q "capture image handoff failed missing screen" Sources/CaptureController.swift
rg -q "capture delivery outcome=handoff-failed" Sources/CaptureController.swift
if output="$(awk 'index($0, "private func completeSelection(") { in_body = 1 } in_body { print } index($0, "private func scheduleCropAndDelivery") { exit }' Sources/CaptureController.swift | rg -n "\\.crop\\(globalSelection")"; then
  echo "$output"
  echo "Capture completion regression: mouse-up handler must not crop the frozen image synchronously on the main actor." >&2
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
rg -F -q "self.prewarmID == prewarmID" Sources/CaptureController.swift
rg -F -q "prewarmTask = nil" Sources/CaptureController.swift
rg -F -q "session?.shutdown()" Sources/CaptureController.swift
rg -F -q "freezer.shutdown()" Sources/CaptureController.swift
rg -F -q "isShuttingDown = true" Sources/ScreenFreezePipeline.swift
rg -q "capture stream refresh ready" Sources/ScreenFreezePipeline.swift
rg -F -q 'refreshWarmStreams(reason: "prewarm")' Sources/ScreenFreezePipeline.swift
rg -q "capture stream frame accepted" Sources/ScreenFreezePipeline.swift
rg -q "capture stream fresh frame missed" Sources/ScreenFreezePipeline.swift
rg -q "capture stream stopped" Sources/ScreenFreezePipeline.swift
rg -q "capture freeze screens ready" Sources/ScreenFreezePipeline.swift
rg -q "window.sharingType = .none" Sources/WindowCaptureProtection.swift
rg -q "WindowCaptureProtection.excludeFromScreenCapture" Sources/Overlay.swift
rg -q "WindowCaptureProtection.excludeFromScreenCapture" Sources/ThumbnailManager.swift
rg -q "WindowCaptureProtection.excludeFromScreenCapture" Sources/PinnedWindow.swift
rg -q "WindowCaptureProtection.excludeFromScreenCapture" Sources/SettingsWindow.swift
if output="$(rg -n "ScreenFrameCache|CachedFrame|validatedAt|preparedFrozenScreens" Sources README.md PRODUCT_CONTRACT.md)"; then
  echo "$output"
  echo "Capture architecture regression: old stale-cache vocabulary must not remain in active contracts or code." >&2
  exit 1
fi
rg -F -q "config.showsCursor = false" Sources/ScreenFreezePipeline.swift
if output="$(rg -n "GlassButton" Sources/ThumbnailWindow.swift)"; then
  echo "$output"
  echo "Thumbnail controls regression: thumbnail cards must use DesignSystemButton, not native Liquid Glass." >&2
  exit 1
fi
rg -q "DesignSystemButton" Sources/ThumbnailWindow.swift
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
rg -q "capture overlay ready" scripts/verify-capture-observed.sh
rg -q "capture frozen ready" scripts/verify-capture-observed.sh
rg -q "overlay activation completed" scripts/verify-capture-observed.sh
rg -q "phase=trigger" scripts/verify-capture-observed.sh
rg -q "REQUIRE_HOTKEY_EVENT" scripts/verify-capture-observed.sh
rg -q "REQUIRE_COMPLETED_SELECTION" scripts/verify-capture-observed.sh
rg -q "hotkey event received" scripts/verify-capture-observed.sh
rg -q "capture clipboard copied" scripts/verify-capture-observed.sh
rg -q "capture delivery outcome=completed" scripts/verify-capture-observed.sh
rg -q "capture end outcome=completed" scripts/verify-capture-observed.sh
rg -q "completedSelection" scripts/verify-capture-observed.sh
