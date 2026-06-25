import AppKit

enum ThumbStyle {
    static let gap: CGFloat = 12                 // зазор между карточками
    static let margin: CGFloat = 16              // отступ от краёв экрана
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 640
    static let defaultWidth: CGFloat = 240
    static let resizeBand: CGFloat = 12          // полуширина краевой ручки ресайза (центрирована на крае: ±resizeBand)
    static let dragThreshold: CGFloat = 6        // порог, после которого клик тела становится drag-out
}

/// Тайминги анимаций трея (одна точка правки, зеркальные вход/выход). Быстро и почти незаметно:
/// пространственное движение ~160ms, стаггер минимальный, везде ease-out без перелёта.
enum TrayAnim {
    static let move: Double = 0.16               // влёт новой карточки (scale+fade)
    static let collapse: Double = 0.16           // растворение/проявление карточки (зеркально move)
    static let stagger: Double = 0.015           // сдвиг старта между карточками
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

/// Окно-хост всего трея: ОДНА прозрачная nonactivating-панель на весь экран. Карточки и хаб —
/// её сабвью. Так стекло рисуется в активном виде (активный вид даёт только key-окно — публичного
/// способа показать активное стекло в не-key окне нет, подтверждено Apple DevForums), клики по
/// стеклянным кнопкам диспатчатся штатно, нет флаппинга между панелями и обрезки press-lift.
/// По прозрачным пикселям borderless-окно пропускает клики в приложения под треем (per-pixel hit),
/// поэтому полноэкранный хост не перехватывает мышь в пустых областях.
final class TrayHostPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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

    private let host: TrayHostPanel
    private let hostContent = NSView()

    private let defaults = UserDefaults.standard
    private let widthKey = "thumbnailCardWidth"

    private(set) var cardWidth: CGFloat = ThumbStyle.defaultWidth

