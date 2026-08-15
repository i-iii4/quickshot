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
@MainActor
final class ThumbnailManager {

    private var collectionModel = ThumbnailCollectionModel()
    private var itemByID: [UUID: ThumbnailWindow] = [:]
    private var items: [ThumbnailWindow] {
        collectionModel.ids.compactMap { itemByID[$0] }
    }
    private let artifactStore: CaptureArtifactStore
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
    /// Библиотека снимков: редактор перезаписывает через неё файл в папке.
    weak var library: ScreenshotLibrary?
    /// Редактируемые состояния и запечённые версии живут, пока снимок в трее.
    private let sessions = AnnotationSessionStore()
    private let editedImages = EditedImageStore()
    private var trayHoverActive = false
    private var pointerInsideHoverIsland = false
    private var capturePresentationSessions: Set<UUID> = []
    private var activeDragPayloads: Set<ObjectIdentifier> = []
    private var viewportScrollAccumulator: CGFloat = 0

    private let defaults = UserDefaults.standard
    private let widthKey = "thumbnailCardWidth"

    private var preferredCardWidth: CGFloat = ThumbStyle.defaultWidth
    private(set) var cardWidth: CGFloat = ThumbStyle.defaultWidth

    init(artifactStore: CaptureArtifactStore) {
        self.artifactStore = artifactStore
        host = TrayHostPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        host.isOpaque = false
        host.backgroundColor = .clear                 // прозрачный фон → клики сквозь пустоту проходят
        host.hasShadow = false                        // тень несёт каждая карточка слоем, не окно
        host.level = .statusBar
        host.isFloatingPanel = true
        host.hidesOnDeactivate = false
        host.becomesKeyOnlyIfNeeded = false           // makeKey должен срабатывать для controls трея
        host.acceptsMouseMovedEvents = true
        WindowCaptureProtection.excludeFromScreenCapture(host)
        host.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hostContent.wantsLayer = true
        host.contentView = hostContent
        hostContent.addSubview(hub.view)              // хаб — верхний сабвью; карточки кладём под него

        let saved = defaults.double(forKey: widthKey)
        if saved > 0 {
            preferredCardWidth = min(ThumbStyle.maxWidth,
                                     max(ThumbStyle.minWidth, CGFloat(saved)))
            cardWidth = preferredCardWidth
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
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                       .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) {
                [weak self] _ in
                DispatchQueue.main.async { self?.refreshHostPointerRouting() }
            }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                       .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) {
                [weak self] event in
                self?.refreshHostPointerRouting()
                return event
            }
        // Отключили монитор, на котором стоял трей — перенести на главный, чтобы не завис на «нигде».
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParamsChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private var clickMonitor: Any?
    private var pointerMonitor: Any?
    private var localPointerMonitor: Any?

    isolated deinit {
        collapsedPeekWorkItem?.cancel()
        hoverExitWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
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
        if capturePresentationSessions.isEmpty, mouseOverTray() {
            host.makeKey()
        }
    }

    /// Видимая геометрия острова в координатах хоста: раскрытый хаб и каждая
    /// показанная карточка. Зазоры между ними замыкает `TrayHover.bridge`.
    private func trayIslandRects() -> [NSRect] {
        var rects: [NSRect] = []
        if !hub.view.isHidden, hub.view.alphaValue > 0.01 {
            rects.append(hub.visibleFrame)
        }
        for item in items where !item.hostView.isHidden && item.hostView.alphaValue > 0.01 {
            rects.append(contentsOf: item.interactiveFramesInHost)
        }
        return rects
    }

    /// Указатель над содержимым трея? Ответ решает, принимает ли полноэкранный
    /// хост события вообще, поэтому внешнего запаса здесь нет: клик рядом с
    /// треем обязан уходить в приложение под ним. Зазоры внутри острова при
    /// этом замкнуты — проход между командами и карточками не роняет окно.
    private func mouseOverTray() -> Bool {
        trayHoverRegionContains(toLocal(NSEvent.mouseLocation),
                                rects: trayIslandRects(),
                                shield: 0,
                                bridge: TrayHover.bridge)
    }

