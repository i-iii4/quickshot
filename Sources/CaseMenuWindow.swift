import AppKit

/// Меню команд шкатулки в СВОЁМ окне (`TR-45`).
///
/// Внутри поверхности шкатулки меню жить не может: `dropdown-menu` жёстко
/// зажимается в границы холста, поэтому упиралось в край подложки. Штатного
/// способа «SDK показывает меню отдельным окном» тоже нет – нативный презентер
/// меню есть только у полного macOS-хоста SDK, а QuickShot собран в
/// embed-режиме, где его нет вовсе; `popover` и `menu-surface` в разметке
/// помечены недоступными и требуют Zig-вьюхи.
///
/// Остаётся путь, уже проложенный в проекте окном настроек и подсказкой к
/// кнопкам: окно создаёт AppKit, а рисует его содержимое SDK. Компоненты те
/// же, что были: `dropdown-menu`, `menu-item`, `separator`.
@MainActor
final class CaseMenuWindow {
    /// Зазор между пилюлей-триггером и меню.
    private static let gap: CGFloat = 6
    /// Поле вокруг холста под тень: её рисует движок SDK, и без запаса она
    /// обрезалась бы краем окна.
    private static let shadowSlack: CGFloat = 24

    private let panel: NSPanel
    private let content = NativeCaseMenuView(frame: .zero)

    var isVisible: Bool { panel.isVisible }
    /// Экранная рамка самого меню, без поля под тень: по ней проверяется, попал
    /// ли клик внутрь, и она же входит в остров наведения трея.
    var menuFrame: NSRect {
        guard panel.isVisible else { return .null }
        return content.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    var onCopyAll: (() -> Void)? {
        get { content.onCopyAll } set { content.onCopyAll = newValue }
    }
    var onSaveAll: (() -> Void)? {
        get { content.onSaveAll } set { content.onSaveAll = newValue }
    }
    var onDeleteAll: (() -> Void)? {
        get { content.onDeleteAll } set { content.onDeleteAll = newValue }
    }
    var onDismiss: (() -> Void)? {
        get { content.onDismiss } set { content.onDismiss = newValue }
    }

    init() {
        panel = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Тень рисует SDK внутри холста: системная добавила бы вторую.
        panel.hasShadow = false
        // QuickShot почти всегда неактивен, и панель по умолчанию пряталась бы
        // при деактивации – как у трея, выключаем явно.
        panel.hidesOnDeactivate = false
        // На ступень выше трея: меню лежит поверх карточек и шкатулки.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)
        // Меню не попадает в собственные снимки экрана.
        WindowCaptureProtection.excludeFromScreenCapture(panel)

        let host = MenuHostView(frame: .zero)
        host.addSubview(content)
        panel.contentView = host
    }

    /// Показать меню у пилюли. `anchor` – её экранная рамка, `preferAbove` –
    /// раскрывать вверх (пилюля стоит у нижнего края шкатулки).
    func show(anchor: NSRect, preferAbove: Bool, on screen: NSScreen?) {
        let size = content.fittingSize
        let slack = Self.shadowSlack
        var origin = NSPoint(x: anchor.minX,
                             y: preferAbove ? anchor.maxY + Self.gap
                                            : anchor.minY - Self.gap - size.height)
        // Не хватает места с выбранной стороны – переворачиваем: у меню в
        // отдельном окне граница одна, край экрана.
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            if preferAbove, origin.y + size.height > visible.maxY {
                origin.y = anchor.minY - Self.gap - size.height
            } else if !preferAbove, origin.y < visible.minY {
                origin.y = anchor.maxY + Self.gap
            }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        }
        panel.setFrame(NSRect(x: origin.x - slack, y: origin.y - slack,
                              width: size.width + slack * 2,
                              height: size.height + slack * 2),
                       display: false)
        content.frame = NSRect(x: slack, y: slack, width: size.width, height: size.height)
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Уровень окна на время съёмки: меню обязано уехать вместе с треем,
    /// иначе оно окажется под шторкой захвата или попадёт в кадр.
    func setElevated(_ elevated: Bool) {
        let base = elevated ? CaptureWindowLevels.protectedInterface.rawValue
                            : NSWindow.Level.floating.rawValue
        panel.level = NSWindow.Level(rawValue: base + 1)
    }

    /// Хост-вью окна: мышь ловит только меню, поле под тень прозрачно для неё.
    private final class MenuHostView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            for sub in subviews.reversed() {
                if let hit = sub.hitTest(convert(point, from: superview)) { return hit }
            }
            return nil
        }
    }
}
