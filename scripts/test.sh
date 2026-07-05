#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="$(uname -m)"
DEPLOY="26.0"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -t quickshot-hub-tests)"
HUB_LIVE_OUT="$(mktemp -t quickshot-hub-live-tests)"
THUMBNAIL_LIVE_OUT="$(mktemp -t quickshot-thumbnail-live-tests)"
CACHE_OUT="$(mktemp -t quickshot-cache-tests)"
SELECTION_OUT="$(mktemp -t quickshot-selection-tests)"
CAPTURE_HOT_PATH_OUT="$(mktemp -t quickshot-capture-hot-path-tests)"
trap 'rm -f "$OUT" "$HUB_LIVE_OUT" "$THUMBNAIL_LIVE_OUT" "$CACHE_OUT" "$SELECTION_OUT" "$CAPTURE_HOT_PATH_OUT"' EXIT

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
  Sources/ScreenFrameCache.swift \
  Tests/ScreenFrameCacheBehaviorTests.swift \
  -o "$CACHE_OUT"

"$CACHE_OUT"

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

if output="$(rg -n "captureFull\\(|SCScreenshotManager|falling back|one-shot" Sources/CaptureController.swift)"; then
  echo "$output"
  echo "Capture flow regression: CaptureController hotkey path must not use one-shot screenshot fallback." >&2
  exit 1
fi

if output="$(rg -n "frameCache\\.frozenScreen" Sources/CaptureController.swift)"; then
  echo "$output"
  echo "Capture flow regression: CaptureController must not synchronously resolve frozen frames on the main actor." >&2
  exit 1
fi

if output="$(rg -n "func frozenScreen\\(" Sources/ScreenFrameCache.swift)"; then
  echo "$output"
  echo "Capture flow regression: ScreenFrameCache must expose only the async frozen-frame wait API." >&2
  exit 1
fi

if output="$(rg -n "if !CGPreflightScreenCaptureAccess\\(\\)" Sources/CaptureController.swift)"; then
  echo "$output"
  echo "Capture flow regression: hotkey path must use cached permission state after prewarm." >&2
  exit 1
fi

if output="$(rg -n "beginFrozenSelection" Sources)"; then
  echo "$output"
  echo "Capture flow regression: frozen-first overlay API must not come back." >&2
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

if output="$(rg -n "short-lived snapshot bridge|post-capture.*snapshot|post-capture.*prepared" PRODUCT_CONTRACT.md)"; then
  echo "$output"
  echo "Product contract regression: post-capture preparation must remain stream-only." >&2
  exit 1
fi

rg -q "beginLiveSelection" Sources/CaptureController.swift
rg -q "installFrozenBackdrops" Sources/CaptureController.swift
rg -F -q "w.isReleasedWhenClosed = false" Sources/Overlay.swift
rg -F -q "guard !isDismissed else { return }" Sources/Overlay.swift
rg -F -q "w.close()" Sources/Overlay.swift
rg -F -q "Task.detached(priority: .userInitiated)" Sources/CaptureController.swift
rg -q "frozenFrameWaitNanoseconds" Sources/CaptureController.swift
if output="$(rg -n "6_000_000_000" Sources/CaptureController.swift)"; then
  echo "$output"
  echo "Capture flow regression: frozen-frame wait must not use the old multi-second deadline." >&2
  exit 1
fi
rg -q "ScreenFrameCache" Sources/CaptureController.swift
rg -q "let cacheStart = await frameCache.start" Sources/CaptureController.swift
rg -q "cacheStart.unavailableReason" Sources/CaptureController.swift
rg -q "rectSnapshotFrozenScreen" Sources/CaptureController.swift
rg -q "capture cache rect snapshot ready" Sources/CaptureController.swift
rg -q "capture cache unavailable at start" Sources/CaptureController.swift
rg -q "CaptureError.captureStackUnavailable" Sources/CaptureController.swift
rg -q "fresh stream frame unavailable before timeout" Sources/CaptureController.swift
if output="$(rg -n "freezeFailed\\(CaptureError\\.cacheUnavailable\\)" Sources/CaptureController.swift)"; then
  echo "$output"
  echo "Capture architecture regression: CaptureSession must expose typed captureStackUnavailable, not generic cacheUnavailable." >&2
  exit 1
fi
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
rg -q "capture pending selection awaiting frozen frame" Sources/CaptureController.swift
rg -q "dismissCompletedOverlayAwaitingFrozenFrame" Sources/CaptureController.swift
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
rg -F -q "frameCache.shutdown()" Sources/CaptureController.swift
rg -F -q "end(prepareNext: false)" Sources/CaptureController.swift
rg -F -q "if prepareNext, let displayToPrepare" Sources/CaptureController.swift
rg -q "prepareForNextCapture" Sources/CaptureController.swift
rg -q "prepareForNextCapture" Sources/ScreenFrameCache.swift
rg -F -q "private var isShuttingDown = false" Sources/ScreenFrameCache.swift
rg -F -q "isShuttingDown = true" Sources/ScreenFrameCache.swift
rg -F -q "streams.removeAll()" Sources/ScreenFrameCache.swift
rg -F -q "refreshInFlight.removeAll()" Sources/ScreenFrameCache.swift
rg -F -q "startingDisplays.removeAll()" Sources/ScreenFrameCache.swift
rg -F -q "recentShareableDisplayFailure = nil" Sources/ScreenFrameCache.swift
rg -F -q "recentRectSnapshotFailure = nil" Sources/ScreenFrameCache.swift
rg -F -q "rectSnapshotProbeInFlight = false" Sources/ScreenFrameCache.swift
rg -F -q "stream.stop(reason: \"shutdown\")" Sources/ScreenFrameCache.swift
rg -q "preparedFrozenScreens" Sources/ScreenFrameCache.swift
rg -q "validatedFrameMaxPixelAge" Sources/ScreenFrameCache.swift
rg -q "shouldValidateStaticFrame" Sources/ScreenFrameCache.swift
rg -q "maintenanceRefreshAge" Sources/ScreenFrameCache.swift
rg -q "streamRestartAge" Sources/ScreenFrameCache.swift
rg -q "streamSnapshotDelayNanoseconds" Sources/ScreenFrameCache.swift
rg -q "snapshotTimeoutNanoseconds" Sources/ScreenFrameCache.swift
rg -q "refreshEscalationDelayNanoseconds" Sources/ScreenFrameCache.swift
rg -q "streamStartTimeoutNanoseconds" Sources/ScreenFrameCache.swift
rg -q "rectSnapshotTimeoutNanoseconds" Sources/ScreenFrameCache.swift
if output="$(rg -n "rectSnapshotTimeoutNanoseconds: UInt64 = 2_000_000_000" Sources/ScreenFrameCache.swift)"; then
  echo "$output"
  echo "Capture cache regression: active rect snapshot recovery must stay below the old two-second timeout." >&2
  exit 1
fi
rg -q "rectSnapshotFailureCooldown" Sources/ScreenFrameCache.swift
rg -q "rectSnapshotProbeJoinNanoseconds" Sources/ScreenFrameCache.swift
rg -q "shouldAttemptRectSnapshotRecovery" Sources/ScreenFrameCache.swift
rg -q "await shouldAttemptRectSnapshotRecovery" Sources/ScreenFrameCache.swift
rg -q "capture cache rect snapshot skipped" Sources/ScreenFrameCache.swift
rg -q "previousFailure=probe-in-flight" Sources/ScreenFrameCache.swift
rg -q "recentRectSnapshotFailure" Sources/ScreenFrameCache.swift
rg -q "rectSnapshotProbeInFlight" Sources/ScreenFrameCache.swift
rg -q "scheduleRectSnapshotProbe" Sources/ScreenFrameCache.swift
rg -q "probeRectSnapshotRecovery" Sources/ScreenFrameCache.swift
rg -q "capture cache rect snapshot probe failed" Sources/ScreenFrameCache.swift
rg -q "StreamStartTimeout" Sources/ScreenFrameCache.swift
rg -q "RectSnapshotTimeout" Sources/ScreenFrameCache.swift
rg -q "SnapshotTimeout" Sources/ScreenFrameCache.swift
rg -q "capture cache stream starting" Sources/ScreenFrameCache.swift
rg -q "CachedFrameAcceptance" Sources/ScreenFrameCache.swift
rg -q "debugCachedFrameAcceptance" Sources/ScreenFrameCache.swift
rg -F -q "source=\\(acceptance.rawValue" Sources/ScreenFrameCache.swift
rg -F -q "updatedAt >= requestedAt ? .postRequest : nil" Sources/ScreenFrameCache.swift
if output="$(sed -n '/private enum CachedFrameAcceptance/,/^    }/p' Sources/ScreenFrameCache.swift | rg -n "responsive|validated")"; then
  echo "$output"
  echo "Capture cache regression: active capture acceptance must not expose pre-request responsive/validated sources." >&2
  exit 1
fi
if output="$(sed -n '/private static func cachedFrameAcceptance/,/^    }/p' Sources/ScreenFrameCache.swift | rg -n "responsiveCachedFrameAge|shouldValidateStaticFrame|frameAge|\\.responsive|\\.validated")"; then
  echo "$output"
  echo "Capture cache regression: cached frame acceptance must require post-request pixels only." >&2
  exit 1
fi
if output="$(sed -n '/private static func shouldServePreparedFrozenScreen/,/^    }/p' Sources/ScreenFrameCache.swift | rg -n "immediatePreparedFrameAge|frameAge|\\|\\|")"; then
  echo "$output"
  echo "Capture cache regression: prepared frozen images must not bridge pre-request pixels." >&2
  exit 1
fi
rg -q "preparedFrozenScreenRetentionAge" Sources/ScreenFrameCache.swift
rg -q "startingDisplays" Sources/ScreenFrameCache.swift
rg -q "startedDisplays" Sources/ScreenFrameCache.swift
rg -q "enum StartResult" Sources/ScreenFrameCache.swift
rg -q "enum StartUnavailableReason" Sources/ScreenFrameCache.swift
rg -q "unavailableReason" Sources/ScreenFrameCache.swift
rg -F -q "func start(displays: [CaptureDisplay], excludingBundleIdentifier bundleID: String?) async -> StartResult" Sources/ScreenFrameCache.swift
if output="$(rg -n "case unavailable\\(String\\)" Sources/ScreenFrameCache.swift)"; then
  echo "$output"
  echo "Capture cache regression: StartResult must use typed unavailable reasons, not raw String." >&2
  exit 1
fi
if output="$(rg -n "func start\\(displays: \\[CaptureDisplay\\], excludingBundleIdentifier bundleID: String\\?\\) async -> Bool" Sources/ScreenFrameCache.swift)"; then
  echo "$output"
  echo "Capture cache regression: ScreenFrameCache.start must return StartResult, not Bool." >&2
  exit 1
fi
rg -q "shareableDisplayFailureCooldown" Sources/ScreenFrameCache.swift
rg -q "recentShareableDisplayFailure" Sources/ScreenFrameCache.swift
rg -q "recordShareableDisplayFailure" Sources/ScreenFrameCache.swift
rg -q "clearShareableDisplayFailure" Sources/ScreenFrameCache.swift
rg -q "capture cache shareable content skipped" Sources/ScreenFrameCache.swift
rg -F -q "defer { finishStarting(displaysToStart) }" Sources/ScreenFrameCache.swift
rg -F -q "return startResult(for: displays, unavailableReason: failure.reason)" Sources/ScreenFrameCache.swift
rg -q "hasUsableCache" Sources/ScreenFrameCache.swift
rg -q "pendingStartupRegistrationWaitNanoseconds" Sources/ScreenFrameCache.swift
rg -q "waitForUsableCacheOrFinishedStartup" Sources/ScreenFrameCache.swift
rg -q "capture cache pending startup did not become ready before short wait" Sources/ScreenFrameCache.swift
if output="$(sed -n '/func hasUsableCache/,/^    }/p' Sources/ScreenFrameCache.swift | rg -n "startingDisplays")"; then
  echo "$output"
  echo "Capture cache regression: pending startup must not be treated as usable cache." >&2
  exit 1
fi
if output="$(sed -n '/func hasUsableCache/,/^    }/p' Sources/ScreenFrameCache.swift | rg -n "streams\\[display\\.id\\] != nil")"; then
  echo "$output"
  echo "Capture cache regression: registered streams must not be usable before startCapture completes." >&2
  exit 1
fi
rg -F -q "startedDisplays.contains(display.id)" Sources/ScreenFrameCache.swift
rg -F -q "markStreamStarted(pending.stream, for: pending.display.id)" Sources/ScreenFrameCache.swift
rg -F -q "startedDisplays.remove(displayID)" Sources/ScreenFrameCache.swift
rg -F -q "startedDisplays.removeAll()" Sources/ScreenFrameCache.swift
rg -q "loadShareableContent" Sources/ScreenFrameCache.swift
rg -q "had no displays; retrying on-screen listing" Sources/ScreenFrameCache.swift
rg -q "retrying desktop-excluded listing" Sources/ScreenFrameCache.swift
rg -q "SCShareableContent.currentProcess" Sources/ScreenFrameCache.swift
rg -q "SCShareableContent.current" Sources/ScreenFrameCache.swift
rg -q "capture cache rect snapshot" Sources/ScreenFrameCache.swift
rg -q "captureRectScreenshot" Sources/ScreenFrameCache.swift
rg -q "window.sharingType = .none" Sources/WindowCaptureProtection.swift
rg -q "WindowCaptureProtection.excludeFromScreenCapture" Sources/Overlay.swift
rg -q "WindowCaptureProtection.excludeFromScreenCapture" Sources/ThumbnailManager.swift
rg -q "WindowCaptureProtection.excludeFromScreenCapture" Sources/PinnedWindow.swift
rg -q "WindowCaptureProtection.excludeFromScreenCapture" Sources/SettingsWindow.swift
if output="$(rg -n "startInFlight|hasReliableAppExclusion" Sources/ScreenFrameCache.swift)"; then
  echo "$output"
  echo "Capture cache regression: stream startup must be display-scoped and avoid dead unused exclusion state." >&2
  exit 1
fi
if output="$(rg -n "await preparedTask\\.value|FrozenWaitResult|starting sequential snapshot fallback|capture cache prepared task waiting" Sources/ScreenFrameCache.swift)"; then
  echo "$output"
  echo "Capture cache regression: frozen wait must not block mouse-up on a slow prepared task." >&2
  exit 1
fi
if output="$(rg -n "preparedFrozenScreenTasks|registerPreparedFrozenScreenTask|finishPreparedFrozenScreenTask|postCaptureSnapshotDelayNanoseconds|preparedTaskGraceNanoseconds" Sources/ScreenFrameCache.swift)"; then
  echo "$output"
  echo "Capture cache regression: post-capture preparation must not create joinable snapshot tasks." >&2
  exit 1
fi
rg -q "capture cache stream frame still pending" Sources/ScreenFrameCache.swift
rg -q "starting nonblocking snapshot fallback" Sources/ScreenFrameCache.swift
rg -q "startSnapshotFallback" Sources/ScreenFrameCache.swift
rg -q "capture cache prepared image accepted" Sources/ScreenFrameCache.swift
rg -q "capture cache prepared image expired" Sources/ScreenFrameCache.swift
rg -q "shouldRequestMaintenanceFrame" Sources/ScreenFrameCache.swift
rg -q "shouldRestartCachedStream" Sources/ScreenFrameCache.swift
rg -q "reason: \"old frame maintenance\"" Sources/ScreenFrameCache.swift
rg -q "allowsStreamRestart: false" Sources/ScreenFrameCache.swift
rg -q "post-capture prewarm" Sources/ScreenFrameCache.swift
rg -q "allowsStreamRestart: false" Sources/ScreenFrameCache.swift
rg -q "allowsStreamRestart: true" Sources/ScreenFrameCache.swift
rg -q "capture cache fresh frame request stayed soft" Sources/ScreenFrameCache.swift
rg -q "capture cache fresh frame request skipped static validation" Sources/ScreenFrameCache.swift
rg -F -q "Task.detached(priority: Self.taskPriority(for: priority))" Sources/ScreenFrameCache.swift
rg -F -q "case .capture:" Sources/ScreenFrameCache.swift
rg -F -q "return .userInitiated" Sources/ScreenFrameCache.swift
rg -F -q "case .maintenance, .idle:" Sources/ScreenFrameCache.swift
rg -F -q "return .utility" Sources/ScreenFrameCache.swift
rg -U -q "defer \\{\\n[[:space:]]+self\\.endRefresh\\(for: display\\.id, refreshID: refreshID\\)" Sources/ScreenFrameCache.swift
rg -q "RefreshPriority" Sources/ScreenFrameCache.swift
rg -q "RefreshRequest" Sources/ScreenFrameCache.swift
rg -F -q "refreshInFlight: [CGDirectDisplayID: RefreshRequest]" Sources/ScreenFrameCache.swift
rg -q "capture cache refresh superseding" Sources/ScreenFrameCache.swift
rg -q "capture cache fresh frame request superseded" Sources/ScreenFrameCache.swift
rg -F -q "refreshInFlight[displayID]?.id == refreshID" Sources/ScreenFrameCache.swift
rg -F -q "isCurrentRefresh(for: display.id, refreshID: refreshID)" Sources/ScreenFrameCache.swift
rg -F -q "SCContentFilter(display: scDisplay, excludingApplications: excludedApps, exceptingWindows: [])" Sources/ScreenFrameCache.swift
rg -F -q "config.showsCursor = false" Sources/ScreenFrameCache.swift
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
rg -q "overlay activation completed" scripts/verify-capture-observed.sh
rg -q "accepted cache frame did not report its acceptance source" scripts/verify-capture-observed.sh
rg -q "accepted cache frame did not report its acceptance source" scripts/verify-capture-runtime.sh
rg -q "accepted cache frame did not report its acceptance source" scripts/verify-capture-cold-start.sh
rg -q "accepted cache frame did not report its acceptance source" scripts/verify-capture-selection-output.sh
rg -q "forbidden pre-request cache frame source" scripts/verify-capture-observed.sh
rg -q "forbidden pre-request cache frame source" scripts/verify-capture-runtime.sh
rg -q "forbidden pre-request cache frame source" scripts/verify-capture-cold-start.sh
rg -q "forbidden pre-request cache frame source" scripts/verify-capture-selection-output.sh
rg -q "source=post-request" scripts/verify-capture-observed.sh
rg -q "phase=trigger" scripts/verify-capture-observed.sh
rg -q "REQUIRE_HOTKEY_EVENT" scripts/verify-capture-observed.sh
rg -q "REQUIRE_POST_CAPTURE_PREPARE" scripts/verify-capture-observed.sh
rg -q "REQUIRE_COMPLETED_SELECTION" scripts/verify-capture-observed.sh
rg -q "hotkey event received" scripts/verify-capture-observed.sh
rg -q "capture clipboard copied" scripts/verify-capture-observed.sh
rg -q "capture delivery outcome=completed" scripts/verify-capture-observed.sh
rg -q "capture end outcome=completed" scripts/verify-capture-observed.sh
rg -q "completedSelection" scripts/verify-capture-observed.sh
rg -q "postCapturePrepare" scripts/verify-capture-observed.sh
rg -q "capture cache post-capture prepare" scripts/verify-capture-runtime.sh
rg -q "capture cache post-capture prepare" scripts/verify-capture-cold-start.sh
rg -q "rectSnapshot=" scripts/verify-capture-observed.sh
rg -q "rectSnapshot=" scripts/verify-capture-runtime.sh
rg -q "rectSnapshot=" scripts/verify-capture-cold-start.sh
rg -q "rectSnapshot=" scripts/verify-capture-selection-output.sh
rg -F -q "capture cache fresh frame request escalating .*reason=post-capture prewarm" scripts/verify-capture-observed.sh
rg -F -q "capture cache fresh frame request escalating .*reason=post-capture prewarm" scripts/verify-capture-runtime.sh
rg -F -q "capture cache fresh frame request escalating .*reason=post-capture prewarm" scripts/verify-capture-cold-start.sh
rg -F -q "capture cache fresh frame request escalating .*reason=post-capture prewarm" scripts/verify-capture-selection-output.sh