    /// Указатель внутри hover-острова? Здесь запас есть, и выход считается по
    /// большему порогу, чем вход: этот ответ удерживает раскрытый трей.
    private func mouseInsideHoverIsland() -> Bool {
        let inside = trayPointerRemainsInside(toLocal(NSEvent.mouseLocation),
                                              rects: trayIslandRects(),
                                              wasInside: pointerInsideHoverIsland)
        pointerInsideHoverIsland = inside
        return inside
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
        guard activeDragPayloads.isEmpty else { return }
        cancelHoverExit()
        let generation = hoverExitGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.trayHoverActive || (self.collapsed && self.collapsedPeekItem != nil) else { return }
            guard self.hoverExitGeneration == generation else { return }
            self.hoverExitWorkItem = nil
            guard !self.mouseInsideHoverIsland() else { return }
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
        refreshHostPointerRouting()
    }

    /// Запрос key у хоста (вызывает карточка на ховере): controls получают первый клик без активации app.
    func hostBecomeKey() {
        refreshHostPointerRouting()
        if host.isVisible, !host.ignoresMouseEvents, capturePresentationSessions.isEmpty {
            host.makeKey()
        }
    }

    /// The tray host spans a display for stable animation coordinates. It must
    /// therefore be pointer-transparent everywhere except the actual hub/cards.
    /// Global movement opens the interactive island; local movement closes it as
    /// soon as the pointer leaves. Capture mode always remains fully passive.
    private func refreshHostPointerRouting() {
        let overContent = host.isVisible && mouseOverTray()
        _ = mouseInsideHoverIsland()          // гистерезис живёт по движению, не по таймеру
        let ignores = trayHostIgnoresMouseEvents(
            isVisible: host.isVisible,
            captureActive: !capturePresentationSessions.isEmpty,
            dragActive: !activeDragPayloads.isEmpty,
            pointerOverContent: overContent)
        if host.ignoresMouseEvents != ignores {
            host.ignoresMouseEvents = ignores
            if ignores, host.isKeyWindow { host.resignKey() }
        }
        syncHubPointer()
    }

    /// Позицией указателя владеет трей: его мониторы живут всегда, а tracking
    /// areas хаба молчат, пока хост прозрачен для мыши. Без этого hover не
    /// восстанавливается, если указатель остановился на кнопке и больше не
    /// двигается.
    private func syncHubPointer() {
        guard host.isVisible,
              !hub.view.isHidden,
              capturePresentationSessions.isEmpty,
              !items.isEmpty else { return }
        hub.updatePointer(at: toLocal(NSEvent.mouseLocation))
    }

    /// Keeps the capture-excluded tray visible between the frozen backdrop and
    /// selection chrome. The chrome remains above it and owns all pointer input.
    func beginCapturePresentation(sessionID: UUID) {
        let inserted = capturePresentationSessions.insert(sessionID).inserted
        guard inserted, capturePresentationSessions.count == 1 else { return }
        host.level = CaptureWindowLevels.protectedInterface
        if host.isVisible { host.orderFrontRegardless() }
        refreshHostPointerRouting()
    }

    func endCapturePresentation(sessionID: UUID) {
        guard capturePresentationSessions.remove(sessionID) != nil,
              capturePresentationSessions.isEmpty else { return }
        host.level = .statusBar
        if host.isVisible { host.orderFrontRegardless() }
        refreshHostPointerRouting()
    }

    // MARK: добавление/удаление

