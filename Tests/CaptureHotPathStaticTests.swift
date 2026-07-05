import Foundation

@main
struct CaptureHotPathStaticTests {
    static func main() {
        do {
            let source = try String(contentsOfFile: "Sources/CaptureController.swift", encoding: .utf8)
            let overlaySource = try String(contentsOfFile: "Sources/Overlay.swift", encoding: .utf8)
            let appDelegateSource = try String(contentsOfFile: "Sources/AppDelegate.swift", encoding: .utf8)
            let hotKeySource = try String(contentsOfFile: "Sources/GlobalHotKey.swift", encoding: .utf8)
            let protectionSource = try String(contentsOfFile: "Sources/WindowCaptureProtection.swift", encoding: .utf8)
            let clipboardSource = try String(contentsOfFile: "Sources/Clipboard.swift", encoding: .utf8)
            let thumbnailManagerSource = try String(contentsOfFile: "Sources/ThumbnailManager.swift", encoding: .utf8)
            let thumbnailWindowSource = try String(contentsOfFile: "Sources/ThumbnailWindow.swift", encoding: .utf8)
            let pinnedWindowSource = try String(contentsOfFile: "Sources/PinnedWindow.swift", encoding: .utf8)
            try testCaptureSessionStartsOverlayBeforeFreeze(source)
            try testCaptureSessionStartHasNoHeavyCaptureBeforeOverlay(source)
            try testFreezeWorkStaysDetached(source)
            try testTriggerDoesNotPrewarmOrStartCache(source)
            try testLegacyRegionCapturerIsRemoved()
            try testCaptureErrorSurfaceMatchesCurrentArchitecture()
            try testCaptureEndPreparesNextFrame(source)
            try testCompletedSelectionDismissesOverlayWhenFreezePending(captureSource: source)
            try testScreenFrameCacheJoinsPostCapturePreparation()
            try testScreenFrameCacheStartIsDisplayScoped()
            try testOverlayActivationIsDeferred(overlaySource)
            try testOverlayDismissClosesFullscreenWindows(overlaySource)
            try testCompletedCaptureIsObservable(captureSource: source)
            try testClipboardPayloadPreparationIsCentralized(clipboardSource: clipboardSource,
                                                             thumbnailManagerSource: thumbnailManagerSource,
                                                             thumbnailWindowSource: thumbnailWindowSource,
                                                             pinnedWindowSource: pinnedWindowSource)
            try testCaptureEndOutcomeIsExplicit(captureSource: source)
            try testCaptureStackUnavailableIsTypedAndNonmodal(captureSource: source)
            try testHotKeyEventSeedsCaptureTiming(appDelegateSource: appDelegateSource,
                                                  hotKeySource: hotKeySource,
                                                  captureSource: source)
            try testCaptureShutdownIsExplicit(appDelegateSource: appDelegateSource,
                                               captureSource: source)
            try testQuickShotWindowsAreExcludedFromScreenCapture(protectionSource: protectionSource,
                                                                 overlaySource: overlaySource)
            print("CaptureHotPathStaticTests: passed")
        } catch {
            fputs("CaptureHotPathStaticTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testCaptureSessionStartsOverlayBeforeFreeze(_ source: String) throws {
        let startBody = try functionBody(named: "start", in: source, after: "private final class CaptureSession")
        try require(startBody.range(of: "beginOverlay(on: targetScreen)") != nil,
                    "CaptureSession.start must show the live overlay explicitly")
        try require(startBody.range(of: "HiddenAppWindows.hideVisibleApplicationWindows()") != nil,
                    "CaptureSession.start must hide QuickShot windows before frozen-frame work")
        try require(startBody.range(of: "startFreezeTask(targetDisplay: targetDisplay, requestedAt: requestedAt)") != nil,
                    "CaptureSession.start must start frozen-frame work explicitly")
        let overlayIndex = try index(of: "beginOverlay(on: targetScreen)", in: startBody)
        let hideWindowsIndex = try index(of: "HiddenAppWindows.hideVisibleApplicationWindows()", in: startBody)
        let freezeIndex = try index(of: "startFreezeTask(targetDisplay: targetDisplay, requestedAt: requestedAt)", in: startBody)
        try require(overlayIndex < hideWindowsIndex,
                    "CaptureSession.start must activate overlay before hiding QuickShot windows")
        try require(hideWindowsIndex < freezeIndex,
                    "CaptureSession.start must hide QuickShot windows before starting freeze work")
    }

    private static func testCaptureSessionStartHasNoHeavyCaptureBeforeOverlay(_ source: String) throws {
        let startBody = try functionBody(named: "start", in: source, after: "private final class CaptureSession")
        let beforeOverlay = try prefix(before: "beginOverlay(on: targetScreen)", in: startBody)
        let forbidden = [
            "waitForFrozenScreen",
            "frameCache.start",
            "SCShareableContent",
            "SCScreenshotManager",
            "createCGImage",
            "CGPreflightScreenCaptureAccess",
            "hideVisibleApplicationWindows",
            "addGlobalMonitorForEvents",
            "CaptureGestureTracker"
        ]
        for token in forbidden {
            try require(!beforeOverlay.contains(token),
                        "CaptureSession.start must not run \(token) before overlay activation")
        }
    }

    private static func testFreezeWorkStaysDetached(_ source: String) throws {
        let body = try functionBody(named: "startFreezeTask", in: source, after: "private final class CaptureSession")
        try require(body.contains("Task.detached(priority: .userInitiated)"),
                    "Frozen-frame work must stay off the main actor")
        try require(source.contains("frozenFrameWaitNanoseconds"),
                    "Frozen-frame wait must have a named direct-manipulation budget")
        try require(!body.contains("6_000_000_000"),
                    "Frozen-frame wait must not keep the old multi-second unnamed deadline")
        try require(body.contains("waitForFrozenScreen"),
                    "Frozen-frame work should use the async cache wait path")
        try require(body.contains("let cacheStart = await frameCache.start"),
                    "Frozen-frame work must preserve the typed cache start result")
        try require(body.contains("cacheStart.unavailableReason"),
                    "Frozen-frame work must pass cache-owned unavailability reasons through recovery/failure")
        try require(body.contains("capture cache unavailable at start"),
                    "Unavailable ScreenCaptureKit display content must fail quickly with a clear log")
        try require(body.contains("rectSnapshotFrozenScreen"),
                    "Frozen-frame work should use the cache-owned rect snapshot recovery when shareable displays are unavailable")
        try require(body.contains("capture cache rect snapshot ready"),
                    "Rect snapshot recovery must be observable in capture logs")
    }

    private static func testTriggerDoesNotPrewarmOrStartCache(_ source: String) throws {
        let body = try functionBody(named: "triggerCapture", in: source, after: "final class CaptureController")
        for token in ["prewarmCapturePipeline()", "frameCache.start", "waitForFrozenScreen", "SCShareableContent", "SCScreenshotManager"] {
            try require(!body.contains(token), "triggerCapture must not run \(token) on the hot path")
        }
    }

    private static func testLegacyRegionCapturerIsRemoved() throws {
        try require(!FileManager.default.fileExists(atPath: "Sources/RegionCapturer.swift"),
                    "Legacy RegionCapturer.swift must not coexist with ScreenFrameCache as a second capture path")
        let sourceFiles = try FileManager.default.contentsOfDirectory(atPath: "Sources")
        for file in sourceFiles where file.hasSuffix(".swift") {
            let path = "Sources/\(file)"
            let source = try String(contentsOfFile: path, encoding: .utf8)
            try require(!source.contains("final class RegionCapturer") && !source.contains("captureFull("),
                        "\(path) must not reintroduce the legacy captureFull path")
        }
    }

    private static func testCaptureErrorSurfaceMatchesCurrentArchitecture() throws {
        let errorSource = try String(contentsOfFile: "Sources/CaptureTypes.swift", encoding: .utf8)
        try require(!errorSource.contains("exclusionUnavailable"),
                    "CaptureError must not keep RegionCapturer-era exclusion errors")
        try require(!errorSource.contains("case failed"),
                    "CaptureError must not keep an untyped RegionCapturer-era failed wrapper")
        try require(!errorSource.contains("cacheUnavailable"),
                    "CaptureError must not expose internal cache timeout markers")
        for token in ["permissionDenied", "noDisplay", "captureStackUnavailable"] {
            try require(errorSource.contains(token), "CaptureError must retain \(token)")
        }
    }

    private static func testCaptureEndPreparesNextFrame(_ source: String) throws {
        let startBody = try functionBody(named: "start", in: source, after: "private final class CaptureSession")
        let beforeOverlay = try prefix(before: "beginOverlay(on: targetScreen)", in: startBody)
        try require(!beforeOverlay.contains("prepareForNextCapture"),
                    "Next-capture preparation must not run before overlay activation")

        let endBody = try functionBody(named: "end", in: source, after: "private final class CaptureSession")
        try require(endBody.contains("frameCache.prepareForNextCapture(display: displayToPrepare)"),
                    "CaptureSession.end must move freshness recovery to the post-capture idle path")
        let onEndIndex = try index(of: "onEnd()", in: endBody)
        let prepareIndex = try index(of: "prepareForNextCapture", in: endBody)
        try require(onEndIndex < prepareIndex,
                    "Next-capture preparation should run after the session is released")
    }

    private static func testScreenFrameCacheJoinsPostCapturePreparation() throws {
        let source = try String(contentsOfFile: "Sources/ScreenFrameCache.swift", encoding: .utf8)
        let waitBody = try functionBody(named: "waitForFrozenScreen", in: source, after: "final class ScreenFrameCache")
        try require(!waitBody.contains("preparedFrozenScreenTask"),
                    "Frozen wait must not join speculative post-capture snapshot work on mouse-up")
        try require(!waitBody.contains("await preparedTask.value"),
                    "Frozen wait must not block on a slow post-capture preparation task")
        try require(waitBody.contains("streamSnapshotDelayNanoseconds"),
                    "Capture-time snapshot fallback must wait behind the stream validation grace")
        try require(waitBody.contains("capture cache stream frame still pending"),
                    "Delayed stream-frame fallback must be visible in logs")
        try require(waitBody.contains("startSnapshotFallback"),
                    "Capture-time snapshot fallback must be detached from the hot wait")
        try require(!source.contains("preparedFrozenScreenTasks"),
                    "Speculative post-capture snapshot tasks must not be tracked or joined by active capture")
        try require(!source.contains("registerPreparedFrozenScreenTask"),
                    "Post-capture preparation must stay stream-only and avoid one-shot snapshot registration")
        try require(!source.contains("finishPreparedFrozenScreenTask"),
                    "Post-capture preparation must not need prepared-task cleanup")
        let snapshotFallbackBody = try functionBody(named: "startSnapshotFallback", in: source, after: "final class ScreenFrameCache")
        try require(snapshotFallbackBody.contains("Task.detached(priority: .userInitiated)"),
                    "Snapshot fallback must run outside the frozen-frame wait task")
        try require(snapshotFallbackBody.contains("hasFrameUpdated(for: display.id, since: requestedAt)"),
                    "Snapshot fallback must not overwrite a fresher stream frame")
        try require(source.contains("snapshotTimeoutNanoseconds"),
                    "Stream-owned screenshot fallback must be bounded")
        let streamSnapshotBody = try functionBody(named: "captureSnapshot", in: source, after: "private final class CachedDisplayStream")
        try require(streamSnapshotBody.contains("Self.captureImage"),
                    "Stream snapshot fallback must use the bounded captureImage helper")
        let boundedCaptureBody = try functionBody(named: "captureImage", in: source, after: "private final class CachedDisplayStream")
        try require(boundedCaptureBody.contains("snapshotTimeoutNanoseconds") && boundedCaptureBody.contains("group.cancelAll()"),
                    "Stream snapshot fallback must cancel the losing timeout/capture task")
        let prepareBody = try functionBody(named: "prepareForNextCapture", in: source, after: "final class ScreenFrameCache")
        try require(prepareBody.contains("requestFreshFrame"),
                    "Post-capture preparation must refresh or validate the live stream for the next capture")
        try require(prepareBody.contains("allowsStreamRestart: false"),
                    "Post-capture preparation must keep stream refresh soft instead of tearing down the stream immediately")
        try require(!prepareBody.contains("streamSnapshotFrozenScreen"),
                    "Post-capture preparation must not start SCScreenshotManager work that can delay the next mouse-up")
        try require(!prepareBody.contains("startSnapshotFallback"),
                    "Post-capture preparation must leave snapshot fallback to active capture only")
        let cachedBody = try functionBody(named: "cachedFrozenScreen", in: source, after: "final class ScreenFrameCache")
        try require(cachedBody.contains("allowsStreamRestart: true"),
                    "Capture-time stale-frame recovery must still be allowed to escalate to a stream restart")
        try require(source.contains("private enum CachedFrameAcceptance"),
                    "Cached stream-frame acceptance must keep the screenshot source observable")
        try require(source.contains("validatedAt: TimeInterval"),
                    "Cached stream frames must track stream validation separately from pixel updates")
        try require(source.contains("validatedFrameMaxPixelAge"),
                    "Static-stream validation must keep a hard pixel-age ceiling for maintenance decisions")
        try require(source.contains("shouldValidateStaticFrame"),
                    "Static stream validation must be guarded by pixel age, not validation age alone")
        try require(!source.contains("case responsive = \"responsive\""),
                    "Active capture must not accept responsive pre-request pixels")
        try require(!source.contains("case validated = \"validated\""),
                    "Active capture must not accept validation-backed pre-request pixels")
        let acceptanceBody = try functionBody(named: "cachedFrameAcceptance", in: source, after: "final class ScreenFrameCache")
        try require(acceptanceBody.contains("updatedAt >= requestedAt ? .postRequest : nil"),
                    "Cached frame acceptance must require pixels from the current capture request")
        for token in ["responsiveCachedFrameAge", "shouldValidateStaticFrame", "frameAge(", ".responsive", ".validated"] {
            try require(!acceptanceBody.contains(token),
                        "Cached frame acceptance must not use \(token) to admit pre-request pixels")
        }
        let preparedAcceptanceBody = try functionBody(named: "shouldServePreparedFrozenScreen", in: source, after: "final class ScreenFrameCache")
        try require(preparedAcceptanceBody.contains("updatedAt >= requestedAt"),
                    "Prepared frozen images must require pixels from the current capture request")
        for token in ["immediatePreparedFrameAge", "frameAge(", "||"] {
            try require(!preparedAcceptanceBody.contains(token),
                        "Prepared frozen image acceptance must not use \(token) to admit pre-request pixels")
        }
        try require(source.contains("markFrameValidated"),
                    "Successful stream fresh-frame requests must refresh validation state")
        try require(cachedBody.contains("source=\\(acceptance.rawValue"),
                    "Accepted cached frames must log their acceptance source")
        try require(source.contains("debugCachedFrameAcceptance"),
                    "ScreenFrameCache behavior tests must be able to assert acceptance reason")
        try require(source.contains("maintenanceRefreshAge"),
                    "ScreenFrameCache must refresh live stream frames before cached pixels become suspect")
        try require(source.contains("streamRestartAge"),
                    "ScreenFrameCache must reserve destructive restarts for suspect old streams")
        let ageMonitorBody = try functionBody(named: "handleAgeMonitor", in: source, after: "final class ScreenFrameCache")
        let maintenanceRequestIndex = try index(of: "shouldRequestMaintenanceFrame", in: ageMonitorBody)
        let softRequestIndex = try index(of: "allowsStreamRestart: false", in: ageMonitorBody)
        try require(maintenanceRequestIndex < softRequestIndex,
                    "Maintenance refresh must request a fresh frame softly before destructive restart")
        try require(!ageMonitorBody.contains("requestedAt: cached.validatedAt"),
                    "Maintenance refresh must compare frame updates against the maintenance request time, not the previous validation time")
        try require(ageMonitorBody.contains("requestedAt: now"),
                    "Maintenance refresh must let a successful static refresh update validation age")
        let requestBody = try functionBody(named: "requestFreshFrame", in: source, after: "final class ScreenFrameCache")
        try require(requestBody.contains("if !allowsStreamRestart"),
                    "Fresh-frame request must support a soft non-restarting policy")
        try require(requestBody.contains("capture cache fresh frame request stayed soft"),
                    "Soft fresh-frame requests must be observable in logs")
        let requestFrameIndex = try index(of: "await stream.requestFrame(reason: reason)", in: requestBody)
        let refreshGraceIndex = try index(of: "Task.sleep(nanoseconds: Self.refreshEscalationDelayNanoseconds)", in: requestBody)
        let markValidatedIndex = try index(of: "markFrameValidated", in: requestBody)
        try require(requestFrameIndex < refreshGraceIndex && refreshGraceIndex < markValidatedIndex,
                    "Stream validation must wait through the short refresh grace window before reusing a static frame")
        try require(requestBody.contains("canValidateStaticFrame(for: display.id)"),
                    "Fresh-frame requests must not validate an over-age pixel buffer")
        try require(requestBody.contains("skipped static validation"),
                    "Skipping static validation for over-age pixels must be observable in logs")
        try require(requestBody.contains("defer {\n                self.endRefresh(for: display.id, refreshID: refreshID)"),
                    "Fresh-frame refresh must release its owner with guaranteed cleanup")
        try require(requestBody.contains("Task.detached(priority: Self.taskPriority(for: priority))"),
                    "Fresh-frame refresh task priority must follow RefreshPriority instead of always running as userInitiated")
        let taskPriorityBody = try functionBody(named: "taskPriority", in: source, after: "final class ScreenFrameCache")
        try require(taskPriorityBody.contains("case .capture") && taskPriorityBody.contains("return .userInitiated"),
                    "Active capture recovery must keep userInitiated task priority")
        try require(taskPriorityBody.contains("case .maintenance, .idle") && taskPriorityBody.contains("return .utility"),
                    "Maintenance and post-capture idle refresh must not compete with user-visible crop/delivery as userInitiated work")
        try require(source.contains("private enum RefreshPriority"),
                    "Refresh coalescing must model priority, not just a boolean in-flight flag")
        try require(source.contains("private struct RefreshRequest"),
                    "Refresh coalescing must have an owner id so old tasks cannot clear newer refresh work")
        try require(source.contains("refreshInFlight: [CGDirectDisplayID: RefreshRequest]"),
                    "Refresh in-flight state must be owner-scoped per display")
        let beginRefreshBody = try functionBody(named: "beginRefresh", in: source, after: "final class ScreenFrameCache")
        try require(beginRefreshBody.contains("priority.rawValue > current.priority.rawValue"),
                    "Higher-priority capture recovery must be able to supersede idle refresh")
        try require(beginRefreshBody.contains("capture cache refresh superseding"),
                    "Refresh priority supersession must be observable in logs")
        let endRefreshBody = try functionBody(named: "endRefresh", in: source, after: "final class ScreenFrameCache")
        try require(endRefreshBody.contains("refreshInFlight[displayID]?.id == refreshID"),
                    "Old refresh tasks must not clear a newer refresh owner")
        try require(requestBody.contains("isCurrentRefresh(for: display.id, refreshID: refreshID)"),
                    "Destructive stream restart must verify it still owns the refresh slot")
        let refreshBody = try functionBody(named: "refreshStreamInBackground", in: source, after: "final class ScreenFrameCache")
        try require(refreshBody.contains("defer {\n                self.endRefresh(for: display.id, refreshID: refreshID)"),
                    "Maintenance refresh must release its owner with guaranteed cleanup")
        let removeBody = try functionBody(named: "removeStream", in: source, after: "final class ScreenFrameCache")
        try require(removeBody.contains("if dropFrame"),
                    "Prepared tasks should be cancelled only when the frame cache is intentionally dropped")
        try require(!removeBody.contains("preparedTask"),
                    "Stream restarts must not manage obsolete prepared snapshot tasks")
    }

    private static func testCompletedSelectionDismissesOverlayWhenFreezePending(captureSource: String) throws {
        let selectionBody = try functionBody(named: "selectionCompleted", in: captureSource, after: "private final class CaptureSession")
        try require(selectionBody.contains("pendingSelection = (globalRect, screen)"),
                    "A selection completed before freeze readiness must be recorded")
        try require(selectionBody.contains("dismissCompletedOverlayAwaitingFrozenFrame()"),
                    "Mouse-up must dismiss the visible overlay instead of leaving the selected rectangle stuck on screen")

        let dismissBody = try functionBody(named: "dismissCompletedOverlayAwaitingFrozenFrame",
                                           in: captureSource,
                                           after: "private final class CaptureSession")
        try require(dismissBody.contains("capture pending selection awaiting frozen frame"),
                    "Pending-freeze selection dismissal must be observable in logs")
        try require(dismissBody.contains("overlay?.dismiss()") && dismissBody.contains("overlay = nil"),
                    "Pending-freeze selection must close the overlay window immediately after mouse-up")
    }

    private static func testScreenFrameCacheStartIsDisplayScoped() throws {
        let source = try String(contentsOfFile: "Sources/ScreenFrameCache.swift", encoding: .utf8)
        try require(!source.contains("startInFlight"),
                    "Stream startup must not use one global in-flight flag that can block unrelated displays")
        try require(source.contains("startingDisplays: Set<CGDirectDisplayID>"),
                    "Stream startup should track in-flight work per display")
        try require(source.contains("startedDisplays: Set<CGDirectDisplayID>"),
                    "Stream readiness must distinguish registered streams from started streams")
        let startBody = try functionBody(named: "start", in: source, after: "final class ScreenFrameCache")
        try require(source.contains("enum StartResult"),
                    "ScreenFrameCache.start must expose a typed startup result")
        try require(source.contains("enum StartUnavailableReason"),
                    "ScreenFrameCache startup failures must use typed unavailable reasons")
        try require(source.contains("func start(displays: [CaptureDisplay], excludingBundleIdentifier bundleID: String?) async -> StartResult"),
                    "ScreenFrameCache.start must return typed availability instead of a bare Bool")
        try require(source.contains("var unavailableReason: String"),
                    "ScreenFrameCache.StartResult must carry the cache-owned unavailable reason")
        try require(!source.contains("case unavailable(String)"),
                    "ScreenFrameCache.StartResult must not store raw string failure reasons")
        try require(source.contains("hasUsableCache(for: displays)"),
                    "ScreenFrameCache.start must distinguish no-op existing cache from unavailable startup")
        try require(!source.contains("func start(displays: [CaptureDisplay], excludingBundleIdentifier bundleID: String?) async -> Bool"),
                    "ScreenFrameCache.start must not collapse cache failures into a bare Bool result")
        try require(source.contains("shareableDisplayFailureCooldown"),
                    "ScreenFrameCache must remember recent empty shareable-display listings")
        try require(source.contains("recentShareableDisplayFailure"),
                    "Shareable-content health state must be explicit")
        try require(source.contains("capture cache shareable content skipped"),
                    "Skipping repeated shareable-content enumeration must be observable in logs")
        try require(startBody.contains("recentShareableDisplayFailure(for: displaysToStart)"),
                    "ScreenFrameCache.start must gate repeated shareable-content enumeration through health state")
        try require(startBody.contains("recordShareableDisplayFailure(.shareableContentHasNoDisplays)"),
                    "Empty display listings must record shareable-content health failure")
        try require(startBody.contains("clearShareableDisplayFailure()"),
                    "Recovered display listings must clear shareable-content health failure")
        try require(source.contains("pendingStartupRegistrationWaitNanoseconds"),
                    "Concurrent startup should have a short registration wait, not the full frozen-frame deadline")
        try require(source.contains("waitForUsableCacheOrFinishedStartup"),
                    "ScreenFrameCache.start must join pending startup only through a bounded helper")
        let usableBody = try functionBody(named: "hasUsableCache", in: source, after: "final class ScreenFrameCache")
        try require(!usableBody.contains("startingDisplays"),
                    "Pending startup must not be reported as usable cache")
        try require(!usableBody.contains("streams[display.id] != nil"),
                    "A registered stream must not be reported as usable before startCapture completes")
        try require(usableBody.contains("startedDisplays.contains(display.id)"),
                    "A started stream may be treated as a usable capture source candidate")
        let pendingBody = try functionBody(named: "waitForUsableCacheOrFinishedStartup", in: source, after: "final class ScreenFrameCache")
        try require(pendingBody.contains("pendingStartupRegistrationWaitNanoseconds"),
                    "Pending startup join must use its short registration deadline")
        try require(pendingBody.contains("capture cache pending startup did not become ready before short wait"),
                    "Timed-out pending startup must be visible in logs")
        try require(source.contains("rectSnapshotFrozenScreen"),
                    "ScreenFrameCache must own rect snapshot recovery instead of pushing screenshot APIs into CaptureController")
        try require(source.contains("captureRectScreenshot"),
                    "Rect snapshot recovery must have a bounded helper")
        try require(source.contains("rectSnapshotTimeoutNanoseconds"),
                    "Rect snapshot recovery must not wait forever")
        try require(!source.contains("rectSnapshotTimeoutNanoseconds: UInt64 = 2_000_000_000"),
                    "Rect snapshot recovery must stay inside a short active-capture budget")
        try require(source.contains("rectSnapshotFailureCooldown"),
                    "Rect snapshot recovery must suppress repeated active-path attempts after failure")
        try require(source.contains("shouldAttemptRectSnapshotRecovery"),
                    "Rect snapshot recovery must have an explicit health gate")
        try require(source.contains("capture cache rect snapshot skipped"),
                    "Skipped rect snapshot recovery must be observable in logs")
        try require(source.contains("rectSnapshotProbeInFlight"),
                    "Background rect snapshot health probes must be owner-scoped")
        try require(source.contains("rectSnapshotProbeJoinNanoseconds"),
                    "Active rect snapshot recovery must join an in-flight health probe only briefly")
        try require(source.contains("scheduleRectSnapshotProbe"),
                    "Empty display listings should schedule a background rect snapshot health probe")
        try require(source.contains("capture cache rect snapshot probe failed"),
                    "Background rect snapshot health probe failures must be observable in logs")
        try require(startBody.contains("scheduleRectSnapshotProbe"),
                    "ScreenFrameCache.start must probe rect snapshot health when shareable displays are unavailable")
        let snapshotBody = try functionBody(named: "rectSnapshotFrozenScreen", in: source, after: "final class ScreenFrameCache")
        try require(snapshotBody.contains("await shouldAttemptRectSnapshotRecovery"),
                    "Active rect snapshot recovery must respect the async health/probe gate")
        let gateBody = try functionBody(named: "shouldAttemptRectSnapshotRecovery", in: source, after: "final class ScreenFrameCache")
        try require(gateBody.contains("rectSnapshotProbeJoinNanoseconds"),
                    "Active rect snapshot recovery must not wait indefinitely for a background probe")
        try require(gateBody.contains("previousFailure=probe-in-flight"),
                    "Skipping duplicate rect snapshot recovery while a probe is in flight must be observable")
        try require(startBody.contains("let displaysToStart = beginStarting(displays)"),
                    "ScreenFrameCache.start must filter startup work through the display-scoped gate")
        try require(startBody.contains("return await waitForUsableCacheOrFinishedStartup(for: displays)"),
                    "ScreenFrameCache.start must not treat an in-flight startup as immediately usable")
        try require(startBody.contains("Self.loadShareableContent()"),
                    "ScreenFrameCache.start must use the retrying shareable-content loader")
        try require(startBody.contains("defer { finishStarting(displaysToStart) }"),
                    "ScreenFrameCache.start must clear display-scoped startup state on every return")
        let beginStartingIndex = try index(of: "let displaysToStart = beginStarting(displays)", in: startBody)
        let finishStartingIndex = try index(of: "defer { finishStarting(displaysToStart) }", in: startBody)
        let healthGateIndex = try index(of: "recentShareableDisplayFailure(for: displaysToStart)", in: startBody)
        let loadContentIndex = try index(of: "Self.loadShareableContent()", in: startBody)
        try require(beginStartingIndex < finishStartingIndex && finishStartingIndex < healthGateIndex && healthGateIndex < loadContentIndex,
                    "Display startup state must be owned before shareable-content health early returns can fire")
        try require(startBody.contains("return startResult(for: displays, unavailableReason: failure.reason)"),
                    "Shareable-content health early return must still report cache-owned availability")
        let contentBody = try functionBody(named: "loadShareableContent", in: source, after: "final class ScreenFrameCache")
        try require(contentBody.contains("onScreenWindowsOnly: false"),
                    "Shareable-content loading should prefer the broad app listing for QuickShot exclusion")
        try require(contentBody.contains("onScreenWindowsOnly: true"),
                    "Shareable-content loading must retry with the on-screen listing when displays are missing")
        try require(contentBody.contains("excludingDesktopWindows(true, onScreenWindowsOnly: true)"),
                    "Shareable-content loading should retry the desktop-excluded listing before giving up")
        try require(contentBody.contains("SCShareableContent.currentProcess"),
                    "Shareable-content loading should try the current-process listing before the final current listing")
        try require(contentBody.contains("SCShareableContent.current"),
                    "Shareable-content loading should fall back to the current listing if filtered listings are empty")
        try require(contentBody.contains("had no displays; retrying on-screen listing"),
                    "Empty ScreenCaptureKit display listings must be observable in logs")
        try require(startBody.contains("let registeredStreams = pendingStreams.filter"),
                    "ScreenFrameCache.start must start only streams that were registered before shutdown")
        try require(startBody.contains("capture cache stream starting"),
                    "ScreenFrameCache.start must log stream startup before awaiting ScreenCaptureKit")
        try require(source.contains("streamStartTimeoutNanoseconds"),
                    "ScreenFrameCache.start must not await ScreenCaptureKit stream startup forever")
        try require(source.contains("StreamStartTimeout"),
                    "ScreenFrameCache.start timeout must be explicit and diagnosable")
        try require(source.contains("startStream(pending.stream, display: pending.display)"),
                    "ScreenFrameCache.start must use the bounded startup helper")
        try require(startBody.contains("registerStream(pending.stream, for: pending.display.id)"),
                    "ScreenFrameCache.start must atomically reject late streams after shutdown")
        try require(startBody.contains("shouldStartRegisteredStream(pending.stream, for: pending.display.id)"),
                    "ScreenFrameCache.start must verify ownership immediately before stream start")
        try require(startBody.contains("shouldKeepStartedStream(pending.stream, for: pending.display.id)"),
                    "ScreenFrameCache.start must stop a stream that started while shutdown won the race")
        try require(startBody.contains("markStreamStarted(pending.stream, for: pending.display.id)"),
                    "ScreenFrameCache.start must mark readiness only after startCapture completes")
        try require(startBody.contains("shutdown after start"),
                    "ScreenFrameCache.start must visibly stop streams that start after shutdown")
        let preparingBody = try functionBody(named: "isPreparingFrame", in: source, after: "final class ScreenFrameCache")
        try require(preparingBody.contains("startingDisplays.contains(display.id)"),
                    "Preparing-frame state must be display-scoped")
        try require(preparingBody.contains("!startedDisplays.contains(display.id)"),
                    "Preparing-frame state must include registered-but-not-started streams")
        let registerBody = try functionBody(named: "registerStream", in: source, after: "final class ScreenFrameCache")
        try require(registerBody.contains("startedDisplays.remove(displayID)"),
                    "Registering a replacement stream must clear stale started-state")
        let markStartedBody = try functionBody(named: "markStreamStarted", in: source, after: "final class ScreenFrameCache")
        try require(markStartedBody.contains("streams[displayID]?.id == stream.id")
                    && markStartedBody.contains("startedDisplays.insert(displayID)"),
                    "Started-state must be ownership checked before insertion")
        let removeBody = try functionBody(named: "removeStream", in: source, after: "final class ScreenFrameCache")
        try require(removeBody.contains("startedDisplays.remove(displayID)"),
                    "Removing a stream must clear started-state")
    }

    private static func testOverlayActivationIsDeferred(_ source: String) throws {
        let body = try functionBody(named: "begin", in: source, after: "final class OverlayController")
        let beforeOverlayBegin = try prefix(before: "overlay begin", in: body)
        try require(!beforeOverlayBegin.contains("NSApp.activate"),
                    "Overlay must not activate the app before it reports overlay begin")
        try require(!beforeOverlayBegin.contains("makeKeyAndOrderFront"),
                    "Overlay must not make a key window before it reports overlay begin")
        let afterOverlayBegin = String(body[try index(of: "overlay begin", in: body)...])
        try require(afterOverlayBegin.contains("DispatchQueue.main.async"),
                    "Overlay app activation should be deferred to the next main-loop turn")
        try require(afterOverlayBegin.contains("NSApp.activate"),
                    "Overlay still needs deferred activation for key events")
    }

    private static func testOverlayDismissClosesFullscreenWindows(_ source: String) throws {
        let body = try functionBody(named: "dismiss", in: source, after: "final class OverlayController")
        try require(source.contains("deinit {\n        dismiss()\n    }"),
                    "OverlayController deinit must dismiss any surviving fullscreen overlay windows")
        try require(source.contains("w.isReleasedWhenClosed = false"),
                    "Overlay windows must stay ARC-owned so explicit close is deterministic")
        try require(body.contains("guard !isDismissed else { return }"),
                    "Overlay dismiss must be idempotent")
        try require(body.contains("w.orderOut(nil)") && body.contains("w.close()"),
                    "Overlay dismiss must close fullscreen windows, not only order them out")
        try require(body.contains("w.contentView = nil"),
                    "Overlay dismiss should detach fullscreen backdrop contents before closing")
    }

    private static func testQuickShotWindowsAreExcludedFromScreenCapture(protectionSource: String,
                                                                         overlaySource: String) throws {
        try require(protectionSource.contains("window.sharingType = .none"),
                    "QuickShot windows must opt out of WindowServer capture before rect snapshot recovery is allowed")
        try require(overlaySource.contains("WindowCaptureProtection.excludeFromScreenCapture(w)"),
                    "Overlay windows must be excluded from screen capture")
        for file in ["Sources/ThumbnailManager.swift", "Sources/PinnedWindow.swift", "Sources/SettingsWindow.swift"] {
            let source = try String(contentsOfFile: file, encoding: .utf8)
            try require(source.contains("WindowCaptureProtection.excludeFromScreenCapture"),
                        "\(file) must exclude its windows from screen capture")
        }
    }

    private static func testCompletedCaptureIsObservable(captureSource: String) throws {
        let completeBody = try functionBody(named: "completeSelection", in: captureSource, after: "private final class CaptureSession")
        let dismissIndex = try index(of: "overlay?.dismiss()", in: completeBody)
        let endIndex = try index(of: "end()", in: completeBody)
        let cropScheduleIndex = try index(of: "scheduleCropAndDelivery", in: completeBody)
        try require(dismissIndex < endIndex && endIndex < cropScheduleIndex,
                    "Completed capture must dismiss overlay and end the session before scheduling crop/handoff")
        try require(!completeBody.contains("onImage(cropped, screen)"),
                    "Completed capture must not deliver image synchronously in mouse-up")
        try require(!completeBody.contains(".crop(globalSelection:"),
                    "Completed capture must not crop synchronously in the mouse-up handler")

        let cropBody = try functionBody(named: "scheduleCropAndDelivery", in: captureSource, after: "private final class CaptureSession")
        try require(cropBody.contains("DispatchQueue.global(qos: .userInitiated).async"),
                    "Completed capture crop must leave the main actor before doing CGImage cropping")
        try require(cropBody.contains("shot.crop(globalSelection: selection)"),
                    "Completed capture must still crop the immutable frozen frame")
        try require(cropBody.contains("DispatchQueue.main.async"),
                    "Completed capture must return to the main thread only for logging and delivery")
        try require(cropBody.contains("capture crop complete"),
                    "Completed crop must remain observable in logs")
        try require(cropBody.contains("capture crop failed"),
                    "Asynchronous crop failures must remain observable in logs")
        try require(cropBody.contains("capture delivery outcome=crop-failed"),
                    "Asynchronous crop failures must have an explicit delivery outcome")
        try require(cropBody.contains("deliveryDisplayID"),
                    "Completed capture must carry only a display id across the background crop boundary")
        try require(cropBody.contains("capture image handoff failed missing screen"),
                    "Completed capture must log if the target screen disappears before delivery")
        try require(cropBody.contains("capture delivery outcome=handoff-failed"),
                    "Screen handoff failures must have an explicit delivery outcome")
        try require(cropBody.contains("deliver(cropped, deliveryScreen)"),
                    "Completed capture must deliver the cropped image after background crop")

        let deliveryBody = try functionBody(named: "deliverCapturedImage", in: captureSource, after: "final class CaptureController")
        try require(deliveryBody.contains("capture thumbnail added"),
                    "Completed capture must log thumbnail delivery")
        try require(deliveryBody.contains("Clipboard.prepareImage(cgImage: image)"),
                    "Completed capture must use the centralized async clipboard payload preparation API")
        try require(deliveryBody.contains("Clipboard.copy(preparedImage: prepared)"),
                    "Completed capture must publish the prepared clipboard payload")
        try require(deliveryBody.contains("capture delivery outcome=completed"),
                    "Completed image delivery must have an explicit delivery outcome")
        let copyIndex = try index(of: "Clipboard.copy(preparedImage: prepared)", in: deliveryBody)
        let logIndex = try index(of: "capture clipboard copied", in: deliveryBody)
        try require(copyIndex < logIndex,
                    "Completed capture must log after the prepared image is copied to the clipboard")
        let deliveryOutcomeIndex = try index(of: "capture delivery outcome=completed", in: deliveryBody)
        try require(logIndex < deliveryOutcomeIndex,
                    "Delivery completion must be logged only after clipboard publication")
    }

    private static func testClipboardPayloadPreparationIsCentralized(clipboardSource: String,
                                                                     thumbnailManagerSource: String,
                                                                     thumbnailWindowSource: String,
                                                                     pinnedWindowSource: String) throws {
        try require(clipboardSource.contains("import ImageIO"),
                    "Clipboard payload encoding should use ImageIO instead of AppKit image reps")
        try require(clipboardSource.contains("struct PreparedImage"),
                    "Clipboard must expose a prepared payload type")
        try require(clipboardSource.contains("prepareImages(cgImages: [CGImage])"),
                    "Clipboard must batch-prepare multi-image payloads off the UI path")
        try require(clipboardSource.contains("DispatchQueue.global(qos: qos).async"),
                    "Clipboard must own the off-main payload preparation queue")
        try require(clipboardSource.contains("pasteboardItem(preparedImage"),
                    "Drag-out and multi-copy must share the same prepared pasteboard item builder")
        try require(!clipboardSource.contains("copy(cgImage:"),
                    "Clipboard must not expose a synchronous copy(cgImage:) convenience API")
        try require(!clipboardSource.contains("copyAll(cgImages:"),
                    "Clipboard must not expose a synchronous copyAll(cgImages:) convenience API")

        for (name, source) in [
            ("ThumbnailManager", thumbnailManagerSource),
            ("ThumbnailWindow", thumbnailWindowSource),
            ("PinnedWindow", pinnedWindowSource)
        ] {
            try require(!source.contains("NSBitmapImageRep(cgImage:"),
                        "\(name) must not encode PNG data directly in production copy/drag paths")
            try require(!source.contains("tiffRepresentation"),
                        "\(name) must not build TIFF data directly in production copy/drag paths")
            try require(!source.contains("Clipboard.copy(cgImage:"),
                        "\(name) must use prepared clipboard payloads, not synchronous image copy")
        }

        let copyBody = try functionBody(named: "copy", in: thumbnailManagerSource, after: "final class ThumbnailManager")
        try require(copyBody.contains("cachedClipboardPayload()"),
                    "Thumbnail copy should use the precomputed payload when available")
        try require(copyBody.contains("Clipboard.prepareImage(cgImage: image)"),
                    "Thumbnail copy fallback must use the centralized async preparation API")
        try require(copyBody.contains("Clipboard.copy(preparedImage: prepared)"),
                    "Thumbnail copy must publish the prepared payload")

        let copyAllBody = try functionBody(named: "copyAll", in: thumbnailManagerSource, after: "final class ThumbnailManager")
        try require(copyAllBody.contains("Clipboard.prepareImages(cgImages: images)"),
                    "Copy-all must use the centralized batch preparation API")
        try require(copyAllBody.contains("Clipboard.copy(preparedImages: prepared)"),
                    "Copy-all must publish prepared payloads")

        let dragBody = try functionBody(named: "beginDragOut", in: thumbnailWindowSource, after: "private final class ThumbnailView")
        try require(dragBody.contains("Clipboard.pasteboardItem(preparedImage: prepared)"),
                    "Drag-out must use the centralized pasteboard item builder")
        try require(thumbnailWindowSource.contains("prepareClipboardPayload()"),
                    "Thumbnail cards should precompute clipboard/drag payloads in the background")
        try require(pinnedWindowSource.contains("prepareClipboardPayload()"),
                    "Pinned windows should precompute copy payloads in the background")
    }

    private static func testCaptureEndOutcomeIsExplicit(captureSource: String) throws {
        try require(captureSource.contains("private var endOutcome = \"unknown\""),
                    "CaptureSession must track an explicit end outcome")
        let completeBody = try functionBody(named: "completeSelection", in: captureSource, after: "private final class CaptureSession")
        try require(completeBody.contains("endOutcome = \"completed\""),
                    "Completed selections must mark the session outcome before image handoff")
        try require(completeBody.contains("endOutcome = \"ignored-small-selection\""),
                    "Small ignored selections must not look like completed captures in logs")
        let cancelBody = try functionBody(named: "cancel", in: captureSource, after: "private final class CaptureSession")
        try require(cancelBody.contains("endOutcome = \"cancelled\""),
                    "Cancelled sessions must have an explicit outcome")
        let failedBody = try functionBody(named: "freezeFailed", in: captureSource, after: "private final class CaptureSession")
        try require(failedBody.contains("endOutcome = \"failed\""),
                    "Failed sessions must have an explicit outcome")
        let endBody = try functionBody(named: "end", in: captureSource, after: "private final class CaptureSession")
        try require(endBody.contains("capture end outcome="),
                    "Capture end logs must include the explicit outcome")
    }

    private static func testCaptureStackUnavailableIsTypedAndNonmodal(captureSource: String) throws {
        let errorSource = try String(contentsOfFile: "Sources/CaptureTypes.swift", encoding: .utf8)
        try require(errorSource.contains("case captureStackUnavailable(String)"),
                    "CaptureError must distinguish system capture-stack failure from no display")
        try require(errorSource.contains("captureStackUnavailable"),
                    "CaptureError description must make capture-stack failures searchable")

        let freezeBody = try functionBody(named: "startFreezeTask", in: captureSource, after: "private final class CaptureSession")
        try require(freezeBody.contains("CaptureError.captureStackUnavailable"),
                    "Unavailable ScreenCaptureKit displays plus failed rect snapshot must not be reported as noDisplay")
        try require(freezeBody.contains("cacheStart.unavailableReason"),
                    "Capture-stack failure reason must come from ScreenFrameCache.StartResult")
        try require(freezeBody.contains("rect snapshot failed"),
                    "Capture-stack failure should include the recovery failure boundary")
        try require(freezeBody.contains("fresh stream frame unavailable before timeout"),
                    "Active stream wait timeout must be reported as a capture-stack failure")
        try require(!freezeBody.contains("freezeFailed(CaptureError.cacheUnavailable)"),
                    "CaptureSession must not expose generic cacheUnavailable as a user-facing failure")

        let handleBody = try functionBody(named: "handleCaptureError", in: captureSource, after: "final class CaptureController")
        try require(handleBody.contains("CaptureError.captureStackUnavailable"),
                    "CaptureController must handle capture-stack failure explicitly")
        try require(handleBody.contains("presentCaptureStackFailureNotice"),
                    "Capture-stack failure must produce a nonmodal notice")

        let noticeBody = try functionBody(named: "presentCaptureStackFailureNotice", in: captureSource, after: "final class CaptureController")
        try require(noticeBody.contains("didNotifyCaptureStackFailure"),
                    "Capture-stack failure notice must be one-shot to avoid notification spam")
        try require(noticeBody.contains("NSApp.requestUserAttention(.informationalRequest)"),
                    "Capture-stack failure should use a nonmodal user-attention request")
        try require(!noticeBody.contains("NSAlert"),
                    "Capture-stack failure must not block the user with a modal alert")
    }

    private static func testHotKeyEventSeedsCaptureTiming(appDelegateSource: String,
                                                          hotKeySource: String,
                                                          captureSource: String) throws {
        try require(captureSource.contains("func triggerCapture(startedAt triggerStartedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent())"),
                    "Capture timing must be seeded at the earliest request event")
        try require(appDelegateSource.contains("GlobalHotKey.shared.register { [weak self] startedAt in"),
                    "AppDelegate must receive the hotkey event timestamp")
        try require(appDelegateSource.contains("capture.triggerCapture(startedAt: startedAt)"),
                    "AppDelegate must pass the hotkey event timestamp into capture")
        try require(hotKeySource.contains("let receivedAt = CFAbsoluteTimeGetCurrent()"),
                    "GlobalHotKey must timestamp the Carbon event immediately")
        try require(hotKeySource.contains("hotkey event received"),
                    "GlobalHotKey must log the earliest observed hotkey event")
        try require(hotKeySource.contains("if Thread.isMainThread"),
                    "GlobalHotKey should not add an avoidable main-queue turn when already on main")
        try require(hotKeySource.contains("onTrigger?(receivedAt)"),
                    "GlobalHotKey must invoke the handler with the original event timestamp")
    }

    private static func testCaptureShutdownIsExplicit(appDelegateSource: String,
                                                      captureSource: String) throws {
        let cacheSource = try String(contentsOfFile: "Sources/ScreenFrameCache.swift", encoding: .utf8)
        let terminationBody = try functionBody(named: "applicationWillTerminate", in: appDelegateSource, after: "final class AppDelegate")
        try require(terminationBody.contains("capture.shutdown()"),
                    "App termination must explicitly shut down active capture UI and cache work")

        let controllerShutdown = try functionBody(named: "shutdown", in: captureSource, after: "final class CaptureController")
        try require(captureSource.contains("private var prewarmTask: Task<Void, Never>?"),
                    "CaptureController must own startup prewarm work")
        try require(captureSource.contains("private var prewarmID = UUID()"),
                    "CaptureController must invalidate stale startup prewarm completions")
        let prewarmBody = try functionBody(named: "prewarmCapturePipeline", in: captureSource, after: "final class CaptureController")
        try require(prewarmBody.contains("prewarmTask?.cancel()"),
                    "Starting a new prewarm must cancel the previous prewarm task")
        try require(prewarmBody.contains("prewarmTask = Task.detached"),
                    "Prewarm work should stay off the main actor but remain owned by CaptureController")
        try require(prewarmBody.contains("self.prewarmID == prewarmID"),
                    "Stale prewarm completions must not update permission state")
        try require(controllerShutdown.contains("session?.shutdown()"),
                    "CaptureController.shutdown must dismiss any active capture session")
        try require(controllerShutdown.contains("prewarmTask?.cancel()") && controllerShutdown.contains("prewarmTask = nil"),
                    "CaptureController.shutdown must cancel owned startup prewarm work")
        try require(controllerShutdown.contains("frameCache.shutdown()"),
                    "CaptureController.shutdown must stop ScreenFrameCache work")

        let sessionShutdown = try functionBody(named: "shutdown", in: captureSource, after: "private final class CaptureSession")
        try require(sessionShutdown.contains("endOutcome = \"shutdown\""),
                    "CaptureSession.shutdown must make shutdown visible in capture end logs")
        try require(sessionShutdown.contains("overlay?.dismiss()"),
                    "CaptureSession.shutdown must dismiss active fullscreen overlay windows")
        try require(sessionShutdown.contains("end(prepareNext: false)"),
                    "CaptureSession.shutdown must not schedule post-capture prewarm")

        let endBody = try functionBody(named: "end", in: captureSource, after: "private final class CaptureSession")
        try require(endBody.contains("if prepareNext, let displayToPrepare"),
                    "CaptureSession.end must allow shutdown to skip next-capture preparation")

        let cacheShutdown = try functionBody(named: "shutdown", in: cacheSource, after: "final class ScreenFrameCache")
        for token in ["isShuttingDown = true",
                      "streams.removeAll()",
                      "refreshInFlight.removeAll()",
                      "startingDisplays.removeAll()",
                      "startedDisplays.removeAll()",
                      "recentShareableDisplayFailure = nil",
                      "recentRectSnapshotFailure = nil",
                      "rectSnapshotProbeInFlight = false",
                      "stream.stop(reason: \"shutdown\")"] {
            try require(cacheShutdown.contains(token),
                        "ScreenFrameCache.shutdown must include \(token)")
        }
        try require(cacheSource.contains("private var isShuttingDown = false"),
                    "ScreenFrameCache must have a terminal shutdown gate")
        try require(cacheSource.contains("guard !isShutdown else { return }"),
                    "ScreenFrameCache async entry points must ignore late work after shutdown")
        try require(cacheSource.contains("private func registerStream"),
                    "ScreenFrameCache must register streams through a shutdown-aware helper")
        try require(cacheSource.contains("private func shouldStartRegisteredStream"),
                    "ScreenFrameCache must verify stream ownership before starting")
        try require(cacheSource.contains("private func shouldKeepStartedStream"),
                    "ScreenFrameCache must verify stream ownership after start completes")
    }

    private static func functionBody(named name: String, in source: String, after marker: String) throws -> String {
        guard let markerRange = source.range(of: marker) else {
            throw Failure("Missing marker \(marker)")
        }
        let scoped = source[markerRange.upperBound...]
        guard let funcRange = scoped.range(of: "func \(name)(") else {
            throw Failure("Missing function \(name)")
        }
        guard let openBrace = scoped[funcRange.lowerBound...].firstIndex(of: "{") else {
            throw Failure("Missing function body for \(name)")
        }

        var depth = 0
        var end = openBrace
        var current = openBrace
        while current < scoped.endIndex {
            let character = scoped[current]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    end = current
                    break
                }
            }
            current = scoped.index(after: current)
        }

        guard depth == 0 else { throw Failure("Unclosed function body for \(name)") }
        return String(scoped[openBrace...end])
    }

    private static func prefix(before token: String, in source: String) throws -> String {
        guard let range = source.range(of: token) else { throw Failure("Missing token \(token)") }
        return String(source[..<range.lowerBound])
    }

    private static func index(of token: String, in source: String) throws -> String.Index {
        guard let range = source.range(of: token) else { throw Failure("Missing token \(token)") }
        return range.lowerBound
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
