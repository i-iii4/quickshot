import AppKit

/// Пункт в строке меню. Меню — системное `NSMenu`: это не фирменная
/// поверхность продукта, а системная точка входа, где пользователь ожидает
/// ровно платформенного поведения. От системы приходят бесплатно клавиатурная
/// навигация (стрелки, Esc, первые буквы), VoiceOver, drag-select от иконки,
/// подсветка активного статус-айтема, материал и позиционирование на любом
/// экране. Собственная отрисовка меню всё это теряла.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let onCapture: () -> Void
    private let onSettings: () -> Void

    init(onCapture: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onSettings = onSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            WindowCaptureProtection.registerExternalWindow { [weak button] in button?.window }
            button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "QuickShot")
            button.image?.isTemplate = true
            if let window = button.window {
                WindowCaptureProtection.excludeFromScreenCapture(window)
            }
        }

        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(item(title: "Сделать снимок",
                          action: #selector(menuCapture),
                          keyEquivalent: "4",
                          modifiers: [.command, .shift]))
        menu.addItem(item(title: "Настройки...",
                          action: #selector(menuSettings),
                          keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(item(title: "Открыть доступ к записи экрана",
                          action: #selector(menuAccess)))
        menu.addItem(.separator())
        menu.addItem(item(title: "Выйти из QuickShot",
                          action: #selector(menuQuit),
                          keyEquivalent: "q"))
        return menu
    }

    private func item(title: String,
                      action: Selector,
                      keyEquivalent: String = "",
                      modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if !keyEquivalent.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    /// Меню статус-айтема — окно WindowServer, а не окно приложения, поэтому
    /// защита от захвата ставится на него при каждом открытии.
    func menuWillOpen(_ menu: NSMenu) {
        WindowCaptureProtection.protectAllApplicationWindows()
    }

    // Снимок запускается после закрытия меню: иначе системная анимация
    // закрытия попала бы в замороженные пиксели.
    @objc private func menuCapture() {
        let capture = onCapture
        DispatchQueue.main.async { capture() }
    }

    @objc private func menuSettings() { onSettings() }

    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuAccess() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
