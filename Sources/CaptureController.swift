import AppKit
import CoreGraphics

/// Оркестратор запуска захвата. Сам цикл захвата живёт в `CaptureSession`: так у одного
/// hotkey-цикла есть явное состояние, один владелец overlay и один путь завершения.
@MainActor
final class CaptureController {

    private let capturer = RegionCapturer()
    private let thumbnails = ThumbnailManager()
    private var session: CaptureSession?

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

        let s = CaptureSession(
            capturer: capturer,
            onImage: { [weak self] image, screen in
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
}

/// Одна сессия захвата:
/// 1. мгновенно показывает live selection chrome;
/// 2. параллельно делает frozen screenshot, исключая окна QuickShot;
/// 3. подкладывает frozen backdrop под уже видимую рамку;
/// 4. кадрирует только frozen image.
@MainActor
private final class CaptureSession {

    private enum Phase {
        case freezing
        case frozen
        case finishing
        case cancelled
    }

    private let capturer: RegionCapturer
    private let onImage: (CGImage, NSScreen) -> Void
    private let onError: (Error) -> Void
    private let onEnd: () -> Void

    private var phase: Phase = .freezing
    private var overlay: OverlayController?
    private var frozen: [FrozenScreen] = []
    private var pendingSelection: (rect: NSRect, screen: NSScreen)?
    private var freezeTask: Task<Void, Never>?
    private var didEnd = false

    init(capturer: RegionCapturer,
         onImage: @escaping (CGImage, NSScreen) -> Void,
         onError: @escaping (Error) -> Void,
         onEnd: @escaping () -> Void) {
        self.capturer = capturer
        self.onImage = onImage
        self.onError = onError
        self.onEnd = onEnd
    }

    func start() {
        let initialMouseDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
            ? NSEvent.mouseLocation
            : nil

        let overlay = OverlayController()
        self.overlay = overlay
        overlay.beginLiveSelection(
            initialMouseDownAt: initialMouseDown,
            onComplete: { [weak self] rect, screen in
                self?.selectionCompleted(rect, screen)
            },
            onCancel: { [weak self] in
                self?.cancel()
            })

        let displays = NSScreen.screens.map { (id: Self.displayID(of: $0), frame: $0.frame) }
        freezeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let shots = try await self.capturer.captureFull(
                    displays: displays,
                    excludingBundleIdentifier: Bundle.main.bundleIdentifier)
                guard !Task.isCancelled else { return }
                self.freezeCompleted(shots)
            } catch {
                guard !Task.isCancelled else { return }
                self.freezeFailed(error)
            }
        }
    }

    private func freezeCompleted(_ shots: [FrozenScreen]) {
        guard isRunning else { return }
        guard !shots.isEmpty else {
            freezeFailed(CaptureError.noDisplay)
            return
        }

        frozen = shots
        phase = .frozen
        overlay?.installFrozenBackdrops(Dictionary(uniqueKeysWithValues: shots.map { ($0.displayID, $0.image) }))

        if let pendingSelection {
            self.pendingSelection = nil
            completeSelection(pendingSelection.rect, pendingSelection.screen)
        }
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
        if frozen.isEmpty {
            pendingSelection = (globalRect, screen)
            return
        }
        completeSelection(globalRect, screen)
    }

    private func completeSelection(_ globalRect: NSRect, _ screen: NSScreen) {
        guard isRunning else { return }
        phase = .finishing

        let did = Self.displayID(of: screen)
        let shot = frozen.first { $0.displayID == did }

        overlay?.dismiss()
        overlay = nil
        frozen = []
        pendingSelection = nil

        defer { end() }

        guard let shot else { return }
        let clamped = globalRect.intersection(screen.frame)
        guard clamped.width >= 3, clamped.height >= 3,
              let cropped = shot.crop(globalSelection: clamped) else { return }
        onImage(cropped, screen)
    }

    private func cancel() {
        guard isRunning else { return }
        phase = .cancelled
        overlay?.dismiss()
        overlay = nil
        frozen = []
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
        onEnd()
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        CGDirectDisplayID(
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }
}
