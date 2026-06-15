import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItemController?
    private let capture = CaptureController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Пункт в строке меню: «Сделать снимок» и «Выйти».
        statusItem = StatusItemController(onCapture: { [weak self] in
            self?.capture.triggerCapture()
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
