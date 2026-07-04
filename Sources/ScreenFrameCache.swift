import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import OSLog
import ScreenCaptureKit

struct CaptureDisplay {
    let id: CGDirectDisplayID
    let frame: CGRect
}

/// Keeps ScreenCaptureKit streams warm so a hotkey can freeze an already available frame
/// instead of paying screenshot API latency on the user's gesture path.
final class ScreenFrameCache {

    private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")

    private struct CachedFrame {
        let frame: CGRect
        let pixelBuffer: CVPixelBuffer
        let scale: CGFloat
        let updatedAt: CFTimeInterval
    }

    private let lock = NSLock()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var streams: [CGDirectDisplayID: CachedDisplayStream] = [:]
    private var frames: [CGDirectDisplayID: CachedFrame] = [:]
    private var priorityDisplays: Set<CGDirectDisplayID> = []
    private var startInFlight = false
    private var hasReliableAppExclusion = false

    func start(displays: [CaptureDisplay], excludingBundleIdentifier bundleID: String?) async {
        guard CGPreflightScreenCaptureAccess() else { return }
        guard needsStreams(for: displays) else { return }
        guard beginStartIfNeeded() else { return }
        defer { endStart() }

        Self.log.info("capture cache start requested displays=\(displays.map { String($0.id) }.joined(separator: ","), privacy: .public)")

        let content: SCShareableContent
        let contentStartedAt = CFAbsoluteTimeGetCurrent()
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let contentMs = (CFAbsoluteTimeGetCurrent() - contentStartedAt) * 1000
            Self.log.info("capture cache shareable content ready ms=\(contentMs, privacy: .public)")
        } catch {
            Self.log.error("capture cache shareable content failed: \(String(describing: error), privacy: .public)")
            return
        }

        let excludedApps: [SCRunningApplication]
        if let bundleID {
            excludedApps = content.applications.filter { $0.bundleIdentifier == bundleID }
            guard !excludedApps.isEmpty else {
                Self.log.error("capture cache cannot find app exclusion for \(bundleID, privacy: .public); stream cache disabled")
                return
            }
        } else {
            excludedApps = []
        }

        hasReliableAppExclusion = true
        let scDisplays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        let orderedDisplays = displays.sorted { lhs, rhs in
            priorityRank(for: lhs.id) < priorityRank(for: rhs.id)
        }

