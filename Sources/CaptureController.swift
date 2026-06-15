import AppKit

/// Оркестратор одного цикла захвата:
/// хоткей/меню -> проверка доступа -> оверлеи -> выделение -> спрятать оверлеи ->
/// дать кадр компоновщику -> захват -> миниатюра с «Копировать».
final class CaptureController {

    private let capturer = RegionCapturer()
    private var overlay: OverlayController?
    private var thumbnail: ThumbnailController?
    private var busy = false

    func triggerCapture() {
        guard !busy else { return }

        // Проверяем доступ ДО показа оверлея, чтобы пользователь не выделил область
        // впустую (после выдачи прав ScreenCaptureKit нередко требует перезапуска).
        if !CGPreflightScreenCaptureAccess() {
            let askedKey = "didRequestScreenRecording"
            if !UserDefaults.standard.bool(forKey: askedKey) {
                // Первый раз: показываем ТОЛЬКО системный запрос (у него есть кнопка
                // «Открыть Системные настройки»), без дублирующего своего диалога.
                UserDefaults.standard.set(true, forKey: askedKey)
                _ = CGRequestScreenCaptureAccess()
            } else {
                // Уже спрашивали раньше, доступа по-прежнему нет — направляем в настройки.
                presentPermissionAlert(firstRun: false)
            }
            return
        }

        busy = true
        let oc = OverlayController()
        overlay = oc
        oc.begin(onComplete: { [weak self] rect, screen in
            self?.handleSelection(rect, screen)
        }, onCancel: { [weak self] in
            self?.overlay?.dismiss()
            self?.overlay = nil
            self?.busy = false
        })
    }

    private func handleSelection(_ globalRect: NSRect, _ screen: NSScreen) {
        guard let oc = overlay else { busy = false; return }

        let clamped = globalRect.intersection(screen.frame)        // не вылезать за дисплей
        guard clamped.width >= 3, clamped.height >= 3 else {
            oc.dismiss(); overlay = nil; busy = false; return
        }

        // Готовим только Sendable-данные (CGRect/идентификатор/frame), чтобы не тащить
        // NSScreen через границу Task; NSScreen для миниатюры заново найдём на главном потоке.
        let displayID = CGDirectDisplayID(
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
        let displayFrame = screen.frame

        // 1) спрятать оверлеи. 2) дать компоновщику ~один-два кадра, чтобы затемнение
        // ушло из следующего захваченного кадра. 3) только потом захватывать.
        oc.orderOutAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            Task {
                do {
                    let image = try await self.capturer.capture(
                        globalRect: clamped, displayID: displayID, displayFrame: displayFrame)
                    await MainActor.run {
                        oc.dismiss(); self.overlay = nil
                        let scr = Self.screen(for: displayID) ?? NSScreen.main
                        self.showThumbnail(image, on: scr)
                        self.busy = false
                    }
                } catch {
                    await MainActor.run {
                        oc.dismiss(); self.overlay = nil
                        self.busy = false
                        self.handleCaptureError(error)
                    }
                }
            }
        }
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    private func showThumbnail(_ image: CGImage, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        thumbnail?.close()
        let tc = ThumbnailController(image: image, screen: screen)
        thumbnail = tc
        tc.onClose = { [weak self] in self?.thumbnail = nil }
        tc.show()
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
