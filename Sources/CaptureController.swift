import AppKit

/// Оркестратор одного цикла захвата по модели «заморозка → кадрирование»:
/// хоткей/меню -> проверка доступа -> МГНОВЕННЫЙ снимок полных экранов (без оверлея и активации,
/// чтобы не сбить ховеры/тултипы/активные состояния) -> оверлей с замороженным кадром как подложкой
/// -> выделение -> кадрирование уже снятого изображения -> миниатюра.
final class CaptureController {

    private let capturer = RegionCapturer()
    private var overlay: OverlayController?
    private let thumbnails = ThumbnailManager()
    private var busy = false
    private var frozen: [FrozenScreen] = []

    func triggerCapture() {
        guard !busy else { return }

        // Проверяем доступ ДО снимка, чтобы не ловить пустой кадр.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()   // идемпотентно: перерегистрирует приложение, диалог если статус не определён
            let key = "didRequestScreenRecording"
            if UserDefaults.standard.bool(forKey: key) {
                presentPermissionAlert(firstRun: true)   // спрашивали раньше, доступа нет — ведём в настройки
            } else {
                UserDefaults.standard.set(true, forKey: key)   // первый раз — только системный диалог, без дубля
            }
            return
        }

        busy = true

        // КЛЮЧЕВОЕ: снимаем полные экраны в ПЕРВЫЙ миг — никакого оверлея и NSApp.activate до этого,
        // иначе ховер/тултип/активное состояние под курсором сбросятся ещё до кадра. Только Sendable
        // данные (id + frame) уходят в Task; NSScreen через границу не тащим.
        let displays = NSScreen.screens.map { (id: Self.displayID(of: $0), frame: $0.frame) }
        Task {
            do {
                let shots = try await self.capturer.captureFull(displays: displays)
                await MainActor.run { self.presentSelection(shots) }
            } catch {
                await MainActor.run { self.busy = false; self.handleCaptureError(error) }
            }
        }
    }

    /// Показать выделение поверх замороженных кадров. Здесь активация и оверлей уже безвредны —
    /// пиксели сняты.
    private func presentSelection(_ shots: [FrozenScreen]) {
        guard !shots.isEmpty else { busy = false; return }
        frozen = shots

        var backdrops: [CGDirectDisplayID: CGImage] = [:]
        for s in shots { backdrops[s.displayID] = s.image }

        let oc = OverlayController()
        overlay = oc
        oc.begin(backdrops: backdrops, onComplete: { [weak self] rect, screen in
            self?.handleSelection(rect, screen)
        }, onCancel: { [weak self] in
            self?.overlay?.dismiss(); self?.overlay = nil
            self?.frozen = []; self?.busy = false
        })
    }

    private func handleSelection(_ globalRect: NSRect, _ screen: NSScreen) {
        let did = Self.displayID(of: screen)
        let shot = frozen.first { $0.displayID == did }
        overlay?.dismiss(); overlay = nil
        frozen = []
        busy = false

        guard let shot else { return }
        let clamped = globalRect.intersection(screen.frame)          // не вылезать за дисплей
        guard clamped.width >= 3, clamped.height >= 3,
              let cropped = shot.crop(globalSelection: clamped) else { return }
        thumbnails.add(image: cropped, on: screen)
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        CGDirectDisplayID(
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
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