    func add(artifact: CaptureArtifact, on screen: NSScreen) {
        finishCollectionMotion()
        finishTrayMotion()
        cancelCollapsedPeekDismiss()
        cancelHoverExit()
        let previousHostFrame = host.frame
        ensureHost(on: screen)
        if host.isVisible, previousHostFrame != screen.frame { layout() }
        updateClampedCardWidth(on: screen)
        let previousVisible = Set(items.filter { !$0.hostView.isHidden }.map { ObjectIdentifier($0) })
        let oldFrames = Dictionary(uniqueKeysWithValues: items.map {
            (ObjectIdentifier($0), $0.layoutFrame)
        })
        let t = ThumbnailWindow(artifact: artifact, screen: screen, manager: self,
                                width: cardWidth, screenHeight: screen.frame.height)
        t.onHoverChanged = { [weak self, weak t] entered in
            guard let self, let t else { return }
            self.thumbnailHoverChanged(t, entered: entered)
        }
        collectionModel.insert(id: artifact.id, sequence: artifact.sequence)
        itemByID[artifact.id] = t
        hostContent.addSubview(t.hostView, positioned: .below, relativeTo: hub.view)  // новейшая — поверх старых, под хабом
        for it in items { it.applyWidth(cardWidth, screenHeight: screen.frame.height) }
        showHost()
        positionHub(on: screen, animateChevron: false, animateCount: true)
        hub.setCountTransitionProgress(0)
        cardsAreCollapsed ? presentCollapsedCapture(t, on: screen)
                          : animateInsertion(t,
                                             on: screen,
                                             previousVisible: previousVisible,
                                             oldFrames: oldFrames)
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
                               onFrame: { [weak self] progress in
            onFrame(progress)
            self?.refreshHostPointerRouting()
        },
                               onDone: { [weak self] in
            guard let self else { return }
            self.collectionCompletion = nil
            completion()
            self.refreshHostPointerRouting()
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
        refreshHostPointerRouting()
    }

    private func animateInsertion(_ inserted: ThumbnailWindow,
                                  on screen: NSScreen,
                                  previousVisible: Set<ObjectIdentifier>,
                                  oldFrames: [ObjectIdentifier: NSRect]) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let (visible, hidden) = cardLayout(on: screen)
        let visibleIDs = Set(visible.map { ObjectIdentifier($0.0) })
        let outgoing = hidden.filter {
            previousVisible.contains(ObjectIdentifier($0)) && $0 !== inserted
        }
        for item in hidden where !outgoing.contains(where: { $0 === item }) {
            item.hide()
        }

        var reflowing: [(ThumbnailWindow, NSRect)] = []
        for (item, origin) in visible where item !== inserted {
            guard let oldFrame = oldFrames[ObjectIdentifier(item)] else {
                item.placeInstant(origin: toLocal(origin))
                continue
            }
            item.prepareReflow(from: oldFrame,
                               to: thumbnailAxisLockedOrigin(candidate: toLocal(origin),
                                                             oldOuterFrame: oldFrame,
                                                             resizeBand: ThumbStyle.resizeBand,
                                                             vertical: TrayPosition.current.isVertical),
                               reduceMotion: reduceMotion)
            reflowing.append((item, oldFrame))
        }
        for item in outgoing {
            item.prepareRemoval(toward: collectionDirectionalOffset(), reduceMotion: reduceMotion)
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
        runCollectionMotion(duration: reduceMotion ? TrayAnim.reducedTransition : TrayAnim.removalAndReflow,
                            onFrame: { [weak self, weak inserted] progress in
            inserted?.applyInsertion(progress: progress, reduceMotion: reduceMotion)
            for (item, oldFrame) in reflowing {
                item.applyReflow(progress: progress, from: oldFrame, reduceMotion: reduceMotion)
            }
            for item in outgoing {
                item.applyRemoval(progress: progress, reduceMotion: reduceMotion)
            }
            self?.hub.setCountTransitionProgress(progress)
        }, completion: { [weak self, weak inserted] in
            inserted?.finishCollectionMotion()
            for (item, _) in reflowing { item.finishCollectionMotion() }
            for item in outgoing { item.finishCollectionMotion(hidden: true) }
            for item in self?.items ?? [] where !visibleIDs.contains(ObjectIdentifier(item)) {
                item.hide()
            }
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
        for item in removed {
            sessions.discard(item.artifact.id)
            editedImages.discard(item.artifact.id)
        }
        finishCollectionMotion()
        finishTrayMotion()
        cancelCollapsedPeekDismiss()
        cancelHoverExit()
        let removesVisiblePeek = removed.contains { $0 === collapsedPeekItem }
        if removesVisiblePeek { collapsedPeekItem = nil }
        guard let screen = anchorScreen ?? NSScreen.main else { return }
        let oldVisibleIDs = Set(items.filter { !$0.hostView.isHidden }.map { ObjectIdentifier($0) })
        let oldFrames = Dictionary(uniqueKeysWithValues: items.map { (ObjectIdentifier($0), $0.layoutFrame) })
        let removedArtifactIDs = Set(removed.map { $0.artifact.id })
        collectionModel.remove(ids: removedArtifactIDs)
        for id in removedArtifactIDs {
            itemByID.removeValue(forKey: id)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let animateCards = !cardsAreCollapsed || removesVisiblePeek

        positionHub(on: screen, animateChevron: false, animateCount: true)
        if items.isEmpty { hub.show() }
        hub.setCountTransitionProgress(0)

        let (visible, hidden) = cardLayout(on: screen)
        for item in hidden { item.hide() }
        var reflowing: [(ThumbnailWindow, NSRect)] = []
        var entering: [ThumbnailWindow] = []
        if animateCards {
            for (item, origin) in visible {
                let identifier = ObjectIdentifier(item)
                guard oldVisibleIDs.contains(identifier), let oldFrame = oldFrames[identifier] else {
                    item.prepareInsertion(at: toLocal(origin),
                                          from: collectionDirectionalOffset(),
                                          reduceMotion: reduceMotion)
                    entering.append(item)
                    continue
                }
                item.prepareReflow(
                    from: oldFrame,
                    to: thumbnailAxisLockedOrigin(candidate: toLocal(origin),
                                                  oldOuterFrame: oldFrame,
                                                  resizeBand: ThumbStyle.resizeBand,
                                                  vertical: TrayPosition.current.isVertical),
                    reduceMotion: reduceMotion)
                reflowing.append((item, oldFrame))
            }
        } else {
            for (item, _) in visible { item.hide() }
        }
        let animatedRemoved = animateCards
            ? removed.filter { oldVisibleIDs.contains(ObjectIdentifier($0)) || $0 === collapsedPeekItem }
            : []
        let immediateRemoved = removed.filter { candidate in
            !animatedRemoved.contains(where: { $0 === candidate })
        }
        for item in immediateRemoved { closeAndRelease(item) }
        if animateCards {
            for item in animatedRemoved {
                item.prepareRemoval(toward: collectionDirectionalOffset(), reduceMotion: reduceMotion)
            }
        }

        runCollectionMotion(duration: reduceMotion ? TrayAnim.reducedTransition : TrayAnim.removalAndReflow,
                            onFrame: { [weak self] progress in
            for (item, oldFrame) in reflowing {
                item.applyReflow(progress: progress, from: oldFrame, reduceMotion: reduceMotion)
            }
            for item in entering { item.applyInsertion(progress: progress, reduceMotion: reduceMotion) }
            if animateCards {
                for item in animatedRemoved { item.applyRemoval(progress: progress, reduceMotion: reduceMotion) }
            }
            self?.hub.setCountTransitionProgress(progress)
        }, completion: { [weak self] in
            guard let self else { return }
            for (item, _) in reflowing { item.finishCollectionMotion() }
            for item in entering { item.finishCollectionMotion() }
            for item in animatedRemoved { self.closeAndRelease(item) }
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
                self.refreshHostPointerRouting()
            }
        })
    }

    private func collectionDirectionalOffset() -> NSPoint {
        thumbnailCollectionOffset(vertical: TrayPosition.current.isVertical)
    }

    /// Scrolls the finite tray viewport without moving the hub. A newly captured
    /// screenshot always returns the viewport to the newest page.
    func scrollTray(with event: NSEvent) {
        guard items.count > 1, !cardsAreCollapsed else { return }
        let delta = TrayPosition.current.isVertical
            ? event.scrollingDeltaY
            : (abs(event.scrollingDeltaX) > 0.01 ? event.scrollingDeltaX : event.scrollingDeltaY)
        guard abs(delta) > 0.01 else { return }

        if event.phase == .began || event.phase == .mayBegin { viewportScrollAccumulator = 0 }
        viewportScrollAccumulator += delta
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 18 : 1
        guard abs(viewportScrollAccumulator) >= threshold else { return }

        let step = viewportScrollAccumulator > 0 ? -1 : 1
        viewportScrollAccumulator = 0
        shiftViewport(by: step)
    }

    private func shiftViewport(by delta: Int) {
        finishCollectionMotion()
        finishTrayMotion()
        guard let screen = anchorScreen ?? NSScreen.main, !items.isEmpty else { return }

        let maximumStart = newestViewportLayout(on: screen).firstVisibleIndex
        guard collectionModel.shiftViewport(by: delta, maximumStart: maximumStart) else { return }

        let oldVisible = items.filter { !$0.hostView.isHidden }
        let oldVisibleIDs = Set(oldVisible.map { ObjectIdentifier($0) })
        let oldFrames = Dictionary(uniqueKeysWithValues: oldVisible.map {
            (ObjectIdentifier($0), $0.layoutFrame)
        })
        animateViewportChange(on: screen,
                              oldVisibleIDs: oldVisibleIDs,
                              oldFrames: oldFrames)
    }

    private func animateViewportChange(on screen: NSScreen,
                                       oldVisibleIDs: Set<ObjectIdentifier>,
                                       oldFrames: [ObjectIdentifier: NSRect]) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let (visible, hidden) = cardLayout(on: screen)
        let visibleIDs = Set(visible.map { ObjectIdentifier($0.0) })
        let outgoing = hidden.filter { oldVisibleIDs.contains(ObjectIdentifier($0)) }
        for item in hidden where !outgoing.contains(where: { $0 === item }) { item.hide() }

        var reflowing: [(ThumbnailWindow, NSRect)] = []
        var entering: [ThumbnailWindow] = []
        for (item, origin) in visible {
            let identifier = ObjectIdentifier(item)
            if let oldFrame = oldFrames[identifier] {
                item.prepareReflow(
                    from: oldFrame,
                    to: thumbnailAxisLockedOrigin(candidate: toLocal(origin),
                                                  oldOuterFrame: oldFrame,
                                                  resizeBand: ThumbStyle.resizeBand,
                                                  vertical: TrayPosition.current.isVertical),
                    reduceMotion: reduceMotion)
                reflowing.append((item, oldFrame))
            } else {
                item.prepareInsertion(at: toLocal(origin),
                                      from: collectionDirectionalOffset(),
                                      reduceMotion: reduceMotion)
                entering.append(item)
            }
        }
        for item in outgoing {
            item.prepareRemoval(toward: collectionDirectionalOffset(), reduceMotion: reduceMotion)
        }

        runCollectionMotion(duration: reduceMotion ? TrayAnim.reducedTransition : TrayAnim.removalAndReflow,
                            onFrame: { progress in
            for (item, oldFrame) in reflowing {
                item.applyReflow(progress: progress, from: oldFrame, reduceMotion: reduceMotion)
            }
            for item in entering { item.applyInsertion(progress: progress, reduceMotion: reduceMotion) }
            for item in outgoing { item.applyRemoval(progress: progress, reduceMotion: reduceMotion) }
        }, completion: { [weak self] in
            guard let self else { return }
            for (item, _) in reflowing { item.finishCollectionMotion() }
            for item in entering { item.finishCollectionMotion() }
            for item in outgoing { item.finishCollectionMotion(hidden: true) }
            for item in self.items where !visibleIDs.contains(ObjectIdentifier(item)) { item.hide() }
        })
    }

    /// Копирование НЕ закрывает карточку — только короткий фидбэк.
    func copy(_ t: ThumbnailWindow) {
        // `ED-4`: после сохранения копируется изменённая версия.
        if let edited = editedImages.preparedImage(for: t.artifact.id) {
            Clipboard.copy(preparedImage: edited)
            t.flashCopied()
            return
        }
        artifactStore.copy(t.artifact) { [weak t] in t?.flashCopied() }
    }

    func copyAll() {
        let artifacts = items.map(\.artifact)
        guard !artifacts.isEmpty else { return }
        let last = items.last
        artifactStore.copyAll(artifacts) { [weak last] in last?.flashCopied() }
    }

    /// Закрытие трея уничтожает редактируемые состояния и запечённые версии
    /// (`ED-7`). В папке остаётся последняя сохранённая версия (`ST-9`).
    func deleteAll() {
        guard !items.isEmpty else { return }
        sessions.discardAll()
        editedImages.discardAll()
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
            writeArtifact(items[0].artifact, to: url)
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
            writeArtifact(item.artifact, to: url)
        }
    }

    private func defaultFileName(index: Int? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let suffix = index.map { String(format: "-%02d", $0) } ?? ""
        return "QuickShot-\(formatter.string(from: Date()))\(suffix).png"
    }

    private func writeArtifact(_ artifact: CaptureArtifact, to url: URL) {
        Task { @MainActor in
            let prepared = await artifact.preparedImage()
            guard let data = prepared.png else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("QuickShot: save failed: \(error)")
            }
        }
    }

