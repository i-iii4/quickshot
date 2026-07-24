import AppKit
import CoreGraphics
import OSLog

@MainActor
final class CaptureController {
    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot",
                                                category: "capture")
    private static let permissionGrantedKey = "screenCaptureAccessGranted"

    private let artifactStore: CaptureArtifactStore
    private let thumbnails: ThumbnailManager
    private let snapshotProvider = DirectScreenSnapshotProvider()
    private var sequenceGenerator = CaptureSequenceGenerator()
    private var selectionSession: CaptureSession?
    private var finishingSessions: [UUID: CaptureSession] = [:]
    private var prewarmTask: Task<Void, Never>?
    private var prewarmID = UUID()
    private var hasScreenCaptureAccess: Bool? = UserDefaults.standard
        .bool(forKey: permissionGrantedKey) ? true : nil
    private var didNotifyCaptureStackFailure = false

    init() {
        let artifactStore = CaptureArtifactStore()
        self.artifactStore = artifactStore
        self.thumbnails = ThumbnailManager(artifactStore: artifactStore)
    }

    func prewarmCapturePipeline() {
        prewarmTask?.cancel()
        let prewarmID = UUID()
        self.prewarmID = prewarmID
        prewarmTask = Task.detached(priority: .utility) { [weak self] in
            let startedAt = CFAbsoluteTimeGetCurrent()
            let granted = CGPreflightScreenCaptureAccess()
            let directAvailable = DirectScreenSnapshotProvider.isDirectCaptureAvailable
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.prewarmID == prewarmID, !Task.isCancelled else { return }
                self.hasScreenCaptureAccess = granted
                UserDefaults.standard.set(granted, forKey: Self.permissionGrantedKey)
                Self.log.info("capture prewarm permission=\(granted, privacy: .public) direct=\(directAvailable, privacy: .public) pixels=false ms=\(elapsedMs, privacy: .public)")
            }
        }
    }

    func triggerCapture(startedAt triggerStartedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard selectionSession == nil else {
            Self.log.info("capture trigger ignored reason=selection-active")
            return
        }
        Self.log.info("capture trigger accepted")

        guard DirectScreenSnapshotProvider.isDirectCaptureAvailable else {
            handleCaptureError(CaptureError.captureStackUnavailable(
                "Direct CoreGraphics capture symbol is unavailable"))
            return
        }

        if hasScreenCaptureAccess != true {
            let preflightStartedAt = CFAbsoluteTimeGetCurrent()
            let granted = CGPreflightScreenCaptureAccess()
            let preflightMs = (CFAbsoluteTimeGetCurrent() - preflightStartedAt) * 1000
            hasScreenCaptureAccess = granted
            UserDefaults.standard.set(granted, forKey: Self.permissionGrantedKey)
            Self.log.info("capture permission preflight granted=\(granted, privacy: .public) ms=\(preflightMs, privacy: .public) phase=trigger")
        }

        guard hasScreenCaptureAccess == true else {
            _ = CGRequestScreenCaptureAccess()
            let key = "didRequestScreenRecording"
            if UserDefaults.standard.bool(forKey: key) {
                presentPermissionAlert(firstRun: true)
            } else {
                UserDefaults.standard.set(true, forKey: key)
            }
            return
        }

        let protectedCount = WindowCaptureProtection.protectAllApplicationWindows()
        do {
            try WindowCaptureProtection.auditOnScreenWindows()
        } catch {
            handleCaptureError(CaptureError.captureStackUnavailable(
                String(describing: error)))
            return
        }
        Self.log.info("capture windows protected count=\(protectedCount, privacy: .public)")

        let sequence = sequenceGenerator.next()
        artifactStore.registerCapture(sequence)
        let session = CaptureSession(
            sequence: sequence,
            snapshotProvider: snapshotProvider,
            onSelectionReleased: { [weak self] id in
                self?.releaseSelectionSession(id: id)
            },
            onImage: { [weak self] sequence, image, screen, mouseUpAt in
                self?.deliverCapturedImage(sequence: sequence,
                                           image,
                                           on: screen,
                                           mouseUpAt: mouseUpAt)
            },
            onError: { [weak self] error in
                self?.handleCaptureError(error)
            },
            onEnd: { [weak self] id, sequence, outcome in
                self?.removeSession(id: id, sequence: sequence, outcome: outcome)
            },
            startedAt: triggerStartedAt)
        selectionSession = session
        thumbnails.beginCapturePresentation(sessionID: session.id)
        session.start()
    }

    private func releaseSelectionSession(id: UUID) {
        guard let session = selectionSession, session.id == id else { return }
        thumbnails.endCapturePresentation(sessionID: id)
        finishingSessions[id] = session
        selectionSession = nil
        Self.log.info("capture selection released inFlight=\(self.finishingSessions.count, privacy: .public)")
    }

    private func removeSession(id: UUID,
                               sequence: CaptureSequence,
                               outcome: CaptureSessionOutcome) {
        thumbnails.endCapturePresentation(sessionID: id)
        if selectionSession?.id == id { selectionSession = nil }
        finishingSessions.removeValue(forKey: id)
        if outcome != .completed {
            artifactStore.markCaptureFailed(sequence)
        }
    }

    private func deliverCapturedImage(sequence: CaptureSequence,
                                      _ image: CGImage,
                                      on screen: NSScreen,
                                      mouseUpAt: CFAbsoluteTime) {
        do {
            let artifact = try artifactStore.admit(sequence: sequence, image: image)
            thumbnails.add(artifact: artifact, on: screen)
            let mouseUpToCardMs = (CFAbsoluteTimeGetCurrent() - mouseUpAt) * 1000
            Self.log.info("capture thumbnail added sequence=\(sequence.rawValue, privacy: .public) width=\(image.width, privacy: .public) height=\(image.height, privacy: .public) mouseUpToCardMs=\(mouseUpToCardMs, privacy: .public)")
        } catch {
            artifactStore.markCaptureFailed(sequence)
            NSApp.requestUserAttention(.criticalRequest)
            Self.log.error("capture artifact rejected sequence=\(sequence.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    func shutdown() {
        prewarmTask?.cancel()
        prewarmTask = nil
        prewarmID = UUID()
        let finishing = Array(finishingSessions.values)
        selectionSession?.shutdown()
        for session in finishing { session.shutdown() }
        selectionSession = nil
        finishingSessions.removeAll()
        thumbnails.shutdown()
        artifactStore.shutdown()
    }

    private func handleCaptureError(_ error: Error) {
        switch error {
        case CaptureError.permissionDenied:
            presentPermissionAlert(firstRun: false)
        case CaptureError.captureStackUnavailable(let reason),
             CaptureError.snapshotUnavailable(let reason):
            Self.log.error("capture stack unavailable reason=\(reason, privacy: .public)")
            presentCaptureStackFailureNotice(reason: reason)
        default:
            Self.log.error("capture failed error=\(String(describing: error), privacy: .public)")
            NSLog("QuickShot: захват не удался: \(error)")
        }
    }

    private func presentCaptureStackFailureNotice(reason: String) {
        guard !didNotifyCaptureStackFailure else { return }
        didNotifyCaptureStackFailure = true
        NSApp.requestUserAttention(.informationalRequest)
        NSLog("QuickShot: системный слой захвата недоступен: \(reason)")
    }

    private func presentPermissionAlert(firstRun: Bool) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = firstRun
            ? "Нужен доступ «Запись экрана»"
            : "Доступ «Запись экрана» выключен"
        alert.informativeText = "Откройте Системные настройки → Конфиденциальность и безопасность → "
            + "Запись экрана, включите QuickShot и перезапустите приложение."
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

private enum CaptureSessionOutcome: String {
    case unknown
    case completed
    case cancelled
    case failed
    case shutdown
    case ignoredSmallSelection
}

@MainActor
private final class CaptureSession {
    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot",
                                                category: "capture")

    private enum Phase: String {
        case snapshotting
        case selecting
        case delivering
        case cancelled
        case finished
    }

    let id = UUID()
    let sequence: CaptureSequence

    private let snapshotProvider: DirectScreenSnapshotProvider
    private let onSelectionReleased: (UUID) -> Void
    private let onImage: (CaptureSequence, CGImage, NSScreen, CFAbsoluteTime) -> Void
    private let onError: (Error) -> Void
    private let onEnd: (UUID, CaptureSequence, CaptureSessionOutcome) -> Void
    private let startedAt: CFAbsoluteTime

    private var phase: Phase = .snapshotting
    private var overlay: OverlayController?
    private var frozen: [CGDirectDisplayID: FrozenScreen] = [:]
    private var screens: [NSScreen] = []
    private var snapshotTask: Task<Void, Never>?
    private var cropTask: Task<Void, Never>?
    private var inputTracker: CaptureInputTracker?
    private var didEnd = false
    private var endOutcome: CaptureSessionOutcome = .unknown

    init(sequence: CaptureSequence,
         snapshotProvider: DirectScreenSnapshotProvider,
         onSelectionReleased: @escaping (UUID) -> Void,
         onImage: @escaping (CaptureSequence, CGImage, NSScreen, CFAbsoluteTime) -> Void,
         onError: @escaping (Error) -> Void,
         onEnd: @escaping (UUID, CaptureSequence, CaptureSessionOutcome) -> Void,
         startedAt: CFAbsoluteTime) {
        self.sequence = sequence
        self.snapshotProvider = snapshotProvider
        self.onSelectionReleased = onSelectionReleased
        self.onImage = onImage
        self.onError = onError
        self.onEnd = onEnd
        self.startedAt = startedAt
    }

    func start() {
        let inputTracker = CaptureInputTracker(onEscape: { [weak self] in self?.cancel() })
        guard inputTracker.escapeIsRegistered else {
            fail(CaptureError.captureStackUnavailable("Escape hotkey registration failed"))
            return
        }
        self.inputTracker = inputTracker
        Self.log.info("capture hot path gesture snapshot ready ms=\(self.elapsedMs, privacy: .public)")

        let orderedScreens = Self.captureScreens(pointer: inputTracker.initialPointer)
        guard !orderedScreens.isEmpty else {
            fail(CaptureError.noDisplay)
            return
        }
        screens = orderedScreens
        let displays = orderedScreens.map(Self.captureDisplay)
        let displayList = displays.map { String($0.id) }.joined(separator: ",")
        Self.log.info("capture direct snapshot pending displays=\(displayList, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
        startSnapshotTask(displays: displays)
    }

    private func startSnapshotTask(displays: [CaptureDisplay]) {
        let provider = snapshotProvider
        let sessionID = id
        let startedAt = self.startedAt
        snapshotTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let batch = try await provider.capture(sessionID: sessionID, displays: displays)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    Self.log.info("capture frozen ready displays=\(batch.screens.count, privacy: .public) ms=\(elapsedMs, privacy: .public)")
                    self.snapshotCompleted(batch)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.fail(error)
                }
            }
        }
    }

    private func snapshotCompleted(_ batch: FrozenSnapshotBatch) {
        guard phase == .snapshotting, !didEnd else { return }
        guard batch.sessionID == id else {
            fail(CaptureError.snapshotUnavailable("Snapshot belongs to another session"))
            return
        }

        let expectedIDs = Set(screens.map(Self.displayID))
        let receivedIDs = Set(batch.screens.map(\.displayID))
        guard batch.screens.count == expectedIDs.count,
              receivedIDs.count == batch.screens.count,
              expectedIDs == receivedIDs else {
            fail(CaptureError.snapshotUnavailable(
                "Display set mismatch expected=\(expectedIDs) received=\(receivedIDs)"))
            return
        }
        guard batch.maximumDisplaySkew <= 0.120 else {
            fail(CaptureError.snapshotUnavailable(
                "Display batch skew exceeds the 120ms product bound"))
            return
        }

        frozen = Dictionary(uniqueKeysWithValues: batch.screens.map { ($0.displayID, $0) })
        phase = .selecting
        if completeBufferedGestureIfNeeded() { return }
        beginOverlay(backdrops: Dictionary(uniqueKeysWithValues:
            batch.screens.map { ($0.displayID, $0.image) }))
    }

    private func completeBufferedGestureIfNeeded() -> Bool {
        guard let resolution = inputTracker?.resolution else { return false }
        switch resolution {
        case .completed(let start, let end):
            guard let screen = Self.screen(containing: start.point) else {
                fail(CaptureError.noDisplay)
                return true
            }
            inputTracker?.stopMouseMonitoring()
            let rect = CGRect(x: min(start.point.x, end.point.x),
                              y: min(start.point.y, end.point.y),
                              width: abs(end.point.x - start.point.x),
                              height: abs(end.point.y - start.point.y))
            selectionCompleted(rect, screen)
            return true
        case .cancelled:
            cancel()
            return true
        case .idle, .dragging:
            return false
        }
    }

    private func beginOverlay(backdrops: [CGDirectDisplayID: CGImage]) {
        let overlayStartedAt = CFAbsoluteTimeGetCurrent()
        let overlay = OverlayController()
        self.overlay = overlay
        overlay.beginFrozenSelection(
            screens: screens,
            backdrops: backdrops,
            pendingGesture: { [weak self] in
                self?.inputTracker?.resolution
                    ?? .cancelled
            },
            onReady: { [weak self] in
                guard let self else { return }
                self.inputTracker?.stopMouseMonitoring()
                let overlayMs = (CFAbsoluteTimeGetCurrent() - overlayStartedAt) * 1000
                Self.log.info("capture frozen overlay constructed ms=\(overlayMs, privacy: .public)")
                Self.log.info("capture overlay ready ms=\(self.elapsedMs, privacy: .public)")
            },
            onComplete: { [weak self] rect, screen in
                self?.selectionCompleted(rect, screen)
            },
            onCancel: { [weak self] in
                self?.cancel()
            })
    }

    private func selectionCompleted(_ globalRect: NSRect, _ screen: NSScreen) {
        guard phase == .selecting, !didEnd else { return }
        let clamped = globalRect.intersection(screen.frame)
        guard clamped.width >= 3, clamped.height >= 3 else {
            endOutcome = .ignoredSmallSelection
            phase = .finished
            end()
            return
        }

        let displayID = Self.displayID(of: screen)
        guard let shot = frozen[displayID] else {
            fail(CaptureError.snapshotUnavailable(
                "Missing frozen image for display \(displayID)"))
            return
        }

        phase = .delivering
        let mouseUpAt = CFAbsoluteTimeGetCurrent()
        Self.log.info("capture selection completed display=\(displayID, privacy: .public) width=\(Int(clamped.width), privacy: .public) height=\(Int(clamped.height), privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
        overlay?.dismiss()
        overlay = nil
        frozen.removeAll()
        onSelectionReleased(id)
        startCropTask(shot: shot,
                      selection: clamped,
                      deliveryDisplayID: displayID,
                      mouseUpAt: mouseUpAt)
    }

    private func startCropTask(shot: FrozenScreen,
                               selection: CGRect,
                               deliveryDisplayID: CGDirectDisplayID,
                               mouseUpAt: CFAbsoluteTime) {
        let deliver = onImage
        cropTask = Task.detached(priority: .userInitiated) { [weak self] in
            let cropStartedAt = CFAbsoluteTimeGetCurrent()
            let cropped = shot.crop(globalSelection: selection)
            let cropMs = (CFAbsoluteTimeGetCurrent() - cropStartedAt) * 1000
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.phase == .delivering, !self.didEnd else { return }
                guard let cropped else {
                    self.endOutcome = .failed
                    self.onError(CaptureError.snapshotUnavailable("Frozen image crop failed"))
                    self.end()
                    return
                }
                guard let screen = Self.screen(forDisplayID: deliveryDisplayID)
                        ?? NSScreen.main ?? NSScreen.screens.first else {
                    self.endOutcome = .failed
                    self.onError(CaptureError.noDisplay)
                    self.end()
                    return
                }

                let mouseUpToHandoffMs = (CFAbsoluteTimeGetCurrent() - mouseUpAt) * 1000
                Self.log.info("capture crop complete width=\(cropped.width, privacy: .public) height=\(cropped.height, privacy: .public) cropMs=\(cropMs, privacy: .public) mouseUpToHandoffMs=\(mouseUpToHandoffMs, privacy: .public)")
                Self.log.info("capture image handoff started width=\(cropped.width, privacy: .public) height=\(cropped.height, privacy: .public)")
                deliver(self.sequence, cropped, screen, mouseUpAt)
                self.endOutcome = .completed
                self.phase = .finished
                self.end()
            }
        }
    }

    private func fail(_ error: Error) {
        guard !didEnd else { return }
        phase = .cancelled
        endOutcome = .failed
        end()
        onError(error)
    }

    private func cancel() {
        guard !didEnd else { return }
        phase = .cancelled
        endOutcome = .cancelled
        end()
    }

    func shutdown() {
        guard !didEnd else { return }
        phase = .cancelled
        endOutcome = .shutdown
        end()
    }

    private func end() {
        guard !didEnd else { return }
        didEnd = true
        snapshotTask?.cancel()
        snapshotTask = nil
        cropTask?.cancel()
        cropTask = nil
        inputTracker?.stop()
        inputTracker = nil
        overlay?.dismiss()
        overlay = nil
        frozen.removeAll()
        Self.log.info("capture end outcome=\(self.endOutcome.rawValue, privacy: .public) phase=\(self.phase.rawValue, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
        onEnd(id, sequence, endOutcome)
    }

    private var elapsedMs: Double {
        (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
    }

    private static func captureScreens(pointer: NSPoint) -> [NSScreen] {
        NSScreen.screens.sorted { lhs, rhs in
            displayRank(lhs, pointer: pointer) < displayRank(rhs, pointer: pointer)
        }
    }

    private static func displayRank(_ screen: NSScreen, pointer: NSPoint) -> Int {
        if NSMouseInRect(pointer, screen.frame, false) { return 0 }
        if let main = NSScreen.main, displayID(of: main) == displayID(of: screen) { return 1 }
        return 2
    }

    private static func captureDisplay(for screen: NSScreen) -> CaptureDisplay {
        let id = displayID(of: screen)
        return CaptureDisplay(id: id,
                              frame: screen.frame,
                              quartzBounds: CGDisplayBounds(id))
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        CGDirectDisplayID(
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }

    private static func screen(forDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == displayID }
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}

@MainActor
private final class CaptureInputTracker {
    private var monitor: Any?
    private var gestureBuffer: CaptureGestureBuffer
    private let escapeHotKey = SessionEscapeHotKey()
    let initialPointer: NSPoint
    let escapeIsRegistered: Bool

    init(onEscape: @escaping () -> Void) {
        let pointer = NSEvent.mouseLocation
        initialPointer = pointer
        gestureBuffer = CaptureGestureBuffer(
            initialPointer: pointer,
            timestamp: ProcessInfo.processInfo.systemUptime,
            leftButtonDown: CGEventSource.buttonState(.combinedSessionState, button: .left))
        escapeIsRegistered = escapeHotKey.register(onEscape)
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]) { [weak self] event in
                let type = event.type
                let point = NSEvent.mouseLocation
                let timestamp = event.timestamp
                Task { @MainActor [weak self] in
                    self?.record(type: type, point: point, timestamp: timestamp)
                }
            }
    }

    var resolution: CaptureGestureResolution {
        gestureBuffer.resolution
    }

    func stopMouseMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    func stop() {
        stopMouseMonitoring()
        escapeHotKey.unregister()
    }

    private func record(type: NSEvent.EventType,
                        point: NSPoint,
                        timestamp: TimeInterval) {
        switch type {
        case .leftMouseDown:
            gestureBuffer.recordMouseDown(at: point, timestamp: timestamp)
        case .leftMouseDragged:
            gestureBuffer.recordMouseDragged(to: point, timestamp: timestamp)
        case .leftMouseUp:
            gestureBuffer.recordMouseUp(at: point, timestamp: timestamp)
        case .mouseMoved:
            gestureBuffer.updateIdlePointer(to: point, timestamp: timestamp)
        default:
            break
        }
    }

}
