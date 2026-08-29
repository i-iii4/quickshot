import AppKit

/// Шкатулка (`TR-30`, `TR-31`): подложка с обводкой, в которую упакована
/// собранная защёлкой стопка, плюс панель кнопок над карточками.
///
/// Подложка — СПЛОШНАЯ заливка со ступени поверхностей Mine (`QS.Color`),
/// без системных материалов. Псевдостекло убрано целиком (приёмка
/// 27.08.2026): просвечивающий `NSVisualEffectView` брал тон у того, что под
/// окном, поэтому его нельзя было согласовать ни с одним токеном — меню
/// дизайн-системы читалось на нём вырезанной дырой. Заодно снимается вся сага
/// с Liquid Glass и пином активного вида: гаснуть больше нечему.
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
    /// Скругление контура шкатулки – единственный радиус проекта.
    static let cornerRadius: CGFloat = QS.radius

    private let fill = CALayer()
    private let borderLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Сплошная заливка со ступени поверхностей Mine вместо системного
        // материала. Псевдостекло убрано целиком: `NSVisualEffectView`
        // просвечивал рабочий стол, и тон подложки зависел от того, что под
        // ней, — с ним нельзя было согласовать ни один токен (приёмка
        // 27.08.2026).
        fill.backgroundColor = QS.Color.surface.cgColor
        fill.cornerRadius = Self.cornerRadius
        fill.masksToBounds = true
        layer?.addSublayer(fill)

        borderLayer.fillColor = nil
        borderLayer.strokeColor = QS.Color.border.cgColor
        borderLayer.lineWidth = QS.hairline
        layer?.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        // Слои без обёртки анимируют смену рамки сами, и подложка тянулась бы
        // за шкатулкой с отставанием в четверть секунды.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = bounds
        let inset = borderLayer.lineWidth / 2
        borderLayer.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                  cornerWidth: Self.cornerRadius,
                                  cornerHeight: Self.cornerRadius,
                                  transform: nil)
        CATransaction.commit()
    }

    /// Подложка ловит мышь на всей своей площади: клики по шкатулке не
    /// проваливаются в приложения под треем. Пустота ВНЕ шкатулки
    /// по-прежнему прозрачна для мыши — это решает хост.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
}
