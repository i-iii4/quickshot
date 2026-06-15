import AppKit

/// Панель хаба. isKeyWindow=true — стекло и цифра всегда рисуются в активном виде, без
/// makeKey-флаппинга между панелями. Это только self-report для отрисовки: системное key-окно
/// и ввод с клавиатуры у активного приложения не трогаются.
private final class HubPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

/// Кнопка хаба. В borderless nonactivating-панели модальный tracking-loop ячейки NSButton не
/// доводит target/action до диспетчеризации, поэтому клик ловим сами: подсветка на нажатии,
/// onClick — на отпускании внутри bounds. super.mouseDown не зовём (его цикл съел бы mouseUp),
/// target/action обнулены в HubWindow — двойного срабатывания нет.
private final class HubButton: GlassButton {
    override func mouseDown(with event: NSEvent) { isHighlighted = true }
    override func mouseDragged(with event: NSEvent) {
        isHighlighted = bounds.contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        isHighlighted = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Круглый нативный Liquid Glass хаб-кнопка со счётчиком. Клик сворачивает/разворачивает трей.
/// Ховер/нажатие/подъём рисует система (bezelStyle .glass). Цифра — это контент: она всегда
/// на полном контрасте и НЕ анимируется (никакого масштаба всего слоя), только обновляет
/// значение; фидбэк «снимок добавлен» несёт влёт самой карточки.
final class HubWindow {

    private let panel: HubPanel
    private let button: HubButton
    private let diameter: CGFloat

    var onClick: (() -> Void)? { didSet { button.onClick = onClick } }
    var size: CGFloat { diameter }
    var center: NSPoint { NSPoint(x: panel.frame.midX, y: panel.frame.midY) }

    init() {
        button = HubButton(title: "0", a11y: "Свернуть скриншоты")
        button.borderShape = .circle
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .semibold)
        button.font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,
                             size: base.pointSize) ?? base
        // Клик ловит сам HubButton (mouseUp), цикл ячейки не используем — обнуляем target/action,
        // чтобы исключить второй путь срабатывания.
        button.target = nil
        button.action = nil
        // Диаметр = стандартная высота large-контрола (системная метрика), а не магическое число.
        diameter = ceil(button.fittingSize.height)
        button.frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        button.attributedTitle = Self.glyph("0", font: button.font ?? base)

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

    /// Цифра хаба всегда белая на полном контрасте: задаём явным attributedTitle (цвет + шрифт +
    /// центрирование), а не голым title — иначе система перекрашивает её под состояние кнопки.
    private static func glyph(_ s: String, font: NSFont) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        return NSAttributedString(string: s, attributes: [
            .foregroundColor: NSColor.white,
            .font: font,
            .paragraphStyle: para,
        ])
    }

    /// Обновить счётчик и озвучку. Число — это accessibilityValue, состояние трея — label
    /// (без повтора числа), чтобы VoiceOver не дублировал счётчик.
    func setState(count: Int, collapsed: Bool) {
        button.attributedTitle = Self.glyph("\(count)", font: button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large)))
        button.setAccessibilityValue("\(count)")
        button.setAccessibilityLabel(collapsed ? "Развернуть скриншоты" : "Свернуть скриншоты")
        button.setAccessibilityHelp("Нажмите, чтобы развернуть или свернуть трей")
    }

    func setOrigin(_ p: NSPoint) { panel.setFrameOrigin(p) }
    // Активный вид (цифра на полном контрасте, стекло яркое) даёт isKeyWindow=true панели —
    // makeKey не нужен (он вызывал key-флаппинг между панелями).
    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
}
