import AppKit

/// Шкатулка (`TR-30`, `TR-31`): подложка с обводкой, в которую упакована
/// собранная защёлкой стопка, плюс панель кнопок над карточками.
///
/// Подложка — системный материал с ПИНОМ активного вида
/// (`NSVisualEffectView`, `state = .active`): просвечивающее размытие, не
/// зависящее от того, ключевое окно или нет. Liquid Glass здесь запрещён —
/// его вид гаснет вне фокуса, а трей почти всегда не в фокусе (сага в DEVLOG
/// за июнь 2026). Системное «Понизить прозрачность» материал уважает сам.
///
/// Карточки внутрь НЕ переносятся: они остаются сабвью хоста и лежат между
/// подложкой и панелью. Порядок слоёв задаёт менеджер.
@MainActor
final class TrayCaseView: NSView {
    /// Отступ подложки от карточки ПО БОКАМ. Снизу подложка идёт вровень с
    /// карточкой, сверху место занимает панель кнопок (`TR-30`).
    static let sidePadding: CGFloat = 8
    /// Зазор вокруг панели кнопок: между карточкой и панелью, и над панелью.
    static let panelGap: CGFloat = 8
    /// Скругление контура шкатулки.
    static let cornerRadius: CGFloat = 18

    private let material = NSVisualEffectView(frame: .zero)
    private let borderLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        // Пин активного вида: без него материал гаснет, когда окно не key.
        material.state = .active
        material.appearance = NSAppearance(named: .darkAqua)
        material.wantsLayer = true
        material.layer?.cornerRadius = Self.cornerRadius
        material.layer?.masksToBounds = true
        addSubview(material)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor(white: 1, alpha: 0.14).cgColor
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        material.frame = bounds
        let inset = borderLayer.lineWidth / 2
        borderLayer.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                  cornerWidth: Self.cornerRadius,
                                  cornerHeight: Self.cornerRadius,
                                  transform: nil)
    }

    /// Подложка ловит мышь на всей своей площади: клики по шкатулке не
    /// проваливаются в приложения под треем. Пустота ВНЕ шкатулки
    /// по-прежнему прозрачна для мыши — это решает хост.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
}
