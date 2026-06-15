import AppKit

/// Панель хаба должна уметь становиться key: иначе клик по стеклянной кнопке в borderless
/// nonactivating-панели не диспатчится, а контент стекла рисуется в неактивном (приглушённом)
/// виде. Nonactivating — берёт key, не активируя приложение.
private final class HubPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Круглый нативный Liquid Glass хаб-кнопка со счётчиком. Клик сворачивает/разворачивает трей.
/// Ховер/нажатие/подъём рисует система (bezelStyle .glass). Цифра — это контент: она всегда
/// на полном контрасте и НЕ анимируется (никакого масштаба всего слоя), только обновляет
/// значение; фидбэк «снимок добавлен» несёт влёт самой карточки.
final class HubWindow {

    private let panel: HubPanel
    private let button: GlassButton
    private let diameter: CGFloat

    var onClick: (() -> Void)? { didSet { button.onClick = onClick } }
    var size: CGFloat { diameter }
    var center: NSPoint { NSPoint(x: panel.frame.midX, y: panel.frame.midY) }

    init() {
        button = GlassButton(title: "0", a11y: "Свернуть скриншоты")
        button.borderShape = .circle
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .semibold)
        button.font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,
                             size: base.pointSize) ?? base
        // Диаметр = стандартная высота large-контрола (системная метрика), а не магическое число.
        diameter = ceil(button.fittingSize.height)
        button.frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)

        panel = HubPanel(contentRect: NSRect(x: 0, y: 0, width: diameter, height: diameter),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                 // у стеклянной кнопки свой материал/тень
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        content.addSubview(button)
        panel.contentView = content
    }

    /// Обновить счётчик и озвучку. Число — это accessibilityValue, состояние трея — label
    /// (без повтора числа), чтобы VoiceOver не дублировал счётчик.
    func setState(count: Int, collapsed: Bool) {
        button.title = "\(count)"
        button.setAccessibilityValue("\(count)")
        button.setAccessibilityLabel(collapsed ? "Развернуть скриншоты" : "Свернуть скриншоты")
        button.setAccessibilityHelp("Нажмите, чтобы развернуть или свернуть трей")
    }

    func setOrigin(_ p: NSPoint) { panel.setFrameOrigin(p) }
    // key (nonactivating — без активации приложения): цифра рисуется на полном контрасте,
    // и клик по кнопке надёжно диспатчится.
    func show() { panel.orderFrontRegardless(); panel.makeKey() }
    func hide() { panel.orderOut(nil) }
}
