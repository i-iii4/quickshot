import AppKit
import UniformTypeIdentifiers

enum ThumbStyle {
    static let gap: CGFloat = 12                 // зазор между карточками
    static let margin: CGFloat = 16              // отступ от краёв экрана
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 640
    static let defaultWidth: CGFloat = 240
    static let resizeBand: CGFloat = 12          // полуширина краевой ручки ресайза (центрирована на крае: ±resizeBand)
    static let dragThreshold: CGFloat = 6        // порог, после которого клик тела становится drag-out
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
/// её сабвью. Панель может стать key внутри процесса, не активируя чужое приложение; так первый
/// клик стабильно доходит до controls трея, без флаппинга между несколькими панелями.
/// По прозрачным пикселям borderless-окно пропускает клики в приложения под треем (per-pixel hit),
/// поэтому полноэкранный хост не перехватывает мышь в пустых областях.
final class TrayHostPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Менеджер трея миниатюр. Карточки выкладываются у угла (колонка/ряд), у самого угла —
/// House Dark command hub со счётчиком. Клик по хабу растворяет карточки в него
/// (сворачивание) или проявляет обратно (разворачивание). Новый снимок в свёрнутом трее
/// показывается как короткое подтверждение, не меняя состояние трея.
/// Общая ширина карточки сохраняется между сессиями.
final class ThumbnailManager {

    private var items: [ThumbnailWindow] = []
    private var collapsed = false
    private var anchorScreen: NSScreen?
    private let hub = HubWindow()

    private let host: TrayHostPanel
    private let hostContent = TrayHostContentView()
    private lazy var trayAnimator = TrayProgressAnimator(hostView: hostContent)
    private lazy var collectionAnimator = CollectionProgressAnimator(hostView: hostContent)
    private var trayProgress: CGFloat = 0
    private var collectionCompletion: (() -> Void)?
    private var collapsedPeekWorkItem: DispatchWorkItem?
    private var hoverExitWorkItem: DispatchWorkItem?
    private var collapsedPeekGeneration: UInt = 0
    private var hoverExitGeneration: UInt = 0
    private weak var collapsedPeekItem: ThumbnailWindow?
    private var trayHoverActive = false

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
        host.becomesKeyOnlyIfNeeded = false           // makeKey должен срабатывать для controls трея
        WindowCaptureProtection.excludeFromScreenCapture(host)
        host.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hostContent.wantsLayer = true
        host.contentView = hostContent
        hostContent.addSubview(hub.view)              // хаб — верхний сабвью; карточки кладём под него

        let saved = defaults.double(forKey: widthKey)
        if saved > 0 {
            cardWidth = min(ThumbStyle.maxWidth, max(ThumbStyle.minWidth, CGFloat(saved)))
        }
        hub.onClick = { [weak self] in self?.toggleCollapse() }
        hub.onDelete = { [weak self] in self?.deleteAll() }
        hub.onSaveAs = { [weak self] in self?.saveAllAs() }
        hub.onCopyAll = { [weak self] in self?.copyAll() }
        hub.onHoverChanged = { [weak self] entered in
            self?.hubHoverChanged(entered: entered)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(trayPositionChanged),
            name: TrayPosition.changedNotification, object: nil)
        // Смена Spaces/экрана свайпом снимает key с хоста. Если курсор над треем
        // (пользователь его трогает) — пере-key'им, чтобы первый клик снова шёл в controls.
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
        collapsedPeekWorkItem?.cancel()
        hoverExitWorkItem?.cancel()
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
        layout()
    }

    @objc private func screenParamsChanged() {
        guard host.isVisible, let a = anchorScreen, !NSScreen.screens.contains(a),
              let main = NSScreen.main else { return }
        anchorScreen = main
        layout()
    }

    @objc private func trayPositionChanged() { layout() }

    @objc private func activeSpaceChanged() {
        guard host.isVisible else { return }
        host.orderFrontRegardless()             // доталкиваем трей в текущий Space (вкл. фуллскрин via fullScreenAuxiliary)
        if mouseOverTray() { host.makeKey() }   // controls трея остаются доступны, если курсор над ним
    }

