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

            try testOldStreamCacheIsRemoved(captureSource: captureSource)
            try testMioStyleFreezePrecedesOverlay(captureSource)
            try testFreshSnapshotFreezer(freezeSource)
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

    private static func testOldStreamCacheIsRemoved(captureSource: String) throws {
        try require(!FileManager.default.fileExists(atPath: "Sources/ScreenFrameCache.swift"),
                    "Old ScreenFrameCache.swift must not coexist with the Mio-style freezer")
        try require(captureSource.contains("private let freezer = ScreenFreezePipeline()"),
                    "CaptureController must own the fresh snapshot freezer")
        try require(!captureSource.contains("ScreenFrameCache"),
                    "CaptureController must not depend on stale stream-cache architecture")
        try require(!captureSource.contains("waitForFrozenScreen"),
                    "CaptureSession must not wait for cached frames")
        try require(!captureSource.contains("rectSnapshotFrozenScreen"),
                    "Mio-style capture must not keep the cache-owned rect snapshot bridge")
        try require(!captureSource.contains("source=post-request"),
                    "Post-request source labels belonged to the old cache acceptance model")
    }

    private static func testMioStyleFreezePrecedesOverlay(_ source: String) throws {
        let startBody = try functionBody(named: "start", in: source, after: "private final class CaptureSession")
        try require(startBody.contains("HiddenAppWindows.hideVisibleApplicationWindows()"),
                    "QuickShot windows must be hidden before fresh ScreenCaptureKit freeze")
        try require(startBody.contains("startFreezeTask(displays: displays)"),
                    "CaptureSession.start must explicitly begin the freeze task")
        try require(!startBody.contains("beginOverlay("),
                    "Mio-style flow must not show overlay before fresh frozen pixels exist")

        let freezeCompletedBody = try functionBody(named: "freezeCompleted", in: source, after: "private final class CaptureSession")
        try require(freezeCompletedBody.contains("capture frozen ready"),
                    "Frozen readiness must stay observable")
        try require(freezeCompletedBody.contains("beginOverlay(backdrops:"),
                    "Overlay must be shown only after fresh frozen screenshots are available")

        let beginOverlayBody = try functionBody(named: "beginOverlay", in: source, after: "private final class CaptureSession")
        try require(beginOverlayBody.contains("beginFrozenSelection"),
                    "Overlay must receive ready frozen backdrops at construction")
        try require(beginOverlayBody.contains("capture overlay ready"),
                    "Overlay readiness must stay logged")
        try require(beginOverlayBody.contains("preOverlayMouseTracker?.mouseDownSeedPoint()"),
                    "Fast hotkey+drag should seed the selection from pre-overlay mouse state")
    }

    private static func testFreshSnapshotFreezer(_ source: String) throws {
        try require(source.contains("actor ScreenFreezePipeline"),
                    "Fresh freeze work should live in an isolated pipeline")
        try require(source.contains("func prewarm() async"),
                    "Pipeline must keep Mio's ScreenCaptureKit prewarm")
        try require(source.contains("func captureFrozenScreens(displays requestedDisplays: [CaptureDisplay]) async throws -> [FrozenScreen]"),
                    "Pipeline must expose full-display fresh freeze capture")
        try require(source.contains("SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)"),
                    "Pipeline should use a tight shareable-content listing before fallback")
        try require(source.contains("SCScreenshotManager.captureImage"),
                    "Mio-style fresh freeze must use ScreenCaptureKit screenshot capture")
        try require(source.contains("config.showsCursor = false"),
                    "Frozen screenshots must not bake the system cursor")
        try require(source.contains("captureBatchSize = 3"),
                    "Display capture concurrency must stay capped like Mio")
        try require(source.contains("prewarmPixelSize = 2"),
                    "Prewarm must remain a tiny dummy screenshot")
        try require(source.contains("capture freeze screens ready"),
                    "Freeze timing must be observable")
        for forbidden in ["SCStream(", "CVPixelBuffer", "CachedFrame", "validatedAt", "preparedFrozenScreens"] {
            try require(!source.contains(forbidden), "Fresh freezer must not keep old stream-cache token \(forbidden)")
        }
    }

    private static func testOverlayKeepsQuickShotSelectionContract(overlaySource: String,
                                                                   protectionSource: String) throws {
        try require(overlaySource.contains("func beginFrozenSelection"),
                    "Overlay must expose a frozen-start path")
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
