import AppKit

enum ThumbStyle {
    static let gap: CGFloat = 12                 // зазор между карточками
    static let margin: CGFloat = 16              // отступ от краёв экрана
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 640
    static let defaultWidth: CGFloat = 240
    static let edgeBand: CGFloat = 16            // ширина кромки для ресайза (тянуть за край) — крупная зона хвата
    static let dragThreshold: CGFloat = 6        // порог, после которого клик тела становится drag-out
}

/// Тайминги анимаций трея (одна точка правки, зеркальные вход/выход).
enum TrayAnim {
    static let collapse: Double = 0.3            // растворение/проявление карточки
    static let stagger: Double = 0.03            // сдвиг старта между карточками
}

/// Положение трея миниатюр. Сохраняется в UserDefaults, меняется из окна настроек.
enum TrayPosition: String {
    case right, left, bottom, top
    var isVertical: Bool { self == .right || self == .left }

    static let defaultsKey = "trayPosition"
    static let changedNotification = Notification.Name("QuickShotTrayPositionChanged")

    static var current: TrayPosition {
        TrayPosition(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .right
    }
    static func set(_ pos: TrayPosition) {
        UserDefaults.standard.set(pos.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}

/// Менеджер трея миниатюр. Карточки выкладываются у угла (колонка/ряд), у самого угла —
/// круглый Liquid Glass хаб со счётчиком. Клик по хабу растворяет карточки в него
/// (сворачивание) или проявляет обратно (разворачивание). Новый снимок авто-разворачивает.
/// Общая ширина карточки сохраняется между сессиями.
final class ThumbnailManager {

    private var items: [ThumbnailWindow] = []
    private var collapsed = false
    private var anchorScreen: NSScreen?
    private let hub = HubWindow()

    private let defaults = UserDefaults.standard
    private let widthKey = "thumbnailCardWidth"

    private(set) var cardWidth: CGFloat = ThumbStyle.defaultWidth

    init() {
        let saved = defaults.double(forKey: widthKey)
        if saved > 0 {
            cardWidth = min(ThumbStyle.maxWidth, max(ThumbStyle.minWidth, CGFloat(saved)))
        }
        hub.onClick = { [weak self] in self?.toggleCollapse() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(trayPositionChanged),
            name: TrayPosition.changedNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func trayPositionChanged() { layout(animateNewest: false) }

    private var anchorHeight: CGFloat { (anchorScreen ?? NSScreen.main)?.frame.height ?? 900 }

    // MARK: добавление/удаление

    func add(image: CGImage, on screen: NSScreen) {
        anchorScreen = screen
        let t = ThumbnailWindow(image: image, screen: screen, manager: self,
                                width: cardWidth, screenHeight: screen.frame.height)
        items.append(t)
        for it in items { it.applyWidth(cardWidth, screenHeight: screen.frame.height) }
        if collapsed { expand() }                 // новый снимок авто-разворачивает трей
        else { layout(animateNewest: true) }      // новейшая карточка влетает scale+fade
    }

    func remove(_ t: ThumbnailWindow) {
        items.removeAll { $0 === t }
        t.close()
        layout()
    }

    /// Копирование НЕ закрывает карточку — только короткий фидбэк.
    func copy(_ t: ThumbnailWindow) {
        Clipboard.copy(cgImage: t.image)
        t.flashCopied()
    }

    // MARK: ресайз (общая ширина, сохраняется между сессиями)

    func updateWidthLive(_ w: CGFloat) {
        cardWidth = min(ThumbStyle.maxWidth, max(ThumbStyle.minWidth, w))
        let h = anchorHeight
        for t in items { t.applyWidth(cardWidth, screenHeight: h) }
        layout()
    }

    func persistWidth() { defaults.set(Double(cardWidth), forKey: widthKey) }

    // MARK: сворачивание/разворачивание (растворение в хаб)

    func toggleCollapse() { collapsed ? expand() : collapse() }

    func collapse() {
        guard !collapsed, items.count > 1, let screen = anchorScreen ?? NSScreen.main else { return }
        collapsed = true
        positionHub(on: screen)
        for t in items { t.setCollapsed(true) }
        let c = hub.center
        let (visible, hidden) = cardLayout(on: screen)
        for t in hidden { t.hide() }
        let n = visible.count
        for (i, pair) in visible.enumerated() {       // i=0 — новейшая (у хаба); дальние растворяются первыми
            pair.0.dissolve(toHubCenter: c, duration: TrayAnim.collapse, delay: Double(n - 1 - i) * TrayAnim.stagger)
        }
        hub.setState(count: items.count, collapsed: collapsed)
    }

    func expand() {
        guard collapsed, let screen = anchorScreen ?? NSScreen.main else { return }
        collapsed = false
        positionHub(on: screen)
        for t in items { t.setCollapsed(false) }
        let c = hub.center
        let (visible, hidden) = cardLayout(on: screen)
        for t in hidden { t.hide() }
        for (i, pair) in visible.enumerated() {        // ближняя (новейшая) выходит первой
            pair.0.emerge(fromHubCenter: c, toOrigin: pair.1, duration: TrayAnim.collapse, delay: Double(i) * TrayAnim.stagger)
        }
        hub.setState(count: items.count, collapsed: collapsed)
    }

    // MARK: раскладка (добавление/ресайз/смена положения)

    /// Расставить карточки по местам. animateNewest=true — новейшая карточка (i=0 у хаба)
    /// влетает scale+fade, остальные ставятся мгновенно (иначе fade повторялся бы при
    /// каждом ресайзе/перемещении трея).
    private func layout(animateNewest: Bool = false) {
        guard let screen = anchorScreen ?? NSScreen.main else { return }
        positionHub(on: screen)
        for t in items { t.setCollapsed(collapsed) }
        let (visible, hidden) = cardLayout(on: screen)
        for t in hidden { t.hide() }
        if collapsed {
            for (t, _) in visible { t.hide() }
        } else {
            for (i, pair) in visible.enumerated() {
                if animateNewest && i == 0 { pair.0.appear(at: pair.1) }
                else { pair.0.placeInstant(origin: pair.1) }
            }
        }
    }

    private func positionHub(on screen: NSScreen) {
        hub.setOrigin(hubOrigin(on: screen))
        hub.setState(count: items.count, collapsed: collapsed)
        if items.count >= 2 { hub.show() } else { hub.hide() }
    }

    private func hubOrigin(on screen: NSScreen) -> NSPoint {
        let vf = screen.visibleFrame
        let s = hub.size
        switch TrayPosition.current {
        case .right:  return NSPoint(x: vf.maxX - ThumbStyle.margin - s, y: vf.minY + ThumbStyle.margin)
        case .left:   return NSPoint(x: vf.minX + ThumbStyle.margin,     y: vf.minY + ThumbStyle.margin)
        case .bottom: return NSPoint(x: vf.maxX - ThumbStyle.margin - s, y: vf.minY + ThumbStyle.margin)
        case .top:    return NSPoint(x: vf.maxX - ThumbStyle.margin - s, y: vf.maxY - ThumbStyle.margin - s)
        }
    }

    /// Позиции видимых карточек (новейшая у хаба) + список переполнения (прячем).
    private func cardLayout(on screen: NSScreen) -> (visible: [(ThumbnailWindow, NSPoint)], hidden: [ThumbnailWindow]) {
        let vf = screen.visibleFrame
        let pos = TrayPosition.current
        let s = hub.size
        var visible: [(ThumbnailWindow, NSPoint)] = []
        var hidden: [ThumbnailWindow] = []
        var overflow = false

        if pos.isVertical {
            let x = pos == .right ? (vf.maxX - ThumbStyle.margin - cardWidth) : (vf.minX + ThumbStyle.margin)
            var y = vf.minY + ThumbStyle.margin + s + ThumbStyle.gap      // над хабом
            for (idx, t) in items.reversed().enumerated() {
                if overflow { hidden.append(t); continue }
                let h = t.cardHeight
                if idx > 0 && (y + h) > (vf.maxY - ThumbStyle.margin) { overflow = true; hidden.append(t); continue }
                visible.append((t, NSPoint(x: x, y: y)))
                y += h + ThumbStyle.gap
            }
        } else {
            var x = (vf.maxX - ThumbStyle.margin - s) - ThumbStyle.gap - cardWidth   // слева от хаба
            for (idx, t) in items.reversed().enumerated() {
                if overflow { hidden.append(t); continue }
                if idx > 0 && x < (vf.minX + ThumbStyle.margin) { overflow = true; hidden.append(t); continue }
                let y = pos == .bottom ? (vf.minY + ThumbStyle.margin) : (vf.maxY - ThumbStyle.margin - t.cardHeight)
                visible.append((t, NSPoint(x: x, y: y)))
                x -= (cardWidth + ThumbStyle.gap)
            }
        }
        return (visible, hidden)
    }
}
