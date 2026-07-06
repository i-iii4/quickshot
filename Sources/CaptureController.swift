import AppKit
import CoreGraphics
import OSLog

/// Оркестратор запуска захвата. Сам цикл захвата живёт в `CaptureSession`: у одного
/// hotkey-цикла есть явное состояние, один владелец overlay и один путь завершения.
@MainActor
final class CaptureController {

    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")
    private static let permissionGrantedKey = "screenCaptureAccessGranted"

    private let freezer = ScreenFreezePipeline()
    private let thumbnails = ThumbnailManager()
    private var session: CaptureSession?
    private var prewarmTask: Task<Void, Never>?
    private var prewarmID = UUID()
    private var hasScreenCaptureAccess: Bool? = UserDefaults.standard.bool(forKey: permissionGrantedKey) ? true : nil
    private var didNotifyCaptureStackFailure = false

    func prewarmCapturePipeline() {
        prewarmTask?.cancel()
        let prewarmID = UUID()
        self.prewarmID = prewarmID
        let freezer = self.freezer
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
            guard accessGranted, !Task.isCancelled else { return }
            await freezer.prewarm()
        }
    }

    func triggerCapture(startedAt triggerStartedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard session == nil else { return }
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
            freezer: freezer,
            onImage: { [weak self] image, screen in
                self?.deliverCapturedImage(image, on: screen)
            },
            onError: { [weak self] error in
                self?.handleCaptureError(error)
            },
            onEnd: { [weak self] in
                self?.session = nil
            },
            startedAt: triggerStartedAt)
        session = s
        s.start()
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
        session?.shutdown()
        session = nil
        Task { await freezer.shutdown() }
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

/// Stream-backed сессия захвата:
/// 1. фиксирует раннее состояние мыши;
/// 2. скрывает окна QuickShot, чтобы они не попали в freeze;
/// 3. ждёт ScreenCaptureKit stream freshness без one-shot fallback;
/// 4. показывает selection overlay уже поверх immutable frozen pixels;
/// 5. кадрирует только этот immutable frozen image.
@MainActor
private final class CaptureSession {

    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")

    private enum Phase {
        case freezing
        case selecting
        case finishing
        case cancelled
    }

    private let freezer: ScreenFreezePipeline
    private let onImage: (CGImage, NSScreen) -> Void
    private let onError: (Error) -> Void
    private let onEnd: () -> Void

    private var phase: Phase = .freezing
    private var overlay: OverlayController?
    private var frozen: [CGDirectDisplayID: FrozenScreen] = [:]
    private var screens: [NSScreen] = []
    private var displays: [CaptureDisplay] = []
    private var freezeTask: Task<Void, Never>?
    private var hiddenWindows: HiddenAppWindows?
    private var gestureSnapshot: CaptureGestureSnapshot?
    private var preOverlayMouseTracker: PreOverlayMouseTracker?
    private var endOutcome = "unknown"
    private var didEnd = false
    private let startedAt: CFAbsoluteTime

    init(freezer: ScreenFreezePipeline,
         onImage: @escaping (CGImage, NSScreen) -> Void,
         onError: @escaping (Error) -> Void,
         onEnd: @escaping () -> Void,
         startedAt: CFAbsoluteTime) {
        self.freezer = freezer
        self.onImage = onImage
        self.onError = onError
        self.onEnd = onEnd
        self.startedAt = startedAt
    }

    func start() {
        let snapshot = CaptureGestureSnapshot()
        gestureSnapshot = snapshot
        preOverlayMouseTracker = PreOverlayMouseTracker(initialMouseDownAt: snapshot.initialMouseDownAt)
        Self.log.info("capture hot path gesture snapshot ready ms=\(self.elapsedMs, privacy: .public)")

        let orderedScreens = Self.captureScreens(pointer: snapshot.preferredStartPoint)
        guard !orderedScreens.isEmpty else {
            freezeFailed(CaptureError.noDisplay)
            return
        }

        screens = orderedScreens
        displays = orderedScreens.map(Self.captureDisplay)
        let displayList = displays.map { String($0.id) }.joined(separator: ",")
        Self.log.info("capture freeze pending displays=\(displayList, privacy: .public)")

        hiddenWindows = HiddenAppWindows.hideVisibleApplicationWindows()
        let hiddenAt = CFAbsoluteTimeGetCurrent()
        Self.log.info("capture hot path windows hidden ms=\(self.elapsedMs, privacy: .public)")
        startFreezeTask(displays: displays, readyAfter: hiddenAt)
    }