    func pin(_ t: ThumbnailWindow) {
        artifactStore.retainPin(t.artifact)
        PinnedWindowController.show(artifact: t.artifact,
                                    on: t.screen,
                                    artifactStore: artifactStore)
    }

    /// Открыть редактор аннотаций для карточки (`ED-1`).
    func openEditor(_ t: ThumbnailWindow) {
        AnnotationEditorController.present(artifact: t.artifact,
                                           library: library,
                                           restoring: sessions.objects(for: t.artifact.id)) {
            [weak self, weak t] artifact, image, objects in
            self?.applyEditedImage(image, objects: objects, to: artifact, card: t)
        }
    }

    /// Отредактированная версия для выдачи (`ED-4`): буфер, перетаскивание и
    /// экспорт после сохранения отдают именно её.
    func preparedImageForDelivery(_ artifact: CaptureArtifact) -> Clipboard.PreparedImage? {
        editedImages.preparedImage(for: artifact.id)
    }

    /// Сохранение из редактора: файл в папке перезаписывается изменённой
    /// версией (`ED-2`). Признак `Edited` на карточке и подмена версии для
    /// выдачи — следующий пакет работ.
    private func applyEditedImage(_ image: CGImage,
                                  objects: [AnnotationObject],
                                  to artifact: CaptureArtifact,
                                  card: ThumbnailWindow?) {
        sessions.store(objects: objects, for: artifact.id)
        editedImages.store(image, for: artifact.id)
        card?.isEdited = sessions.isEdited(artifact.id)
        card?.setDisplayImage(image)

        // При выключенном автосохранении файла нет: сохранение фиксирует
        // изменения на карточке и только (`ED-12`).
        guard let library, library.settings.autosaveEnabled,
              let png = Clipboard.pngData(cgImage: image) else { return }
        if let url = artifact.libraryURL {
            artifact.libraryURL = library.update(url: url, with: png)
        } else {
            artifact.libraryURL = library.store(pngData: png)
        }
    }

