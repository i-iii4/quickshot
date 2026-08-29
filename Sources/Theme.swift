import AppKit

/// Токены оформления QuickShot.
///
/// Источник истины – дизайн-система Mine
/// (`/Users/i_iii/Проекты/local-arena/src/styles/global.css`, тёмная тема) и
/// её описание в `/Users/i_iii/Проекты/local-arena/DESIGN_SYSTEM.md`. Значения
/// переведены из oklch в sRGB (D65, oklch → linear sRGB → гамма).
///
/// Псевдостекла в приложении больше нет: подложки красятся сплошным цветом со
/// ступени поверхностей, а не системным материалом (приёмка 27.08.2026).
enum QS {
    /// Внешний радиус: скругление окон macOS 27, где Apple вернула единое
    /// значение для всех окон системы. Шкатулка обязана читаться как окно
    /// системы, а не как своя фигура.
    static let radiusOuter: CGFloat = 16

    /// Внутренний радиус: скругление самого скриншота внутри шкатулки.
    ///
    /// Углы КОНЦЕНТРИЧНЫ: внутренний равен внешнему минус поле между ними
    /// (16 − 4 = 12). При этом дуги внешнего и внутреннего контура идут
    /// параллельно; если внутренний взять произвольным, зазор между контурами
    /// в углу «дышит» – в середине стороны он один, в углу другой.
    static let radiusInner: CGFloat = 12

    /// Поле между внешним и внутренним контуром: подложка шкатулки вокруг
    /// карточек. Оно же задаёт разницу радиусов.
    static let inset: CGFloat = 4

    /// Радиус мелких элементов: бейджей и контролов Native SDK. `--radius-1`
    /// шкалы Mine – своя ступень, не связанная с окном.
    static let radius: CGFloat = 3

    /// Стандартный шаг разметки macOS (8pt-сетка) — отступ и зазор контролов.
    static let s2: CGFloat = 8

    /// Толщина единственной обводки проекта. Mine: «по умолчанию все линии
    /// используют `--border`», 1px без исключений по толщине.
    static let hairline: CGFloat = 1

    /// Лестница поверхностей Mine, равномерный шаг L 0.03.
    enum Color {
        /// `--background` oklch(0.14 0 0) – основание лестницы.
        static let background = NSColor(srgbRed: 9 / 255, green: 9 / 255, blue: 9 / 255, alpha: 1)
        /// `--card` oklch(0.17 0 0) – поверхность панели: подложка шкатулки.
        static let surface = NSColor(srgbRed: 15 / 255, green: 15 / 255, blue: 15 / 255, alpha: 1)
        /// `--secondary` oklch(0.2 0 0) – поверхность +1.
        static let surfaceRaised = NSColor(srgbRed: 22 / 255, green: 22 / 255, blue: 22 / 255, alpha: 1)
        /// `--border` oklch(0.26 0 0) – единственная линия проекта.
        static let border = NSColor(srgbRed: 36 / 255, green: 36 / 255, blue: 36 / 255, alpha: 1)
        /// `--foreground` oklch(0.985 0 0).
        static let text = NSColor(srgbRed: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: 1)
        /// `--muted-foreground` oklch(0.6862 0 0).
        static let textMuted = NSColor(srgbRed: 154 / 255, green: 154 / 255, blue: 154 / 255, alpha: 1)
    }
}
