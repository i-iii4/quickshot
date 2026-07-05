import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import OSLog
import QuartzCore
import ScreenCaptureKit

struct CaptureDisplay {
    let id: CGDirectDisplayID
    let frame: CGRect
}

/// Keeps ScreenCaptureKit streams warm so a hotkey can freeze an already available frame
/// instead of paying screenshot API latency on the user's gesture path.
final class ScreenFrameCache {

    private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")
    private static let validatedFrameMaxPixelAge: TimeInterval = 30.0
    private static let preparedFrozenScreenRetentionAge: TimeInterval = 1.25
    private static let maintenanceRefreshAge: TimeInterval = 3.0
    private static let streamRestartAge: TimeInterval = 30.0
    private static let refreshEscalationDelayNanoseconds: UInt64 = 250_000_000
    private static let streamSnapshotDelayNanoseconds: UInt64 = 450_000_000
    private static let pendingStartupRegistrationWaitNanoseconds: UInt64 = 300_000_000
    private static let streamStartTimeoutNanoseconds: UInt64 = 2_000_000_000
    private static let rectSnapshotTimeoutNanoseconds: UInt64 = 650_000_000
    private static let rectSnapshotProbeJoinNanoseconds: UInt64 = 120_000_000
    private static let shareableDisplayFailureCooldown: TimeInterval = 8.0
    private static let rectSnapshotFailureCooldown: TimeInterval = 8.0

    private struct CachedFrame {
        let frame: CGRect
        let pixelBuffer: CVPixelBuffer
        let scale: CGFloat
        let updatedAt: TimeInterval
        let validatedAt: TimeInterval
    }

    private enum CachedFrameAcceptance: String {
        case postRequest = "post-request"
    }

    private struct PreparedFrozenScreen {
        let frozen: FrozenScreen
        let updatedAt: TimeInterval
    }

    private enum RefreshPriority: Int {
        case idle = 0
        case maintenance = 1
        case capture = 2
    }

    private struct RefreshRequest {
        let id: UUID
        let priority: RefreshPriority
    }

    private struct StreamStartTimeout: Error, CustomStringConvertible {
        let displayID: CGDirectDisplayID
        var description: String { "stream start timed out for display \(displayID)" }
    }

    private struct RectSnapshotTimeout: Error, CustomStringConvertible {
        var description: String { "rect snapshot timed out" }
    }

    private struct CaptureStackFailure {
        let reason: String
        let updatedAt: TimeInterval
    }

    private struct ShareableDisplayFailure {
        let reason: StartUnavailableReason
        let updatedAt: TimeInterval
    }

    private enum RectSnapshotRecoveryGate {
        case ready
        case recentFailure(CaptureStackFailure)
        case probeInFlight
    }

    enum StartUnavailableReason: CustomStringConvertible {
        case cacheShutdown
        case screenCapturePermissionDenied
        case shareableContentFailed(String)
        case shareableContentHasNoDisplays
        case appExclusionUnavailable
        case noStreamCandidates
        case streamStartupUnavailable
        case cacheUnavailable
        case startupWaitCancelled
        case pendingStartupFinishedWithoutUsableCache
        case pendingStartupDidNotBecomeReady

        var description: String {
            switch self {
            case .cacheShutdown:
                return "cache shutdown"
            case .screenCapturePermissionDenied:
                return "screen capture permission denied"
            case .shareableContentFailed(let details):
                return "shareable content failed: \(details)"
            case .shareableContentHasNoDisplays:
                return "shareable content has no displays"
            case .appExclusionUnavailable:
                return "app exclusion unavailable"
            case .noStreamCandidates:
                return "no stream candidates"
            case .streamStartupUnavailable:
                return "stream startup unavailable"
            case .cacheUnavailable:
                return "cache unavailable"
            case .startupWaitCancelled:
                return "startup wait cancelled"
            case .pendingStartupFinishedWithoutUsableCache:
                return "pending startup finished without usable cache"
            case .pendingStartupDidNotBecomeReady:
                return "pending startup did not become ready"
            }
        }
    }

    enum StartResult {
        case usable
        case unavailable(StartUnavailableReason)

        var isUsable: Bool {
            switch self {
            case .usable:
                return true
            case .unavailable:
                return false
            }
        }

        var unavailableReason: String {
            switch self {
            case .usable:
                return ""
            case .unavailable(let reason):
                return reason.description
            }
        }
    }

    private let lock = NSLock()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var streams: [CGDirectDisplayID: CachedDisplayStream] = [:]
    private var frames: [CGDirectDisplayID: CachedFrame] = [:]
    private var preparedFrozenScreens: [CGDirectDisplayID: PreparedFrozenScreen] = [:]
    private var priorityDisplays: Set<CGDirectDisplayID> = []
    private var refreshInFlight: [CGDirectDisplayID: RefreshRequest] = [:]
    private var ageMonitors: Set<CGDirectDisplayID> = []
    private var startingDisplays: Set<CGDirectDisplayID> = []
    private var startedDisplays: Set<CGDirectDisplayID> = []
    private var recentShareableDisplayFailure: ShareableDisplayFailure?
    private var recentRectSnapshotFailure: CaptureStackFailure?
    private var rectSnapshotProbeInFlight = false
    private var restartBundleIdentifier: String?
    private var isShuttingDown = false