    func beginDrag(_ t: ThumbnailWindow) -> CaptureArtifactDragPayload? {
        artifactStore.beginDrag(of: t.artifact)
    }

    func dragSessionWillBegin(_ payload: CaptureArtifactDragPayload) {
        activeDragPayloads.insert(ObjectIdentifier(payload))
        cancelHoverExit()
        refreshHostPointerRouting()
    }

    func finishDrag(_ payload: CaptureArtifactDragPayload) {
        activeDragPayloads.remove(ObjectIdentifier(payload))
        artifactStore.finishDrag(payload)
        refreshHostPointerRouting()
        if trayHoverActive || (collapsed && collapsedPeekItem != nil) {
            scheduleCollapsedPresentationExit()
        }
    }

#if TESTING
    var debugActiveDragSessionCount: Int { activeDragPayloads.count }
#endif

    func shutdown() {
        finishCollectionMotion()
        finishTrayMotion()
        cancelCollapsedPeekDismiss()
        cancelHoverExit()
        activeDragPayloads.removeAll()
        for item in items { closeAndRelease(item) }
        collectionModel.removeAll()
        itemByID.removeAll()
        host.orderOut(nil)
        refreshHostPointerRouting()
    }

    private func closeAndRelease(_ item: ThumbnailWindow) {
        item.close()
        artifactStore.releaseCard(item.artifact)
    }