    init() {
        host = TrayHostPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        host.isOpaque = false
        host.backgroundColor = .clear                 // прозрачный фон → клики сквозь пустоту проходят
        host.hasShadow = false                        // тень несёт каждая карточка слоем, не окно
        host.level = .statusBar
        host.isFloatingPanel = true
        host.hidesOnDeactivate = false
        host.becomesKeyOnlyIfNeeded = false           // makeKey должен срабатывать для активного стекла
        host.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hostContent.wantsLayer = true
        host.contentView = hostContent
        hostContent.addSubview(hub.view)              // хаб — верхний сабвью; карточки кладём под него

        let saved = defaults.double(forKey: widthKey)
        if saved > 0 {
            cardWidth = min(ThumbStyle.maxWidth, max(ThumbStyle.minWidth, CGFloat(saved)))
        }
        hub.onClick = { [weak self] in self?.toggleCollapse() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(trayPositionChanged),
            name: TrayPosition.changedNotification, object: nil)
        // Смена Spaces/экрана свайпом снимает key с хоста → стекло гаснет («disabled»). Если курсор
        // над треем (пользователь его трогает) — пере-key'им, чтобы стекло ожило без out-and-back.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        // Трей следует за активным экраном. Переход на другой монитор НЕ шлёт activeSpaceDidChange
        // (проверено логом), а NSScreen.main отстаёт на событие — поэтому ловим клики глобально
        // (видят чужие приложения, прав не требуют) и берём экран под курсором: он на первом же
        // клике точен. Триггер по намеренному клику, а не по каждому движению мыши — без дёрганья.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in self?.followActiveScreen()
        }
        // Отключили монитор, на котором стоял трей — перенести на главный, чтобы не завис на «нигде».
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParamsChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private var clickMonitor: Any?

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    private func cursorScreen() -> NSScreen? {
        let m = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) }
    }

    /// Перенести трей на экран под курсором, если он не там (по клику в активном экране).
    private func followActiveScreen() {
        guard host.isVisible, let cur = cursorScreen(), host.frame != cur.frame else { return }
        anchorScreen = cur
        layout(animateNewest: false)
    }

    @objc private func screenParamsChanged() {
        guard host.isVisible, let a = anchorScreen, !NSScreen.screens.contains(a),
              let main = NSScreen.main else { return }
        anchorScreen = main
        layout(animateNewest: false)
    }

    @objc private func trayPositionChanged() { layout(animateNewest: false) }

    @objc private func activeSpaceChanged() {
        guard host.isVisible, mouseOverTray() else { return }
        host.makeKey()
    }

    /// Курсор над картой/хабом (в глобальных координатах)? Хост полноэкранный, поэтому проверяем
    /// именно интерактивные сабвью, а не весь хост.
    private func mouseOverTray() -> Bool {
        let m = NSEvent.mouseLocation
        let o = host.frame.origin
        func globalFrame(_ v: NSView) -> NSRect {
            NSRect(x: o.x + v.frame.minX, y: o.y + v.frame.minY, width: v.frame.width, height: v.frame.height)
        }
        if !hub.view.isHidden, globalFrame(hub.view).contains(m) { return true }
        return items.contains { !$0.hostView.isHidden && globalFrame($0.hostView).contains(m) }
    }

    private var anchorHeight: CGFloat { (anchorScreen ?? NSScreen.main)?.frame.height ?? 900 }

    // MARK: окно-хост (одно key-окно на весь трей)

    /// Подогнать хост под экран привязки: занимает весь frame экрана, координаты сабвью —
    /// это глобальные минус origin экрана.
    private func ensureHost(on screen: NSScreen) {
        anchorScreen = screen
        if host.frame != screen.frame { host.setFrame(screen.frame, display: true) }
    }

    /// Глобальная точка экрана → координаты хоста.
    private func toLocal(_ g: NSPoint) -> NSPoint {
        NSPoint(x: g.x - host.frame.minX, y: g.y - host.frame.minY)
    }

    private func showHost() {
        host.orderFrontRegardless()
        host.makeKey()                                // одно окно — без флаппинга; стекло активно
    }

    /// Запрос key у хоста (вызывает карточка на ховере): стеклянные кнопки светлеют без клика.
    func hostBecomeKey() { if host.isVisible { host.makeKey() } }

    // MARK: добавление/удаление

    func add(image: CGImage, on screen: NSScreen) {
        ensureHost(on: screen)
        let t = ThumbnailWindow(image: image, screen: screen, manager: self,
                                width: cardWidth, screenHeight: screen.frame.height)
        items.append(t)
        hostContent.addSubview(t.hostView, positioned: .below, relativeTo: hub.view)  // новейшая — поверх старых, под хабом
        for it in items { it.applyWidth(cardWidth, screenHeight: screen.frame.height) }
        showHost()
        if collapsed { expand() }                 // новый снимок авто-разворачивает трей
        else { layout(animateNewest: true) }      // новейшая карточка влетает scale+fade
    }

    func remove(_ t: ThumbnailWindow) {
        items.removeAll { $0 === t }
        t.close()
        if items.isEmpty { host.orderOut(nil) } else { layout() }
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
        // Сворачиваем при любом count >= 1 (хаб теперь виден и при одном снимке — клик должен работать).
        guard !collapsed, !items.isEmpty, let screen = anchorScreen ?? NSScreen.main else { return }
        collapsed = true
        positionHub(on: screen)
        for t in items { t.setCollapsed(true) }
        let c = hub.center                            // уже в координатах хоста
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
        let c = hub.center                            // уже в координатах хоста
        let (visible, hidden) = cardLayout(on: screen)
        for t in hidden { t.hide() }
        for (i, pair) in visible.enumerated() {        // ближняя (новейшая) выходит первой
            pair.0.emerge(fromHubCenter: c, toOrigin: toLocal(pair.1), duration: TrayAnim.collapse, delay: Double(i) * TrayAnim.stagger)
        }
        hub.setState(count: items.count, collapsed: collapsed)
    }

    // MARK: раскладка (добавление/ресайз/смена положения)

    /// Расставить карточки по местам. animateNewest=true — новейшая карточка (i=0 у хаба)
    /// влетает scale+fade, остальные ставятся мгновенно.
    private func layout(animateNewest: Bool = false) {
        guard let screen = anchorScreen ?? NSScreen.main else { return }
        ensureHost(on: screen)
        positionHub(on: screen)
        let edgePos = TrayPosition.current
        for t in items { t.setCollapsed(collapsed); t.configureResize(for: edgePos) }
        let (visible, hidden) = cardLayout(on: screen)
        for t in hidden { t.hide() }
        if collapsed {
            for (t, _) in visible { t.hide() }
        } else {
            for (i, pair) in visible.enumerated() {
                let localOrigin = toLocal(pair.1)
                if animateNewest && i == 0 { pair.0.appear(at: localOrigin) }
                else { pair.0.placeInstant(origin: localOrigin) }
            }
        }
    }

    private func positionHub(on screen: NSScreen) {
        hub.setState(count: items.count, collapsed: collapsed)   // сначала размер (ширина капсулы), потом позиция
        hub.setOrigin(toLocal(hubOrigin(on: screen)))
        if items.isEmpty { hub.hide() } else { hub.show() }      // счётчик виден при любом count >= 1
    }

    private func hubOrigin(on screen: NSScreen) -> NSPoint {
        let vf = screen.visibleFrame
        let w = hub.width, h = hub.height                        // капсула: ширина переменная, высота фикс.
        switch TrayPosition.current {
        case .right:  return NSPoint(x: vf.maxX - ThumbStyle.margin - w, y: vf.minY + ThumbStyle.margin)
        case .left:   return NSPoint(x: vf.minX + ThumbStyle.margin,     y: vf.minY + ThumbStyle.margin)
        case .bottom: return NSPoint(x: vf.maxX - ThumbStyle.margin - w, y: vf.minY + ThumbStyle.margin)
        case .top:    return NSPoint(x: vf.maxX - ThumbStyle.margin - w, y: vf.maxY - ThumbStyle.margin - h)
        }
    }

    /// Позиции видимых карточек (новейшая у хаба) + список переполнения (прячем). В ГЛОБАЛЬНЫХ
    /// координатах экрана; вызывающий конвертирует в координаты хоста через toLocal.
    private func cardLayout(on screen: NSScreen) -> (visible: [(ThumbnailWindow, NSPoint)], hidden: [ThumbnailWindow]) {
        let vf = screen.visibleFrame
        let pos = TrayPosition.current
        let hubW = hub.width, hubH = hub.height                  // капсула: высота для вертикали, ширина для горизонтали
        var visible: [(ThumbnailWindow, NSPoint)] = []
        var hidden: [ThumbnailWindow] = []
        var overflow = false

        if pos.isVertical {
            let x = pos == .right ? (vf.maxX - ThumbStyle.margin - cardWidth) : (vf.minX + ThumbStyle.margin)
            var y = vf.minY + ThumbStyle.margin + hubH + ThumbStyle.gap   // над хабом — высота хаба
            for (idx, t) in items.reversed().enumerated() {
                if overflow { hidden.append(t); continue }
                let h = t.cardHeight
                if idx > 0 && (y + h) > (vf.maxY - ThumbStyle.margin) { overflow = true; hidden.append(t); continue }
                visible.append((t, NSPoint(x: x, y: y)))
                y += h + ThumbStyle.gap
            }
        } else {
            var x = (vf.maxX - ThumbStyle.margin - hubW) - ThumbStyle.gap - cardWidth   // слева от хаба — ширина хаба
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
