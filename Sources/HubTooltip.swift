import AppKit
import OSLog

/// Подпись команды-иконки. Системный help tag здесь не работает: его
/// tracking-области живут только в активном приложении, а QuickShot —
/// accessory-процесс, который почти никогда не активен. Поэтому ярлык
/// показывает собственное окно, управляемое тем же hover-пайплайном, что
/// и подсветка кнопок. Цвета приходят из отрендеренной House-поверхности,
/// радиус — из токена контролов; Swift не держит собственных констант цвета.
@MainActor
final class HubTooltipWindow {
    static let showDelay: TimeInterval = 0.6
    private static let fade: TimeInterval = 0.09
    private static let gap: CGFloat = 5
    private static let paddingX: CGFloat = 8
    private static let paddingY: CGFloat = 5

    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot",
                                                category: "tooltip")

    private let panel: NSPanel
    private let bubble = NSView()
    private let label = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        // Панель прячется при деактивации приложения по умолчанию, а QuickShot
        // неактивен почти всегда — как и у панели трея, выключаем явно.
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)
        WindowCaptureProtection.excludeFromScreenCapture(panel)
        bubble.wantsLayer = true
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.alignment = .center
        bubble.addSubview(label)
        panel.contentView = bubble
    }

    /// `anchor` — экранный frame кнопки. `below` — для трея у верхнего края,
    /// где над рядом нет места.
    func show(text: String,
              anchor: NSRect,
              below: Bool,
              fill: NSColor,
              stroke: NSColor,
              radius: CGFloat,
              screen: NSScreen?) {
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + Self.paddingX * 2,
                          height: ceil(label.frame.height) + Self.paddingY * 2)
        label.frame = NSRect(x: Self.paddingX, y: Self.paddingY,
                             width: size.width - Self.paddingX * 2,
                             height: size.height - Self.paddingY * 2)

        var origin = NSPoint(x: anchor.midX - size.width / 2,
                             y: below ? anchor.minY - Self.gap - size.height
                                      : anchor.maxY + Self.gap)
        if let bounds = screen?.frame {
            origin.x = min(max(origin.x, bounds.minX + Self.paddingX),
                           bounds.maxX - size.width - Self.paddingX)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
        }

        if let layer = bubble.layer {
            layer.backgroundColor = fill.cgColor
            layer.borderColor = stroke.cgColor
            layer.borderWidth = 1 / max(1, panel.backingScaleFactor)
            layer.cornerRadius = radius
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        let firstShow = !panel.isVisible
        panel.orderFrontRegardless()
        Self.log.info("show '\(text, privacy: .public)' at \(String(describing: NSRect(origin: origin, size: size)), privacy: .public) visible=\(self.panel.isVisible)")
        guard firstShow else { return }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fade
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

#if TESTING
    var debugVisibleText: String? { panel.isVisible ? label.stringValue : nil }
    var debugSharingIsNone: Bool { panel.sharingType == .none }
    var debugIgnoresMouse: Bool { panel.ignoresMouseEvents }
#endif
}
