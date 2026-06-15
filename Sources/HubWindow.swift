import AppKit

/// Круглый нативный Liquid Glass хаб-кнопка со счётчиком. Теперь это САБВЬЮ общего окна-хоста
/// трея (`TrayHostPanel`), а не отдельное окно. Так стекло рисуется в активном виде (одно key-окно,
/// без флаппинга), а клик диспатчится штатным `target/action` NSButton — без ручного перехвата
/// событий. Цифра — это контент: всегда белая (явный attributedTitle), не анимируется.
final class HubWindow {

    /// Кнопка-сабвью. Хост добавляет её в свою иерархию и позиционирует в своих координатах.
    let view: GlassButton
    private let diameter: CGFloat

    var onClick: (() -> Void)? { didSet { view.onClick = onClick } }
    var size: CGFloat { diameter }
    /// Центр в координатах хоста (для растворения/появления карточек в точку хаба).
    var center: NSPoint { NSPoint(x: view.frame.midX, y: view.frame.midY) }

    init() {
        let b = GlassButton(title: "0", a11y: "Свернуть скриншоты")
        b.borderShape = .circle
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .semibold)
        b.font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,
                        size: base.pointSize) ?? base
        // Диаметр = стандартная высота large-контрола (системная метрика), а не магическое число.
        diameter = ceil(b.fittingSize.height)
        b.frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        view = b
        view.attributedTitle = Self.glyph("0", font: view.font ?? base)
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

    /// Обновить счётчик и озвучку. Число — accessibilityValue, состояние трея — label
    /// (без повтора числа), чтобы VoiceOver не дублировал счётчик.
    func setState(count: Int, collapsed: Bool) {
        let f = view.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large))
        view.attributedTitle = Self.glyph("\(count)", font: f)
        view.setAccessibilityValue("\(count)")
        view.setAccessibilityLabel(collapsed ? "Развернуть скриншоты" : "Свернуть скриншоты")
        view.setAccessibilityHelp("Нажмите, чтобы развернуть или свернуть трей")
    }

    /// Позиция в координатах хоста.
    func setOrigin(_ p: NSPoint) { view.setFrameOrigin(p) }
    func show() { view.isHidden = false }
    func hide() { view.isHidden = true }
}
