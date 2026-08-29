import AppKit
import Foundation

/// Рендер панели шкатулки в PNG – свёрнутой и с открытым меню.
///
/// Канал обратной связи для правок интерфейса: смотреть на результат надо
/// ДО сборки приложения, иначе каждая догадка о вёрстке живёт до следующей
/// фотографии экрана (`CLAUDE.md`, девлог 24.08.2026).
@MainActor
@main
struct CasePanelSnapshotTool {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"

        let panel = NativeCasePanelView(frame: .zero)
        panel.setCount(5)
        shoot(panel, name: "case-pill", in: directory)

        panel.frame = NSRect(origin: .zero, size: panel.fittingSize)
        panel.debugToggleCommands()
        shoot(panel, name: "case-pill-expanded", in: directory)

        // Подсветка наведения – часть штатного компонента: её скругление
        // проверяется кадром, а не рассуждением.
        panel.frame = NSRect(origin: .zero, size: panel.fittingSize)
        panel.layoutSubtreeIfNeeded()
        panel.debugHoverButton(title: "Download")
        shoot(panel, name: "case-menu-hover", in: directory)

        // Выравнивание корня привязано к поверхности: трей обязан остаться
        // центрованным. Проверяется кадром, а не рассуждением.
        let copyButton = NativeThumbnailButtonView(kind: .copy)
        shoot(copyButton, name: "tray-copy-button", in: directory)

        print("снимки записаны в \(directory)")
    }

    /// Панель рисуется в своём измеренном размере на подложке шкатулки:
    /// прозрачный фон скрыл бы, куда именно ушло меню.
    private static func shoot(_ panel: NSView, name: String, in directory: String) {
        let size = panel.fittingSize
        let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
        panel.frame = backdrop.bounds
        backdrop.addSubview(panel)
        let window = NSWindow(contentRect: backdrop.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = backdrop
        backdrop.layoutSubtreeIfNeeded()
        panel.layoutSubtreeIfNeeded()
        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let path = "\(directory)/\(name).png"
        try? data.write(to: URL(fileURLWithPath: path))
        print(String(format: "%@: %.0f×%.0f", name, size.width, size.height))
        panel.removeFromSuperview()
    }
}
