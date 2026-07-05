import AppKit
import CoreGraphics
import OSLog

/// Оркестратор запуска захвата. Сам цикл захвата живёт в `CaptureSession`: так у одного
/// hotkey-цикла есть явное состояние, один владелец overlay и один путь завершения.
@MainActor
final class CaptureController {

    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")
    private static let permissionGrantedKey = "screenCaptureAccessGranted"

    private let frameCache = ScreenFrameCache()
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
        let displays = Self.captureDisplays()
        let bundleID = Bundle.main.bundleIdentifier
        let frameCache = self.frameCache
        prewarmTask = Task.detached(priority: .userInitiated) { [weak self] in
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
            guard accessGranted else { return }
            guard !Task.isCancelled else { return }
            await frameCache.start(displays: displays, excludingBundleIdentifier: bundleID)
        }
    }

    func triggerCapture(startedAt triggerStartedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard session == nil else { return }
        Self.log.info("capture trigger accepted")

        // Проверяем доступ ДО любого overlay, чтобы не показывать UI поверх неизбежного system prompt.
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
            frameCache: frameCache,
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
        frameCache.shutdown()
    }

    private static func captureDisplays() -> [CaptureDisplay] {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens
            .sorted { lhs, rhs in
                displayWarmupRank(lhs, pointer: pointer) < displayWarmupRank(rhs, pointer: pointer)
            }
            .map { CaptureDisplay(id: displayID(of: $0), frame: $0.frame) }
    }

    private static func displayWarmupRank(_ screen: NSScreen, pointer: NSPoint) -> Int {
        if NSMouseInRect(pointer, screen.frame, false) { return 0 }
        if let main = NSScreen.main, displayID(of: main) == displayID(of: screen) { return 1 }
        return 2
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

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        CGDirectDisplayID(
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }
}

/// Одна сессия захвата:
/// 1. показывает interactive overlay immediately, so the user can start selection without waiting;
/// 2. скрывает уже видимые окна QuickShot перед frozen-frame work, чтобы они не попали в кадр;
/// 3. installs a fresh frozen ScreenCaptureKit frame into that overlay when it arrives;
/// 4. кадрирует только тот же fresh frozen image, никогда старый pre-request frame.
@MainActor
private final class CaptureSession {

    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")
    nonisolated private static let frozenFrameWaitNanoseconds: UInt64 = 1_200_000_000

    private enum Phase {
        case freezing
        case frozen
        case finishing
        case cancelled
    }

    private let frameCache: ScreenFrameCache
    private let onImage: (CGImage, NSScreen) -> Void
    private let onError: (Error) -> Void
    private let onEnd: () -> Void

    private var phase: Phase = .freezing
    private var overlay: OverlayController?
    private var frozen: [CGDirectDisplayID: FrozenScreen] = [:]
    private var pendingSelection: (rect: NSRect, screen: NSScreen)?
    private var freezeTask: Task<Void, Never>?
    private var hiddenWindows: HiddenAppWindows?
    private var gestureSnapshot: CaptureGestureSnapshot?
    private var targetDisplay: CaptureDisplay?
    private var endOutcome = "unknown"
    private var didEnd = false
    private let startedAt: CFAbsoluteTime

    init(frameCache: ScreenFrameCache,
         onImage: @escaping (CGImage, NSScreen) -> Void,
         onError: @escaping (Error) -> Void,
         onEnd: @escaping () -> Void,
         startedAt: CFAbsoluteTime) {
        self.frameCache = frameCache
        self.onImage = onImage
        self.onError = onError
        self.onEnd = onEnd
        self.startedAt = startedAt
    }

    func start() {
        let snapshot = CaptureGestureSnapshot()
        gestureSnapshot = snapshot
        Self.log.info("capture hot path gesture snapshot ready ms=\(self.elapsedMs, privacy: .public)")

        let targetScreen = Self.screen(containing: snapshot.preferredStartPoint) ?? NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen else {
            freezeFailed(CaptureError.noDisplay)
            return
        }
        let targetDisplay = CaptureDisplay(id: Self.displayID(of: targetScreen), frame: targetScreen.frame)
        self.targetDisplay = targetDisplay
        let requestedAt = ScreenFrameCache.captureClock
        Self.log.info("capture start targetDisplay=\(targetDisplay.id, privacy: .public)")
        Self.log.info("capture hot path target resolved ms=\(self.elapsedMs, privacy: .public)")

        beginOverlay(on: targetScreen)
        hiddenWindows = HiddenAppWindows.hideVisibleApplicationWindows()
        Self.log.info("capture hot path windows hidden ms=\(self.elapsedMs, privacy: .public)")
        startFreezeTask(targetDisplay: targetDisplay, requestedAt: requestedAt)
    }