    @discardableResult
    func start(displays: [CaptureDisplay], excludingBundleIdentifier bundleID: String?) async -> StartResult {
        guard !isShutdown else { return .unavailable(.cacheShutdown) }
        guard CGPreflightScreenCaptureAccess() else { return .unavailable(.screenCapturePermissionDenied) }
        rememberRestartBundleIdentifier(bundleID)
        let displaysToStart = beginStarting(displays)
        guard !displaysToStart.isEmpty else {
            return await waitForUsableCacheOrFinishedStartup(for: displays)
        }
        defer { finishStarting(displaysToStart) }

        Self.log.info("capture cache start requested displays=\(displaysToStart.map { String($0.id) }.joined(separator: ","), privacy: .public)")
        if let failure = recentShareableDisplayFailure(for: displaysToStart) {
            return startResult(for: displays, unavailableReason: failure.reason)
        }

        let content: SCShareableContent
        let contentStartedAt = CFAbsoluteTimeGetCurrent()
        do {
            content = try await Self.loadShareableContent()
            let contentMs = (CFAbsoluteTimeGetCurrent() - contentStartedAt) * 1000
            Self.log.info("capture cache shareable content ready ms=\(contentMs, privacy: .public)")
            Self.log.info("capture cache shareable displays=\(content.displays.map { String($0.displayID) }.joined(separator: ","), privacy: .public)")
            if !content.displays.isEmpty {
                clearShareableDisplayFailure()
                clearRectSnapshotFailure()
            } else {
                recordShareableDisplayFailure(.shareableContentHasNoDisplays)
            }
        } catch {
            Self.log.error("capture cache shareable content failed: \(String(describing: error), privacy: .public)")
            let reason = StartUnavailableReason.shareableContentFailed(String(describing: error))
            recordShareableDisplayFailure(reason)
            return startResult(for: displays, unavailableReason: reason)
        }
        guard !isShutdown else { return .unavailable(.cacheShutdown) }

        let excludedApps: [SCRunningApplication]
        if let bundleID {
            excludedApps = content.applications.filter { $0.bundleIdentifier == bundleID }
            guard !excludedApps.isEmpty else {
                Self.log.error("capture cache cannot find app exclusion for \(bundleID, privacy: .public); stream cache disabled")
                return startResult(for: displays, unavailableReason: .appExclusionUnavailable)
            }
        } else {
            excludedApps = []
        }

        let scDisplays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        let orderedDisplays = displaysToStart.sorted { lhs, rhs in
            priorityRank(for: lhs.id) < priorityRank(for: rhs.id)
        }

        let pendingStreams: [(display: CaptureDisplay, stream: CachedDisplayStream)] = orderedDisplays.compactMap { display in
            if hasStream(for: display.id) { return nil }
            guard let scDisplay = scDisplays[display.id] else {
                Self.log.error("capture cache display missing display=\(display.id, privacy: .public)")
                return nil
            }
            do {
                let cached = try CachedDisplayStream(
                    display: display,
                    scDisplay: scDisplay,
                    excludedApps: excludedApps,
                    onFrame: { [weak self] streamID, displayID, frame, scale, pixelBuffer in
                        self?.storeFrame(streamID: streamID,
                                         displayID: displayID,
                                         frame: frame,
                                         scale: scale,
                                         pixelBuffer: pixelBuffer)
                    })
                return (display, cached)
            } catch {
                Self.log.error("capture cache stream create failed display=\(display.id, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        if pendingStreams.isEmpty {
            Self.log.warning("capture cache no stream candidates requested=\(orderedDisplays.map { String($0.id) }.joined(separator: ","), privacy: .public) available=\(content.displays.map { String($0.displayID) }.joined(separator: ","), privacy: .public)")
            if content.displays.isEmpty, let probeDisplay = orderedDisplays.first {
                scheduleRectSnapshotProbe(for: probeDisplay, reason: "shareable displays unavailable")
            }
        }

        let registeredStreams = pendingStreams.filter { pending in
            registerStream(pending.stream, for: pending.display.id)
        }
        if registeredStreams.isEmpty, !pendingStreams.isEmpty {
            Self.log.warning("capture cache no streams registered requested=\(orderedDisplays.map { String($0.id) }.joined(separator: ","), privacy: .public)")
        }
        guard !registeredStreams.isEmpty else {
            let reason: StartUnavailableReason = content.displays.isEmpty ? .shareableContentHasNoDisplays : .noStreamCandidates
            return startResult(for: displays, unavailableReason: reason)
        }

        await withTaskGroup(of: Void.self) { group in
            for pending in registeredStreams {
                group.addTask {
                    guard self.shouldStartRegisteredStream(pending.stream, for: pending.display.id) else { return }
                    do {
                        Self.log.info("capture cache stream starting display=\(pending.display.id, privacy: .public)")
                        try await Self.startStream(pending.stream, display: pending.display)
                        guard self.shouldKeepStartedStream(pending.stream, for: pending.display.id) else {
                            await pending.stream.stop(reason: "shutdown after start")
                            return
                        }
                        guard self.markStreamStarted(pending.stream, for: pending.display.id) else {
                            await pending.stream.stop(reason: "superseded after start")
                            return
                        }
                        Self.log.info("capture cache stream started display=\(pending.display.id, privacy: .public)")
                    } catch {
                        self.removeStream(for: pending.display.id, reason: "start failed")
                        Self.log.error("capture cache stream start failed display=\(pending.display.id, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
        return startResult(for: displays, unavailableReason: .streamStartupUnavailable)
    }

    private static func loadShareableContent() async throws -> SCShareableContent {
        // Prefer the broad listing so the LSUIElement menu-bar process is still available for
        // ScreenCaptureKit app exclusion when no QuickShot window is visible.
        let full = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        if !full.displays.isEmpty {
            return full
        }
        Self.log.warning("capture cache shareable content had no displays; retrying on-screen listing")
        let onScreen = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        if !onScreen.displays.isEmpty {
            return onScreen
        }
        Self.log.warning("capture cache on-screen shareable content had no displays; retrying desktop-excluded listing")
        let desktopExcluded = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        if !desktopExcluded.displays.isEmpty {
            return desktopExcluded
        }
        Self.log.warning("capture cache desktop-excluded shareable content had no displays; retrying current-process listing")
        let currentProcess = try await SCShareableContent.currentProcess
        if !currentProcess.displays.isEmpty {
            return currentProcess
        }
        Self.log.warning("capture cache current-process shareable content had no displays; retrying current listing")
        return try await SCShareableContent.current
    }

    private static func startStream(_ stream: CachedDisplayStream, display: CaptureDisplay) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await stream.start()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: streamStartTimeoutNanoseconds)
                throw StreamStartTimeout(displayID: display.id)
            }
            do {
                _ = try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private static func captureRectScreenshot(rect: CGRect,
                                              configuration: SCScreenshotConfiguration) async throws -> SCScreenshotOutput {
        try await withThrowingTaskGroup(of: SCScreenshotOutput.self) { group in
            group.addTask {
                try await SCScreenshotManager.captureScreenshot(rect: rect, configuration: configuration)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: rectSnapshotTimeoutNanoseconds)
                throw RectSnapshotTimeout()
            }
            do {
                guard let output = try await group.next() else {
                    group.cancelAll()
                    throw RectSnapshotTimeout()
                }
                group.cancelAll()
                return output
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func prioritize(display: CaptureDisplay) {
        lock.lock()
        guard !isShuttingDown else {
            lock.unlock()
            return
        }
        priorityDisplays.insert(display.id)
        lock.unlock()
        Self.log.info("capture cache priority display=\(display.id, privacy: .public)")
    }

    func shutdown() {
        let streamsToStop: [CachedDisplayStream]

        lock.lock()
        isShuttingDown = true
        streamsToStop = Array(streams.values)
        streams.removeAll()
        frames.removeAll()
        preparedFrozenScreens.removeAll()
        priorityDisplays.removeAll()
        refreshInFlight.removeAll()
        ageMonitors.removeAll()
        startingDisplays.removeAll()
        startedDisplays.removeAll()
        recentShareableDisplayFailure = nil
        recentRectSnapshotFailure = nil
        rectSnapshotProbeInFlight = false
        restartBundleIdentifier = nil
        lock.unlock()

        for stream in streamsToStop {
            Task { await stream.stop(reason: "shutdown") }
        }
        Self.log.info("capture cache shutdown streams=\(streamsToStop.count, privacy: .public)")
    }

    func prepareForNextCapture(display: CaptureDisplay) {
        guard !isShutdown else { return }
        let requestedAt = Self.now
        Self.log.info("capture cache post-capture prepare display=\(display.id, privacy: .public)")

        requestFreshFrame(for: display,
                          requestedAt: requestedAt,
                          reason: "post-capture prewarm",
                          allowsStreamRestart: false)
    }

    static var captureClock: TimeInterval { now }

    func waitForFrozenScreen(for display: CaptureDisplay,
                             requestedAt: TimeInterval,
                             timeoutNanoseconds: UInt64) async -> FrozenScreen? {
        if let frozen = cachedFrozenScreen(for: display, requestedAt: requestedAt, requestFreshIfStale: true) {
            return frozen
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        var didStartSnapshotFallback = false

        while DispatchTime.now().uptimeNanoseconds - startedAt < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if Task.isCancelled { return nil }
            if let frozen = cachedFrozenScreen(for: display,
                                               requestedAt: requestedAt,
                                               requestFreshIfStale: false) {
                return frozen
            }

            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            if !didStartSnapshotFallback && elapsed >= Self.streamSnapshotDelayNanoseconds {
                didStartSnapshotFallback = true
                Self.log.info("capture cache stream frame still pending display=\(display.id, privacy: .public); starting nonblocking snapshot fallback")
                startSnapshotFallback(for: display,
                                      requestedAt: requestedAt,
                                      reason: "capture requires fresh frame")
            }
        }

        return nil
    }

    func rectSnapshotFrozenScreen(for display: CaptureDisplay, reason: String) async -> FrozenScreen? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard await shouldAttemptRectSnapshotRecovery(for: display, reason: reason) else { return nil }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let config = SCScreenshotConfiguration()
        config.showsCursor = false
        config.displayIntent = .local
        config.dynamicRange = .sdr

        do {
            let output = try await Self.captureRectScreenshot(rect: display.frame, configuration: config)
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            guard let image = output.sdrImage ?? output.hdrImage else {
                Self.log.error("capture cache rect snapshot missing image display=\(display.id, privacy: .public) reason=\(reason, privacy: .public) ms=\(ms, privacy: .public)")
                recordRectSnapshotFailure("missing image")
                return nil
            }
            let scale = max(1, CGFloat(image.width) / max(1, display.frame.width))
            clearRectSnapshotFailure()
            Self.log.info("capture cache rect snapshot display=\(display.id, privacy: .public) reason=\(reason, privacy: .public) ms=\(ms, privacy: .public)")
            return FrozenScreen(displayID: display.id, frame: display.frame, scale: scale, image: image)
        } catch {
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            Self.log.error("capture cache rect snapshot failed display=\(display.id, privacy: .public) reason=\(reason, privacy: .public) ms=\(ms, privacy: .public): \(String(describing: error), privacy: .public)")
            recordRectSnapshotFailure(String(describing: error))
            return nil
        }
    }

    func isPreparingFrame(for display: CaptureDisplay) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return startingDisplays.contains(display.id)
            || (streams[display.id] != nil && !startedDisplays.contains(display.id))
            || (startedDisplays.contains(display.id) && frames[display.id] == nil)
    }

    private func cachedFrozenScreen(for display: CaptureDisplay,
                                    requestedAt: TimeInterval,
                                    requestFreshIfStale: Bool = true) -> FrozenScreen? {
        let cached: CachedFrame?
        let prepared: PreparedFrozenScreen?
        let age: TimeInterval
        let validationAge: TimeInterval
        let preparedAge: TimeInterval
        let now = Self.now
        lock.lock()
        cached = frames[display.id]
        prepared = preparedFrozenScreens[display.id]
        age = cached.map { Self.frameAge(updatedAt: $0.updatedAt, now: now) } ?? 0
        validationAge = cached.map { Self.frameAge(updatedAt: $0.validatedAt, now: now) } ?? 0
        preparedAge = prepared.map { Self.frameAge(updatedAt: $0.updatedAt, now: now) } ?? 0
        lock.unlock()

        if let cached,
           let acceptance = Self.cachedFrameAcceptance(updatedAt: cached.updatedAt,
                                                       requestedAt: requestedAt) {
            let requestDelta = max(0, requestedAt - cached.updatedAt)
            Self.log.info("capture cache frame accepted display=\(display.id, privacy: .public) source=\(acceptance.rawValue, privacy: .public) ageMs=\(age * 1000, privacy: .public) validationAgeMs=\(validationAge * 1000, privacy: .public) requestDeltaMs=\(requestDelta * 1000, privacy: .public)")
            let width = CVPixelBufferGetWidth(cached.pixelBuffer)
            let height = CVPixelBufferGetHeight(cached.pixelBuffer)
            let image = CIImage(cvPixelBuffer: cached.pixelBuffer)
            guard let cgImage = ciContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
                return nil
            }

            return FrozenScreen(displayID: display.id, frame: cached.frame, scale: cached.scale, image: cgImage)
        }

        if let prepared,
           Self.shouldServePreparedFrozenScreen(updatedAt: prepared.updatedAt, requestedAt: requestedAt, now: now) {
            Self.log.info("capture cache prepared image accepted display=\(display.id, privacy: .public) ageMs=\(preparedAge * 1000, privacy: .public)")
            return prepared.frozen
        }

        guard cached != nil || prepared != nil else { return nil }

        if cached != nil || prepared != nil {
            if requestFreshIfStale {
                let newestUpdate = max(cached?.updatedAt ?? 0, prepared?.updatedAt ?? 0)
                let requestDelta = max(0, requestedAt - newestUpdate)
                Self.log.warning("capture cache old frame rejected display=\(display.id, privacy: .public) ageMs=\(age * 1000, privacy: .public) requestDeltaMs=\(requestDelta * 1000, privacy: .public) requiredSource=post-request; requesting fresh frame")
                requestFreshFrame(for: display,
                                  requestedAt: requestedAt,
                                  reason: "capture requires fresh frame",
                                  allowsStreamRestart: true)
            }
            return nil
        }

        return nil
    }

    private func storeFrame(streamID: UUID,
                            displayID: CGDirectDisplayID,
                            frame: CGRect,
                            scale: CGFloat,
                            pixelBuffer: CVPixelBuffer) {
        lock.lock()
        guard !isShuttingDown,
              streams[displayID]?.id == streamID else {
            lock.unlock()
            return
        }
        let now = Self.now
        frames[displayID] = CachedFrame(frame: frame,
                                        pixelBuffer: pixelBuffer,
                                        scale: scale,
                                        updatedAt: now,
                                        validatedAt: now)
        preparedFrozenScreens.removeValue(forKey: displayID)
        lock.unlock()
        scheduleAgeMonitor(for: CaptureDisplay(id: displayID, frame: frame))
    }

    private func storePreparedFrozenScreen(_ frozen: FrozenScreen, reason: String) -> PreparedFrozenScreen {
        let now = Self.now
        let prepared = PreparedFrozenScreen(frozen: frozen, updatedAt: now)
        lock.lock()
        guard !isShuttingDown else {
            lock.unlock()
            return prepared
        }
        preparedFrozenScreens[frozen.displayID] = prepared
        lock.unlock()
        Self.log.info("capture cache prepared image stored display=\(frozen.displayID, privacy: .public) reason=\(reason, privacy: .public)")
        schedulePreparedFrozenScreenExpiration(displayID: frozen.displayID, updatedAt: now)
        scheduleAgeMonitor(for: CaptureDisplay(id: frozen.displayID, frame: frozen.frame))
        return prepared
    }

    private func rememberRestartBundleIdentifier(_ bundleID: String?) {
        guard let bundleID else { return }
        lock.lock()
        restartBundleIdentifier = bundleID
        lock.unlock()
    }

    private func hasStream(for displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return streams[displayID] != nil
    }

    private func hasUsableCache(for displays: [CaptureDisplay]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return displays.contains { display in
            startedDisplays.contains(display.id)
                || frames[display.id] != nil
                || preparedFrozenScreens[display.id] != nil
        }
    }

    private func hasPendingStartup(for displays: [CaptureDisplay]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return displays.contains { startingDisplays.contains($0.id) }
    }

    private func startResult(for displays: [CaptureDisplay], unavailableReason: StartUnavailableReason) -> StartResult {
        hasUsableCache(for: displays) ? .usable : .unavailable(unavailableReason)
    }

    private func waitForUsableCacheOrFinishedStartup(for displays: [CaptureDisplay]) async -> StartResult {
        if hasUsableCache(for: displays) { return .usable }
        guard hasPendingStartup(for: displays) else { return .unavailable(.cacheUnavailable) }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - startedAt < Self.pendingStartupRegistrationWaitNanoseconds {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if Task.isCancelled { return .unavailable(.startupWaitCancelled) }
            if isShutdown { return .unavailable(.cacheShutdown) }
            if hasUsableCache(for: displays) {
                Self.log.info("capture cache pending startup became usable displays=\(displays.map { String($0.id) }.joined(separator: ","), privacy: .public)")
                return .usable
            }
            if !hasPendingStartup(for: displays) {
                return startResult(for: displays, unavailableReason: .pendingStartupFinishedWithoutUsableCache)
            }
        }

        Self.log.warning("capture cache pending startup did not become ready before short wait displays=\(displays.map { String($0.id) }.joined(separator: ","), privacy: .public)")
        return startResult(for: displays, unavailableReason: .pendingStartupDidNotBecomeReady)
    }

    private func beginStarting(_ displays: [CaptureDisplay]) -> [CaptureDisplay] {
        lock.lock()
        defer { lock.unlock() }
        guard !isShuttingDown else { return [] }
        var pending: [CaptureDisplay] = []
        for display in displays where streams[display.id] == nil && !startingDisplays.contains(display.id) {
            startingDisplays.insert(display.id)
            pending.append(display)
        }
        return pending
    }

    private func finishStarting(_ displays: [CaptureDisplay]) {
        lock.lock()
        for display in displays {
            startingDisplays.remove(display.id)
        }
        lock.unlock()
    }

    private func registerStream(_ stream: CachedDisplayStream, for displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isShuttingDown else { return false }
        streams[displayID] = stream
        startedDisplays.remove(displayID)
        priorityDisplays.remove(displayID)
        return true
    }

    private func shouldStartRegisteredStream(_ stream: CachedDisplayStream, for displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isShuttingDown && streams[displayID]?.id == stream.id
    }

    private func shouldKeepStartedStream(_ stream: CachedDisplayStream, for displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isShuttingDown && streams[displayID]?.id == stream.id
    }

    private func markStreamStarted(_ stream: CachedDisplayStream, for displayID: CGDirectDisplayID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isShuttingDown,
              streams[displayID]?.id == stream.id else { return false }
        startedDisplays.insert(displayID)
        return true
    }

    private func removeStream(for displayID: CGDirectDisplayID, reason: String, dropFrame: Bool = true) {
        let stream: CachedDisplayStream?
        lock.lock()
        stream = streams.removeValue(forKey: displayID)
        startedDisplays.remove(displayID)
        if dropFrame {
            frames.removeValue(forKey: displayID)
            preparedFrozenScreens.removeValue(forKey: displayID)
        }
        lock.unlock()

        if let stream {
            Task { await stream.stop(reason: reason) }
        }
    }

    private func requestFreshFrame(for display: CaptureDisplay,
                                   requestedAt: TimeInterval,
                                   reason: String,
                                   allowsStreamRestart: Bool) {
        let priority: RefreshPriority = allowsStreamRestart ? .capture : .idle
        guard let refreshID = beginRefresh(for: display.id, priority: priority, reason: reason) else { return }
        let stream = currentStream(for: display.id)
        Task.detached(priority: Self.taskPriority(for: priority)) { [weak self] in
            guard let self else { return }
            defer {
                self.endRefresh(for: display.id, refreshID: refreshID)
                self.scheduleAgeMonitor(for: display)
            }

            if let stream {
                let didValidateStream = await stream.requestFrame(reason: reason)
                guard !self.isShutdown else { return }
                try? await Task.sleep(nanoseconds: Self.refreshEscalationDelayNanoseconds)
                guard !self.isShutdown else { return }
                if self.hasFrameUpdated(for: display.id, since: requestedAt) {
                    return
                }
                if didValidateStream {
                    if self.canValidateStaticFrame(for: display.id) {
                        self.markFrameValidated(for: display.id, streamID: stream.id)
                        Self.log.info("capture cache fresh frame request validated static frame display=\(display.id, privacy: .public) reason=\(reason, privacy: .public)")
                        return
                    }
                    Self.log.warning("capture cache fresh frame request skipped static validation display=\(display.id, privacy: .public) reason=\(reason, privacy: .public)")
                }
                if !allowsStreamRestart {
                    Self.log.info("capture cache fresh frame request stayed soft display=\(display.id, privacy: .public) reason=\(reason, privacy: .public)")
                    return
                }
                guard self.isCurrentRefresh(for: display.id, refreshID: refreshID) else {
                    Self.log.info("capture cache fresh frame request superseded display=\(display.id, privacy: .public) reason=\(reason, privacy: .public)")
                    return
                }
                Self.log.warning("capture cache fresh frame request escalating display=\(display.id, privacy: .public) reason=\(reason, privacy: .public)")
            }

            self.removeStream(for: display.id, reason: reason, dropFrame: false)
            guard !self.isShutdown else { return }
            await self.start(displays: [display], excludingBundleIdentifier: self.bundleIdentifierForRestart())
        }
    }

    private static func taskPriority(for refreshPriority: RefreshPriority) -> TaskPriority {
        switch refreshPriority {
        case .capture:
            return .userInitiated
        case .maintenance, .idle:
            return .utility
        }
    }

    private func refreshStreamInBackground(for display: CaptureDisplay, reason: String) {
        guard let refreshID = beginRefresh(for: display.id, priority: .maintenance, reason: reason) else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.endRefresh(for: display.id, refreshID: refreshID)
                self.scheduleAgeMonitor(for: display)
            }
            guard self.isCurrentRefresh(for: display.id, refreshID: refreshID) else {
                Self.log.info("capture cache maintenance refresh superseded display=\(display.id, privacy: .public) reason=\(reason, privacy: .public)")
                return
            }
            self.removeStream(for: display.id, reason: reason, dropFrame: false)
            guard !self.isShutdown else { return }
            await self.start(displays: [display], excludingBundleIdentifier: self.bundleIdentifierForRestart())
        }
    }

    private func currentStream(for displayID: CGDirectDisplayID) -> CachedDisplayStream? {
        lock.lock()
        let stream = streams[displayID]
        lock.unlock()
        return stream
    }

    private func hasFrameUpdated(for displayID: CGDirectDisplayID, since requestedAt: TimeInterval) -> Bool {
        lock.lock()
        let updatedAt = frames[displayID]?.updatedAt
        lock.unlock()
        guard let updatedAt else { return false }
        return updatedAt >= requestedAt
    }

    private func canValidateStaticFrame(for displayID: CGDirectDisplayID) -> Bool {
        let now = Self.now
        lock.lock()
        let updatedAt = frames[displayID]?.updatedAt
        lock.unlock()
        guard let updatedAt else { return false }
        return Self.shouldValidateStaticFrame(updatedAt: updatedAt, now: now)
    }

    private func markFrameValidated(for displayID: CGDirectDisplayID, streamID: UUID) {
        let now = Self.now
        lock.lock()
        if streams[displayID]?.id == streamID,
           let cached = frames[displayID] {
            frames[displayID] = CachedFrame(frame: cached.frame,
                                            pixelBuffer: cached.pixelBuffer,
                                            scale: cached.scale,
                                            updatedAt: cached.updatedAt,
                                            validatedAt: now)
        }
        lock.unlock()
    }

    private func beginRefresh(for displayID: CGDirectDisplayID,
                              priority: RefreshPriority,
                              reason: String) -> UUID? {
        let refreshID = UUID()
        lock.lock()
        defer { lock.unlock() }
        guard !isShuttingDown else { return nil }
        if let current = refreshInFlight[displayID] {
            guard priority.rawValue > current.priority.rawValue else {
                return nil
            }
            Self.log.info("capture cache refresh superseding display=\(displayID, privacy: .public) reason=\(reason, privacy: .public)")
        }
        refreshInFlight[displayID] = RefreshRequest(id: refreshID, priority: priority)
        return refreshID
    }

    private func endRefresh(for displayID: CGDirectDisplayID, refreshID: UUID) {
        lock.lock()
        if refreshInFlight[displayID]?.id == refreshID {
            refreshInFlight.removeValue(forKey: displayID)
        }
        lock.unlock()
    }

    private func isCurrentRefresh(for displayID: CGDirectDisplayID, refreshID: UUID) -> Bool {
        lock.lock()
        let isCurrent = refreshInFlight[displayID]?.id == refreshID
        lock.unlock()
        return isCurrent
    }

    private func bundleIdentifierForRestart() -> String? {
        lock.lock()
        let bundleID = restartBundleIdentifier
        lock.unlock()
        return bundleID ?? Bundle.main.bundleIdentifier
    }

    private func recentShareableDisplayFailure(for displays: [CaptureDisplay]) -> ShareableDisplayFailure? {
        let now = Self.now
        lock.lock()
        if let existing = recentShareableDisplayFailure,
           !Self.hasRecentShareableDisplayFailure(updatedAt: existing.updatedAt, now: now) {
            recentShareableDisplayFailure = nil
        }
        let failure = recentShareableDisplayFailure
        lock.unlock()

        guard let failure else { return nil }
        let ageMs = Self.frameAge(updatedAt: failure.updatedAt, now: now) * 1000
        Self.log.warning("capture cache shareable content skipped displays=\(displays.map { String($0.id) }.joined(separator: ","), privacy: .public) previousFailure=\(failure.reason.description, privacy: .public) ageMs=\(ageMs, privacy: .public)")
        return failure
    }

    private func recordShareableDisplayFailure(_ reason: StartUnavailableReason) {
        lock.lock()
        guard !isShuttingDown else {
            lock.unlock()
            return
        }
        recentShareableDisplayFailure = ShareableDisplayFailure(reason: reason, updatedAt: Self.now)
        lock.unlock()
    }

    private func clearShareableDisplayFailure() {
        lock.lock()
        let hadFailure = recentShareableDisplayFailure != nil
        recentShareableDisplayFailure = nil
        lock.unlock()
        if hadFailure {
            Self.log.info("capture cache shareable content failure cleared")
        }
    }

    private func shouldAttemptRectSnapshotRecovery(for display: CaptureDisplay, reason: String) async -> Bool {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var didLogJoin = false

        while true {
            switch rectSnapshotRecoveryGate(now: Self.now) {
            case .ready:
                return true
            case .recentFailure(let failure):
                let ageMs = Self.frameAge(updatedAt: failure.updatedAt, now: Self.now) * 1000
                Self.log.warning("capture cache rect snapshot skipped display=\(display.id, privacy: .public) reason=\(reason, privacy: .public) previousFailure=\(failure.reason, privacy: .public) ageMs=\(ageMs, privacy: .public)")
                return false
            case .probeInFlight:
                let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
                guard elapsed < Self.rectSnapshotProbeJoinNanoseconds else {
                    let elapsedMs = Double(elapsed) / 1_000_000
                    Self.log.warning("capture cache rect snapshot skipped display=\(display.id, privacy: .public) reason=\(reason, privacy: .public) previousFailure=probe-in-flight ageMs=\(elapsedMs, privacy: .public)")
                    return false
                }
                if !didLogJoin {
                    didLogJoin = true
                    Self.log.info("capture cache rect snapshot waiting for probe display=\(display.id, privacy: .public) reason=\(reason, privacy: .public)")
                }
                try? await Task.sleep(nanoseconds: 10_000_000)
                if Task.isCancelled { return false }
            }
        }
    }

    private func rectSnapshotRecoveryGate(now: TimeInterval) -> RectSnapshotRecoveryGate {
        lock.lock()
        defer { lock.unlock() }
        if let existing = recentRectSnapshotFailure,
           !Self.hasRecentRectSnapshotFailure(updatedAt: existing.updatedAt, now: now) {
            recentRectSnapshotFailure = nil
        }
        if let failure = recentRectSnapshotFailure {
            return .recentFailure(failure)
        }
        if rectSnapshotProbeInFlight {
            return .probeInFlight
        }
        return .ready
    }

    private func recordRectSnapshotFailure(_ reason: String) {
        lock.lock()
        guard !isShuttingDown else {
            lock.unlock()
            return
        }
        recentRectSnapshotFailure = CaptureStackFailure(reason: reason, updatedAt: Self.now)
        lock.unlock()
    }

    private func clearRectSnapshotFailure() {
        lock.lock()
        let hadFailure = recentRectSnapshotFailure != nil
        recentRectSnapshotFailure = nil
        lock.unlock()
        if hadFailure {
            Self.log.info("capture cache rect snapshot failure cleared")
        }
    }

    private func scheduleRectSnapshotProbe(for display: CaptureDisplay, reason: String) {
        guard beginRectSnapshotProbe() else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.finishRectSnapshotProbe() }
            guard !self.isShutdown else { return }
            await self.probeRectSnapshotRecovery(for: display, reason: reason)
        }
    }

    private func beginRectSnapshotProbe() -> Bool {
        let now = Self.now
        lock.lock()
        defer { lock.unlock() }
        guard !isShuttingDown, !rectSnapshotProbeInFlight else { return false }
        if let failure = recentRectSnapshotFailure {
            if Self.hasRecentRectSnapshotFailure(updatedAt: failure.updatedAt, now: now) {
                return false
            }
            recentRectSnapshotFailure = nil
        }
        rectSnapshotProbeInFlight = true
        return true
    }

    private func finishRectSnapshotProbe() {
        lock.lock()
        rectSnapshotProbeInFlight = false
        lock.unlock()
    }

    private func probeRectSnapshotRecovery(for display: CaptureDisplay, reason: String) async {
        guard CGPreflightScreenCaptureAccess() else { return }
        let rect = CGRect(x: display.frame.midX, y: display.frame.midY, width: 16, height: 16)
        let startedAt = CFAbsoluteTimeGetCurrent()
        let config = SCScreenshotConfiguration()
        config.showsCursor = false
        config.displayIntent = .local
        config.dynamicRange = .sdr

        do {
            let output = try await Self.captureRectScreenshot(rect: rect, configuration: config)
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            guard output.sdrImage != nil || output.hdrImage != nil else {
                Self.log.error("capture cache rect snapshot probe missing image display=\(display.id, privacy: .public) reason=\(reason, privacy: .public) ms=\(ms, privacy: .public)")
                recordRectSnapshotFailure("probe missing image")
                return
            }
            clearRectSnapshotFailure()
            Self.log.info("capture cache rect snapshot probe ok display=\(display.id, privacy: .public) reason=\(reason, privacy: .public) ms=\(ms, privacy: .public)")
        } catch {
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            Self.log.error("capture cache rect snapshot probe failed display=\(display.id, privacy: .public) reason=\(reason, privacy: .public) ms=\(ms, privacy: .public): \(String(describing: error), privacy: .public)")
            recordRectSnapshotFailure("probe \(String(describing: error))")
        }
    }

    private var isShutdown: Bool {
        lock.lock()
        let value = isShuttingDown
        lock.unlock()
        return value
    }

    private func streamSnapshotFrozenScreen(for display: CaptureDisplay,
                                            reason: String = "capture requires fresh frame") async -> FrozenScreen? {
        guard CGPreflightScreenCaptureAccess(),
              let stream = currentStream(for: display.id),
              let snapshot = await stream.captureSnapshot(reason: reason) else {
            return nil
        }
        return FrozenScreen(displayID: display.id, frame: display.frame, scale: snapshot.scale, image: snapshot.image)
    }

    private func startSnapshotFallback(for display: CaptureDisplay,
                                       requestedAt: TimeInterval,
                                       reason: String) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self, !self.isShutdown else { return }
            if self.hasFrameUpdated(for: display.id, since: requestedAt) { return }
            guard let frozen = await self.streamSnapshotFrozenScreen(for: display, reason: reason) else { return }
            guard !Task.isCancelled,
                  !self.isShutdown,
                  !self.hasFrameUpdated(for: display.id, since: requestedAt) else { return }
            _ = self.storePreparedFrozenScreen(frozen, reason: reason)
        }
    }

    private func scheduleAgeMonitor(for display: CaptureDisplay) {
        lock.lock()
        if isShuttingDown || ageMonitors.contains(display.id) {
            lock.unlock()
            return
        }
        ageMonitors.insert(display.id)
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            let nanoseconds = UInt64(Self.maintenanceRefreshAge * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.handleAgeMonitor(for: display)
        }
    }

    private func schedulePreparedFrozenScreenExpiration(displayID: CGDirectDisplayID, updatedAt: TimeInterval) {
        guard !isShutdown else { return }
        Task.detached(priority: .utility) { [weak self] in
            let nanoseconds = UInt64(Self.preparedFrozenScreenRetentionAge * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, self?.isShutdown != true else { return }
            self?.expirePreparedFrozenScreen(displayID: displayID, updatedAt: updatedAt)
        }
    }

    private func expirePreparedFrozenScreen(displayID: CGDirectDisplayID, updatedAt: TimeInterval) {
        let now = Self.now
        var didExpire = false
        lock.lock()
        if let prepared = preparedFrozenScreens[displayID],
           prepared.updatedAt == updatedAt,
           Self.shouldExpirePreparedFrozenScreen(updatedAt: prepared.updatedAt, now: now) {
            preparedFrozenScreens.removeValue(forKey: displayID)
            didExpire = true
        }
        lock.unlock()
        if didExpire {
            Self.log.info("capture cache prepared image expired display=\(displayID, privacy: .public)")
        }
    }

    private func handleAgeMonitor(for display: CaptureDisplay) {
        let cached: CachedFrame?
        let prepared: PreparedFrozenScreen?
        let age: TimeInterval
        let validationAge: TimeInterval
        var didExpirePrepared = false

        lock.lock()
        cached = frames[display.id]
        prepared = preparedFrozenScreens[display.id]
        age = cached.map { Self.frameAge(updatedAt: $0.updatedAt, now: Self.now) } ?? 0
        validationAge = cached.map { Self.frameAge(updatedAt: $0.validatedAt, now: Self.now) } ?? 0
        if let prepared,
           Self.shouldExpirePreparedFrozenScreen(updatedAt: prepared.updatedAt, now: Self.now) {
            preparedFrozenScreens.removeValue(forKey: display.id)
            didExpirePrepared = true
        }
        ageMonitors.remove(display.id)
        lock.unlock()

        if didExpirePrepared {
            Self.log.info("capture cache prepared image expired display=\(display.id, privacy: .public)")
        }

        guard let cached else { return }
        let now = Self.now
        if Self.shouldRestartCachedStream(updatedAt: cached.updatedAt, validatedAt: cached.validatedAt, now: now) {
            Self.log.warning("capture cache old frame maintenance display=\(display.id, privacy: .public) ageMs=\(age * 1000, privacy: .public) validationAgeMs=\(validationAge * 1000, privacy: .public) restartAgeMs=\(Self.streamRestartAge * 1000, privacy: .public) maxValidatedPixelAgeMs=\(Self.validatedFrameMaxPixelAge * 1000, privacy: .public); restarting stream in background")
            refreshStreamInBackground(for: display, reason: "old frame maintenance")
        } else if Self.shouldRequestMaintenanceFrame(validatedAt: cached.validatedAt, now: now) {
            Self.log.info("capture cache old frame maintenance display=\(display.id, privacy: .public) ageMs=\(age * 1000, privacy: .public) validationAgeMs=\(validationAge * 1000, privacy: .public) refreshAgeMs=\(Self.maintenanceRefreshAge * 1000, privacy: .public); requesting fresh frame")
            requestFreshFrame(for: display,
                              requestedAt: now,
                              reason: "old frame maintenance",
                              allowsStreamRestart: false)
        } else {
            scheduleAgeMonitor(for: display)
        }
    }

    private func priorityRank(for displayID: CGDirectDisplayID) -> Int {
        lock.lock()
        let isPriority = priorityDisplays.contains(displayID)
        lock.unlock()
        return isPriority ? 0 : 1
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private static func frameAge(updatedAt: TimeInterval, now: TimeInterval) -> TimeInterval {
        max(0, now - updatedAt)
    }

    private static func shouldServeCachedFrame(updatedAt: TimeInterval,
                                               validatedAt: TimeInterval,
                                               requestedAt: TimeInterval,
                                               now: TimeInterval) -> Bool {
        cachedFrameAcceptance(updatedAt: updatedAt, requestedAt: requestedAt) != nil
    }

    private static func cachedFrameAcceptance(updatedAt: TimeInterval,
                                              requestedAt: TimeInterval) -> CachedFrameAcceptance? {
        updatedAt >= requestedAt ? .postRequest : nil
    }

    private static func shouldServePreparedFrozenScreen(updatedAt: TimeInterval,
                                                        requestedAt: TimeInterval,
                                                        now: TimeInterval) -> Bool {
        updatedAt >= requestedAt
    }

    private static func shouldExpirePreparedFrozenScreen(updatedAt: TimeInterval, now: TimeInterval) -> Bool {
        frameAge(updatedAt: updatedAt, now: now) > preparedFrozenScreenRetentionAge
    }

    private static func shouldRequestMaintenanceFrame(validatedAt: TimeInterval, now: TimeInterval) -> Bool {
        frameAge(updatedAt: validatedAt, now: now) >= maintenanceRefreshAge
    }

    private static func shouldValidateStaticFrame(updatedAt: TimeInterval, now: TimeInterval) -> Bool {
        frameAge(updatedAt: updatedAt, now: now) <= validatedFrameMaxPixelAge
    }

    private static func shouldRestartCachedStream(updatedAt: TimeInterval,
                                                  validatedAt: TimeInterval,
                                                  now: TimeInterval) -> Bool {
        frameAge(updatedAt: updatedAt, now: now) >= validatedFrameMaxPixelAge
            || frameAge(updatedAt: validatedAt, now: now) >= streamRestartAge
    }

    private static func hasRecentRectSnapshotFailure(updatedAt: TimeInterval, now: TimeInterval) -> Bool {
        frameAge(updatedAt: updatedAt, now: now) <= rectSnapshotFailureCooldown
    }

    private static func hasRecentShareableDisplayFailure(updatedAt: TimeInterval, now: TimeInterval) -> Bool {
        frameAge(updatedAt: updatedAt, now: now) <= shareableDisplayFailureCooldown
    }

    fileprivate static func configuration(for display: CaptureDisplay, scale: CGFloat) -> SCStreamConfiguration {
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
        return config
    }

#if TESTING
    static var debugValidatedFrameMaxPixelAge: TimeInterval { validatedFrameMaxPixelAge }
    static var debugPreparedFrozenScreenRetentionAge: TimeInterval { preparedFrozenScreenRetentionAge }
    static var debugMaintenanceRefreshAge: TimeInterval { maintenanceRefreshAge }
    static var debugStreamRestartAge: TimeInterval { streamRestartAge }
    static var debugRefreshEscalationDelayNanoseconds: UInt64 { refreshEscalationDelayNanoseconds }
    static var debugStreamSnapshotDelayNanoseconds: UInt64 { streamSnapshotDelayNanoseconds }
    static var debugRectSnapshotTimeoutNanoseconds: UInt64 { rectSnapshotTimeoutNanoseconds }
    static var debugRectSnapshotProbeJoinNanoseconds: UInt64 { rectSnapshotProbeJoinNanoseconds }
    static var debugShareableDisplayFailureCooldown: TimeInterval { shareableDisplayFailureCooldown }
    static var debugRectSnapshotFailureCooldown: TimeInterval { rectSnapshotFailureCooldown }

    static func debugShouldServeCachedFrame(updatedAt: TimeInterval,
                                            validatedAt: TimeInterval? = nil,
                                            requestedAt: TimeInterval,
                                            now: TimeInterval) -> Bool {
        shouldServeCachedFrame(updatedAt: updatedAt,
                               validatedAt: validatedAt ?? updatedAt,
                               requestedAt: requestedAt,
                               now: now)
    }

    static func debugCachedFrameAcceptance(updatedAt: TimeInterval,
                                           validatedAt: TimeInterval? = nil,
                                           requestedAt: TimeInterval,
                                           now: TimeInterval) -> String? {
        cachedFrameAcceptance(updatedAt: updatedAt, requestedAt: requestedAt)?.rawValue
    }

    static func debugShouldRequestMaintenanceFrame(validatedAt: TimeInterval, now: TimeInterval) -> Bool {
        shouldRequestMaintenanceFrame(validatedAt: validatedAt, now: now)
    }

    static func debugShouldValidateStaticFrame(updatedAt: TimeInterval, now: TimeInterval) -> Bool {
        shouldValidateStaticFrame(updatedAt: updatedAt, now: now)
    }

    static func debugShouldRestartCachedStream(updatedAt: TimeInterval? = nil,
                                               validatedAt: TimeInterval,
                                               now: TimeInterval) -> Bool {
        shouldRestartCachedStream(updatedAt: updatedAt ?? validatedAt,
                                  validatedAt: validatedAt,
                                  now: now)
    }

    static func debugShouldServePreparedFrozenScreen(updatedAt: TimeInterval,
                                                     requestedAt: TimeInterval,
                                                     now: TimeInterval) -> Bool {
        shouldServePreparedFrozenScreen(updatedAt: updatedAt, requestedAt: requestedAt, now: now)
    }

    static func debugShouldExpirePreparedFrozenScreen(updatedAt: TimeInterval, now: TimeInterval) -> Bool {
        shouldExpirePreparedFrozenScreen(updatedAt: updatedAt, now: now)
    }

    static func debugHasRecentRectSnapshotFailure(updatedAt: TimeInterval, now: TimeInterval) -> Bool {
        hasRecentRectSnapshotFailure(updatedAt: updatedAt, now: now)
    }

    static func debugHasRecentShareableDisplayFailure(updatedAt: TimeInterval, now: TimeInterval) -> Bool {
        hasRecentShareableDisplayFailure(updatedAt: updatedAt, now: now)
    }
#endif
}

private final class CachedDisplayStream: NSObject, SCStreamOutput {

    private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")
    private static let snapshotTimeoutNanoseconds: UInt64 = 2_000_000_000

    private struct SnapshotTimeout: Error, CustomStringConvertible {
        var description: String { "stream snapshot timed out" }
    }

    struct Snapshot {
        let image: CGImage
        let scale: CGFloat
    }

    let id = UUID()
    private let display: CaptureDisplay
    private let stream: SCStream
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let queue: DispatchQueue
    private let onFrame: (UUID, CGDirectDisplayID, CGRect, CGFloat, CVPixelBuffer) -> Void
    private let scale: CGFloat
    private var didLogFirstFrame = false
    private let startedAt = CFAbsoluteTimeGetCurrent()

    init(display: CaptureDisplay,
         scDisplay: SCDisplay,
         excludedApps: [SCRunningApplication],
         onFrame: @escaping (UUID, CGDirectDisplayID, CGRect, CGFloat, CVPixelBuffer) -> Void) throws {
        self.display = display
        self.onFrame = onFrame

        let filter = excludedApps.isEmpty
            ? SCContentFilter(display: scDisplay, excludingWindows: [])
            : SCContentFilter(display: scDisplay, excludingApplications: excludedApps, exceptingWindows: [])
        self.filter = filter
        self.scale = CGFloat(filter.pointPixelScale)

        let config = ScreenFrameCache.configuration(for: display, scale: scale)
        self.configuration = config

        self.stream = SCStream(filter: filter, configuration: config, delegate: nil)
        self.queue = DispatchQueue(label: "QuickShot.capture-cache.\(display.id)")
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        try await stream.startCapture()
    }

    func requestFrame(reason: String) async -> Bool {
        do {
            try await stream.updateConfiguration(configuration)
            try await stream.updateContentFilter(filter)
            Self.log.info("capture cache stream fresh frame requested display=\(self.display.id, privacy: .public) reason=\(reason, privacy: .public)")
            return true
        } catch {
            Self.log.error("capture cache stream fresh frame request failed display=\(self.display.id, privacy: .public) reason=\(reason, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func captureSnapshot(reason: String) async -> Snapshot? {
        let startedAt = CFAbsoluteTimeGetCurrent()
        do {
            let image = try await Self.captureImage(contentFilter: filter, configuration: configuration)
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            Self.log.info("capture cache stream snapshot display=\(self.display.id, privacy: .public) reason=\(reason, privacy: .public) ms=\(ms, privacy: .public)")
            return Snapshot(image: image, scale: scale)
        } catch {
            Self.log.error("capture cache stream snapshot failed display=\(self.display.id, privacy: .public) reason=\(reason, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func captureImage(contentFilter: SCContentFilter,
                                     configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask {
                try await SCScreenshotManager.captureImage(contentFilter: contentFilter,
                                                           configuration: configuration)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: snapshotTimeoutNanoseconds)
                throw SnapshotTimeout()
            }
            do {
                guard let image = try await group.next() else {
                    group.cancelAll()
                    throw SnapshotTimeout()
                }
                group.cancelAll()
                return image
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    func stop(reason: String) async {
        do {
            try await stream.stopCapture()
            Self.log.info("capture cache stream stopped display=\(self.display.id, privacy: .public) reason=\(reason, privacy: .public)")
        } catch {
            Self.log.error("capture cache stream stop failed display=\(self.display.id, privacy: .public) reason=\(reason, privacy: .public): \(String(describing: error), privacy: .public)")
        }
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
        onFrame(id, display.id, display.frame, scale, pixelBuffer)
    }
}