        let pendingStreams: [(display: CaptureDisplay, stream: CachedDisplayStream)] = orderedDisplays.compactMap { display in
            if hasStream(for: display.id) { return nil }
            guard let scDisplay = scDisplays[display.id] else { return nil }
            do {
                let cached = try CachedDisplayStream(
                    display: display,
                    scDisplay: scDisplay,
                    excludedApps: excludedApps,
                    onFrame: { [weak self] displayID, frame, scale, pixelBuffer in
                        self?.storeFrame(displayID: displayID, frame: frame, scale: scale, pixelBuffer: pixelBuffer)
                    })
                return (display, cached)
            } catch {
                Self.log.error("capture cache stream create failed display=\(display.id, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }

        for pending in pendingStreams {
            setStream(pending.stream, for: pending.display.id)
        }

        await withTaskGroup(of: Void.self) { group in
            for pending in pendingStreams {
                group.addTask {
                    do {
                        try await pending.stream.start()
                        Self.log.info("capture cache stream started display=\(pending.display.id, privacy: .public)")
                    } catch {
                        self.removeStream(for: pending.display.id)
                        Self.log.error("capture cache stream start failed display=\(pending.display.id, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
    }

    func prioritize(display: CaptureDisplay) {
        lock.lock()
        priorityDisplays.insert(display.id)
        lock.unlock()
        Self.log.info("capture cache priority display=\(display.id, privacy: .public)")
    }

    func frozenScreen(for display: CaptureDisplay) -> FrozenScreen? {
        guard hasReliableAppExclusion else { return nil }
        return cachedFrozenScreen(for: display)
    }

    func waitForFrozenScreen(for display: CaptureDisplay, timeoutNanoseconds: UInt64) async -> FrozenScreen? {
        if let frozen = frozenScreen(for: display) { return frozen }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - startedAt < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if Task.isCancelled { return nil }
            if let frozen = frozenScreen(for: display) { return frozen }
        }
        return nil
    }

    func isPreparingFrame(for display: CaptureDisplay) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startInFlight || (streams[display.id] != nil && frames[display.id] == nil)
    }

    private func cachedFrozenScreen(for display: CaptureDisplay) -> FrozenScreen? {
        let cached: CachedFrame?
        lock.lock()
        cached = frames[display.id]
        lock.unlock()

        guard let cached else { return nil }
        let width = CVPixelBufferGetWidth(cached.pixelBuffer)
        let height = CVPixelBufferGetHeight(cached.pixelBuffer)
        let image = CIImage(cvPixelBuffer: cached.pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            return nil
        }

        return FrozenScreen(displayID: display.id, frame: cached.frame, scale: cached.scale, image: cgImage)
    }

    private func storeFrame(displayID: CGDirectDisplayID, frame: CGRect, scale: CGFloat, pixelBuffer: CVPixelBuffer) {
        lock.lock()
        frames[displayID] = CachedFrame(frame: frame, pixelBuffer: pixelBuffer, scale: scale, updatedAt: CFAbsoluteTimeGetCurrent())
        lock.unlock()
    }

    private func beginStartIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if startInFlight { return false }
        startInFlight = true
        return true
    }

    private func endStart() {
        lock.lock()
        startInFlight = false
        lock.unlock()
    }

    private func hasStream(for displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return streams[displayID] != nil
    }

    private func needsStreams(for displays: [CaptureDisplay]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return displays.contains { streams[$0.id] == nil }
    }

    private func setStream(_ stream: CachedDisplayStream, for displayID: CGDirectDisplayID) {
        lock.lock()
        streams[displayID] = stream
        priorityDisplays.remove(displayID)
        lock.unlock()
    }

    private func removeStream(for displayID: CGDirectDisplayID) {
        lock.lock()
        streams.removeValue(forKey: displayID)
        frames.removeValue(forKey: displayID)
        lock.unlock()
    }

    private func priorityRank(for displayID: CGDirectDisplayID) -> Int {
        lock.lock()
        let isPriority = priorityDisplays.contains(displayID)
        lock.unlock()
        return isPriority ? 0 : 1
    }
}

private final class CachedDisplayStream: NSObject, SCStreamOutput {

    private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")

    private let display: CaptureDisplay
    private let stream: SCStream
    private let queue: DispatchQueue
    private let onFrame: (CGDirectDisplayID, CGRect, CGFloat, CVPixelBuffer) -> Void
    private let scale: CGFloat
    private var didLogFirstFrame = false
    private let startedAt = CFAbsoluteTimeGetCurrent()

    init(display: CaptureDisplay,
         scDisplay: SCDisplay,
         excludedApps: [SCRunningApplication],
         onFrame: @escaping (CGDirectDisplayID, CGRect, CGFloat, CVPixelBuffer) -> Void) throws {
        self.display = display
        self.onFrame = onFrame

        let filter = excludedApps.isEmpty
            ? SCContentFilter(display: scDisplay, excludingWindows: [])
            : SCContentFilter(display: scDisplay, excludingApplications: excludedApps, exceptingWindows: [])
        self.scale = CGFloat(filter.pointPixelScale)

        let config = SCStreamConfiguration()
        config.width = max(1, Int((display.frame.width * scale).rounded()))
        config.height = max(1, Int((display.frame.height * scale).rounded()))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 2
        config.scalesToFit = false
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.captureResolution = .best

        self.stream = SCStream(filter: filter, configuration: config, delegate: nil)
        self.queue = DispatchQueue(label: "QuickShot.capture-cache.\(display.id)")
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if !didLogFirstFrame {
            didLogFirstFrame = true
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            Self.log.info("capture cache first frame display=\(self.display.id, privacy: .public) ms=\(ms, privacy: .public)")
        }
        onFrame(display.id, display.frame, scale, pixelBuffer)
    }
}