    /// Курсор над картой/хабом (в глобальных координатах)? Хост полноэкранный, поэтому проверяем
    /// именно интерактивные сабвью, а не весь хост.
    private func mouseOverTray() -> Bool {
        let m = NSEvent.mouseLocation
        let o = host.frame.origin
        func globalFrame(_ v: NSView) -> NSRect {
            NSRect(x: o.x + v.frame.minX, y: o.y + v.frame.minY, width: v.frame.width, height: v.frame.height)
        }
        let localMouse = NSPoint(x: m.x - o.x, y: m.y - o.y)
        if !hub.view.isHidden, hub.contains(localMouse) { return true }
        return items.contains { !$0.hostView.isHidden && globalFrame($0.hostView).contains(m) }
    }

    private var cardsAreCollapsed: Bool {
        thumbnailTrayCollapseTarget(userCollapsed: collapsed,
                                    hoverExpanded: trayHoverActive) == 1
    }

    private func cancelCollapsedPeekDismiss() {
        collapsedPeekGeneration &+= 1
        collapsedPeekWorkItem?.cancel()
        collapsedPeekWorkItem = nil
    }

    private func cancelHoverExit() {
        hoverExitGeneration &+= 1
        hoverExitWorkItem?.cancel()
        hoverExitWorkItem = nil
    }

    private func hubHoverChanged(entered: Bool) {
        guard !items.isEmpty else { return }
        if entered {
            cancelHoverExit()
            beginTrayHoverSession()
        } else if trayHoverActive {
            scheduleCollapsedPresentationExit()
        }
    }

    private func thumbnailHoverChanged(_ thumbnail: ThumbnailWindow, entered: Bool) {
        if entered {
            cancelHoverExit()
            if collapsedPeekItem === thumbnail { cancelCollapsedPeekDismiss() }
            if collapsed, !trayHoverActive, collapsedPeekItem == nil, trayProgress < 0.999 {
                beginTrayHoverSession()
            }
        } else if trayHoverActive || collapsedPeekItem === thumbnail {
            scheduleCollapsedPresentationExit()
        }
    }

    private func beginTrayHoverSession() {
        guard !trayHoverActive, !items.isEmpty else { return }
        if collapsed {
            cancelCollapsedPeekDismiss()
            collapsedPeekItem = nil
            finishCollectionMotion()
        }
        trayHoverActive = true
        hub.setTrayHoverActive(true)
        if collapsed, let screen = anchorScreen ?? NSScreen.main {
            runTrayTransition(to: 0, on: screen)
        }
    }

