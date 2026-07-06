import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import OSLog
@preconcurrency import ScreenCaptureKit

/// Persistent stream freezer.
///
/// Hot capture path contract:
/// - no `SCShareableContent.current`;
/// - no foreground screenshot fallback;
/// - accept only a complete frame, or an idle heartbeat proving no display
///   change, after the trigger/post-hide boundary;
/// - if ScreenCaptureKit withholds idle callbacks for a static display, accept
///   the latest complete frame from the active matching stream.
actor ScreenFreezePipeline {

    private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")
    private static let streamFrameRate: Int32 = 60
    private static let streamQueueDepth = 3
    private static let freshFrameDeadlineNanoseconds: UInt64 = 150_000_000
    private static let freshFramePollNanoseconds: UInt64 = 2_000_000
    private static let postHideSettleSeconds: CFTimeInterval = 0.016

    private let ciContext = CIContext(options: nil)
    private var streams: [CGDirectDisplayID: WarmDisplayStream] = [:]
    private var latestFrames: [CGDirectDisplayID: StreamFrame] = [:]
    private var latestIdleHeartbeats: [CGDirectDisplayID: CFAbsoluteTime] = [:]
    private var maintenanceTask: Task<Void, Never>?
    private var isShuttingDown = false

    nonisolated static var captureClock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func prewarm() async {
        guard !isShuttingDown else { return }
        await refreshWarmStreams(reason: "prewarm")
    }

    func captureFrozenScreens(displays requestedDisplays: [CaptureDisplay],
                              requestedAt: CFAbsoluteTime,
                              readyAfter: CFAbsoluteTime) async throws -> [FrozenScreen] {
        guard !isShuttingDown else {
            throw CaptureError.captureStackUnavailable("screen freeze pipeline is shut down")
        }
        guard !requestedDisplays.isEmpty else {
            throw CaptureError.noDisplay
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let missing = requestedDisplays.filter { !isWarm(display: $0) }
        guard missing.isEmpty else {
            scheduleMaintenance(reason: "missing-stream")
            let ids = missing.map { String($0.id) }.joined(separator: ",")
            throw CaptureError.captureStackUnavailable("warm stream unavailable for display(s): \(ids)")
        }

        let acceptedAfter = max(requestedAt, readyAfter) + Self.postHideSettleSeconds
        let frames = try await waitForFreshFrames(displays: requestedDisplays,
                                                  acceptedAfter: acceptedAfter,
                                                  startedAt: startedAt)
        var frozen: [FrozenScreen] = []
        frozen.reserveCapacity(frames.count)
        for frame in frames {
            frozen.append(try makeFrozenScreen(display: frame.display, frame: frame.frame, startedAt: startedAt))
            let waitMs = (frame.confirmedAt - acceptedAfter) * 1000
            let pixelAgeMs = (frame.confirmedAt - frame.frame.receivedAt) * 1000
            let totalMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            Self.log.info("capture stream frame accepted display=\(frame.display.id, privacy: .public) freshness=\(frame.freshness.logValue, privacy: .public) waitMs=\(waitMs, privacy: .public) pixelAgeMs=\(pixelAgeMs, privacy: .public) totalMs=\(totalMs, privacy: .public)")
        }

        let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        Self.log.info("capture freeze screens ready source=stream displays=\(frozen.count, privacy: .public) ms=\(ms, privacy: .public)")
        return frozen
    }

    func shutdown() async {
        isShuttingDown = true
        maintenanceTask?.cancel()
        maintenanceTask = nil
        await stopAllStreams(reason: "shutdown")
        Self.log.info("capture freeze pipeline shutdown")
    }

    private func waitForFreshFrames(displays requestedDisplays: [CaptureDisplay],
                                    acceptedAfter: CFAbsoluteTime,
                                    startedAt: CFAbsoluteTime) async throws -> [FreshStreamFrame] {
        let deadline = CFAbsoluteTimeGetCurrent() + (Double(Self.freshFrameDeadlineNanoseconds) / 1_000_000_000)
        while CFAbsoluteTimeGetCurrent() < deadline {
            let ready = requestedDisplays.compactMap { display -> FreshStreamFrame? in
                freshStreamFrame(display: display, acceptedAfter: acceptedAfter)
            }
            if ready.count == requestedDisplays.count {
                return ready
            }
            try await Task.sleep(nanoseconds: Self.freshFramePollNanoseconds)
        }

        let now = CFAbsoluteTimeGetCurrent()
        let latest = requestedDisplays.compactMap { display -> FreshStreamFrame? in
            latestActiveStreamFrame(display: display, now: now)
        }
        if latest.count == requestedDisplays.count {
            let maxAgeMs = (latest.map { now - $0.frame.receivedAt }.max() ?? 0) * 1000
            Self.log.info("capture stream latest active frame accepted reason=missing-post-hide-heartbeat maxAgeMs=\(maxAgeMs, privacy: .public)")
            return latest
        }

        let missing = requestedDisplays.compactMap { display -> String? in
            guard let frame = latestFrames[display.id] else { return String(display.id) }
            if frame.receivedAt >= acceptedAfter { return nil }
            if let idleAt = latestIdleHeartbeats[display.id], idleAt >= acceptedAfter { return nil }
            return "\(display.id):stale"
        }.joined(separator: ",")
        let waitedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        Self.log.error("capture stream fresh frame missed displays=\(missing, privacy: .public) waitedMs=\(waitedMs, privacy: .public)")
        scheduleMaintenance(reason: "fresh-frame-missed")
        throw CaptureError.captureStackUnavailable("fresh stream frame unavailable before deadline for display(s): \(missing)")
    }

    private func freshStreamFrame(display: CaptureDisplay,
                                  acceptedAfter: CFAbsoluteTime) -> FreshStreamFrame? {
        guard let frame = latestFrames[display.id] else { return nil }
        if frame.receivedAt >= acceptedAfter {
            return FreshStreamFrame(display: display,
                                    frame: frame,
                                    confirmedAt: frame.receivedAt,
                                    freshness: .complete)
        }
        if let idleAt = latestIdleHeartbeats[display.id], idleAt >= acceptedAfter {
            return FreshStreamFrame(display: display,
                                    frame: frame,
                                    confirmedAt: idleAt,
                                    freshness: .idleHeartbeat)
        }
        return nil
    }

    private func latestActiveStreamFrame(display: CaptureDisplay,
                                         now: CFAbsoluteTime) -> FreshStreamFrame? {
        guard isWarm(display: display), let frame = latestFrames[display.id] else { return nil }
        return FreshStreamFrame(display: display,
                                frame: frame,
                                confirmedAt: now,
                                freshness: .latestActiveStream)
    }

    private func refreshWarmStreams(reason: String) async {
        guard !isShuttingDown else { return }
        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let requestedDisplays = await Self.currentDisplays()
            guard !requestedDisplays.isEmpty else {
                Self.log.warning("capture stream refresh skipped reason=no-display")
                return
            }

            let content = try await SCShareableContent.current
            let requestedIDs = Set(requestedDisplays.map(\.id))
            for displayID in streams.keys where !requestedIDs.contains(displayID) {
                await stopStream(displayID: displayID, reason: "display-removed")
            }

            for display in requestedDisplays {
                if let existing = streams[display.id], existing.matches(display) {
                    continue
                }
                if streams[display.id] != nil {
                    await stopStream(displayID: display.id, reason: "display-changed")
                }
                guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
                    throw CaptureError.captureStackUnavailable("No SCDisplay matching displayID \(display.id)")
                }
                try await startStream(display: display, scDisplay: scDisplay, reason: reason)
            }

            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            Self.log.info("capture stream refresh ready reason=\(reason, privacy: .public) displays=\(requestedDisplays.count, privacy: .public) ms=\(ms, privacy: .public)")
        } catch {
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            Self.log.error("capture stream refresh failed reason=\(reason, privacy: .public) ms=\(ms, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private func startStream(display: CaptureDisplay, scDisplay: SCDisplay, reason: String) async throws {
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = Self.streamConfiguration(for: display)
        let output = StreamOutput(displayID: display.id, owner: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        let queue = DispatchQueue(label: "com.iiii.quickshot.screen-stream.\(display.id)", qos: .userInitiated)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: queue)

        let state = WarmDisplayStream(display: display,
                                      stream: stream,
                                      output: output,
                                      queue: queue,
                                      startedAt: CFAbsoluteTimeGetCurrent())
        streams[display.id] = state
        let startedAt = CFAbsoluteTimeGetCurrent()
        try await stream.startCapture()
        let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        Self.log.info("capture stream started display=\(display.id, privacy: .public) reason=\(reason, privacy: .public) ms=\(ms, privacy: .public)")
    }

    func recordFrame(displayID: CGDirectDisplayID,
                     pixelBuffer: CVPixelBuffer,
                     receivedAt: CFAbsoluteTime) {
        guard !isShuttingDown else { return }
        latestFrames[displayID] = StreamFrame(displayID: displayID,
                                              pixelBuffer: pixelBuffer,
                                              receivedAt: receivedAt)
        guard let stream = streams[displayID], !stream.didReceiveFirstFrame else { return }
        stream.didReceiveFirstFrame = true
        let ms = (receivedAt - stream.startedAt) * 1000
        Self.log.info("capture stream first frame display=\(displayID, privacy: .public) ms=\(ms, privacy: .public)")
    }

    func recordIdleFrame(displayID: CGDirectDisplayID, receivedAt: CFAbsoluteTime) {
        guard !isShuttingDown else { return }
        latestIdleHeartbeats[displayID] = receivedAt
        guard let stream = streams[displayID], !stream.didReceiveFirstIdleHeartbeat else { return }
        stream.didReceiveFirstIdleHeartbeat = true
        let ms = (receivedAt - stream.startedAt) * 1000
        Self.log.info("capture stream first idle heartbeat display=\(displayID, privacy: .public) ms=\(ms, privacy: .public)")
    }

    func streamStopped(displayID: CGDirectDisplayID, error: Error) {
        latestFrames.removeValue(forKey: displayID)
        latestIdleHeartbeats.removeValue(forKey: displayID)
        streams.removeValue(forKey: displayID)
        Self.log.error("capture stream stopped display=\(displayID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        scheduleMaintenance(reason: "stream-stopped")
    }

    private func makeFrozenScreen(display: CaptureDisplay,
                                  frame: StreamFrame,
                                  startedAt: CFAbsoluteTime) throws -> FrozenScreen {
        let conversionStartedAt = CFAbsoluteTimeGetCurrent()
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let rect = CGRect(x: 0,
                          y: 0,
                          width: CVPixelBufferGetWidth(frame.pixelBuffer),
                          height: CVPixelBufferGetHeight(frame.pixelBuffer))
        guard let cgImage = ciContext.createCGImage(image, from: rect) else {
            throw CaptureError.captureStackUnavailable("stream frame conversion failed for display \(display.id)")
        }
        let conversionMs = (CFAbsoluteTimeGetCurrent() - conversionStartedAt) * 1000
        let totalMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        Self.log.info("capture freeze display ready source=stream display=\(display.id, privacy: .public) width=\(cgImage.width, privacy: .public) height=\(cgImage.height, privacy: .public) conversionMs=\(conversionMs, privacy: .public) totalMs=\(totalMs, privacy: .public)")
        return FrozenScreen(displayID: display.id,
                            frame: display.frame,
                            scale: display.scale,
                            image: cgImage)
    }

    private func isWarm(display: CaptureDisplay) -> Bool {
        guard let stream = streams[display.id], stream.matches(display), stream.didReceiveFirstFrame else {
            return false
        }
        return latestFrames[display.id] != nil
    }

    private func scheduleMaintenance(reason: String) {
        guard !isShuttingDown else { return }
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            await self?.refreshWarmStreams(reason: reason)
        }
    }

    private func stopAllStreams(reason: String) async {
        let active = streams
        streams.removeAll()
        latestFrames.removeAll()
        latestIdleHeartbeats.removeAll()
        for (displayID, state) in active {
            do {
                try await state.stream.stopCapture()
                Self.log.info("capture stream stopped display=\(displayID, privacy: .public) reason=\(reason, privacy: .public)")
            } catch {
                Self.log.warning("capture stream stop failed display=\(displayID, privacy: .public) reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func stopStream(displayID: CGDirectDisplayID, reason: String) async {
        latestFrames.removeValue(forKey: displayID)
        latestIdleHeartbeats.removeValue(forKey: displayID)
        guard let state = streams.removeValue(forKey: displayID) else { return }
        do {
            try await state.stream.stopCapture()
            Self.log.info("capture stream stopped display=\(displayID, privacy: .public) reason=\(reason, privacy: .public)")
        } catch {
            Self.log.warning("capture stream stop failed display=\(displayID, privacy: .public) reason=\(reason, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    private static func currentDisplays() async -> [CaptureDisplay] {
        await MainActor.run {
            NSScreen.screens.map { screen in
                CaptureDisplay(id: displayID(of: screen),
                               frame: screen.frame,
                               scale: screen.backingScaleFactor)
            }
        }
    }

    private static func streamConfiguration(for display: CaptureDisplay) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(2, Int(display.frame.width * display.scale))
        config.height = max(2, Int(display.frame.height * display.scale))
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = Self.streamQueueDepth
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(Self.streamFrameRate))
        return config
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        CGDirectDisplayID(
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }

#if TESTING
    nonisolated static var debugFreshFrameDeadlineNanoseconds: UInt64 { freshFrameDeadlineNanoseconds }
    nonisolated static var debugStreamFrameRate: Int32 { streamFrameRate }
    nonisolated static var debugHasNoIdleStop: Bool { true }
#endif
}

private final class WarmDisplayStream {
    let display: CaptureDisplay
    let stream: SCStream
    let output: StreamOutput
    let queue: DispatchQueue
    let startedAt: CFAbsoluteTime
    var didReceiveFirstFrame = false
    var didReceiveFirstIdleHeartbeat = false

    init(display: CaptureDisplay,
         stream: SCStream,
         output: StreamOutput,
         queue: DispatchQueue,
         startedAt: CFAbsoluteTime) {
        self.display = display
        self.stream = stream
        self.output = output
        self.queue = queue
        self.startedAt = startedAt
    }

    func matches(_ other: CaptureDisplay) -> Bool {
        display.id == other.id
            && abs(display.frame.width - other.frame.width) < 0.5
            && abs(display.frame.height - other.frame.height) < 0.5
            && abs(display.scale - other.scale) < 0.01
    }
}

private struct StreamFrame {
    let displayID: CGDirectDisplayID
    let pixelBuffer: CVPixelBuffer
    let receivedAt: CFAbsoluteTime
}

private struct FreshStreamFrame {
    let display: CaptureDisplay
    let frame: StreamFrame
    let confirmedAt: CFAbsoluteTime
    let freshness: StreamFrameFreshness
}

private enum StreamFrameFreshness {
    case complete
    case idleHeartbeat
    case latestActiveStream

    var logValue: String {
        switch self {
        case .complete:
            return "complete"
        case .idleHeartbeat:
            return "idle-heartbeat"
        case .latestActiveStream:
            return "latest-active-stream"
        }
    }
}

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let displayID: CGDirectDisplayID
    private weak var owner: ScreenFreezePipeline?

    init(displayID: CGDirectDisplayID, owner: ScreenFreezePipeline) {
        self.displayID = displayID
        self.owner = owner
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue) else {
            return
        }

        let receivedAt = CFAbsoluteTimeGetCurrent()
        if status == .complete, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            Task { [weak owner, displayID] in
                await owner?.recordFrame(displayID: displayID,
                                         pixelBuffer: pixelBuffer,
                                         receivedAt: receivedAt)
            }
        } else if status == .idle {
            Task { [weak owner, displayID] in
                await owner?.recordIdleFrame(displayID: displayID, receivedAt: receivedAt)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { [weak owner, displayID] in
            await owner?.streamStopped(displayID: displayID, error: error)
        }
    }
}
