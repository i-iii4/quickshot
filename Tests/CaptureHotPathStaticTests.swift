import Foundation

@main
struct CaptureHotPathStaticTests {
    static func main() {
        do {
            let captureSource = try String(contentsOfFile: "Sources/CaptureController.swift", encoding: .utf8)
            let freezeSource = try String(contentsOfFile: "Sources/ScreenFreezePipeline.swift", encoding: .utf8)
            let overlaySource = try String(contentsOfFile: "Sources/Overlay.swift", encoding: .utf8)
            let appDelegateSource = try String(contentsOfFile: "Sources/AppDelegate.swift", encoding: .utf8)
            let hotKeySource = try String(contentsOfFile: "Sources/GlobalHotKey.swift", encoding: .utf8)
            let protectionSource = try String(contentsOfFile: "Sources/WindowCaptureProtection.swift", encoding: .utf8)
            let clipboardSource = try String(contentsOfFile: "Sources/Clipboard.swift", encoding: .utf8)
            let thumbnailManagerSource = try String(contentsOfFile: "Sources/ThumbnailManager.swift", encoding: .utf8)
            let thumbnailWindowSource = try String(contentsOfFile: "Sources/ThumbnailWindow.swift", encoding: .utf8)
            let pinnedWindowSource = try String(contentsOfFile: "Sources/PinnedWindow.swift", encoding: .utf8)

            try testOldUnsafeCacheIsRemoved(captureSource: captureSource)
            try testFreshStreamFreezePrecedesOverlay(captureSource)
            try testStreamBackedFreezer(freezeSource)
            try testOverlayKeepsQuickShotSelectionContract(overlaySource: overlaySource,
                                                           protectionSource: protectionSource)
            try testCompletedCaptureIsObservable(captureSource: captureSource)
            try testClipboardPayloadPreparationIsCentralized(clipboardSource: clipboardSource,
                                                             thumbnailManagerSource: thumbnailManagerSource,
                                                             thumbnailWindowSource: thumbnailWindowSource,
                                                             pinnedWindowSource: pinnedWindowSource)
            try testHotKeyEventSeedsCaptureTiming(appDelegateSource: appDelegateSource,
                                                  hotKeySource: hotKeySource,
                                                  captureSource: captureSource)
            try testCaptureShutdownIsExplicit(appDelegateSource: appDelegateSource,
                                               captureSource: captureSource,
                                               freezeSource: freezeSource)
            print("CaptureHotPathStaticTests: passed")
        } catch {
            fputs("CaptureHotPathStaticTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testOldUnsafeCacheIsRemoved(captureSource: String) throws {
        try require(!FileManager.default.fileExists(atPath: "Sources/ScreenFrameCache.swift"),
                    "Old ScreenFrameCache.swift must not coexist with the stream-backed freezer")
        try require(captureSource.contains("private let freezer = ScreenFreezePipeline()"),
                    "CaptureController must own the fresh frame freezer")
        try require(!captureSource.contains("ScreenFrameCache"),
                    "CaptureController must not depend on stale stream-cache architecture")
        try require(!captureSource.contains("waitForFrozenScreen"),
                    "CaptureSession must not wait for cached frames")
        try require(!captureSource.contains("rectSnapshotFrozenScreen"),
                    "Capture must not keep the old cache-owned rect snapshot bridge")
    }

    private static func testFreshStreamFreezePrecedesOverlay(_ source: String) throws {
        let startBody = try functionBody(named: "start", in: source, after: "private final class CaptureSession")
        try require(startBody.contains("HiddenAppWindows.hideVisibleApplicationWindows()"),
                    "QuickShot windows must be hidden before accepting a fresh frame")
        try require(startBody.contains("let hiddenAt = CFAbsoluteTimeGetCurrent()"),
                    "CaptureSession.start must mark the post-hide freshness boundary")
        try require(startBody.contains("startFreezeTask(displays: displays, readyAfter: hiddenAt)"),
                    "CaptureSession.start must explicitly begin the freeze task")
        try require(!startBody.contains("beginOverlay("),
                    "Capture must not show selection UI before frozen screenshots are ready")
        guard let hideRange = startBody.range(of: "HiddenAppWindows.hideVisibleApplicationWindows()"),
              let hiddenAtRange = startBody.range(of: "let hiddenAt = CFAbsoluteTimeGetCurrent()"),
              let freezeRange = startBody.range(of: "startFreezeTask(displays: displays, readyAfter: hiddenAt)") else {
            throw Failure("CaptureSession.start is missing stream fresh-frame ordering anchors")
        }
        try require(hideRange.lowerBound < freezeRange.lowerBound,
                    "CaptureSession.start must hide QuickShot windows before fresh frame work")
        try require(hiddenAtRange.lowerBound < freezeRange.lowerBound,
                    "CaptureSession.start must pass the post-hide boundary into the freezer")

        let freezeTaskBody = try functionBody(named: "startFreezeTask", in: source, after: "private final class CaptureSession")
        try require(freezeTaskBody.contains("requestedAt: startedAt"),
                    "Freezer must receive the original trigger timestamp")
        try require(freezeTaskBody.contains("readyAfter: readyAfter"),
                    "Freezer must receive the post-hide freshness boundary")

        let freezeCompletedBody = try functionBody(named: "freezeCompleted", in: source, after: "private final class CaptureSession")
        try require(freezeCompletedBody.contains("capture frozen ready"),
                    "Frozen readiness must stay observable")
        try require(freezeCompletedBody.contains("beginOverlay(backdrops:"),
                    "Selection UI must be constructed only after frozen screenshots are available")

        let beginOverlayBody = try functionBody(named: "beginOverlay", in: source, after: "private final class CaptureSession")
        try require(beginOverlayBody.contains("beginFrozenSelection"),
                    "Overlay must receive ready frozen backdrops at construction")
        try require(!beginOverlayBody.contains("beginLiveSelection"),
                    "CaptureController must not use the hybrid live overlay path")
        try require(beginOverlayBody.contains("capture overlay ready"),
                    "Overlay readiness must stay logged")
        try require(beginOverlayBody.contains("preOverlayMouseTracker?.mouseDownSeedPoint()"),
                    "Fast hotkey+drag should seed the selection from pre-overlay mouse state")
    }

    private static func testStreamBackedFreezer(_ source: String) throws {
        try require(source.contains("actor ScreenFreezePipeline"),
                    "Fresh freeze work should live in an isolated pipeline")
        try require(source.contains("func prewarm() async"),
                    "Pipeline must keep startup prewarm")
        try require(source.contains("func captureFrozenScreens(displays requestedDisplays: [CaptureDisplay],"),
                    "Pipeline must expose full-display fresh freeze capture")
        try require(source.contains("requestedAt: CFAbsoluteTime") && source.contains("readyAfter: CFAbsoluteTime"),
                    "Freeze API must carry trigger and post-hide boundaries")
        try require(source.contains("SCStream("),
                    "Pipeline must keep short-lived warm streams for fast captures")
        try require(source.contains("SCStreamOutput"),
                    "Pipeline must receive stream frames through SCStreamOutput")
        try require(source.contains("SCFrameStatus(rawValue: statusRawValue)") && source.contains("status == .complete"),
                    "Pipeline must capture complete stream frames")
        try require(source.contains("status == .idle") && source.contains("recordIdleFrame"),
                    "Pipeline must treat ScreenCaptureKit idle frames as post-hide freshness heartbeats")
        try require(source.contains("CMSampleBufferGetImageBuffer"),
                    "Pipeline must store stream pixel buffers instead of old prepared screenshots")
        try require(source.contains("frame.receivedAt >= acceptedAfter"),
                    "Pipeline must prefer post-trigger/post-hide complete stream frames")
        try require(source.contains("idleAt >= acceptedAfter"),
                    "Pipeline must accept a post-hide idle heartbeat when the display has not changed")
        try require(source.contains("latestIdleHeartbeats"),
                    "Pipeline must keep idle freshness separate from complete pixel buffers")
        try require(source.contains("latestActiveStreamFrame(display:")
                    && source.contains("guard isWarm(display: display), let frame = latestFrames[display.id]")
                    && source.contains("freshness: .latestActiveStream")
                    && source.contains("reason=missing-post-hide-heartbeat"),
                    "Pipeline must have an observable active-stream fallback for static displays that do not emit idle quickly")
        try require(source.contains("freshFrameDeadlineNanoseconds"),
                    "Stream path must have a short deadline")
        try require(source.contains("SCShareableContent.current"),
                    "Background stream refresh should use SCShareableContent.current")
        let captureBody = try functionBody(named: "captureFrozenScreens", in: source, after: "actor ScreenFreezePipeline")
        try require(!captureBody.contains("SCShareableContent.current"),
                    "Hot capture path must not enumerate shareable content")
        try require(!captureBody.contains("SCScreenshotManager.captureImage"),
                    "Hot capture path must not call one-shot screenshots")
        try require(!source.contains("SCScreenshotManager.captureImage"),
                    "No-half-measures stream freezer must not keep one-shot fallback")
        try require(source.contains("config.showsCursor = false"),
                    "Frozen frames must not bake the system cursor")
        try require(source.contains("capture freeze screens ready"),
                    "Freeze timing must be observable")
        try require(source.contains("capture freeze screens ready source=stream"),
                    "Fast stream completion must be observable")
        try require(!source.contains("capture freeze screens ready source=one-shot"),
                    "One-shot fallback completion token must not remain")
        try require(!source.contains("idleStopTask") && !source.contains("streamIdleStopNanoseconds"),
                    "Persistent stream mode must not keep the old idle-stop implementation")
        for forbidden in ["CachedFrame", "validatedAt", "preparedFrozenScreens", "CaptureImageRace"] {
            try require(!source.contains(forbidden), "Fresh freezer must not keep old unsafe cache token \(forbidden)")
        }
    }

    private static func testOverlayKeepsQuickShotSelectionContract(overlaySource: String,
                                                                   protectionSource: String) throws {
        try require(overlaySource.contains("func beginFrozenSelection"),
                    "Overlay must expose a frozen-start path")
        try require(!overlaySource.contains("func beginLiveSelection"),
                    "Overlay must not keep the hybrid live-start entry point")
        try require(!overlaySource.contains("func installFrozenBackdrops"),
                    "Frozen backdrops must be present when the overlay is constructed")
        try require(overlaySource.contains("WindowCaptureProtection.excludeFromScreenCapture(w)"),
                    "Overlay windows must opt out of screen capture")
        try require(protectionSource.contains("window.sharingType = .none"),
                    "Window capture protection must use NSWindow.sharingType = .none")
        try require(overlaySource.contains("CGDisplayHideCursor"),
                    "Selection mode must suppress the system cursor")
        try require(overlaySource.contains("makeCrosshair"),
                    "Selection mode must keep QuickShot's custom vector crosshair")
        try require(overlaySource.contains("frameStartOffset"),
                    "Selection frame must keep the cursor/frame separator geometry")
        try require(overlaySource.contains("w.collectionBehavior = [.fullScreenAuxiliary, .stationary]"),
                    "Selection overlay must stay scoped to the current Space")
        try require(!overlaySource.contains(".canJoinAllSpaces"),
                    "Selection overlay must not follow the user across Spaces with stale pixels")
    }

    private static func testCompletedCaptureIsObservable(captureSource: String) throws {
        let cropBody = try functionBody(named: "scheduleCropAndDelivery", in: captureSource, after: "private final class CaptureSession")
        try require(cropBody.contains("DispatchQueue.global(qos: .userInitiated).async"),
                    "Completed capture crop must leave the main actor before doing CGImage cropping")
        try require(cropBody.contains("shot.crop(globalSelection: selection)"),
                    "Completed capture must crop the immutable frozen frame")
        try require(cropBody.contains("DispatchQueue.main.async"),
                    "Completed capture must return to the main thread only for logging and delivery")
        for token in ["capture crop complete",
                      "capture crop failed",
                      "capture delivery outcome=crop-failed",
                      "capture image handoff failed missing screen",
                      "capture delivery outcome=handoff-failed"] {
            try require(cropBody.contains(token), "Completed capture must keep log token \(token)")
        }

        let deliveryBody = try functionBody(named: "deliverCapturedImage", in: captureSource, after: "final class CaptureController")
        try require(deliveryBody.contains("capture thumbnail added"),
                    "Completed capture must log thumbnail delivery")
        try require(deliveryBody.contains("Clipboard.prepareImage(cgImage: image)"),
                    "Completed capture must use centralized async clipboard preparation")
        try require(deliveryBody.contains("Clipboard.copy(preparedImage: prepared)"),
                    "Completed capture must publish the prepared clipboard payload")
        try require(deliveryBody.contains("capture delivery outcome=completed"),
                    "Completed image delivery must have an explicit outcome")
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
        try require(hotKeySource.contains("onTrigger?(receivedAt)"),
                    "GlobalHotKey must invoke the handler with the original event timestamp")
    }

    private static func testCaptureShutdownIsExplicit(appDelegateSource: String,
                                                      captureSource: String,
                                                      freezeSource: String) throws {
        let terminationBody = try functionBody(named: "applicationWillTerminate", in: appDelegateSource, after: "final class AppDelegate")
        try require(terminationBody.contains("capture.shutdown()"),
                    "App termination must explicitly shut down active capture UI and freeze work")

        let controllerShutdown = try functionBody(named: "shutdown", in: captureSource, after: "final class CaptureController")
        try require(controllerShutdown.contains("session?.shutdown()"),
                    "CaptureController.shutdown must dismiss any active capture session")
        try require(controllerShutdown.contains("prewarmTask?.cancel()") && controllerShutdown.contains("prewarmTask = nil"),
                    "CaptureController.shutdown must cancel owned startup prewarm work")
        try require(controllerShutdown.contains("freezer.shutdown()"),
                    "CaptureController.shutdown must stop ScreenFreezePipeline work")

        let sessionShutdown = try functionBody(named: "shutdown", in: captureSource, after: "private final class CaptureSession")
        try require(sessionShutdown.contains("endOutcome = \"shutdown\""),
                    "CaptureSession.shutdown must make shutdown visible in logs")
        try require(sessionShutdown.contains("overlay?.dismiss()"),
                    "CaptureSession.shutdown must dismiss active fullscreen overlay windows")

        let freezerShutdown = try functionBody(named: "shutdown", in: freezeSource, after: "actor ScreenFreezePipeline")
        try require(freezerShutdown.contains("isShuttingDown = true"),
                    "ScreenFreezePipeline must reject late async work after shutdown")
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
                    end = scoped.index(after: current)
                    break
                }
            }
            current = scoped.index(after: current)
        }
        return String(scoped[openBrace..<end])
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