    private func scheduleCollapsedPresentationExit() {
        guard trayHoverActive || (collapsed && collapsedPeekItem != nil) else { return }
        cancelHoverExit()
        let generation = hoverExitGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.trayHoverActive || (self.collapsed && self.collapsedPeekItem != nil) else { return }
            guard self.hoverExitGeneration == generation else { return }
            self.hoverExitWorkItem = nil
            guard !self.mouseOverTray() else { return }
            if self.trayHoverActive {
                self.endTrayHoverSession()
            } else if let peek = self.collapsedPeekItem {
                self.dismissCollapsedPeek(peek)
            }
        }
        hoverExitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TrayAnim.hoverExitGrace, execute: work)
    }

    private func endTrayHoverSession() {
        guard trayHoverActive else { return }
        trayHoverActive = false
        hub.setTrayHoverActive(false)
        guard collapsed, let screen = anchorScreen ?? NSScreen.main else { return }
        finishCollectionMotion()
        runTrayTransition(to: 1, on: screen)
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
        host.makeKey()                                // одно окно — без флаппинга
    }

    /// Запрос key у хоста (вызывает карточка на ховере): controls получают первый клик без активации app.
    func hostBecomeKey() { if host.isVisible { host.makeKey() } }

    // MARK: добавление/удаление

    func add(image: CGImage, on screen: NSScreen) {
        finishCollectionMotion()
        finishTrayMotion()
        cancelCollapsedPeekDismiss()
        cancelHoverExit()
        ensureHost(on: screen)
        let t = ThumbnailWindow(image: image, screen: screen, manager: self,
                                width: cardWidth, screenHeight: screen.frame.height)
        t.onHoverChanged = { [weak self, weak t] entered in
            guard let self, let t else { return }
            self.thumbnailHoverChanged(t, entered: entered)
        }
        items.append(t)
        hostContent.addSubview(t.hostView, positioned: .below, relativeTo: hub.view)  // новейшая — поверх старых, под хабом
        for it in items { it.applyWidth(cardWidth, screenHeight: screen.frame.height) }
        showHost()
        positionHub(on: screen, animateChevron: false, animateCount: true)
        hub.setCountTransitionProgress(0)
        cardsAreCollapsed ? presentCollapsedCapture(t, on: screen)
                          : animateInsertion(t, on: screen)
    }

    func remove(_ t: ThumbnailWindow) {
        guard items.contains(where: { $0 === t }) else { return }
        animateRemoval([t])
    }

    private func runCollectionMotion(duration: CFTimeInterval,
                                     onFrame: @escaping (CGFloat) -> Void,
                                     completion: @escaping () -> Void) {
        collectionCompletion = completion
        collectionAnimator.run(duration: duration,
                               onFrame: onFrame,
                               onDone: { [weak self] in
            guard let self else { return }
            self.collectionCompletion = nil
            completion()
        })
    }

    private func finishCollectionMotion() {
        guard let completion = collectionCompletion else {
            collectionAnimator.cancel()
            return
        }
        collectionCompletion = nil
        collectionAnimator.cancel()
        completion()
    }

    private func animateInsertion(_ inserted: ThumbnailWindow, on screen: NSScreen) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let (visible, hidden) = cardLayout(on: screen)
        for item in hidden { item.hide() }
        for (item, origin) in visible where item !== inserted {
            item.placeInstant(origin: toLocal(origin))
        }
        guard let origin = visible.first(where: { $0.0 === inserted })?.1 else {
            inserted.hide()
            runCollectionMotion(duration: reduceMotion ? TrayAnim.reducedTransition : TrayAnim.insertion,
                                onFrame: { [weak self] progress in
                self?.hub.setCountTransitionProgress(progress)
            }, completion: { [weak self] in
                self?.hub.setCountTransitionProgress(1)
            })
            return
        }
        inserted.prepareInsertion(at: toLocal(origin),
                                  from: collectionDirectionalOffset(),
                                  reduceMotion: reduceMotion)
        runCollectionMotion(duration: reduceMotion ? TrayAnim.reducedTransition : TrayAnim.insertion,
                            onFrame: { [weak self, weak inserted] progress in
            inserted?.applyInsertion(progress: progress, reduceMotion: reduceMotion)
            self?.hub.setCountTransitionProgress(progress)
        }, completion: { [weak self, weak inserted] in
            inserted?.finishCollectionMotion()
            self?.hub.setCountTransitionProgress(1)
        })
    }

    private func presentCollapsedCapture(_ inserted: ThumbnailWindow, on screen: NSScreen) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        collapsedPeekItem = inserted
        for item in items where item !== inserted { item.hide() }
        let edge = ThumbnailLayoutEdge(rawValue: TrayPosition.current.rawValue)!
        let margin = TrayPosition.current == .left
            ? ThumbStyle.margin + hub.leadingRevealClearance
            : ThumbStyle.margin
        let slot = thumbnailLayout(screenFrame: screen.frame,
                                   edge: edge,
                                   cardWidth: cardWidth,
                                   cardHeights: [inserted.cardHeight],
                                   hubSize: NSSize(width: hub.width, height: hub.height),
                                   margin: margin,
                                   gap: ThumbStyle.gap).visible.first
        guard let slot else {
            collapsedPeekItem = nil
            inserted.hide()
            hub.setCountTransitionProgress(1)
            return
        }
        inserted.prepareInsertion(at: toLocal(slot.origin),
                                  from: collectionDirectionalOffset(),
                                  reduceMotion: reduceMotion)
        runCollectionMotion(duration: reduceMotion ? TrayAnim.reducedTransition : TrayAnim.insertion,
                            onFrame: { [weak self, weak inserted] progress in
            inserted?.applyInsertion(progress: progress, reduceMotion: reduceMotion)
            self?.hub.setCountTransitionProgress(progress)
        }, completion: { [weak self, weak inserted] in
            guard let self, let inserted else { return }
            inserted.finishCollectionMotion()
            self.hub.setCountTransitionProgress(1)
            self.scheduleCollapsedPeekDismiss(inserted,
                                              after: TrayAnim.collapsedPeekHold,
                                              reduceMotion: reduceMotion)
        })
    }

    private func scheduleCollapsedPeekDismiss(_ inserted: ThumbnailWindow,
                                              after delay: TimeInterval,
                                              reduceMotion: Bool) {
        cancelCollapsedPeekDismiss()
        let generation = collapsedPeekGeneration
        let work = DispatchWorkItem { [weak self, weak inserted] in
            guard let self, let inserted,
                  self.collapsedPeekGeneration == generation,
                  self.collapsed, !self.trayHoverActive,
                  self.collapsedPeekItem === inserted else { return }
            self.collapsedPeekWorkItem = nil
            guard !self.mouseOverTray() else { return }
            self.dismissCollapsedPeek(inserted, reduceMotion: reduceMotion)
        }
        collapsedPeekWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dismissCollapsedPeek(_ inserted: ThumbnailWindow,
                                      reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        guard collapsed, !trayHoverActive, collapsedPeekItem === inserted else { return }
        finishCollectionMotion()
        guard collapsed, !trayHoverActive, collapsedPeekItem === inserted else { return }
        cancelCollapsedPeekDismiss()
        collapsedPeekItem = nil
        inserted.prepareRemoval(toward: collectionDirectionalOffset(), reduceMotion: reduceMotion)
        runCollectionMotion(duration: reduceMotion ? TrayAnim.reducedTransition : TrayAnim.collapsedPeekExit,
                            onFrame: { [weak inserted] progress in
            inserted?.applyRemoval(progress: progress, reduceMotion: reduceMotion)
        }, completion: { [weak inserted] in
            inserted?.finishCollectionMotion(hidden: true)
        })
    }

    private func animateRemoval(_ removed: [ThumbnailWindow]) {
        finishCollectionMotion()
        finishTrayMotion()
        cancelCollapsedPeekDismiss()
        cancelHoverExit()
        let removesVisiblePeek = removed.contains { $0 === collapsedPeekItem }
        if removesVisiblePeek { collapsedPeekItem = nil }
        guard let screen = anchorScreen ?? NSScreen.main else { return }
        let removedIDs = Set(removed.map { ObjectIdentifier($0) })
        let oldFrames = Dictionary(uniqueKeysWithValues: items.map { (ObjectIdentifier($0), $0.layoutFrame) })
        items.removeAll { removedIDs.contains(ObjectIdentifier($0)) }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animateCards = !cardsAreCollapsed || removesVisiblePeek

        positionHub(on: screen, animateChevron: false, animateCount: true)
        if items.isEmpty { hub.show() }
        hub.setCountTransitionProgress(0)

        let (visible, hidden) = cardLayout(on: screen)
        for item in hidden { item.hide() }
        let reflowing: [(ThumbnailWindow, NSRect)]
        if animateCards {
            reflowing = visible.compactMap { item, origin -> (ThumbnailWindow, NSRect)? in
                guard let oldFrame = oldFrames[ObjectIdentifier(item)] else { return nil }
                item.prepareReflow(from: oldFrame,
                                   to: thumbnailAxisLockedOrigin(candidate: toLocal(origin),
                                                                 oldOuterFrame: oldFrame,
                                                                 resizeBand: ThumbStyle.resizeBand,
                                                                 vertical: TrayPosition.current.isVertical),
                                   reduceMotion: reduceMotion)
                return (item, oldFrame)
            }
        } else {
            reflowing = []
        }
        if animateCards {
            for item in removed {
                item.prepareRemoval(toward: collectionDirectionalOffset(), reduceMotion: reduceMotion)
            }
        }

        runCollectionMotion(duration: reduceMotion ? TrayAnim.reducedTransition : TrayAnim.removalAndReflow,
                            onFrame: { [weak self] progress in
            for (item, oldFrame) in reflowing {
                item.applyReflow(progress: progress, from: oldFrame, reduceMotion: reduceMotion)
            }
            if animateCards {
                for item in removed { item.applyRemoval(progress: progress, reduceMotion: reduceMotion) }
            }
            self?.hub.setCountTransitionProgress(progress)
        }, completion: { [weak self] in
            guard let self else { return }
            for (item, _) in reflowing { item.finishCollectionMotion() }
            for item in removed { item.close() }
            self.hub.setCountTransitionProgress(1)
            if self.items.isEmpty {
                self.collapsed = false
                self.trayHoverActive = false
                self.hub.setTrayHoverActive(false)
                self.collapsedPeekItem = nil
                self.trayAnimator.synchronize(0)
                self.trayProgress = 0
                self.hub.hide()
                self.host.orderOut(nil)
            }
        })
    }

    private func collectionDirectionalOffset() -> NSPoint {
        thumbnailCollectionOffset(vertical: TrayPosition.current.isVertical)
    }

    /// Копирование НЕ закрывает карточку — только короткий фидбэк.
    func copy(_ t: ThumbnailWindow) {
        if let prepared = t.cachedClipboardPayload() {
            Clipboard.copy(preparedImage: prepared)
            t.flashCopied()
            return
        }

        let image = t.image
        Clipboard.prepareImage(cgImage: image) { [weak t] prepared in
            Clipboard.copy(preparedImage: prepared)
            t?.flashCopied()
        }
    }

    func copyAll() {
        let images = items.map(\.image)
        guard !images.isEmpty else { return }
        let last = items.last
        Clipboard.prepareImages(cgImages: images) { [weak last] prepared in
            Clipboard.copy(preparedImages: prepared)
            last?.flashCopied()
        }
    }

    func deleteAll() {
        guard !items.isEmpty else { return }
        animateRemoval(items)
    }

    func saveAllAs() {
        guard !items.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)

        if items.count == 1 {
            let panel = NSSavePanel()
            panel.title = "Save Screenshot"
            panel.prompt = "Save"
            panel.nameFieldStringValue = defaultFileName()
            panel.allowedContentTypes = [.png]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            writePNG(items[0].image, to: url)
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Save Screenshots"
        panel.message = "Choose a folder for \(items.count) screenshots."
        panel.prompt = "Save"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        for (index, item) in items.enumerated() {
            let url = folder.appendingPathComponent(defaultFileName(index: index + 1))
            writePNG(item.image, to: url)
        }
    }

    private func defaultFileName(index: Int? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let suffix = index.map { String(format: "-%02d", $0) } ?? ""
        return "QuickShot-\(formatter.string(from: Date()))\(suffix).png"
    }

    private func writePNG(_ image: CGImage, to url: URL) {
        guard let data = Clipboard.pngData(cgImage: image) else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("QuickShot: save failed: \(error)")
        }
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
        finishCollectionMotion()
        cancelCollapsedPeekDismiss()
        cancelHoverExit()
        collapsedPeekItem = nil
        trayHoverActive = false
        hub.setTrayHoverActive(false)
        collapsed = true
        runTrayTransition(to: 1, on: screen)
    }

    func expand() {
        guard collapsed, let screen = anchorScreen ?? NSScreen.main else { return }
        cancelCollapsedPeekDismiss()
        cancelHoverExit()
        finishCollectionMotion()
        collapsedPeekItem = nil
        collapsed = false
        runTrayTransition(to: 0, on: screen)
    }

    private func runTrayTransition(to target: CGFloat, on screen: NSScreen) {
        positionHub(on: screen, animateChevron: false)
        let travelOffset = thumbnailTrayTravelOffset(vertical: TrayPosition.current.isVertical)
        let (visible, hidden) = cardLayout(on: screen)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        for item in hidden {
            item.setCollapsed(target == 1)
            item.hide()
        }
        for (item, globalOrigin) in visible {
            item.prepareTrayTransition(progress: trayProgress,
                                       travelOffset: travelOffset,
                                       restingOrigin: toLocal(globalOrigin),
                                       expanding: target == 0,
                                       reduceMotion: reduceMotion)
        }
        hub.setTrayCollapseProgress(trayProgress)

        let cards = visible.map(\.0)
        trayAnimator.retarget(to: target,
                              response: TrayAnim.response(reduceMotion: reduceMotion),
                              onFrame: { [weak self] progress in
            guard let self else { return }
            self.trayProgress = progress
            for item in cards {
                item.applyTrayTransition(progress: progress,
                                         travelOffset: travelOffset,
                                         reduceMotion: reduceMotion)
            }
            self.hub.setTrayCollapseProgress(progress)
        }, onDone: { [weak self] in
            guard let self else { return }
            self.trayProgress = target
            let isCollapsed = target == 1
            for item in cards { item.finishTrayTransition(collapsed: isCollapsed) }
            self.hub.setTrayCollapseProgress(target)
        })
    }

    private func finishTrayMotion() {
        let target = thumbnailTrayCollapseTarget(userCollapsed: collapsed,
                                                 hoverExpanded: trayHoverActive)
        trayAnimator.synchronize(target)
        trayProgress = target
        for item in items { item.finishTrayTransition(collapsed: target == 1) }
        hub.setTrayCollapseProgress(target)
    }

    // MARK: раскладка (добавление/ресайз/смена положения)

    /// Расставить карточки по стабильным слотам без запуска transition.
    private func layout() {
        finishCollectionMotion()
        guard let screen = anchorScreen ?? NSScreen.main else { return }
        let settledProgress = thumbnailTrayCollapseTarget(userCollapsed: collapsed,
                                                          hoverExpanded: trayHoverActive)
        trayAnimator.synchronize(settledProgress)
        trayProgress = settledProgress
        ensureHost(on: screen)
        positionHub(on: screen, animateChevron: false)
        hub.setTrayCollapseProgress(settledProgress)
        let edgePos = TrayPosition.current
        for t in items { t.setCollapsed(settledProgress == 1); t.configureResize(for: edgePos) }
        let (visible, hidden) = cardLayout(on: screen)
        for t in hidden { t.hide() }
        if settledProgress == 1 {
            for (t, _) in visible { t.hide() }
        } else {
            for pair in visible {
                let localOrigin = toLocal(pair.1)
                pair.0.placeInstant(origin: localOrigin)
            }
        }
    }

    private func positionHub(on screen: NSScreen,
                             animateChevron: Bool = true,
                             animateCount: Bool = false) {
        hub.setState(count: items.count,
                     collapsed: collapsed,
                     animateChevron: animateChevron,
                     animateCount: animateCount)   // сначала размер (ширина капсулы), потом позиция
        hub.setOrigin(toLocal(hubOrigin(on: screen)))
        if items.isEmpty { hub.hide() } else { hub.show() }      // счётчик виден при любом count >= 1
    }

    private func hubOrigin(on screen: NSScreen) -> NSPoint {
        // Хаб привязан к физическому frame экрана, а не к visibleFrame: Dock/menu bar не должны
        // сдвигать кнопку. Если системный chrome окажется в этом углу, хаб осознанно перекрывает его.
        let sf = screen.frame
        let w = hub.width, h = hub.height                        // капсула: ширина переменная, высота фикс.
        switch TrayPosition.current {
        case .right:  return NSPoint(x: sf.maxX - ThumbStyle.margin - w, y: sf.minY + ThumbStyle.margin)
        case .left:   return NSPoint(x: sf.minX + ThumbStyle.margin + hub.leadingRevealClearance,
                                     y: sf.minY + ThumbStyle.margin)
        case .bottom: return NSPoint(x: sf.maxX - ThumbStyle.margin - w, y: sf.minY + ThumbStyle.margin)
        case .top:    return NSPoint(x: sf.maxX - ThumbStyle.margin - w, y: sf.maxY - ThumbStyle.margin - h)
        }
    }

    /// Позиции видимых карточек в порядке добавления + список переполнения. Существующие карточки
    /// сохраняют свои слоты, новый снимок занимает следующий свободный слот по направлению от хаба.
    /// Координаты глобальные; вызывающий конвертирует их через toLocal.
    private func cardLayout(on screen: NSScreen) -> (visible: [(ThumbnailWindow, NSPoint)], hidden: [ThumbnailWindow]) {
        // Карточки должны жить в той же системе координат, что и хаб: полный frame экрана.
        // Иначе Dock/menu bar сдвигают карточки, а хаб остаётся в углу — между ними появляется дыра.
        let pos = TrayPosition.current
        let edgeMargin = pos == .left
            ? ThumbStyle.margin + hub.leadingRevealClearance
            : ThumbStyle.margin
        let result = thumbnailLayout(screenFrame: screen.frame,
                                     edge: ThumbnailLayoutEdge(rawValue: pos.rawValue)!,
                                     cardWidth: cardWidth,
                                     cardHeights: items.map(\.cardHeight),
                                     hubSize: NSSize(width: hub.width, height: hub.height),
                                     margin: edgeMargin,
                                     gap: ThumbStyle.gap)
        return (
            result.visible.map { (items[$0.index], $0.origin) },
            result.hidden.map { items[$0] }
        )
    }
}
