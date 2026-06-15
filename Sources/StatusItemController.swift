import AppKit

/// Пункт в строке меню. Держит NSStatusItem и его меню; удерживается AppDelegate,
/// чтобы значок не освободился.
final class StatusItemController {

    private let statusItem: NSStatusItem
    private let onCapture: () -> Void

    init(onCapture: @escaping () -> Void) {
        self.onCapture = onCapture
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "QuickShot")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let capture = NSMenuItem(title: "Сделать снимок  ⌘⇧4",
                                 action: #selector(captureAction), keyEquivalent: "")
        capture.target = self
        menu.addItem(capture)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Выйти из QuickShot",
                              action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func captureAction() { onCapture() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}
