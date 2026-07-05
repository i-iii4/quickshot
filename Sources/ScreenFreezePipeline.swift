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
    private static let captureTimeoutNanoseconds: UInt64 = 900_000_000
    private static let prewarmTimeoutNanoseconds: UInt64 = 500_000_000

    private var isShuttingDown = false

    nonisolated static var captureClock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func prewarm() async {
        guard !isShuttingDown else { return }
        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let content = try await Self.loadShareableContent()
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

            _ = try await Self.captureImage(contentFilter: filter,
                                            configuration: config,
                                            timeoutNanoseconds: Self.prewarmTimeoutNanoseconds)
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

        let startedAt = CFAbsoluteTimeGetCurrent()
        let content: SCShareableContent
        do {
            content = try await Self.loadShareableContent()
        } catch {
            throw Self.captureError(from: error, context: "shareable content unavailable")
        }

        let availableDisplayIDs = Set(content.displays.map(\.displayID))
        let missing = requestedDisplays.filter { !availableDisplayIDs.contains($0.id) }
        guard missing.isEmpty else {
            throw CaptureError.captureStackUnavailable("ScreenCaptureKit display missing: \(missing.map { String($0.id) }.joined(separator: ","))")
        }

        var result: [FrozenScreen] = []
        for batchStart in stride(from: 0, to: requestedDisplays.count, by: Self.captureBatchSize) {
            let batch = Array(requestedDisplays[batchStart..<min(batchStart + Self.captureBatchSize, requestedDisplays.count)])
            try await withThrowingTaskGroup(of: FrozenScreen.self) { group in
                for display in batch {
                    guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else { continue }
                    group.addTask {
                        try await Self.captureDisplay(display, scDisplay: scDisplay)
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

    private static func captureDisplay(_ display: CaptureDisplay, scDisplay: SCDisplay) async throws -> FrozenScreen {
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = max(2, Int(display.frame.width * display.scale))
        config.height = max(2, Int(display.frame.height * display.scale))
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false

        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let image = try await captureImage(contentFilter: filter,
                                               configuration: config,
                                               timeoutNanoseconds: captureTimeoutNanoseconds)
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

    private static func loadShareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            log.warning("capture freeze shareable content primary failed: \(String(describing: error), privacy: .public)")
            return try await SCShareableContent.current
        }
    }

    private static func captureImage(contentFilter: SCContentFilter,
                                     configuration: SCStreamConfiguration,
                                     timeoutNanoseconds: UInt64) async throws -> CGImage {
        try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask {
                try await SCScreenshotManager.captureImage(contentFilter: contentFilter,
                                                           configuration: configuration)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw CaptureError.captureStackUnavailable("ScreenCaptureKit screenshot timed out")
            }

            guard let image = try await group.next() else {
                group.cancelAll()
                throw CaptureError.captureStackUnavailable("ScreenCaptureKit screenshot returned no image")
            }
            group.cancelAll()
            return image
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
    nonisolated static var debugCaptureTimeoutNanoseconds: UInt64 { captureTimeoutNanoseconds }
    nonisolated static var debugPrewarmTimeoutNanoseconds: UInt64 { prewarmTimeoutNanoseconds }
#endif
}
