import AppKit

/// Круглый нативный Liquid Glass хаб-счётчик — САБВЬЮ общего окна-хоста трея. Это системная
/// `.glass`-кнопка (`GlassButton`): стекло, ховер/нажатие и цвет цифры рисует система, как у кнопок
/// карточки (крестик/копировать) — визуально совпадает с ними.
///
/// Известный размен (выбран сознательно ради вида): активный вид `.glass` следует за key/active
/// окна, а трей — фоновая nonactivating-панель, поэтому вне фокуса кнопка приглушается («disabled»)
/// и оживает при наведении/взаимодействии. Публичного способа форсировать активный вид системного
/// контрола в не-key окне нет.
///
/// Внешний API (view/onClick/width/height/center/setState/setOrigin/show/hide) сохранён — менеджер
/// и позднейшие фиксы (видимость при count≥1, доталкивание на фуллскрины) работают без изменений.
final class HubWindow {

    private let button: GlassButton
    private let diameter: CGFloat

    /// Сабвью, которую хост добавляет в свою иерархию и позиционирует.
    var view: NSView { button }

    var onClick: (() -> Void)? { didSet { button.onClick = onClick } }
    var width: CGFloat { diameter }            // круг — ширина = высота
    var height: CGFloat { diameter }
    /// Центр в координатах хоста (для растворения/появления карточек в точку хаба).
    var center: NSPoint { NSPoint(x: button.frame.midX, y: button.frame.midY) }

    init() {
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .semibold)
        let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,
                          size: base.pointSize) ?? base
        button = GlassButton(title: "0", a11y: "Свернуть скриншоты")
        button.borderShape = .circle           // круглая, как раньше
        button.font = font
        // Диаметр = стандартная высота large-контрола (системная метрика), а не магическое число.
        diameter = ceil(button.fittingSize.height)
        button.frame = NSRect(x: 0, y: 0, width: diameter, height: diameter)
    }

    /// Обновить счётчик и озвучку. Цифра — обычный `title`: система даёт контрастный, адаптивный под
    /// тему/стекло цвет (`controlTextColor`). Потолок «99+» держит ширину в пределах круга.
    func setState(count: Int, collapsed: Bool) {
        button.title = count > 99 ? "99+" : "\(count)"
        button.setAccessibilityValue("\(count)")
        button.setAccessibilityLabel(collapsed ? "Развернуть скриншоты" : "Свернуть скриншоты")
        button.setAccessibilityHelp("Нажмите, чтобы развернуть или свернуть трей")
    }

    /// Позиция в координатах хоста.
    func setOrigin(_ p: NSPoint) { button.setFrameOrigin(p) }
    func show() { button.isHidden = false }
    func hide() { button.isHidden = true }
}
