import AppKit

/// Пункт в строке меню. Держит NSStatusItem и его меню; удерживается AppDelegate,
/// чтобы значок не освободился.
final class StatusItemController {

    private let statusItem: NSStatusItem
    private let onCapture: () -> Void
    private let onSettings: () -> Void

    init(onCapture: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onSettings = onSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Простой значок камеры.
            button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "QuickShot")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        // ⌘⇧4 ловит глобальный Carbon-хоткей; не показываем его как акселератор пункта меню —
        // в agent-приложении без главного меню он бы не срабатывал и ломал бы типографику строки.
        let capture = NSMenuItem(title: "Сделать снимок",
                                 action: #selector(captureAction), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)

        let settings = NSMenuItem(title: "Настройки…",
                                  action: #selector(settingsAction), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let access = NSMenuItem(title: "Открыть доступ к записи экрана",
                                action: #selector(openAccessAction), keyEquivalent: "")
        access.target = self
        menu.addItem(access)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Выйти из QuickShot",
                              action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func captureAction() { onCapture() }
    @objc private func settingsAction() { onSettings() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    @objc private func openAccessAction() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
