import Foundation

@main
struct CaptureHotPathStaticTests {
    static func main() {
        do {
            let capture = try source("Sources/CaptureController.swift")
            let provider = try source("Sources/DirectScreenSnapshotProvider.swift")
            let overlay = try source("Sources/Overlay.swift")
            let types = try source("Sources/CaptureTypes.swift")
            let coordinates = try source("Sources/CoordinateMath.swift")
            let appDelegate = try source("Sources/AppDelegate.swift")
            let hotKey = try source("Sources/GlobalHotKey.swift")
            let protection = try source("Sources/WindowCaptureProtection.swift")
            let clipboard = try source("Sources/Clipboard.swift")
            let thumbnailManager = try source("Sources/ThumbnailManager.swift")
            let thumbnailWindow = try source("Sources/ThumbnailWindow.swift")
            let pinnedWindow = try source("Sources/PinnedWindow.swift")

            try testDirectSnapshotPrecedesOverlay(capture: capture, provider: provider)
            try testSessionOwnsImmutablePixels(provider: provider, types: types)
            try testFrozenOverlayContract(overlay: overlay, protection: protection)
            try testMouseUpOnlyCropsFrozenImage(capture)
            try testRepeatedCaptureAdmission(capture)
            try testCoordinateMappingUsesImageSize(coordinates)
            try testNoRetiredCapturePath(provider: provider, capture: capture)
            try testObservableTimingAndDelivery(capture)
            try testClipboardPayloadPreparationIsCentralized(
                clipboardSource: clipboard,
                thumbnailManagerSource: thumbnailManager,
                thumbnailWindowSource: thumbnailWindow,
                pinnedWindowSource: pinnedWindow)
            try testHotKeyEventSeedsCaptureTiming(appDelegate: appDelegate,
                                                  hotKey: hotKey,
                                                  capture: capture)
            try testCaptureShutdownIsExplicit(appDelegate: appDelegate,
                                              capture: capture)
            print("CaptureHotPathStaticTests: passed")
        } catch {
            fputs("CaptureHotPathStaticTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testDirectSnapshotPrecedesOverlay(capture: String,
                                                          provider: String) throws {
        let start = try functionBody(named: "start", in: capture,
                                     after: "private final class CaptureSession")
        try require(start.contains("startSnapshotTask(displays: displays)"),
                    "CaptureSession must start pixels before constructing overlay")
        try require(!start.contains("beginOverlay"),
                    "CaptureSession.start must not expose UI before pixels are ready")

        let completed = try functionBody(named: "snapshotCompleted", in: capture,
                                         after: "private final class CaptureSession")
        try require(completed.contains("batch.sessionID == id"),
                    "Snapshot completion must verify session ownership")
        try require(completed.contains("expectedIDs == receivedIDs"),
                    "Snapshot completion must reject partial display batches")
        try require(completed.contains("beginOverlay(backdrops:"),
                    "Frozen overlay must start only from a complete snapshot batch")

        try require(provider.contains("CGWindowListCreateImage"),
                    "Direct provider must resolve the CoreGraphics one-shot symbol")
        try require(provider.contains("withThrowingTaskGroup"),
                    "Displays must be captured concurrently inside one batch")
        try require(provider.contains("CGWindowImageOption.bestResolution"),
                    "Direct provider must request native display resolution")
    }

    private static func testSessionOwnsImmutablePixels(provider: String,
                                                        types: String) throws {
        try require(types.contains("struct FrozenSnapshotBatch"),
                    "Capture types must model a session-owned batch")
        try require(types.contains("let sessionID: UUID"),
                    "Frozen batch must carry its owning session ID")
        try require(types.contains("struct FrozenScreen"),
                    "Frozen display pixels need an immutable value type")
        try require(provider.contains("FrozenSnapshotBatch(sessionID: sessionID"),
                    "Provider must return the caller's session ID")
        for forbidden in ["cache", "latestFrame", "previousFrame", "warmed"] {
            try require(!provider.localizedCaseInsensitiveContains(forbidden),
                        "Direct provider must not keep stale-frame concept: \(forbidden)")
        }
    }

    private static func testFrozenOverlayContract(overlay: String,
                                                  protection: String) throws {
        try require(overlay.contains("func beginFrozenSelection"),
                    "Overlay must expose only the frozen selection entry point")
        try require(!overlay.contains("func beginLiveSelection"),
                    "Live selection must not return to production")
        try require(overlay.contains("BackdropView"),
                    "Frozen pixels need a static backdrop layer")
        try require(overlay.contains("container.addSubview(backdropView)"),
                    "Backdrop must render below selection chrome")
        try require(overlay.contains("container.addSubview(chrome)"),
                    "Selection chrome must remain independent from the bitmap")
        try require(overlay.contains("w.displayIfNeeded()"),
                    "Frozen overlay must render atomically before becoming visible")
        try require(overlay.contains("private let cursorLease = CursorLease()"),
                    "One session-owned lease must own system cursor suppression")
        try require(overlay.contains("cursorLease.acquire()")
                    && overlay.contains("cursorLease.release()"),
                    "Frozen overlay must acquire and release one cursor lease")
        for forbidden in ["CGDisplayHideCursor", "CGDisplayShowCursor",
                          "makeInvisibleSystemCursor", "deferredCursorHide"] {
            try require(!overlay.contains(forbidden),
                        "Competing cursor suppression must stay removed: \(forbidden)")
        }
        guard let acquire = overlay.range(of: "cursorLease.acquire()"),
              let orderFront = overlay.range(of: "w.orderFrontRegardless()"),
              let orderOut = overlay.range(of: "w.orderOut(nil)"),
              let release = overlay.range(of: "cursorLease.release()") else {
            throw Failure("Cursor lifecycle markers are missing")
        }
        try require(acquire.lowerBound < orderFront.lowerBound,
                    "Cursor must be hidden before frozen windows become visible")
        try require(orderOut.lowerBound < release.lowerBound,
                    "Frozen windows must disappear before the system cursor returns")
        try require(overlay.contains("NSApplication.didBecomeActiveNotification")
                    && overlay.contains("guard !isDismissed, !isPresented, NSApp.isActive"),
                    "Frozen windows must reveal only after deterministic activation")
        try require(overlay.contains("onPointerActivity")
                    && overlay.contains("selection !== active"),
                    "All displays must share one visible custom crosshair owner")
        try require(overlay.contains("makeCrosshair") && overlay.contains("frameStartOffset"),
                    "Established cursor/frame geometry must be reused")
        try require(overlay.contains("innerOverlayColor")
                    && overlay.contains("currentRect.fill()")
                    && !overlay.contains("bounds.fill()"),
                    "Only the selected rectangle may receive the light overlay")
        try require(overlay.contains("WindowCaptureProtection.excludeFromScreenCapture(w)"),
                    "Selection windows must be excluded from future captures")
        try require(protection.contains("window.sharingType = .none"),
                    "Window exclusion must remain centralized")
    }

    private static func testMouseUpOnlyCropsFrozenImage(_ capture: String) throws {
        let completed = try functionBody(named: "selectionCompleted", in: capture,
                                         after: "private final class CaptureSession")
        try require(completed.contains("let shot = frozen[displayID]"),
                    "Mouse-up must use the session-owned frozen screen")
        try require(completed.contains("onSelectionReleased(id)"),
                    "Mouse-up must release admission before background crop")
        try require(completed.contains("startCropTask(shot: shot"),
                    "Mouse-up must pass the immutable screen into crop delivery")
        for forbidden in ["capture(", "SCScreenshotManager", "Process()", "screencapture"] {
            try require(!completed.contains(forbidden),
                        "Mouse-up must not start another capture: \(forbidden)")
        }

        let crop = try functionBody(named: "startCropTask", in: capture,
                                    after: "private final class CaptureSession")
        try require(crop.contains("shot.crop(globalSelection: selection)"),
                    "Delivery must crop the hotkey snapshot")
        try require(crop.contains("Task.detached(priority: .userInitiated)"),
                    "Crop must stay off the main actor")
    }

    private static func testRepeatedCaptureAdmission(_ capture: String) throws {
        let trigger = try functionBody(named: "triggerCapture", in: capture,
                                       after: "final class CaptureController")
        try require(trigger.contains("guard selectionSession == nil"),
                    "Only an active selector may block the next hotkey")
        try require(!trigger.contains("finishingSessions.isEmpty"),
                    "A crop delivery must not block a new capture")
        try require(capture.contains("private var finishingSessions: [UUID: CaptureSession] = [:]"),
                    "Finishing crops require independent ownership")

        let release = try functionBody(named: "releaseSelectionSession", in: capture,
                                       after: "final class CaptureController")
        try require(release.contains("finishingSessions[id] = session")
                    && release.contains("selectionSession = nil"),
                    "Released selection must remain retained without blocking admission")
    }

    private static func testCoordinateMappingUsesImageSize(_ coordinates: String) throws {
        try require(coordinates.contains("imageSize.width / displayFrame.width")
                    && coordinates.contains("imageSize.height / displayFrame.height"),
                    "Crop mapping must derive scale from actual pixels")
        try require(coordinates.contains("displayFrame.maxY - clamped.maxY"),
                    "AppKit-to-image conversion must perform the display-local y flip")
    }

    private static func testNoRetiredCapturePath(provider: String,
                                                  capture: String) throws {
        try require(!FileManager.default.fileExists(atPath: "Sources/FreshRegionCapture.swift"),
                    "FreshRegionCapture must be removed")
        try require(!FileManager.default.fileExists(atPath: "Sources/SystemCaptureSession.swift"),
                    "SystemCaptureSession must be removed")
        for source in [provider, capture] {
            for forbidden in ["import ScreenCaptureKit", "SCScreenshotManager",
                              "SCStream", "/usr/sbin/screencapture"] {
                try require(!source.contains(forbidden),
                            "Retired capture path returned: \(forbidden)")
            }
        }
        try require(!capture.contains("HiddenAppWindows") && !capture.contains("orderOut(nil)"),
                    "QuickShot windows must be excluded, never hidden for capture")
    }

    private static func testObservableTimingAndDelivery(_ capture: String) throws {
        for token in ["capture direct snapshot pending", "capture frozen ready",
                      "capture overlay ready", "mouseUpToCardMs", "capture end outcome="] {
            try require(capture.contains(token), "Missing capture timing token: \(token)")
        }
        let delivery = try functionBody(named: "deliverCapturedImage", in: capture,
                                        after: "final class CaptureController")
        try require(delivery.contains("capture thumbnail added"),
                    "Thumbnail delivery must remain observable")
        try require(delivery.contains("Clipboard.prepareImage(cgImage: image)"),
                    "Clipboard encoding must remain centralized")
        try require(delivery.contains("capture delivery outcome=completed"),
                    "Successful delivery needs an explicit outcome")
    }

    private static func testClipboardPayloadPreparationIsCentralized(
        clipboardSource: String,
        thumbnailManagerSource: String,
        thumbnailWindowSource: String,
        pinnedWindowSource: String
    ) throws {
        try require(clipboardSource.contains("import ImageIO")
                    && clipboardSource.contains("struct PreparedImage")
                    && clipboardSource.contains("prepareImages(cgImages: [CGImage])"),
                    "Clipboard must own off-main prepared image payloads")
        for (name, source) in [("ThumbnailManager", thumbnailManagerSource),
                               ("ThumbnailWindow", thumbnailWindowSource),
                               ("PinnedWindow", pinnedWindowSource)] {
            try require(!source.contains("NSBitmapImageRep(cgImage:")
                        && !source.contains("tiffRepresentation")
                        && !source.contains("Clipboard.copy(cgImage:"),
                        "\(name) must not encode copy payloads synchronously")
        }
    }

    private static func testHotKeyEventSeedsCaptureTiming(appDelegate: String,
                                                          hotKey: String,
                                                          capture: String) throws {
        try require(capture.contains("func triggerCapture(startedAt triggerStartedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent())"),
                    "Capture timing must start at the request event")
        try require(appDelegate.contains("capture.triggerCapture(startedAt: startedAt)")
                    && appDelegate.contains("capture.prewarmCapturePipeline()"),
                    "AppDelegate must pass timing and preflight permission at startup")
        try require(hotKey.contains("let receivedAt = CFAbsoluteTimeGetCurrent()")
                    && hotKey.contains("onTrigger?(receivedAt)"),
                    "Carbon hotkey must preserve its earliest timestamp")
    }

    private static func testCaptureShutdownIsExplicit(appDelegate: String,
                                                      capture: String) throws {
        let termination = try functionBody(named: "applicationWillTerminate", in: appDelegate,
                                           after: "final class AppDelegate")
        try require(termination.contains("capture.shutdown()"),
                    "Application termination must shut down capture")
        let controller = try functionBody(named: "shutdown", in: capture,
                                          after: "final class CaptureController")
        try require(controller.contains("selectionSession?.shutdown()")
                    && controller.contains("for session in finishing { session.shutdown() }"),
                    "Controller must stop active and delivering sessions")
        let end = try functionBody(named: "end", in: capture,
                                   after: "private final class CaptureSession")
        try require(end.contains("snapshotTask?.cancel()")
                    && end.contains("cropTask?.cancel()")
                    && end.contains("overlay?.dismiss()")
                    && end.contains("restoreSourceApplication()"),
                    "Every terminal path must restore all session-owned resources")
    }

    private static func source(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func functionBody(named name: String,
                                     in source: String,
                                     after marker: String) throws -> String {
        guard let markerRange = source.range(of: marker) else {
            throw Failure("Missing marker \(marker)")
        }
        let scoped = source[markerRange.upperBound...]
        guard let functionRange = scoped.range(of: "func \(name)("),
              let openBrace = scoped[functionRange.lowerBound...].firstIndex(of: "{") else {
            throw Failure("Missing function \(name)")
        }
        var depth = 0
        var current = openBrace
        while current < scoped.endIndex {
            switch scoped[current] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(scoped[openBrace...current])
                }
            default: break
            }
            current = scoped.index(after: current)
        }
        throw Failure("Unterminated function \(name)")
    }

    private static func require(_ condition: @autoclosure () -> Bool,
                                _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