    private func startFreezeTask(displays: [CaptureDisplay], readyAfter: CFAbsoluteTime) {
        let freezer = self.freezer
        let startedAt = self.startedAt

        freezeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let elapsedMs = { (CFAbsoluteTimeGetCurrent() - startedAt) * 1000 }
            do {
                let shots = try await freezer.captureFrozenScreens(displays: displays,
                                                                    requestedAt: startedAt,
                                                                    readyAfter: readyAfter)
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    Self.log.info("capture freeze completed ms=\(elapsedMs(), privacy: .public)")
                    self.freezeCompleted(shots)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    Self.log.error("capture freeze failed ms=\(elapsedMs(), privacy: .public) error=\(String(describing: error), privacy: .public)")
                    self.freezeFailed(error)
                }
            }
        }
    }

    private func freezeCompleted(_ shots: [FrozenScreen]) {
        guard isRunning else { return }
        guard !shots.isEmpty else {
            freezeFailed(CaptureError.noDisplay)
            return
        }

        frozen = Dictionary(uniqueKeysWithValues: shots.map { ($0.displayID, $0) })
        phase = .selecting
        Self.log.info("capture frozen ready displays=\(shots.count, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
        beginOverlay(backdrops: Dictionary(uniqueKeysWithValues: shots.map { ($0.displayID, $0.image) }))
    }

    private func beginOverlay(backdrops: [CGDirectDisplayID: CGImage]) {
        let overlayStartedAt = CFAbsoluteTimeGetCurrent()
        let overlay = OverlayController()
        self.overlay = overlay
        let initialMouseDownAt = preOverlayMouseTracker?.mouseDownSeedPoint()
        preOverlayMouseTracker?.stop()
        preOverlayMouseTracker = nil
        overlay.beginFrozenSelection(
            screens: screens,
            backdrops: backdrops,
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

    private func freezeFailed(_ error: Error) {
        guard isRunning else { return }
        preOverlayMouseTracker?.stop()
        preOverlayMouseTracker = nil
        overlay?.dismiss()
        overlay = nil
        frozen = [:]
        phase = .cancelled
        endOutcome = "failed"
        onError(error)
        end()
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
            frozen = [:]
            end()
            return
        }

        let did = Self.displayID(of: screen)
        guard let shot = frozen[did] else {
            overlay?.dismiss()
            overlay = nil
            frozen = [:]
            endOutcome = "missing-frozen-frame"
            end()
            return
        }

        phase = .finishing
        overlay?.dismiss()
        overlay = nil
        frozen = [:]
        endOutcome = "completed"
        end()
        scheduleCropAndDelivery(shot: shot, selection: clamped, screen: screen)
    }

    private func scheduleCropAndDelivery(shot: FrozenScreen, selection: NSRect, screen: NSScreen) {
        let deliver = onImage
        let startedAt = self.startedAt
        let deliveryDisplayID = Self.displayID(of: screen)
        let requestedWidth = Int(selection.width)
        let requestedHeight = Int(selection.height)

        DispatchQueue.global(qos: .userInitiated).async {
            let cropped = shot.crop(globalSelection: selection)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000

            DispatchQueue.main.async {
                guard let cropped else {
                    Self.log.error("capture crop failed width=\(requestedWidth, privacy: .public) height=\(requestedHeight, privacy: .public) ms=\(elapsedMs, privacy: .public)")
                    Self.log.error("capture delivery outcome=crop-failed width=\(requestedWidth, privacy: .public) height=\(requestedHeight, privacy: .public) ms=\(elapsedMs, privacy: .public)")
                    return
                }
                Self.log.info("capture crop complete width=\(requestedWidth, privacy: .public) height=\(requestedHeight, privacy: .public) ms=\(elapsedMs, privacy: .public)")
                Self.log.info("capture image handoff started width=\(cropped.width, privacy: .public) height=\(cropped.height, privacy: .public)")
                guard let deliveryScreen = Self.screen(forDisplayID: deliveryDisplayID) ?? NSScreen.main ?? NSScreen.screens.first else {
                    Self.log.error("capture image handoff failed missing screen display=\(deliveryDisplayID, privacy: .public)")
                    Self.log.error("capture delivery outcome=handoff-failed display=\(deliveryDisplayID, privacy: .public)")
                    return
                }
                deliver(cropped, deliveryScreen)
            }
        }
    }

    private func cancel() {
        guard isRunning else { return }
        phase = .cancelled
        endOutcome = "cancelled"
        overlay?.dismiss()
        overlay = nil
        frozen = [:]
        end()
    }

    func shutdown() {
        guard isRunning else { return }
        phase = .cancelled
        endOutcome = "shutdown"
        overlay?.dismiss()
        overlay = nil
        frozen = [:]
        end()
    }

    private var isRunning: Bool {
        switch phase {
        case .freezing, .selecting, .finishing:
            return !didEnd
        case .cancelled:
            return false
        }
    }

    private func end() {
        guard !didEnd else { return }
        didEnd = true
        freezeTask?.cancel()
        freezeTask = nil
        preOverlayMouseTracker?.stop()
        preOverlayMouseTracker = nil
        gestureSnapshot = nil
        hiddenWindows?.restore()
        hiddenWindows = nil
        Self.log.info("capture end outcome=\(self.endOutcome, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
        onEnd()
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

@MainActor
private final class HiddenAppWindows {
    private let windows: [NSWindow]

    private init(windows: [NSWindow]) {
        self.windows = windows
    }

    static func hideVisibleApplicationWindows() -> HiddenAppWindows {
        let visible = NSApp.windows.filter { window in
            window.isVisible && !(window is OverlayWindow)
        }
        for window in visible {
            window.orderOut(nil)
        }
        if !visible.isEmpty {
            NSLog("QuickShot capture: hid \(visible.count) app window(s) before freeze")
        }
        return HiddenAppWindows(windows: visible)
    }

    func restore() {
        for window in windows where !window.isVisible {
            window.orderFrontRegardless()
        }
    }
}

@MainActor
private final class PreOverlayMouseTracker {
    private var monitor: Any?
    private var firstMouseDownAt: NSPoint?
    private var latestPoint: NSPoint

    init(initialMouseDownAt: NSPoint?) {
        self.firstMouseDownAt = initialMouseDownAt
        self.latestPoint = NSEvent.mouseLocation
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let type = event.type
            let point = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.record(type: type, point: point)
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

    private func record(type: NSEvent.EventType, point: NSPoint) {
        latestPoint = point
        switch type {
        case .leftMouseDown:
            if firstMouseDownAt == nil { firstMouseDownAt = point }
        case .leftMouseUp:
            break
        default:
            break
        }
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