    // MARK: ресайз (общая ширина, сохраняется между сессиями)

    func updateWidthLive(_ w: CGFloat) {
        preferredCardWidth = min(ThumbStyle.maxWidth, max(ThumbStyle.minWidth, w))
        if let screen = anchorScreen ?? NSScreen.main {
            updateClampedCardWidth(on: screen)
        } else {
            cardWidth = preferredCardWidth
        }
        let h = anchorHeight
        for t in items { t.applyWidth(cardWidth, screenHeight: h) }
        layout()
    }

    func persistWidth() { defaults.set(Double(preferredCardWidth), forKey: widthKey) }

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
            self.refreshHostPointerRouting()
        }, onDone: { [weak self] in
            guard let self else { return }
            self.trayProgress = target
            let isCollapsed = target == 1
            for item in cards { item.finishTrayTransition(collapsed: isCollapsed) }
            self.hub.setTrayCollapseProgress(target)
            self.refreshHostPointerRouting()
        })
    }

    private func finishTrayMotion() {
        let target = thumbnailTrayCollapseTarget(userCollapsed: collapsed,
                                                 hoverExpanded: trayHoverActive)
        trayAnimator.synchronize(target)
        trayProgress = target
        if let screen = anchorScreen ?? NSScreen.main {
            let (visible, hidden) = cardLayout(on: screen)
            for item in hidden { item.hide() }
            for (item, _) in visible {
                item.finishTrayTransition(collapsed: target == 1)
            }
        }
        hub.setTrayCollapseProgress(target)
        refreshHostPointerRouting()
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
        updateClampedCardWidth(on: screen)
        hub.setTrayCollapseProgress(settledProgress)
        for t in items {
            t.applyWidth(cardWidth, screenHeight: screen.frame.height)
        }
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
        refreshHostPointerRouting()
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
        refreshHostPointerRouting()
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
        let result = resolvedViewportLayout(on: screen)
        return (
            result.visible.map { (items[$0.index], $0.origin) },
            result.hidden.map { items[$0] }
        )
    }

    private func resolvedViewportLayout(on screen: NSScreen) -> ThumbnailLayoutResult {
        guard !items.isEmpty else {
            collectionModel.removeAll()
            return .init(visible: [], hidden: [])
        }

        let newest = newestViewportLayout(on: screen)
        let firstVisibleIndex = collectionModel.resolveFirstVisibleIndex(
            maximumStart: newest.firstVisibleIndex)
        if collectionModel.followsNewest {
            return newest.layout
        }

        return layout(on: screen, firstVisibleIndex: firstVisibleIndex)
    }

    private func newestViewportLayout(on screen: NSScreen) -> ThumbnailViewportResult {
        let geometry = viewportGeometry(on: screen)
        return thumbnailLayoutShowingNewest(screenFrame: screen.frame,
                                            edge: geometry.edge,
                                            cardWidth: cardWidth,
                                            cardHeights: items.map(\.cardHeight),
                                            hubSize: geometry.hubSize,
                                            margin: geometry.margin,
                                            gap: ThumbStyle.gap)
    }

    private func layout(on screen: NSScreen, firstVisibleIndex: Int) -> ThumbnailLayoutResult {
        let geometry = viewportGeometry(on: screen)
        return thumbnailLayout(screenFrame: screen.frame,
                               edge: geometry.edge,
                               cardWidth: cardWidth,
                               cardHeights: items.map(\.cardHeight),
                               hubSize: geometry.hubSize,
                               margin: geometry.margin,
                               gap: ThumbStyle.gap,
                               firstVisibleIndex: firstVisibleIndex)
    }

    private func viewportGeometry(on screen: NSScreen) -> (edge: ThumbnailLayoutEdge,
                                                            hubSize: NSSize,
                                                            margin: CGFloat) {
        // Карточки и хаб используют полный frame экрана, поэтому Dock и menu bar
        // не создают разные системы отсчёта.
        let position = TrayPosition.current
        let margin = position == .left
            ? ThumbStyle.margin + hub.leadingRevealClearance
            : ThumbStyle.margin
        return (ThumbnailLayoutEdge(rawValue: position.rawValue)!,
                NSSize(width: hub.width, height: hub.height),
                margin)
    }

    private func updateClampedCardWidth(on screen: NSScreen) {
        let geometry = viewportGeometry(on: screen)
        cardWidth = thumbnailClampedCardWidth(
            requested: preferredCardWidth,
            screenFrame: screen.frame,
            edge: geometry.edge,
            hubSize: geometry.hubSize,
            margin: geometry.margin,
            gap: ThumbStyle.gap,
            resizeBand: ThumbStyle.resizeBand,
            minimum: ThumbStyle.minWidth,
            maximum: ThumbStyle.maxWidth)
    }
}
