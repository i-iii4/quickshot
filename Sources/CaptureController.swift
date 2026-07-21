import AppKit
import CoreGraphics
import OSLog

@MainActor
final class CaptureController {
    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot",
                                                category: "capture")
    private static let permissionGrantedKey = "screenCaptureAccessGranted"

    private let thumbnails = ThumbnailManager()
    private let snapshotProvider = DirectScreenSnapshotProvider()
    private var selectionSession: CaptureSession?
    private var finishingSessions: [UUID: CaptureSession] = [:]
    private var prewarmTask: Task<Void, Never>?
    private var prewarmID = UUID()
    private var hasScreenCaptureAccess: Bool? = UserDefaults.standard
        .bool(forKey: permissionGrantedKey) ? true : nil
    private var didNotifyCaptureStackFailure = false

    func prewarmCapturePipeline() {
        prewarmTask?.cancel()
        let prewarmID = UUID()
        self.prewarmID = prewarmID
        prewarmTask = Task.detached(priority: .utility) { [weak self] in
            let startedAt = CFAbsoluteTimeGetCurrent()
            let granted = CGPreflightScreenCaptureAccess()
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            let directAvailable = DirectScreenSnapshotProvider.isDirectCaptureAvailable
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.prewarmID == prewarmID, !Task.isCancelled else { return }
                self.hasScreenCaptureAccess = granted
                UserDefaults.standard.set(granted, forKey: Self.permissionGrantedKey)
                Self.log.info("capture prewarm permission=\(granted, privacy: .public) direct=\(directAvailable, privacy: .public) ms=\(elapsedMs, privacy: .public)")
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
        if let unprotected = WindowCaptureProtection.unprotectedOnScreenWindowNumbers(),
           !unprotected.isEmpty {
            handleCaptureError(CaptureError.captureStackUnavailable(
                "Unprotected QuickShot windows: \(unprotected)"))
            return
        }
        Self.log.info("capture windows protected count=\(protectedCount, privacy: .public)")

        let session = CaptureSession(
            snapshotProvider: snapshotProvider,
            onSelectionReleased: { [weak self] id in
                self?.releaseSelectionSession(id: id)
            },
            onImage: { [weak self] image, screen, mouseUpAt in
                self?.deliverCapturedImage(image, on: screen, mouseUpAt: mouseUpAt)
            },
            onError: { [weak self] error in
                self?.handleCaptureError(error)
            },
            onEnd: { [weak self] id in
                self?.removeSession(id: id)
            },
            startedAt: triggerStartedAt)
        selectionSession = session
        session.start()
    }

    private func releaseSelectionSession(id: UUID) {
        guard let session = selectionSession, session.id == id else { return }
        finishingSessions[id] = session
        selectionSession = nil
        Self.log.info("capture selection released inFlight=\(self.finishingSessions.count, privacy: .public)")
    }

    private func removeSession(id: UUID) {
        if selectionSession?.id == id { selectionSession = nil }
        finishingSessions.removeValue(forKey: id)
    }

    private func deliverCapturedImage(_ image: CGImage,
                                      on screen: NSScreen,
                                      mouseUpAt: CFAbsoluteTime) {
        thumbnails.add(image: image, on: screen)
        let mouseUpToCardMs = (CFAbsoluteTimeGetCurrent() - mouseUpAt) * 1000
        Self.log.info("capture thumbnail added width=\(image.width, privacy: .public) height=\(image.height, privacy: .public) mouseUpToCardMs=\(mouseUpToCardMs, privacy: .public)")

        let startedAt = CFAbsoluteTimeGetCurrent()
        Clipboard.prepareImage(cgImage: image) { prepared in
            let prepareMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            Clipboard.copy(preparedImage: prepared)
            Self.log.info("capture clipboard copied width=\(image.width, privacy: .public) height=\(image.height, privacy: .public) prepareMs=\(prepareMs, privacy: .public)")
            Self.log.info("capture delivery outcome=completed width=\(image.width, privacy: .public) height=\(image.height, privacy: .public) prepareMs=\(prepareMs, privacy: .public)")
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

    private let snapshotProvider: DirectScreenSnapshotProvider
    private let onSelectionReleased: (UUID) -> Void
    private let onImage: (CGImage, NSScreen, CFAbsoluteTime) -> Void
    private let onError: (Error) -> Void
    private let onEnd: (UUID) -> Void
    private let startedAt: CFAbsoluteTime

    private var phase: Phase = .snapshotting
    private var overlay: OverlayController?
    private var frozen: [CGDirectDisplayID: FrozenScreen] = [:]
    private var screens: [NSScreen] = []
    private var snapshotTask: Task<Void, Never>?
    private var cropTask: Task<Void, Never>?
    private var gestureSnapshot: CaptureGestureSnapshot?
    private var preOverlayMouseTracker: PreOverlayMouseTracker?
    private var sourceApplication: NSRunningApplication?
    private var didActivateOverlay = false
    private var didRestoreSourceApplication = false
    private var didEnd = false
    private var endOutcome = "unknown"

    init(snapshotProvider: DirectScreenSnapshotProvider,
         onSelectionReleased: @escaping (UUID) -> Void,
         onImage: @escaping (CGImage, NSScreen, CFAbsoluteTime) -> Void,
         onError: @escaping (Error) -> Void,
         onEnd: @escaping (UUID) -> Void,
         startedAt: CFAbsoluteTime) {
        self.snapshotProvider = snapshotProvider
        self.onSelectionReleased = onSelectionReleased
        self.onImage = onImage
        self.onError = onError
        self.onEnd = onEnd
        self.startedAt = startedAt
    }

    func start() {
        sourceApplication = NSWorkspace.shared.frontmostApplication
        let gesture = CaptureGestureSnapshot()
        gestureSnapshot = gesture
        preOverlayMouseTracker = PreOverlayMouseTracker(
            initialMouseDownAt: gesture.initialMouseDownAt,
            onEscape: { [weak self] in self?.cancel() })
        Self.log.info("capture hot path gesture snapshot ready ms=\(self.elapsedMs, privacy: .public)")

        let orderedScreens = Self.captureScreens(pointer: gesture.preferredStartPoint)
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
        guard expectedIDs == receivedIDs else {
            fail(CaptureError.snapshotUnavailable(
                "Display set mismatch expected=\(expectedIDs) received=\(receivedIDs)"))
            return
        }

        frozen = Dictionary(uniqueKeysWithValues: batch.screens.map { ($0.displayID, $0) })
        phase = .selecting
        beginOverlay(backdrops: Dictionary(uniqueKeysWithValues:
            batch.screens.map { ($0.displayID, $0.image) }))
    }

    private func beginOverlay(backdrops: [CGDirectDisplayID: CGImage]) {
        let initialMouseDownAt = preOverlayMouseTracker?.mouseDownSeedPoint()
        preOverlayMouseTracker?.stop()
        preOverlayMouseTracker = nil

        let overlayStartedAt = CFAbsoluteTimeGetCurrent()
        let overlay = OverlayController()
        self.overlay = overlay
        didActivateOverlay = true
        overlay.beginFrozenSelection(
            screens: screens,
            backdrops: backdrops,
            initialMouseDownAt: initialMouseDownAt,
            onReady: { [weak self] in
                guard let self else { return }
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
            endOutcome = "ignored-small-selection"
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
        restoreSourceApplication()
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
                    self.endOutcome = "crop-failed"
                    self.onError(CaptureError.snapshotUnavailable("Frozen image crop failed"))
                    self.end()
                    return
                }
                guard let screen = Self.screen(forDisplayID: deliveryDisplayID)
                        ?? NSScreen.main ?? NSScreen.screens.first else {
                    self.endOutcome = "handoff-failed"
                    self.onError(CaptureError.noDisplay)
                    self.end()
                    return
                }

                let mouseUpToHandoffMs = (CFAbsoluteTimeGetCurrent() - mouseUpAt) * 1000
                Self.log.info("capture crop complete width=\(cropped.width, privacy: .public) height=\(cropped.height, privacy: .public) cropMs=\(cropMs, privacy: .public) mouseUpToHandoffMs=\(mouseUpToHandoffMs, privacy: .public)")
                Self.log.info("capture image handoff started width=\(cropped.width, privacy: .public) height=\(cropped.height, privacy: .public)")
                deliver(cropped, screen, mouseUpAt)
                self.endOutcome = "completed"
                self.phase = .finished
                self.end()
            }
        }
    }

    private func fail(_ error: Error) {
        guard !didEnd else { return }
        phase = .cancelled
        endOutcome = "failed"
        end()
        onError(error)
    }

    private func cancel() {
        guard !didEnd else { return }
        phase = .cancelled
        endOutcome = "cancelled"
        end()
    }

    func shutdown() {
        guard !didEnd else { return }
        phase = .cancelled
        endOutcome = "shutdown"
        end()
    }

    private func end() {
        guard !didEnd else { return }
        didEnd = true
        snapshotTask?.cancel()
        snapshotTask = nil
        cropTask?.cancel()
        cropTask = nil
        preOverlayMouseTracker?.stop()
        preOverlayMouseTracker = nil
        overlay?.dismiss()
        overlay = nil
        frozen.removeAll()
        gestureSnapshot = nil
        restoreSourceApplication()
        Self.log.info("capture end outcome=\(self.endOutcome, privacy: .public) phase=\(self.phase.rawValue, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
        onEnd(id)
    }

    private func restoreSourceApplication() {
        guard didActivateOverlay, !didRestoreSourceApplication else { return }
        didRestoreSourceApplication = true
        guard let sourceApplication,
              !sourceApplication.isTerminated,
              sourceApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        NSApp.yieldActivation(to: sourceApplication)
        sourceApplication.activate(options: [])
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
}

@MainActor
private final class PreOverlayMouseTracker {
    private var monitor: Any?
    private var firstMouseDownAt: NSPoint?
    private var latestPoint: NSPoint
    private let onEscape: () -> Void

    init(initialMouseDownAt: NSPoint?, onEscape: @escaping () -> Void) {
        firstMouseDownAt = initialMouseDownAt
        latestPoint = NSEvent.mouseLocation
        self.onEscape = onEscape
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                let type = event.type
                let keyCode = event.keyCode
                let point = NSEvent.mouseLocation
                Task { @MainActor [weak self] in
                    self?.record(type: type, keyCode: keyCode, point: point)
                }
            }
    }

    func mouseDownSeedPoint() -> NSPoint? {
        guard CGEventSource.buttonState(.combinedSessionState, button: .left) else { return nil }
        return firstMouseDownAt ?? latestPoint
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func record(type: NSEvent.EventType, keyCode: UInt16, point: NSPoint) {
        if type == .keyDown, keyCode == 53 {
            onEscape()
            return
        }
        latestPoint = point
        if type == .leftMouseDown, firstMouseDownAt == nil {
            firstMouseDownAt = point
        }
    }
}

private struct CaptureGestureSnapshot {
    let preferredStartPoint: NSPoint
    let initialMouseDownAt: NSPoint?

    init() {
        let point = NSEvent.mouseLocation
        preferredStartPoint = point
        initialMouseDownAt = CGEventSource.buttonState(.combinedSessionState, button: .left)
            ? point
            : nil
    }
}
