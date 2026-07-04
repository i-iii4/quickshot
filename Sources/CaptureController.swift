import AppKit
import CoreGraphics
import OSLog

/// Оркестратор запуска захвата. Сам цикл захвата живёт в `CaptureSession`: так у одного
/// hotkey-цикла есть явное состояние, один владелец overlay и один путь завершения.
@MainActor
final class CaptureController {

    private let frameCache = ScreenFrameCache()
    private let thumbnails = ThumbnailManager()
    private var session: CaptureSession?

    func prewarmCapturePipeline() {
        let displays = Self.captureDisplays()
        let bundleID = Bundle.main.bundleIdentifier
        let frameCache = self.frameCache
        Task.detached(priority: .userInitiated) {
            await frameCache.start(displays: displays, excludingBundleIdentifier: bundleID)
        }
    }

    func triggerCapture() {
        guard session == nil else { return }

        // Проверяем доступ ДО любого overlay, чтобы не показывать UI поверх неизбежного system prompt.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            let key = "didRequestScreenRecording"
            if UserDefaults.standard.bool(forKey: key) {
                presentPermissionAlert(firstRun: true)
            } else {
                UserDefaults.standard.set(true, forKey: key)
            }
            return
        }

        prewarmCapturePipeline()

        let s = CaptureSession(
            frameCache: frameCache,
            onImage: { [weak self] image, screen in
                Clipboard.copy(cgImage: image)
                self?.thumbnails.add(image: image, on: screen)
            },
            onError: { [weak self] error in
                self?.handleCaptureError(error)
            },
            onEnd: { [weak self] in
                self?.session = nil
            })
        session = s
        s.start()
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
        if case CaptureError.permissionDenied = error {
            presentPermissionAlert(firstRun: false)
        } else {
            NSLog("QuickShot: захват не удался: \(error)")
        }
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
/// 1. скрывает уже видимые окна QuickShot, чтобы они не попали в кадр и не мешали выделению;
/// 2. берёт frozen frame из прогретого ScreenCaptureKit cache, без задержки разового screenshot API;
/// 3. показывает overlay только поверх уже готового frozen backdrop;
/// 4. кадрирует только тот же frozen image.
@MainActor
private final class CaptureSession {

    private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")

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
    private var gestureTracker: CaptureGestureTracker?
    private var didEnd = false
    private let startedAt = CFAbsoluteTimeGetCurrent()

    init(frameCache: ScreenFrameCache,
         onImage: @escaping (CGImage, NSScreen) -> Void,
         onError: @escaping (Error) -> Void,
         onEnd: @escaping () -> Void) {
        self.frameCache = frameCache
        self.onImage = onImage
        self.onError = onError
        self.onEnd = onEnd
    }

