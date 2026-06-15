import AppKit

/// Токены оформления QuickShot. UI — нативный Liquid Glass: стеклянные кнопки (NSButton
/// bezelStyle .glass) поверх карточки-скриншота. Форму кнопок задаёт borderShape
/// (.capsule для иконка+текст, .circle для иконки/цифры) — отдельного corner-radius у них
/// нет; состояния rest/hover/pressed/focus и press-lift рисует система. Цветовых токенов
/// нет: стекло и контент тонирует сама система.
enum QS {
    /// Радиус скругления карточки-скриншота (единственный кастомный радиус в приложении).
    static let radiusCard: CGFloat = 8
    /// Стандартный шаг разметки macOS (8pt-сетка) — отступ и зазор контролов.
    static let s2: CGFloat = 8
}
