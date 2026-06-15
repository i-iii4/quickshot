import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItemController?
    private let capture = CaptureController()
    private let settings = SettingsController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Пункт в строке меню: снимок, настройки, доступ, выход.
        statusItem = StatusItemController(onCapture: { [weak self] in
            self?.capture.triggerCapture()
        }, onSettings: { [weak self] in
            self?.settings.show()
        })

        // Глобальный хоткей ⌘⇧4. Carbon RegisterEventHotKey не требует никаких прав
        // (ни Accessibility, ни Input Monitoring) — работает с первого запуска.
        GlobalHotKey.shared.register { [weak self] in
            self?.capture.triggerCapture()
        }

        NSLog("QuickShot: запущен (агент, ⌘⇧4)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKey.shared.unregister()
    }
}
