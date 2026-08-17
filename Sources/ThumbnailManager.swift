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

    /// Прокрутка обрабатывается на уровне окна. Доставка по `hitTest` не
    /// годится: пустота трея и поля ресайза обязаны пропускать клики насквозь
    /// и потому возвращают nil, поэтому жест обрывался в зазоре между
    /// карточками, а инерция гасла, как только карточка уезжала из-под
    /// курсора. Замыкание возвращает `true`, если событие взято треем.
    var onScrollWheel: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, onScrollWheel?(event) == true { return }
        super.sendEvent(event)
    }
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
    /// `ED-16`: служебное состояние переживает перезапуск, пока жив снимок.
    private lazy var stateStore = AnnotationStateStore(
        directory: (library?.settings.folderURL ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(".quickshot-state", isDirectory: true))
    private var trayHoverActive = false
    private var pointerInsideHoverIsland = false
    private var capturePresentationSessions: Set<UUID> = []
    private var activeDragPayloads: Set<ObjectIdentifier> = []
    private var viewportScrollAccumulator: CGFloat = 0
    private var scrollModel = TrayScrollModel(contentLength: 0, viewportLength: 0, offset: 0)
    private var scrollGestureActive = false
    /// `TR-5`: как разместить ленту после вставки нового снимка. Сжатая стопка
    /// остаётся сжатой и молча получает новый верхний элемент; развёрнутая
    /// лента докручивается ровно настолько, чтобы показать новый снимок.
    private enum ScrollIntent { case none, revealNewest, stayCompressed }
    private var scrollIntent: ScrollIntent = .revealNewest
    private var stackOrderApplied: [ObjectIdentifier] = []
    private var scrollSettleAnimating = false
    private lazy var scrollSettleAnimator = CollectionProgressAnimator(hostView: hostContent)

    /// Уровень трея в покое: выше обычных окон, но НИЖЕ системных
    /// поверхностей. На `.statusBar` карточки перекрывали Центр уведомлений.
    /// Во время захвата уровень поднимается отдельно
    /// (`CaptureWindowLevels.protectedInterface`) — это часть контракта
    /// захвата и к покою не относится.
    static let restingHostLevel: NSWindow.Level = .floating

    /// Шаг колеса мыши в точках: дельта приходит в строках.
    private static let wheelLineHeight: CGFloat = 40

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
        host.level = Self.restingHostLevel
        host.isFloatingPanel = true
        host.hidesOnDeactivate = false
        host.becomesKeyOnlyIfNeeded = false           // makeKey должен срабатывать для controls трея
        host.acceptsMouseMovedEvents = true
        WindowCaptureProtection.excludeFromScreenCapture(host)
        host.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hostContent.wantsLayer = true
        host.contentView = hostContent
        host.onScrollWheel = { [weak self] event in
            self?.handleHostScroll(event) ?? false
        }
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
        host.level = Self.restingHostLevel
        if host.isVisible { host.orderFrontRegardless() }
        refreshHostPointerRouting()
    }

    // MARK: добавление/удаление

    func add(artifact: CaptureArtifact, on screen: NSScreen) {
        // `TR-5`: сжатость читается ДО вставки — после неё максимальный ход
        // уже другой. Само намерение выставляется только после вставки, иначе
        // его сожжёт промежуточный layout ещё со старой длиной ленты.
        // Сжатие — намеренное состояние: без реального хода (`maximumOffset`
        // нулевой у нетронутой короткой ленты) снимок раскладывается открыто.
        let wasCompressed = scrollModel.maximumOffset > 0.5
            && scrollModel.offset >= scrollModel.maximumOffset - 1
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
        scrollIntent = wasCompressed ? .stayCompressed : .revealNewest
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
#if TESTING
        let reduceMotion = Self.debugDisablesInsertionMotion
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
#else
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
#endif
        let (visible, hidden) = cardLayout(on: screen)
        let visibleIDs = Set(visible.map { ObjectIdentifier($0.0) })
        let outgoing = hidden.filter {
            previousVisible.contains(ObjectIdentifier($0)) && $0 !== inserted
        }
        for item in hidden where !outgoing.contains(where: { $0 === item }) {
            item.hide()
        }

        var reflowing: [(ThumbnailWindow, NSRect)] = []
        for (item, slot) in visible where item !== inserted {
            // Кромка стопки не переезжает как полная карточка: полоса встаёт
            // сразу, иначе на время анимации стопка распухает в целые снимки.
            guard slot.isFullCard, let oldFrame = oldFrames[ObjectIdentifier(item)] else {
                place(item, at: slot)
                continue
            }
            item.prepareReflow(from: oldFrame,
                               to: thumbnailAxisLockedOrigin(candidate: toLocal(slot.origin),
                                                             oldOuterFrame: oldFrame,
                                                             resizeBand: ThumbStyle.resizeBand,
                                                             vertical: TrayPosition.current.isVertical),
                               reduceMotion: reduceMotion)
            reflowing.append((item, oldFrame))
        }
        for item in outgoing {
            item.prepareRemoval(toward: collectionDirectionalOffset(), reduceMotion: reduceMotion)
        }

        guard let origin = visible.first(where: { $0.0 === inserted })?.1.origin else {
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
            // Итоговый кадр — из раскладки: карточки, ставшие слоями стопки за
            // время анимации, получают свои полосы, а не полные рамки.
            self?.applyScrollOffset()
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
            stateStore.discard(for: item.artifact.id)
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
            for (item, slot) in visible {
                let identifier = ObjectIdentifier(item)
                // Слои стопки не анимируются полными карточками: полоса встаёт
                // сразу в своё место.
                guard slot.isFullCard else {
                    place(item, at: slot)
                    continue
                }
                guard oldVisibleIDs.contains(identifier), let oldFrame = oldFrames[identifier] else {
                    item.prepareInsertion(at: toLocal(slot.origin),
                                          from: collectionDirectionalOffset(),
                                          reduceMotion: reduceMotion)
                    entering.append(item)
                    continue
                }
                item.prepareReflow(
                    from: oldFrame,
                    to: thumbnailAxisLockedOrigin(candidate: toLocal(slot.origin),
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
    /// Непрерывная прокрутка ленты (`TR-1`, `TR-2`). Пошаговое переключение
    /// заменено на смещение, потому что ступенчатая лента не даёт понять, где
    /// ты находишься, и не позволяет остановиться между карточками.
    func scrollTray(with event: NSEvent) {
        guard !cardsAreCollapsed else { return }
        let vertical = TrayPosition.current.isVertical
        let raw = vertical
            ? event.scrollingDeltaY
            : (abs(event.scrollingDeltaX) > 0.01 ? event.scrollingDeltaX : event.scrollingDeltaY)
        // Колесо мыши шлёт дельту в строках, а не в точках: один щелчок — это
        // единица, и лента ползла на пиксель за щелчок.
        let delta = event.hasPreciseScrollingDeltas ? raw : raw * Self.wheelLineHeight
        // Трекпад шлёт фазы жеста и инерции; классическое колесо — нет.
        let hasPhases = event.phase != [] || event.momentumPhase != []

        if hasPhases {
            scrollSettleAnimator.cancel()
            scrollSettleAnimating = false
            scrollGestureActive = true
        }

        guard scrollModel.isScrollable || abs(delta) > 0.01 else { return }
        scrollIntent = .none
        // Резинка только у жестов с фазами: колесо упирается в край жёстко.
        // Содержимое идёт за пальцами: положительная дельта двигает карточки к
        // хабу. Обратный знак разворачивал ленту против жеста. Жест никогда не
        // прячет и не показывает трей — это делает только клик по кнопке;
        // перетягивание за край лишь пружинит и возвращается.
        scrollModel = scrollModel.scrolled(by: delta, rubberBand: hasPhases)

        applyScrollOffset()

        if !hasPhases {
            scrollModel = scrollModel.settled()
            applyScrollOffset()
            return
        }
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
            scrollGestureActive = false
            settleScrollAnimated()
        }
    }

    /// Возврат из-за края после отпускания: не мгновенный clamp, а короткий
    /// ease-out — лента отвечает движением, как системный rubber-band.
    private func settleScrollAnimated() {
        let from = scrollModel.offset
        let target = scrollModel.settled().offset
        guard abs(target - from) > 0.5 else {
            scrollModel.offset = target
            applyScrollOffset()
            return
        }
        scrollSettleAnimating = true
        scrollSettleAnimator.run(duration: 0.3, onFrame: { [weak self] progress in
            guard let self else { return }
            let eased = 1 - pow(1 - progress, 3)
            self.scrollModel.offset = from + (target - from) * eased
            self.applyScrollOffset()
        }, onDone: { [weak self] in
            guard let self else { return }
            self.scrollSettleAnimating = false
            self.scrollModel.offset = target
            self.applyScrollOffset()
        })
    }

    /// Событие прокрутки, пришедшее в окно трея. Лентой управляет любой скролл
    /// в границах трея, включая область кнопки хаба: жесты больше не прячут и
    /// не показывают трей, поэтому исключение для кнопки не нужно.
    private func handleHostScroll(_ event: NSEvent) -> Bool {
        // Если событие дошло до окна, система уже решила, что оно принимает
        // мышь: повторная проверка `ignoresMouseEvents` здесь только ломает
        // доставку.
        guard host.isVisible else { return false }
        scrollTray(with: event)
        return true
    }

    /// Пересчёт положения карточек по текущему смещению: видимые двигаются
    /// один к одному, ушедшие за край собираются в стопку (`TR-3`).
    /// Лёгкий кадр прокрутки: двигаются только карточки. Полная перекладка
    /// пересчитывает ширину каждой карточки, положение хаба и режимы ресайза —
    /// на каждое событие колеса это и давало рывки.
    private func applyScrollOffset() {
        guard let screen = anchorScreen ?? NSScreen.main, !cardsAreCollapsed else {
            layout()
            return
        }
        let (visible, hidden) = cardLayout(on: screen)
        for item in hidden { item.hide() }
        for (item, slot) in visible {
            place(item, at: slot)
        }
        applyStackOrder()
        refreshHoverUnderPointer()
    }

    /// Развёрнутая карточка встаёт целиком, слой стопки — полосой-кромкой.
    private func place(_ item: ThumbnailWindow, at slot: ThumbnailLayoutSlot) {
        let localOrigin = toLocal(slot.origin)
        if slot.isFullCard && slot.opacity > 0.999 {
            item.placeInstant(origin: localOrigin)
        } else {
            item.placeBand(origin: localOrigin,
                           length: slot.length,
                           scale: slot.scale,
                           cardStartOffset: slot.cardStartOffset,
                           roundsStart: slot.roundsStart,
                           roundsEnd: slot.roundsEnd,
                           opacity: slot.opacity,
                           shadowFraction: slot.shadowFraction,
                           stackOrder: slot.stackOrder,
                           vertical: TrayPosition.current.isVertical)
        }
    }

    /// Высота строки меню на экране: лента не заходит под неё.
    private func menuBarInset(on screen: NSScreen) -> CGFloat {
        max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// Порядок наложения исполняется порядком сабвью: глубокие слои стопки
    /// уходят вниз, обычные карточки остаются поверх, хаб — выше всех.
    private func applyStackOrder() {
        let ordered = items.sorted { $0.stackOrder < $1.stackOrder }
        guard ordered.map(ObjectIdentifier.init) != stackOrderApplied else { return }
        for item in ordered {
            hostContent.addSubview(item.hostView, positioned: .below, relativeTo: hub.view)
        }
        stackOrderApplied = ordered.map(ObjectIdentifier.init)
    }

    /// Вход и выход курсора на карточке: владельца ховера пересчитывает
    /// менеджер — tracking-области шлют события всем карточкам под точкой,
    /// а кнопки положены ровно одной, верхней.
    func pointerHoverChanged() {
        refreshHoverUnderPointer()
    }

    /// Ровно одна карточка под курсором показывает свои кнопки. Карточка,
    /// уехавшая из-под курсора при прокрутке, `mouseExited` не получает.
    private func refreshHoverUnderPointer() {
        guard host.isVisible else { return }
        let pointer = toLocal(NSEvent.mouseLocation)
        // Порядок массива — порядок наложения: побеждает последняя подходящая
        // карточка, она лежит поверх остальных.
        // Побеждает передняя карточка: в стопке слои перекрываются, и владельцем
        // ховера обязан быть верхний слой, а не последний по порядку массива.
        var hovered: ThumbnailWindow?
        var hoveredOrder = -CGFloat.greatestFiniteMagnitude
        // Ховер положен и перекрытым карточкам — по их видимой части:
        // побеждает верхняя в точке курсора.
        for item in items where !item.hostView.isHidden {
            guard item.layoutFrame.contains(pointer) else { continue }
            if item.stackOrder >= hoveredOrder {
                hoveredOrder = item.stackOrder
                hovered = item
            }
        }
        // Крошечный видимый выступ (тоньше ряда кнопок) ховер не получает:
        // кнопкам физически негде встать.
        if let candidate = hovered, candidate.isSliceBand,
           visibleProtrusion(of: candidate) < Self.hoverableProtrusion {
            hovered = nil
        }
        for item in items { item.applyHover(item === hovered) }
    }

    /// Минимальная видимая часть карточки, на которой ховер осмыслен: ряд
    /// кнопок с отступами.
    private static let hoverableProtrusion: CGFloat = 44

    /// Видимый выступ полосы: до ближайшего края вышележащей пересекающейся
    /// карточки со стороны кнопки хаба.
    private func visibleProtrusion(of candidate: ThumbnailWindow) -> CGFloat {
        let frame = candidate.layoutFrame
        let vertical = TrayPosition.current.isVertical
        var limit = vertical ? frame.maxY : frame.maxX
        for item in items where !item.hostView.isHidden && item !== candidate {
            guard item.stackOrder > candidate.stackOrder,
                  item.layoutFrame.intersects(frame) else { continue }
            limit = min(limit, vertical ? item.layoutFrame.minY : item.layoutFrame.minX)
        }
        return limit - (vertical ? frame.minY : frame.minX)
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
        for (item, slot) in visible {
            let identifier = ObjectIdentifier(item)
            // Слои стопки встают полосами сразу, без анимации полной рамкой.
            if !slot.isFullCard {
                place(item, at: slot)
            } else if let oldFrame = oldFrames[identifier] {
                item.prepareReflow(
                    from: oldFrame,
                    to: thumbnailAxisLockedOrigin(candidate: toLocal(slot.origin),
                                                  oldOuterFrame: oldFrame,
                                                  resizeBand: ThumbStyle.resizeBand,
                                                  vertical: TrayPosition.current.isVertical),
                    reduceMotion: reduceMotion)
                reflowing.append((item, oldFrame))
            } else {
                item.prepareInsertion(at: toLocal(slot.origin),
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
        stateStore.discardAll()
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
        // Состояние берётся из памяти, а при её отсутствии — с диска: после
        // перезапуска трей пуст, но объекты снимка ещё живы.
        var restored = sessions.objects(for: t.artifact.id)
        if restored.isEmpty, library?.settings.autosaveEnabled == true {
            restored = stateStore.load(for: t.artifact.id)
        }
        AnnotationEditorController.present(artifact: t.artifact,
                                           library: library,
                                           restoring: restored) {
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
        if library?.settings.autosaveEnabled == true {
            stateStore.save(objects: objects, for: artifact.id)
        }
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
    func debugThumbnail(for id: UUID) -> ThumbnailWindow? { itemByID[id] }
    var debugScrollIsActive: Bool { scrollModel.isScrollable }
    var debugScrollOffset: CGFloat { scrollModel.offset }
    var debugMaximumScrollOffset: CGFloat { scrollModel.maximumOffset }
    var debugIsCollapsed: Bool { collapsed }
    /// Отключение анимации вставки для замеров: позволяет отделить цену
    /// анимации от цены самой карточки.
    static var debugDisablesInsertionMotion = false
    /// Растры карточек считаются обходом дерева слоёв, а не множителем: у
    /// каждой карточки контейнер, тело, ручка ресайза и, при тени, ещё один
    /// буфер того же размера.
    var debugCardRasterMB: Double {
        let scale = host.screen?.backingScaleFactor ?? 2
        var bytes = 0.0
        for item in items {
            bytes += Self.debugLayerBytes(of: item.hostView, scale: scale)
        }
        return bytes / 1_048_576
    }

    private static func debugLayerBytes(of view: NSView, scale: CGFloat) -> Double {
        var bytes = 0.0
        if let layer = view.layer {
            let area = Double(layer.bounds.width * scale * layer.bounds.height * scale * 4)
            bytes += area
            // Тень рисуется в отдельный буфер того же размера.
            if layer.shadowOpacity > 0 { bytes += area }
        }
        for subview in view.subviews {
            bytes += debugLayerBytes(of: subview, scale: scale)
        }
        return bytes
    }

    /// Достроить идущие анимации немедленно: тестовые окружения без живого
    /// display-clock (окно считается occluded) иначе зависают на alpha=0.
    func debugFinishMotions() {
        finishCollectionMotion()
        finishTrayMotion()
    }
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
        // Слои стопки не гоняются полными рамками: при развороте кромка сразу
        // встаёт полосой со своей перспективой, при сворачивании — прячется.
        // Прогон их через transition и оставлял стопку без эффекта глубины в
        // ховер-показе свёрнутого трея.
        var animated: [ThumbnailWindow] = []
        for (item, slot) in visible {
            guard slot.isFullCard else {
                if target == 0 {
                    place(item, at: slot)
                } else {
                    item.hide()
                }
                continue
            }
            item.prepareTrayTransition(progress: trayProgress,
                                       travelOffset: travelOffset,
                                       restingOrigin: toLocal(slot.origin),
                                       expanding: target == 0,
                                       reduceMotion: reduceMotion)
            animated.append(item)
        }
        hub.setTrayCollapseProgress(trayProgress)

        let cards = animated
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
            // Итоговый кадр разворота — из раскладки: кромки получают полосы
            // и перспективу, а не полные рамки.
            if !isCollapsed { self.applyScrollOffset() }
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
            for (item, slot) in visible {
                // Слой стопки в развёрнутом состоянии — полоса с перспективой,
                // а не полная рамка.
                if target != 1, !slot.isFullCard {
                    place(item, at: slot)
                } else {
                    item.finishTrayTransition(collapsed: target == 1)
                }
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
            for (item, slot) in visible {
                place(item, at: slot)
            }
        }
        applyStackOrder()
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
    private func cardLayout(on screen: NSScreen) -> (visible: [(ThumbnailWindow, ThumbnailLayoutSlot)], hidden: [ThumbnailWindow]) {
        let result = resolvedViewportLayout(on: screen)
        return (
            result.visible.map { (items[$0.index], $0) },
            result.hidden.map { items[$0] }
        )
    }

    /// Длина ленты и окна просмотра для модели прокрутки. Модель отвечает на
    /// вопрос «есть ли куда скроллить и насколько перетянуто», раскладку
    /// по-прежнему считает `ThumbnailLayout`.
    private func syncScrollModel(on screen: NSScreen) {
        let vertical = TrayPosition.current.isVertical
        let gap = ThumbStyle.gap
        let lengths = items.map { vertical ? $0.cardSize.height : $0.cardSize.width }
        let content = lengths.reduce(0, +) + gap * CGFloat(max(0, lengths.count - 1))
        let geometry = viewportGeometry(on: screen)
        let viewport = thumbnailTrayViewportLength(screenFrame: screen.frame,
                                                   edge: geometry.edge,
                                                   hubSize: geometry.hubSize,
                                                   margin: geometry.margin,
                                                   menuBarInset: menuBarInset(on: screen))
        scrollModel.contentLength = content
        scrollModel.viewportLength = max(1, viewport)
        scrollModel.lastCardLength = lengths.last ?? 0
        // Пока идёт жест или пружинный возврат, смещение может законно жить за
        // границей — мгновенный clamp здесь и делал резинку невидимой.
        if scrollGestureActive || scrollSettleAnimating {
            if !scrollModel.isScrollable { scrollModel.offset = 0 }
            return
        }
        switch scrollIntent {
        case .stayCompressed:
            // `TR-5`: стопка была собрана — новый снимок молча ложится сверху,
            // лента остаётся полностью сжатой.
            scrollModel.offset = scrollModel.maximumOffset
        case .revealNewest:
            // `TR-5`: развёрнутая лента докручивается ровно до видимости
            // нового снимка; если он и так виден — не трогаем положение.
            scrollModel.offset = max(min(scrollModel.offset, scrollModel.maximumOffset),
                                     scrollModel.revealNewestOffset())
        case .none:
            scrollModel = scrollModel.settled()
        }
        scrollIntent = .none
    }

    private func resolvedViewportLayout(on screen: NSScreen) -> ThumbnailLayoutResult {
        guard !items.isEmpty else {
            collectionModel.removeAll()
            return .init(visible: [], hidden: [])
        }

        // Смещение прокрутки — источник истины для координат карточек
        // (`TR-1`…`TR-3`). Пока лента помещается целиком, смещение нулевое, и
        // раскладка совпадает с прежней.
        syncScrollModel(on: screen)
        if scrollModel.isScrollable {
            let geometry = viewportGeometry(on: screen)
            return thumbnailScrollLayout(screenFrame: screen.frame,
                                         edge: geometry.edge,
                                         cardWidth: cardWidth,
                                         cardHeights: items.map(\.cardHeight),
                                         hubSize: geometry.hubSize,
                                         margin: geometry.margin,
                                         gap: ThumbStyle.gap,
                                         offset: scrollModel.offset,
                                         menuBarInset: menuBarInset(on: screen))
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
