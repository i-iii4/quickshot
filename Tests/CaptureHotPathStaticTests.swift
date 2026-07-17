import Foundation

@main
struct CaptureHotPathStaticTests {
    static func main() {
        do {
            let captureSource = try String(contentsOfFile: "Sources/CaptureController.swift", encoding: .utf8)
            let freshRegionSource = try String(contentsOfFile: "Sources/FreshRegionCapture.swift", encoding: .utf8)
            let overlaySource = try String(contentsOfFile: "Sources/Overlay.swift", encoding: .utf8)
            let appDelegateSource = try String(contentsOfFile: "Sources/AppDelegate.swift", encoding: .utf8)
            let hotKeySource = try String(contentsOfFile: "Sources/GlobalHotKey.swift", encoding: .utf8)
            let protectionSource = try String(contentsOfFile: "Sources/WindowCaptureProtection.swift", encoding: .utf8)
            let clipboardSource = try String(contentsOfFile: "Sources/Clipboard.swift", encoding: .utf8)
            let thumbnailManagerSource = try String(contentsOfFile: "Sources/ThumbnailManager.swift", encoding: .utf8)
            let thumbnailWindowSource = try String(contentsOfFile: "Sources/ThumbnailWindow.swift", encoding: .utf8)
            let pinnedWindowSource = try String(contentsOfFile: "Sources/PinnedWindow.swift", encoding: .utf8)

            try testFrozenPipelineIsOutOfHotPath(captureSource: captureSource)
            try testLiveSelectionStartsImmediately(captureSource)
            try testFreshRegionCaptureAfterSelection(captureSource: captureSource,
                                                     freshRegionSource: freshRegionSource)
            try testRepeatedCaptureDoesNotWaitForFreshPixels(captureSource)
            try testOverlayKeepsLiveSelectionContract(overlaySource: overlaySource,
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
                                               captureSource: captureSource)
            print("CaptureHotPathStaticTests: passed")
        } catch {
            fputs("CaptureHotPathStaticTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testFrozenPipelineIsOutOfHotPath(captureSource: String) throws {
        try require(!FileManager.default.fileExists(atPath: "Sources/ScreenFreezePipeline.swift"),
                    "ScreenFreezePipeline must not remain in the product source set")
        try require(!FileManager.default.fileExists(atPath: "Tests/ScreenFreezePipelineBehaviorTests.swift"),
                    "ScreenFreezePipeline tests must not remain product gates after the UX reset")
        for forbidden in ["ScreenFreezePipeline",
                          "captureFrozenScreens",
                          "beginFrozenSelection",
                          "FrozenScreen",
                          "startFreezeTask",
                          "capture frozen ready",
                          "latest-active-stream"] {
            try require(!captureSource.contains(forbidden),
                        "CaptureController must not keep old frozen/stream token \(forbidden)")
        }
        try require(!captureSource.contains("ScreenFrameCache"),
                    "CaptureController must not depend on stale stream-cache architecture")
    }

    private static func testLiveSelectionStartsImmediately(_ source: String) throws {
        let startBody = try functionBody(named: "start", in: source, after: "private final class CaptureSession")
        try require(startBody.contains("CaptureGestureSnapshot()"),
                    "CaptureSession.start must seed selection timing from the trigger gesture")
        try require(startBody.contains("beginOverlay(initialMouseDownAt: snapshot.initialMouseDownAt)"),
                    "CaptureSession.start must enter live selection immediately")
        try require(!startBody.contains("FreshRegionCapture.capture"),
                    "CaptureSession.start must not do screenshot work before selection")
        try require(!startBody.contains("HiddenAppWindows.hideVisibleApplicationWindows()"),
                    "CaptureSession.start must not visually change the screen by hiding app windows before drag")

        let beginOverlayBody = try functionBody(named: "beginOverlay", in: source, after: "private final class CaptureSession")
        try require(beginOverlayBody.contains("beginLiveSelection"),
                    "Overlay must use the live selection entry point")
        try require(beginOverlayBody.contains("capture overlay ready"),
                    "Overlay readiness must stay observable")
        try require(!beginOverlayBody.contains("beginFrozenSelection"),
                    "Overlay construction must not wait for frozen screenshots")
    }

    private static func testFreshRegionCaptureAfterSelection(captureSource: String,
                                                             freshRegionSource: String) throws {
        let completeBody = try functionBody(named: "completeSelection", in: captureSource, after: "private final class CaptureSession")
        try require(completeBody.contains("startFreshCaptureAndDelivery(selection: clamped, screen: screen)"),
                    "Mouse-up must hand off to fresh region capture")
        try require(!completeBody.contains("FreshRegionCapture.capture"),
                    "Mouse-up handler must not synchronously capture pixels")

        let freshBody = try functionBody(named: "startFreshCaptureAndDelivery", in: captureSource, after: "private final class CaptureSession")
        try require(!freshBody.contains("HiddenAppWindows") && !freshBody.contains("orderOut"),
                    "Fresh capture must exclude QuickShot through ScreenCaptureKit, not hide visible UI")
        try require(freshBody.contains("Task.detached(priority: .userInitiated)"),
                    "Fresh capture must leave the main actor")
        try require(freshBody.contains("FreshRegionCapture.capture(selection: selection"),
                    "Completed selection must use FreshRegionCapture")
        for token in ["capture fresh region pending",
                      "capture fresh region ready",
                      "capture fresh region failed",
                      "capture delivery outcome=fresh-capture-failed"] {
            try require(freshBody.contains(token), "Fresh capture must keep log token \(token)")
        }

        try require(freshRegionSource.contains("SCScreenshotManager.captureImage"),
                    "FreshRegionCapture must own the ScreenCaptureKit screenshot call")
        try require(freshRegionSource.contains("config.sourceRect = spec.sourceRect"),
                    "FreshRegionCapture must request the selected region, not a full frozen desktop")
        try require(freshRegionSource.contains("config.showsCursor = false"),
                    "Fresh region capture must not bake the system cursor")
        try require(freshRegionSource.contains("SCShareableContent.current"),
                    "FreshRegionCapture must resolve the current display at completion time")
        try require(freshRegionSource.contains("excludingApplications: [currentApplication]"),
                    "FreshRegionCapture must exclude the QuickShot application from the filter")
        try require(freshRegionSource.contains("exceptingWindows: []"),
                    "FreshRegionCapture must not except QuickShot windows back into the app exclusion")
        try require(freshRegionSource.contains("owningApplication?.processID == processID"),
                    "FreshRegionCapture must keep a same-process window fallback")
        try require(freshRegionSource.contains("image.cropping(to: px)"),
                    "FreshRegionCapture must guard against APIs returning a full-display image")
    }

    private static func testRepeatedCaptureDoesNotWaitForFreshPixels(_ source: String) throws {
        let triggerBody = try functionBody(named: "triggerCapture", in: source, after: "final class CaptureController")
        try require(triggerBody.contains("guard selectionSession == nil"),
                    "Capture admission must be gated only by an active selection overlay")
        try require(!triggerBody.contains("finishingSessions.isEmpty"),
                    "In-flight pixel delivery must not block the next selection overlay")
        try require(source.contains("private var finishingSessions: [UUID: CaptureSession] = [:]"),
                    "Finishing captures need independent ownership after selection releases")

        let completeBody = try functionBody(named: "completeSelection", in: source, after: "private final class CaptureSession")
        guard let release = completeBody.range(of: "onSelectionReleased(id)"),
              let capture = completeBody.range(of: "startFreshCaptureAndDelivery(selection: clamped, screen: screen)") else {
            throw Failure("Mouse-up must release selection admission before starting slow pixel delivery")
        }
        try require(release.lowerBound < capture.lowerBound,
                    "Slow ScreenCaptureKit delivery still owns the next-trigger admission lock")

        let releaseBody = try functionBody(named: "releaseSelectionSession", in: source, after: "final class CaptureController")
        try require(releaseBody.contains("finishingSessions[id] = session")
                    && releaseBody.contains("selectionSession = nil"),
                    "Released selection must remain retained without blocking a new overlay")
    }

    private static func testOverlayKeepsLiveSelectionContract(overlaySource: String,
                                                              protectionSource: String) throws {
        try require(overlaySource.contains("func beginLiveSelection"),
                    "Overlay must expose a live-start path")
        try require(!overlaySource.contains("func beginFrozenSelection"),
                    "Overlay must not expose the old frozen-start path")
        try require(!overlaySource.contains("BackdropView"),
                    "Live overlay must not keep frozen backdrop views")
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
        try require(overlaySource.contains("innerOverlayColor"),
                    "Selection view must draw the lightweight inner overlay")
        try require(overlaySource.contains("currentRect.fill()"),
                    "Selection view must fill only the selected rect")
        try require(!overlaySource.contains("bounds.fill()"),
                    "Selection view must not draw a full-screen outside dim")
        try require(overlaySource.contains("w.collectionBehavior = [.fullScreenAuxiliary, .stationary]"),
                    "Selection overlay must stay scoped to the current Space")
        try require(!overlaySource.contains(".canJoinAllSpaces"),
                    "Selection overlay must not follow the user across Spaces")
    }

    private static func testCompletedCaptureIsObservable(captureSource: String) throws {
        let freshBody = try functionBody(named: "startFreshCaptureAndDelivery", in: captureSource, after: "private final class CaptureSession")
        try require(freshBody.contains("DispatchQueue.main") == false,
                    "Fresh capture should use Swift tasks, not nested dispatch crop code")
        try require(freshBody.contains("capture image handoff failed missing screen"),
                    "Completed capture must keep missing-screen handoff logging")
        try require(freshBody.contains("capture delivery outcome=handoff-failed"),
                    "Completed capture must have handoff failure outcome")

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
                                                      captureSource: String) throws {
        let terminationBody = try functionBody(named: "applicationWillTerminate", in: appDelegateSource, after: "final class AppDelegate")
        try require(terminationBody.contains("capture.shutdown()"),
                    "App termination must explicitly shut down active capture UI")

        let controllerShutdown = try functionBody(named: "shutdown", in: captureSource, after: "final class CaptureController")
        try require(controllerShutdown.contains("selectionSession?.shutdown()"),
                    "CaptureController.shutdown must dismiss the active selection overlay")
        try require(controllerShutdown.contains("Array(finishingSessions.values)")
                    && controllerShutdown.contains("for session in sessions { session.shutdown() }"),
                    "CaptureController.shutdown must cancel every in-flight capture delivery")
        try require(controllerShutdown.contains("prewarmTask?.cancel()") && controllerShutdown.contains("prewarmTask = nil"),
                    "CaptureController.shutdown must cancel owned startup prewarm work")

        let sessionShutdown = try functionBody(named: "shutdown", in: captureSource, after: "private final class CaptureSession")
        try require(sessionShutdown.contains("endOutcome = \"shutdown\""),
                    "CaptureSession.shutdown must make shutdown visible in logs")
        try require(sessionShutdown.contains("overlay?.dismiss()"),
                    "CaptureSession.shutdown must dismiss active fullscreen overlay windows")

        let endBody = try functionBody(named: "end", in: captureSource, after: "private final class CaptureSession")
        try require(endBody.contains("freshCaptureTask?.cancel()"),
                    "CaptureSession.end must cancel late fresh capture work")
        try require(!captureSource.contains("HiddenAppWindows"),
                    "CaptureSession must not hide and restore QuickShot windows during capture")
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