    func start() {
        let tracker = CaptureGestureTracker()
        gestureTracker = tracker
        hiddenWindows = HiddenAppWindows.hideVisibleApplicationWindows()

        let targetScreen = Self.screen(containing: tracker.preferredStartPoint) ?? NSScreen.main ?? NSScreen.screens.first
        guard let targetScreen else {
            freezeFailed(CaptureError.noDisplay)
            return
        }
        let targetDisplay = CaptureDisplay(id: Self.displayID(of: targetScreen), frame: targetScreen.frame)
        Self.log.info("capture start targetDisplay=\(targetDisplay.id, privacy: .public)")

        if let cached = frameCache.frozenScreen(for: targetDisplay) {
            Self.log.info("capture cache hit targetDisplay=\(targetDisplay.id, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
            freezeCompleted([cached], targetScreen: targetScreen)
            return
        }

        frameCache.prioritize(display: targetDisplay)
        let cacheWaitNanoseconds: UInt64 = 3_000_000_000
        Self.log.info("capture cache pending targetDisplay=\(targetDisplay.id, privacy: .public); waiting for stream cache timeoutMs=\(Double(cacheWaitNanoseconds) / 1_000_000, privacy: .public)")
        freezeTask = Task { [weak self] in
            guard let self else { return }
            await self.frameCache.start(displays: [targetDisplay], excludingBundleIdentifier: Bundle.main.bundleIdentifier)

            if let cached = await self.frameCache.waitForFrozenScreen(for: targetDisplay, timeoutNanoseconds: cacheWaitNanoseconds) {
                guard !Task.isCancelled else { return }
                Self.log.info("capture cache late hit targetDisplay=\(targetDisplay.id, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
                self.freezeCompleted([cached], targetScreen: targetScreen)
                return
            }

            guard !Task.isCancelled else { return }
            Self.log.error("capture cache unavailable targetDisplay=\(targetDisplay.id, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
            self.freezeFailed(CaptureError.cacheUnavailable)
        }
    }

    private func freezeCompleted(_ shots: [FrozenScreen], targetScreen: NSScreen) {
        guard isRunning else { return }
        guard !shots.isEmpty else {
            freezeFailed(CaptureError.noDisplay)
            return
        }

        frozen = Dictionary(uniqueKeysWithValues: shots.map { ($0.displayID, $0) })
        phase = .frozen
        Self.log.info("capture frozen ready displays=\(shots.count, privacy: .public) ms=\(self.elapsedMs, privacy: .public)")

        if let completed = gestureTracker?.completedSelection(on: [targetScreen]) {
            Self.log.info("capture completed before overlay ms=\(self.elapsedMs, privacy: .public)")
            completeSelection(completed.rect, completed.screen)
            return
        }

        let overlay = OverlayController()
        self.overlay = overlay
        overlay.beginFrozenSelection(
            screens: [targetScreen],
            backdrops: Dictionary(uniqueKeysWithValues: shots.map { ($0.displayID, $0.image) }),
            initialMouseDownAt: gestureTracker?.activeMouseDownStart,
            onComplete: { [weak self] rect, screen in
                self?.selectionCompleted(rect, screen)
            },
            onCancel: { [weak self] in
                self?.cancel()
            })
        Self.log.info("capture overlay ready ms=\(self.elapsedMs, privacy: .public)")
    }

    private func freezeFailed(_ error: Error) {
        guard isRunning else { return }
        overlay?.dismiss()
        overlay = nil
        phase = .cancelled
        onError(error)
        end()
    }

    private func selectionCompleted(_ globalRect: NSRect, _ screen: NSScreen) {
        guard isRunning else { return }
        if frozen[Self.displayID(of: screen)] == nil {
            pendingSelection = (globalRect, screen)
            return
        }
        completeSelection(globalRect, screen)
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

        defer { end() }

        guard let shot else { return }
        let clamped = globalRect.intersection(screen.frame)
        guard clamped.width >= 3, clamped.height >= 3,
              let cropped = shot.crop(globalSelection: clamped) else { return }
        Self.log.info("capture crop complete width=\(Int(clamped.width), privacy: .public) height=\(Int(clamped.height), privacy: .public) ms=\(self.elapsedMs, privacy: .public)")
        onImage(cropped, screen)
    }

    private func cancel() {
        guard isRunning else { return }
        phase = .cancelled
        overlay?.dismiss()
        overlay = nil
        frozen = [:]
        pendingSelection = nil
        end()
    }

    private var isRunning: Bool {
        switch phase {
        case .freezing, .frozen, .finishing:
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
        gestureTracker?.stop()
        gestureTracker = nil
        hiddenWindows?.restore()
        hiddenWindows = nil
        Self.log.info("capture end ms=\(self.elapsedMs, privacy: .public)")
        onEnd()
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
private final class CaptureGestureTracker {
    private var monitor: Any?
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var didRelease = false

    init() {
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            let p = NSEvent.mouseLocation
            startPoint = p
            currentPoint = p
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) {
            [weak self] event in
            DispatchQueue.main.async {
                self?.record(event)
            }
        }
    }

    var preferredStartPoint: NSPoint {
        startPoint ?? NSEvent.mouseLocation
    }

    var activeMouseDownStart: NSPoint? {
        guard CGEventSource.buttonState(.combinedSessionState, button: .left), !didRelease else { return nil }
        if startPoint == nil {
            startPoint = NSEvent.mouseLocation
            currentPoint = startPoint
        }
        return startPoint
    }

    func completedSelection(on screens: [NSScreen]) -> (rect: NSRect, screen: NSScreen)? {
        guard didRelease, let startPoint, let currentPoint else { return nil }
        let rect = NSRect(x: min(startPoint.x, currentPoint.x),
                          y: min(startPoint.y, currentPoint.y),
                          width: abs(currentPoint.x - startPoint.x),
                          height: abs(currentPoint.y - startPoint.y))
        let screen = screens.first { $0.frame.intersects(rect) || NSMouseInRect(currentPoint, $0.frame, false) }
        guard let screen else { return nil }
        return (rect, screen)
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func record(_ event: NSEvent) {
        let p = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            if startPoint == nil || didRelease {
                startPoint = p
                currentPoint = p
                didRelease = false
            }
        case .leftMouseDragged:
            if startPoint == nil { startPoint = p }
            currentPoint = p
        case .leftMouseUp:
            if startPoint == nil { startPoint = p }
            currentPoint = p
            didRelease = true
        default:
            break
        }
    }
}
