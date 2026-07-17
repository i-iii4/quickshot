import AppKit
import CoreGraphics
import OSLog

/// Оркестратор запуска захвата. Сам цикл захвата живёт в `CaptureSession`: у одного
/// hotkey-цикла есть явное состояние, один владелец overlay и один путь завершения.
@MainActor
final class CaptureController {

    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")
    private static let permissionGrantedKey = "screenCaptureAccessGranted"

    private let thumbnails = ThumbnailManager()
    private var selectionSession: CaptureSession?
    private var finishingSessions: [UUID: CaptureSession] = [:]
    private var prewarmTask: Task<Void, Never>?
    private var prewarmID = UUID()
    private var hasScreenCaptureAccess: Bool? = UserDefaults.standard.bool(forKey: permissionGrantedKey) ? true : nil
    private var didNotifyCaptureStackFailure = false

    func prewarmCapturePipeline() {
        prewarmTask?.cancel()
        let prewarmID = UUID()
        self.prewarmID = prewarmID
        prewarmTask = Task.detached(priority: .utility) { [weak self] in
            let preflightStartedAt = CFAbsoluteTimeGetCurrent()
            let accessGranted = CGPreflightScreenCaptureAccess()
            let preflightMs = (CFAbsoluteTimeGetCurrent() - preflightStartedAt) * 1000
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.prewarmID == prewarmID, !Task.isCancelled else { return }
                self.hasScreenCaptureAccess = accessGranted
                UserDefaults.standard.set(accessGranted, forKey: Self.permissionGrantedKey)
                Self.log.info("capture permission preflight granted=\(accessGranted, privacy: .public) ms=\(preflightMs, privacy: .public) phase=prewarm")
            }
        }
    }

    func triggerCapture(startedAt triggerStartedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard selectionSession == nil else {
            Self.log.info("capture trigger ignored reason=selection-active")
            return
        }
        Self.log.info("capture trigger accepted")

        if hasScreenCaptureAccess != true {
            let preflightStartedAt = CFAbsoluteTimeGetCurrent()
            let accessGranted = CGPreflightScreenCaptureAccess()
            let preflightMs = (CFAbsoluteTimeGetCurrent() - preflightStartedAt) * 1000
            hasScreenCaptureAccess = accessGranted
            UserDefaults.standard.set(accessGranted, forKey: Self.permissionGrantedKey)
            Self.log.info("capture permission preflight granted=\(accessGranted, privacy: .public) ms=\(preflightMs, privacy: .public) phase=trigger")
        }

        if hasScreenCaptureAccess != true {
            _ = CGRequestScreenCaptureAccess()
            let key = "didRequestScreenRecording"
            if UserDefaults.standard.bool(forKey: key) {
                presentPermissionAlert(firstRun: true)
            } else {
                UserDefaults.standard.set(true, forKey: key)
            }
            return
        }

        let s = CaptureSession(
            onSelectionReleased: { [weak self] id in
                self?.releaseSelectionSession(id: id)
            },
            onImage: { [weak self] image, screen in
                self?.deliverCapturedImage(image, on: screen)
            },
            onError: { [weak self] error in
                self?.handleCaptureError(error)
            },
            onEnd: { [weak self] id in
                self?.removeSession(id: id)
            },
            startedAt: triggerStartedAt)
        selectionSession = s
        s.start()
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

    private func deliverCapturedImage(_ image: CGImage, on screen: NSScreen) {
        thumbnails.add(image: image, on: screen)
        Self.log.info("capture thumbnail added width=\(image.width, privacy: .public) height=\(image.height, privacy: .public)")

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
        let sessions = Array(finishingSessions.values)
        selectionSession?.shutdown()
        for session in sessions { session.shutdown() }
        selectionSession = nil
        finishingSessions.removeAll()
    }

    private func handleCaptureError(_ error: Error) {
        switch error {
        case CaptureError.permissionDenied:
            presentPermissionAlert(firstRun: false)
        case CaptureError.captureStackUnavailable(let reason):
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
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = firstRun
            ? "Нужен доступ «Запись экрана»"
            : "Доступ «Запись экрана» выключен"
        alert.informativeText = "Откройте Системные настройки → Конфиденциальность и безопасность → "
            + "Запись экрана, включите QuickShot и перезапустите приложение."
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// Live-selection сессия:
/// 1. сразу показывает прозрачный selection overlay;
/// 2. пользователь выбирает область на живом экране;
/// 3. overlay закрывается на mouse-up;
/// 4. fresh region capture делается после завершения выделения.
@MainActor
private final class CaptureSession {

    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")

    private enum Phase {
        case selecting
        case finishing
        case cancelled
    }

    let id = UUID()

    private let onSelectionReleased: (UUID) -> Void
    private let onImage: (CGImage, NSScreen) -> Void
    private let onError: (Error) -> Void
    private let onEnd: (UUID) -> Void

    private var phase: Phase = .selecting
    private var overlay: OverlayController?
    private var screens: [NSScreen] = []
    private var freshCaptureTask: Task<Void, Never>?
    private var gestureSnapshot: CaptureGestureSnapshot?
    private var endOutcome = "unknown"
    private var didEnd = false
    private let startedAt: CFAbsoluteTime

    init(onSelectionReleased: @escaping (UUID) -> Void,
         onImage: @escaping (CGImage, NSScreen) -> Void,
         onError: @escaping (Error) -> Void,
         onEnd: @escaping (UUID) -> Void,
         startedAt: CFAbsoluteTime) {
        self.onSelectionReleased = onSelectionReleased
        self.onImage = onImage
        self.onError = onError
        self.onEnd = onEnd
        self.startedAt = startedAt
    }

    func start() {
        let snapshot = CaptureGestureSnapshot()
        gestureSnapshot = snapshot
        Self.log.info("capture hot path gesture snapshot ready ms=\(self.elapsedMs, privacy: .public)")

        let orderedScreens = Self.captureScreens(pointer: snapshot.preferredStartPoint)
        guard !orderedScreens.isEmpty else {
            fail(CaptureError.noDisplay)
            return
        }

        screens = orderedScreens
        Self.log.info("capture live overlay pending screens=\(orderedScreens.count, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
        beginOverlay(initialMouseDownAt: snapshot.initialMouseDownAt)
    }

    private func beginOverlay(initialMouseDownAt: NSPoint?) {
        let overlayStartedAt = CFAbsoluteTimeGetCurrent()
        let overlay = OverlayController()
        self.overlay = overlay
        overlay.beginLiveSelection(
            screens: screens,
            initialMouseDownAt: initialMouseDownAt,
            onComplete: { [weak self] rect, screen in
                self?.selectionCompleted(rect, screen)
            },
            onCancel: { [weak self] in
                self?.cancel()
            })
        let overlayDurationMs = (CFAbsoluteTimeGetCurrent() - overlayStartedAt) * 1000
        Self.log.info("capture hot path overlay constructed ms=\(overlayDurationMs, privacy: .public)")
        Self.log.info("capture overlay ready ms=\(self.elapsedMs, privacy: .public)")
    }

    private func selectionCompleted(_ globalRect: NSRect, _ screen: NSScreen) {
        guard isRunning else { return }
        completeSelection(globalRect, screen)
    }

    private func completeSelection(_ globalRect: NSRect, _ screen: NSScreen) {
        guard isRunning else { return }

        let clamped = globalRect.intersection(screen.frame)
        guard clamped.width >= 3, clamped.height >= 3 else {
            endOutcome = "ignored-small-selection"
            overlay?.dismiss()
            overlay = nil
            end()
            return
        }

        phase = .finishing
        overlay?.dismiss()
        overlay = nil
        Self.log.info("capture selection completed width=\(Int(clamped.width), privacy: .public) height=\(Int(clamped.height), privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
        onSelectionReleased(id)
        startFreshCaptureAndDelivery(selection: clamped, screen: screen)
    }

    private func startFreshCaptureAndDelivery(selection: NSRect, screen: NSScreen) {
        let deliver = onImage
        let reportError = onError
        let startedAt = self.startedAt
        let display = Self.captureDisplay(for: screen)
        let deliveryDisplayID = display.id
        let requestedWidth = Int(selection.width)
        let requestedHeight = Int(selection.height)

        Self.log.info("capture fresh region pending display=\(display.id, privacy: .public) width=\(requestedWidth, privacy: .public) height=\(requestedHeight, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")

        freshCaptureTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let image = try await FreshRegionCapture.capture(selection: selection,
                                                                  display: display,
                                                                  startedAt: startedAt)
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                await MainActor.run { [weak self] in
                    guard let self, self.isRunning else { return }
                    Self.log.info("capture fresh region ready width=\(image.width, privacy: .public) height=\(image.height, privacy: .public) ms=\(elapsedMs, privacy: .public)")
                    guard let deliveryScreen = Self.screen(forDisplayID: deliveryDisplayID) ?? NSScreen.main ?? NSScreen.screens.first else {
                        Self.log.error("capture image handoff failed missing screen display=\(deliveryDisplayID, privacy: .public)")
                        Self.log.error("capture delivery outcome=handoff-failed display=\(deliveryDisplayID, privacy: .public)")
                        self.endOutcome = "handoff-failed"
                        self.end()
                        return
                    }
                    self.endOutcome = "completed"
                    self.end()
                    Self.log.info("capture image handoff started width=\(image.width, privacy: .public) height=\(image.height, privacy: .public)")
                    deliver(image, deliveryScreen)
                }
            } catch {
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                await MainActor.run { [weak self] in
                    guard let self, self.isRunning else { return }
                    Self.log.error("capture fresh region failed width=\(requestedWidth, privacy: .public) height=\(requestedHeight, privacy: .public) ms=\(elapsedMs, privacy: .public) error=\(String(describing: error), privacy: .public)")
                    Self.log.error("capture delivery outcome=fresh-capture-failed width=\(requestedWidth, privacy: .public) height=\(requestedHeight, privacy: .public) ms=\(elapsedMs, privacy: .public)")
                    self.endOutcome = "fresh-capture-failed"
                    self.end()
                    reportError(error)
                }
            }
        }
    }

    private func fail(_ error: Error) {
        guard isRunning else { return }
        phase = .cancelled
        endOutcome = "failed"
        end()
        onError(error)
    }

    private func cancel() {
        guard isRunning else { return }
        phase = .cancelled
        endOutcome = "cancelled"
        overlay?.dismiss()
        overlay = nil
        end()
    }

    func shutdown() {
        guard isRunning else { return }
        phase = .cancelled
        endOutcome = "shutdown"
        overlay?.dismiss()
        overlay = nil
        end()
    }

    private var isRunning: Bool {
        switch phase {
        case .selecting, .finishing:
            return !didEnd
        case .cancelled:
            return false
        }
    }

    private func end() {
        guard !didEnd else { return }
        didEnd = true
        freshCaptureTask?.cancel()
        freshCaptureTask = nil
        overlay?.dismiss()
        overlay = nil
        gestureSnapshot = nil
        Self.log.info("capture end outcome=\(self.endOutcome, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
        onEnd(id)
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
        CaptureDisplay(id: displayID(of: screen),
                       frame: screen.frame,
                       scale: screen.backingScaleFactor)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        CGDirectDisplayID(
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }

    private static func screen(forDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { Self.displayID(of: $0) == displayID }
    }
}

private struct CaptureGestureSnapshot {
    let preferredStartPoint: NSPoint
    let initialMouseDownAt: NSPoint?

    init() {
        let point = NSEvent.mouseLocation
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            preferredStartPoint = point
            initialMouseDownAt = point
        } else {
            preferredStartPoint = point
            initialMouseDownAt = nil
        }
    }
}
