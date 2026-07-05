import AppKit
import CoreGraphics
import OSLog
@preconcurrency import ScreenCaptureKit

/// Mio-style ScreenCaptureKit freezer: each capture request produces fresh full-display
/// snapshots first, then the selection overlay is shown on top of those immutable pixels.
actor ScreenFreezePipeline {

    private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")
    private static let prewarmPixelSize = 2
    private static let captureBatchSize = 3

    private var isShuttingDown = false

    nonisolated static var captureClock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func prewarm() async {
        guard !isShuttingDown else { return }
        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                Self.log.warning("capture freeze prewarm skipped reason=no-display")
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Self.prewarmPixelSize
            config.height = Self.prewarmPixelSize
            config.showsCursor = false
            config.scalesToFit = true

            _ = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                           configuration: config)
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            Self.log.info("capture freeze prewarm ready ms=\(ms, privacy: .public)")
        } catch {
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            Self.log.warning("capture freeze prewarm failed ms=\(ms, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    func captureFrozenScreens(displays requestedDisplays: [CaptureDisplay]) async throws -> [FrozenScreen] {
        guard !isShuttingDown else {
            throw CaptureError.captureStackUnavailable("screen freeze pipeline is shut down")
        }
        guard !requestedDisplays.isEmpty else {
            throw CaptureError.noDisplay
        }

        var result: [FrozenScreen] = []
        let startedAt = CFAbsoluteTimeGetCurrent()
        for batchStart in stride(from: 0, to: requestedDisplays.count, by: Self.captureBatchSize) {
            let batch = Array(requestedDisplays[batchStart..<min(batchStart + Self.captureBatchSize, requestedDisplays.count)])
            try await withThrowingTaskGroup(of: FrozenScreen.self) { group in
                for display in batch {
                    group.addTask {
                        try await Self.captureFullDisplay(display)
                    }
                }

                for try await frozen in group {
                    result.append(frozen)
                }
            }
        }

        guard result.count == requestedDisplays.count else {
            throw CaptureError.captureStackUnavailable("captured \(result.count) of \(requestedDisplays.count) displays")
        }

        let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        Self.log.info("capture freeze screens ready displays=\(result.count, privacy: .public) ms=\(ms, privacy: .public)")
        return result
    }

    func shutdown() {
        isShuttingDown = true
        Self.log.info("capture freeze pipeline shutdown")
    }

    private static func captureFullDisplay(_ display: CaptureDisplay) async throws -> FrozenScreen {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw captureError(from: error, context: "shareable content unavailable")
        }

        guard let targetDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw CaptureError.captureStackUnavailable("No SCDisplay matching displayID \(display.id)")
        }

        let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = max(2, Int(display.frame.width * display.scale))
        config.height = max(2, Int(display.frame.height * display.scale))
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false

        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                    configuration: config)
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            log.info("capture freeze display ready display=\(display.id, privacy: .public) ms=\(ms, privacy: .public)")
            return FrozenScreen(displayID: display.id,
                                frame: display.frame,
                                scale: display.scale,
                                image: image)
        } catch {
            throw captureError(from: error, context: "display \(display.id) freeze failed")
        }
    }

    private static func captureError(from error: Error, context: String) -> CaptureError {
        if let captureError = error as? CaptureError {
            return captureError
        }
        if let streamError = error as? SCStreamError, streamError.code == .userDeclined {
            return .permissionDenied
        }
        return .captureStackUnavailable("\(context): \(error.localizedDescription)")
    }

#if TESTING
    nonisolated static var debugPrewarmPixelSize: Int { prewarmPixelSize }
    nonisolated static var debugCaptureBatchSize: Int { captureBatchSize }
#endif
}