    private func startFreezeTask(targetDisplay: CaptureDisplay, requestedAt: TimeInterval) {
        frameCache.prioritize(display: targetDisplay)
        let frameCache = self.frameCache
        let bundleID = Bundle.main.bundleIdentifier
        let startedAt = self.startedAt

        freezeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let elapsedMs = { (CFAbsoluteTimeGetCurrent() - startedAt) * 1000 }

            Self.log.info("capture cache pending targetDisplay=\(targetDisplay.id, privacy: .public); waiting for fresh stream cache timeoutMs=\(Double(Self.frozenFrameWaitNanoseconds) / 1_000_000, privacy: .public)")
            let cacheStart = await frameCache.start(displays: [targetDisplay], excludingBundleIdentifier: bundleID)
            if !cacheStart.isUsable {
                if let rectSnapshot = await frameCache.rectSnapshotFrozenScreen(for: targetDisplay,
                                                                                reason: cacheStart.unavailableReason) {
                    await MainActor.run { [weak self] in
                        guard let self, !Task.isCancelled else { return }
                        Self.log.info("capture cache rect snapshot ready targetDisplay=\(targetDisplay.id, privacy: .public) ms=\(elapsedMs(), privacy: .public)")
                        self.freezeCompleted([rectSnapshot], targetDisplayID: targetDisplay.id)
                    }
                    return
                }
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    Self.log.error("capture cache unavailable at start targetDisplay=\(targetDisplay.id, privacy: .public) reason=\(cacheStart.unavailableReason, privacy: .public) ms=\(elapsedMs(), privacy: .public)")
                    self.freezeFailed(CaptureError.captureStackUnavailable("\(cacheStart.unavailableReason); rect snapshot failed"))
                }
                return
            }

            if let cached = await frameCache.waitForFrozenScreen(for: targetDisplay,
                                                                 requestedAt: requestedAt,
                                                                 timeoutNanoseconds: Self.frozenFrameWaitNanoseconds) {
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    Self.log.info("capture cache ready targetDisplay=\(targetDisplay.id, privacy: .public) ms=\(elapsedMs(), privacy: .public)")
                    self.freezeCompleted([cached], targetDisplayID: targetDisplay.id)
                }
                return
            }

            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                Self.log.error("capture cache unavailable targetDisplay=\(targetDisplay.id, privacy: .public) ms=\(elapsedMs(), privacy: .public)")
                self.freezeFailed(CaptureError.captureStackUnavailable("fresh stream frame unavailable before timeout"))
            }
        }
    }

    private func beginOverlay(on targetScreen: NSScreen) {
        let overlayStartedAt = CFAbsoluteTimeGetCurrent()
        let overlay = OverlayController()
        self.overlay = overlay
        overlay.beginLiveSelection(
            screens: [targetScreen],
            initialMouseDownAt: gestureSnapshot?.initialMouseDownAt,
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

    private func freezeCompleted(_ shots: [FrozenScreen], targetDisplayID: CGDirectDisplayID) {
        guard isRunning else { return }
        guard !shots.isEmpty else {
            freezeFailed(CaptureError.noDisplay)
            return
        }
        guard Self.screen(forDisplayID: targetDisplayID) != nil else {
            freezeFailed(CaptureError.noDisplay)
            return
        }

        frozen = Dictionary(uniqueKeysWithValues: shots.map { ($0.displayID, $0) })
        phase = .frozen
        Self.log.info("capture frozen ready displays=\(shots.count, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")

        overlay?.installFrozenBackdrops(Dictionary(uniqueKeysWithValues: shots.map { ($0.displayID, $0.image) }))

        if let pendingSelection {
            Self.log.info("capture pending selection resolved ms=\(self.elapsedMs, privacy: .public)")
            completeSelection(pendingSelection.rect, pendingSelection.screen)
            return
        }

    }

    private func freezeFailed(_ error: Error) {
        guard isRunning else { return }
        overlay?.dismiss()
        overlay = nil
        phase = .cancelled
        endOutcome = "failed"
        onError(error)
        end()
    }

    private func selectionCompleted(_ globalRect: NSRect, _ screen: NSScreen) {
        guard isRunning else { return }
        if frozen[Self.displayID(of: screen)] == nil {
            pendingSelection = (globalRect, screen)
            dismissCompletedOverlayAwaitingFrozenFrame()
            return
        }
        completeSelection(globalRect, screen)
    }

    private func dismissCompletedOverlayAwaitingFrozenFrame() {
        Self.log.info("capture pending selection awaiting frozen frame ms=\(self.elapsedMs, privacy: .public)")
        overlay?.dismiss()
        overlay = nil
    }

    private func completeSelection(_ globalRect: NSRect, _ screen: NSScreen) {
        guard isRunning else { return }
        phase = .finishing

        let did = Self.displayID(of: screen)
        let shot = frozen[did]

        overlay?.dismiss()
        overlay = nil
        frozen = [:]
        pendingSelection = nil

        guard let shot else {
            endOutcome = "missing-frozen-frame"
            end()
            return
        }
        let clamped = globalRect.intersection(screen.frame)
        guard clamped.width >= 3, clamped.height >= 3 else {
            endOutcome = "ignored-small-selection"
            end()
            return
        }
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
        pendingSelection = nil
        end()
    }

    func shutdown() {
        guard isRunning else { return }
        phase = .cancelled
        endOutcome = "shutdown"
        overlay?.dismiss()
        overlay = nil
        frozen = [:]
        pendingSelection = nil
        end(prepareNext: false)
    }

    private var isRunning: Bool {
        switch phase {
        case .freezing, .frozen, .finishing:
            return !didEnd
        case .cancelled:
            return false
        }
    }

    private func end(prepareNext: Bool = true) {
        guard !didEnd else { return }
        didEnd = true
        freezeTask?.cancel()
        freezeTask = nil
        gestureSnapshot = nil
        let displayToPrepare = targetDisplay
        targetDisplay = nil
        hiddenWindows?.restore()
        hiddenWindows = nil
        Self.log.info("capture end outcome=\(self.endOutcome, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
        onEnd()
        if prepareNext, let displayToPrepare {
            frameCache.prepareForNextCapture(display: displayToPrepare)
        }
    }

    private var elapsedMs: Double {
        (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        CGDirectDisplayID(
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
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
