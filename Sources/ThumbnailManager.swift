import AppKit
import UniformTypeIdentifiers

enum ThumbStyle {
    static let gap: CGFloat = 12                 // зазор между карточками
    static let margin: CGFloat = 16              // от края карточки до края экрана (`TR-30`)
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
    /// Край, у которого лежит стопка и вдоль которого раскрывается лента.
    /// Пока ось не выбрана — берётся из позиции трея.
    private var activeEdge: ThumbnailLayoutEdge { openAxis }

    /// Вторая ось для текущей позиции трея, или `nil`, если её нет.
    /// Пара обязана выходить из ОДНОГО угла, иначе выбор оси двигал бы
    /// собранную стопку. Для трея у правого края это `.right` и `.bottom`:
    /// обе собираются в правом нижнем углу.
    private var alternateEdge: ThumbnailLayoutEdge? {
        switch ThumbnailLayoutEdge(rawValue: TrayPosition.current.rawValue) ?? .right {
        case .right: return .bottom
        case .bottom: return .right
        default: return nil
        }
    }

    private var axisIsVertical: Bool { activeEdge.isVertical }

    private var items: [ThumbnailWindow] {
        collectionModel.ids.compactMap { itemByID[$0] }
    }
    private let artifactStore: CaptureArtifactStore
    /// Целевые рамки карточек, которые сейчас ВЛЕТАЮТ в ленту. Контур
    /// шкатулки берёт их вместо текущих: влетающая стоит сбоку от своего
    /// места, и контур по её живой рамке уводил шкатулку вбок (приёмка
    /// 20.08.2026).
    private var enteringTargets: [ObjectIdentifier: NSRect] = [:]
    /// Ось, вдоль которой раскрывается колода (`TR-38`). ВСЕГДА определена:
    /// понятия «ось отпущена» нет. Отпускание было бы событием, обязанным
    /// пересчитать модель, — и оба дефекта 20.08.2026 родились именно там:
    /// в одну сторону пересчёт оказался лишним, в другую его не хватало.
    /// Право сменить ось выражается СОСТОЯНИЕМ ленты, а не фазой жеста.
    private lazy var openAxis: ThumbnailLayoutEdge =
        ThumbnailLayoutEdge(rawValue: TrayPosition.current.rawValue) ?? .right
    /// Была ли колода собрана на прошлом событии прокрутки: по переходу в
    /// собранное состояние счёт направления начинается заново.
    private var wasGathered = true
    /// Ход пальца, накопленный до выбора оси.
    private var axisPickupX: CGFloat = 0
    private var axisPickupY: CGFloat = 0
    /// Порог выбора оси. Столько же, сколько система тратит на распознавание
    /// направления свайпа: меньше — ось скачет на дрожании руки.
    private static let axisPickThreshold: CGFloat = 10

    /// Открыт ли текущему жесту ход ЗА упор — на ступень убирания (`TR-41`).
    /// Разделение фаз выражено пределом хода для конкретного жеста, а не
    /// вторым состоянием: два независимых состояния некому согласовывать.
    /// Ступень убирания (`TR-41`): состояние и все решения о нём живут ВНУТРИ
    /// структуры. У менеджера своих полей ступени нет — именно они шесть раз
    /// оставались необнулёнными и роняли ленту в залипание.
    private var deckStep = TrayStowGate()
    /// Контур колоды, запомненный до убирания: по его основанию встаёт
    /// полоска третьей фазы, когда видимых карточек не осталось.
    private var caseBaseline: CGRect?
    private var stepSettling = false
    private lazy var stepAnimator = CollectionProgressAnimator(hostView: hostContent)

    private var collapsed = false
    private var anchorScreen: NSScreen?

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
    /// Защёлка полного сбора (`TR-29`): вход и выход из стопки через точку
    /// напряжения со щелчком.
    private var detent = TrayDetentModel()
    /// Кадровая добавка осадки защёлки поверх смещения: раскладка читает её на
    /// каждом кадре, поэтому события жеста осадку не смазывают.
    /// Трекпад, ведущий текущий жест (`TR-29`): щелчок уходит именно в него.
    private var gestureDevice: UInt64?
    /// Шкатулка (`TR-30`): подложка под собранной стопкой и панель кнопок над
    /// ней. Видима строго когда лента защёлкнута.
    private let caseView = TrayCaseView(frame: .zero)
    private let casePanel = NativeCasePanelView(frame: .zero)
    private var caseVisible = false
    /// Скорость ленты в видимых координатах, pt/с: сглаженная оценка по
    /// событиям. Нужна пружине границы — без передачи скорости движение
    /// рвётся в момент отпускания (`TR-13`).
    private var scrollVelocity: CGFloat = 0
    private var lastScrollTimestamp: TimeInterval = 0
    /// Инерция уже передана пружине границы: остальные её события
    /// игнорируются, как это делает системный скролл.
    private var momentumHandedToSpring = false
    /// Поколение отложенного возврата из-за края: новое событие жеста
    /// обесценивает ранее запланированный возврат.
    private var settleGeneration = 0
    private var detentDip: CGFloat = 0
    private var detentDipAnimating = false
    private lazy var detentDipAnimator = CollectionProgressAnimator(hostView: hostContent)

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
        // Шкатулка (`TR-30`): подложка ЗА карточками, панель — НАД ними.
        caseView.isHidden = true
        casePanel.isHidden = true
        casePanel.onDeleteAll = { [weak self] in self?.deleteAll() }
        casePanel.onCopyAll = { [weak self] in self?.copyAll() }
        casePanel.onSaveAll = { [weak self] in self?.saveAllAs() }
        hostContent.addSubview(caseView)
        hostContent.addSubview(casePanel)
        // Хаб-виджет упразднён (`TR-30`): панель кнопок живёт в шкатулке.

        let saved = defaults.double(forKey: widthKey)
        if saved > 0 {
            preferredCardWidth = min(ThumbStyle.maxWidth,
                                     max(ThumbStyle.minWidth, CGFloat(saved)))
            cardWidth = preferredCardWidth
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
    private func currentIslandRects() -> [NSRect] {
        var rects: [NSRect] = []
        for item in items where !item.hostView.isHidden && item.hostView.alphaValue > 0.01 {
            rects.append(contentsOf: item.interactiveFramesInHost)
        }
        // Шкатулка — часть острова, обоснование в `trayIslandRects`.
        let live = { (view: NSView) -> NSRect? in
            !view.isHidden && view.alphaValue > 0.01 ? view.frame : nil
        }
        return trayIslandRects(cardRects: rects,
                               caseRect: live(caseView),
                               panelRect: live(casePanel))
    }

    /// Указатель над содержимым трея? Ответ решает, принимает ли полноэкранный
    /// хост события вообще, поэтому внешнего запаса здесь нет: клик рядом с
    /// треем обязан уходить в приложение под ним. Зазоры внутри острова при
    /// этом замкнуты — проход между командами и карточками не роняет окно.
    private func mouseOverTray() -> Bool {
        trayHoverRegionContains(toLocal(NSEvent.mouseLocation),
                                rects: currentIslandRects(),
                                shield: 0,
                                bridge: TrayHover.bridge)
    }

    /// Указатель внутри hover-острова? Здесь запас есть, и выход считается по
    /// большему порогу, чем вход: этот ответ удерживает раскрытый трей.
    private func mouseInsideHoverIsland() -> Bool {
        let inside = trayPointerRemainsInside(toLocal(NSEvent.mouseLocation),
                                              rects: currentIslandRects(),
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

    /// Наведение на ЛЮБУЮ карточку разворачивает нижнюю панель кнопок хаба —
    /// так же, как наведение на саму кнопку (`TR-27`). Состояние ленты роли
    /// не играет: панель кнопок и положение ленты — разные вещи, и ховер
    /// ленту не двигает. Прежнее условие пускало сессию ховера только у
    /// свёрнутого трея, поэтому у развёрнутой ленты панель не разворачивалась.
    private func thumbnailHoverChanged(_ thumbnail: ThumbnailWindow, entered: Bool) {
        if entered {
            // Рука подошла к трею — самое время разбудить актуатор внешнего
            // трекпада: его открытие занимает сотни миллисекунд (`TR-29`).
            TrayHaptics.shared.arm()
            cancelHoverExit()
            if collapsedPeekItem === thumbnail { cancelCollapsedPeekDismiss() }
            if !trayHoverActive, collapsedPeekItem == nil {
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
              capturePresentationSessions.isEmpty,
              !items.isEmpty else { return }
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
        //
        // Лента из ОДНОГО снимка — исключение: хода у неё нет, но она есть
        // собранная колода из одного элемента, а не раскрытая (`TR-39`).
        // Считая её раскрытой, второй снимок раскладывал ленту открыто, и
        // она поднималась на резерв под ярусы — 14 pt (приёмка 21.08.2026).
        let wasCompressed = scrollModel.maximumOffset > 0.5 || items.count == 1
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
        hostContent.addSubview(t.hostView, positioned: .below, relativeTo: casePanel)  // новейшая поверх старых, под панелью шкатулки
        for it in items { it.applyWidth(cardWidth, screenHeight: screen.frame.height) }
        showHost()
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
            // Шкатулка обязана следовать за составом ленты КАЖДЫЙ кадр: её
            // контур строится по видимым карточкам, а счётчик — по их числу.
            // Раньше `updateCase` звала только прокрутка, поэтому после
            // удаления подложка оставалась прежнего размера, карточка стояла
            // в ней со сбитыми отступами и упиралась в край, а счётчик
            // показывал старое число (приёмка 20.08.2026).
            self?.updateCase()
            self?.refreshHostPointerRouting()
        },
                               onDone: { [weak self] in
            guard let self else { return }
            self.collectionCompletion = nil
            completion()
            self.updateCase()
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
        updateCase()
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
        // При вставке карточки НЕ удаляются: всё, что ушло в hidden, — слои
        // стопки, сдвинутые на ярус глубже. Прогон их через анимацию «улёта»
        // вбок давал глич: призраки карточек с тенями на мгновение справа от
        // трея. Слои стопки просто скрываются.
        for item in hidden { item.hide() }

        var reflowing: [(ThumbnailWindow, NSRect)] = []
        for (item, slot) in visible where item !== inserted {
            // Кромка стопки не переезжает как полная карточка: полоса встаёт
            // сразу, иначе на время анимации стопка распухает в целые снимки.
            guard slot.isFullCard, let oldFrame = oldFrames[ObjectIdentifier(item)] else {
                place(item, at: slot)
                continue
            }
            item.prepareReflow(from: oldFrame,
                               to: thumbnailReflowOrigin(candidate: toLocal(slot.origin),
                                                      oldOuterFrame: oldFrame,
                                                      targetOuterSize: outerSize(of: item),
                                                      resizeBand: ThumbStyle.resizeBand,
                                                      vertical: axisIsVertical),
                               reduceMotion: reduceMotion)
            reflowing.append((item, oldFrame))
        }

        guard let slot = visible.first(where: { $0.0 === inserted })?.1 else {
            inserted.hide()
            return
        }
        inserted.prepareInsertion(at: toLocal(slot.origin),
                                  from: collectionDirectionalOffset(),
                                  reduceMotion: reduceMotion)
        // Новая карточка тоже влетает сбоку: контур шкатулки берёт её место,
        // а не текущее положение.
        enteringTargets[ObjectIdentifier(inserted)] = thumbnailVisibleFrame(
            slot: slot, cardSize: inserted.cardSize,
            vertical: axisIsVertical)
        runCollectionMotion(duration: reduceMotion ? TrayAnim.reducedTransition : TrayAnim.removalAndReflow,
                            onFrame: { [weak inserted] progress in
            inserted?.applyInsertion(progress: progress, reduceMotion: reduceMotion)
            for (item, oldFrame) in reflowing {
                item.applyReflow(progress: progress, from: oldFrame, reduceMotion: reduceMotion)
            }
        }, completion: { [weak self, weak inserted] in
            inserted?.finishCollectionMotion()
            self?.enteringTargets.removeAll()
            for (item, _) in reflowing { item.finishCollectionMotion() }
            for item in self?.items ?? [] where !visibleIDs.contains(ObjectIdentifier(item)) {
                item.hide()
            }
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
            ? ThumbStyle.margin
            : ThumbStyle.margin
        let slot = thumbnailLayout(screenFrame: screen.frame,
                                   edge: edge,
                                   cardWidth: cardWidth,
                                   cardHeights: [inserted.cardHeight],
                                   hubSize: .zero,
                                   margin: margin,
                                   gap: ThumbStyle.gap).visible.first
        guard let slot else {
            collapsedPeekItem = nil
            inserted.hide()
            return
        }
        inserted.prepareInsertion(at: toLocal(slot.origin),
                                  from: collectionDirectionalOffset(),
                                  reduceMotion: reduceMotion)
        runCollectionMotion(duration: reduceMotion ? TrayAnim.reducedTransition : TrayAnim.insertion,
                            onFrame: { [weak inserted] progress in
            inserted?.applyInsertion(progress: progress, reduceMotion: reduceMotion)
        }, completion: { [weak self, weak inserted] in
            guard let self, let inserted else { return }
            inserted.finishCollectionMotion()
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
                    enteringTargets[identifier] = thumbnailVisibleFrame(
                        slot: slot, cardSize: item.cardSize,
                        vertical: axisIsVertical)
                    entering.append(item)
                    continue
                }
                item.prepareReflow(
                    from: oldFrame,
                    to: thumbnailReflowOrigin(candidate: toLocal(slot.origin),
                                                      oldOuterFrame: oldFrame,
                                                      targetOuterSize: outerSize(of: item),
                                                      resizeBand: ThumbStyle.resizeBand,
                                                      vertical: axisIsVertical),
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
                            onFrame: { progress in
            for (item, oldFrame) in reflowing {
                item.applyReflow(progress: progress, from: oldFrame, reduceMotion: reduceMotion)
            }
            for item in entering { item.applyInsertion(progress: progress, reduceMotion: reduceMotion) }
            if animateCards {
                for item in animatedRemoved { item.applyRemoval(progress: progress, reduceMotion: reduceMotion) }
            }
        }, completion: { [weak self] in
            guard let self else { return }
            for (item, _) in reflowing { item.finishCollectionMotion() }
            for item in entering { item.finishCollectionMotion() }
            for item in animatedRemoved { self.closeAndRelease(item) }
            self.enteringTargets.removeAll()
            // Итоговый кадр — ИЗ РАСКЛАДКИ, как и при вставке. Переезд держит
            // координату поперёк оси по старой рамке
            // (`thumbnailAxisLockedOrigin`), чтобы карточку не мотало вбок, —
            // и без финального пересчёта этот перекос оставался навсегда:
            // после каждого удаления карточки стояли всё кривее (приёмка
            // 20.08.2026).
            if !self.items.isEmpty { self.applyScrollOffset() }
            if self.items.isEmpty {
                self.collapsed = false
                self.trayHoverActive = false
                self.collapsedPeekItem = nil
                self.trayAnimator.synchronize(0)
                self.trayProgress = 0
                self.host.orderOut(nil)
                self.refreshHostPointerRouting()
            }
        })
    }

    private func collectionDirectionalOffset() -> NSPoint {
        thumbnailCollectionOffset(vertical: axisIsVertical)
    }

    /// Колода собрана: лента доехала до упора и стоит там.
    private var deckIsGathered: Bool {
        scrollModel.offset >= scrollModel.maximumOffset - 0.5
    }

    /// Выбирает ось раскрытия по ходу пальца.
    ///
    /// Ось меняется ТОЛЬКО из собранного состояния. Раскрытая лента
    /// продолжает жить по своей оси до самого возврата — смена системы
    /// координат под раскрытой лентой давала прыжки, случайные щелчки и
    /// переходы в чужие состояния (приёмка 20.08.2026).
    private func pickOpenAxis(with event: NSEvent) -> Bool {
        if event.phase == .began {
            axisPickupX = 0
            axisPickupY = 0
        }
        axisPickupX += event.scrollingDeltaX
        axisPickupY += event.scrollingDeltaY

        // Движение ВДОЛЬ текущей оси не ждёт порога: это не заявка на смену
        // направления, а обычная работа с лентой, и задерживать её нельзя —
        // иначе первые точки хода в упор съедались бы и резинка начиналась с
        // опозданием.
        let along = activeEdge.isVertical ? abs(axisPickupY) : abs(axisPickupX)
        let across = activeEdge.isVertical ? abs(axisPickupX) : abs(axisPickupY)
        guard across > along else { return true }

        // Заявка на смену: ждём порога, пока направление не станет явным.
        guard let vertical = trayAxisPick(accumulatedX: axisPickupX,
                                          accumulatedY: axisPickupY,
                                          threshold: Self.axisPickThreshold) else { return false }
        let base = ThumbnailLayoutEdge(rawValue: TrayPosition.current.rawValue) ?? .right
        let chosen = vertical
            ? (base.isVertical ? base : (alternateEdge ?? base))
            : (base.isVertical ? (alternateEdge ?? base) : base)
        guard chosen != activeEdge else { return true }
        switchAxis(to: chosen)
        return true
    }

    /// Переводит ленту на другую ось. Вызывается только при собранной колоде:
    /// там обе оси дают одну и ту же картинку, поэтому переход невидим.
    ///
    /// Лента НЕ переносит смещение из прежней системы координат — длины ленты
    /// по осям разные, и старое смещение оказывалось посреди новой ленты:
    /// колода выглядела раскрытой, защёлка щёлкала сама собой, карточки
    /// прыгали. Вместо переноса лента встаёт в собранное состояние НОВОЙ
    /// оси, то есть остаётся ровно тем, чем была, — собранной колодой в том
    /// же углу.
    private func switchAxis(to edge: ThumbnailLayoutEdge) {
        openAxis = edge
        writeDip(0)
        // История скорости начинается с момента смены: прежние отсчёты сняты
        // с движения по другой оси. Обнулять её на каждом событии нельзя —
        // так ломается оценка скорости, а с ней проекция броска.
        scrollVelocity = 0
        lastScrollTimestamp = ProcessInfo.processInfo.systemUptime
        if let screen = anchorScreen ?? NSScreen.main {
            // Размеры ленты пересчитываются СРАЗУ: обычная синхронизация
            // модели выходит рано, пока жив жест, и лента осталась бы со
            // смещением в координатах прежней оси.
            let metrics = stripMetrics(on: screen)
            applyStripMetrics(content: metrics.content, viewport: metrics.viewport, last: metrics.last)
        }
        writeModel(scrollModel.maximumOffset)
        // Интента «оставаться собранной» здесь БЫТЬ НЕ ДОЛЖНО. Пока жив
        // жест, синхронизация модели выходит рано и интент не тратится, а
        // первый же полный проход после отрыва пальца читает его и
        // схлопывает ленту обратно: раскрытие по новой оси не держалось
        // (приёмка 20.08.2026). Собранное состояние выставлено строкой выше,
        // явно и один раз.
        detent.sync(with: scrollModel)
        // Лёгкий путь раскладки: `layout` гасит коллекционные анимации и
        // пересинхронизирует прогресс трея, а посреди жеста это читается как
        // прыжок.
        applyScrollOffset()
    }

    /// Scrolls the finite tray viewport. A newly captured
    /// screenshot always returns the viewport to the newest page.
    /// Непрерывная прокрутка ленты (`TR-1`, `TR-2`). Пошаговое переключение
    /// заменено на смещение, потому что ступенчатая лента не даёт понять, где
    /// ты находишься, и не позволяет остановиться между карточками.
    func scrollTray(with event: NSEvent) {
        guard !cardsAreCollapsed else { return }
        // `TR-41`: в третьей фазе горизонтальный ход не делает НИЧЕГО — ни
        // возврата колоды, ни раскрытия ленты, ни смены оси. Убирание живёт
        // на вертикальной оси, и выход из него тоже только вертикальный.
        if scrollModel.isStowed, !stepSettling {
            let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            if horizontal || !axisIsVertical { return }
        }
        // `TR-38`: ось раскрытия выбирает ЖЕСТ. Пока колода собрана и ось не
        // выбрана, лента не двигается — копится ход пальца, и по нему
        // решается, вверх раскрывать или влево.
        // Ось выбирает ПАЛЕЦ. Инерция оси не выбирает: события догона летят
        // уже после отрыва, и хвост предыдущего жеста уводил ленту в
        // направление, которого пользователь не показывал (приёмка
        // 20.08.2026).
        let gathered = deckIsGathered
        defer { wasGathered = gathered }
        if gathered, !wasGathered {
            // Колода только что собралась: направление считаем с этой точки,
            // иначе в счётчике остаётся ход, которым её и собирали, и он
            // перевешивает новое направление (приёмка 21.08.2026).
            axisPickupX = 0
            axisPickupY = 0
        }
        if alternateEdge != nil, gathered, event.momentumPhase == [],
           !pickOpenAxis(with: event) { return }
        let vertical = axisIsVertical
        // Ход, накопленный до выбора оси, лента НЕ наверстывает. Порог —
        // мёртвая зона распознавания направления, как у системных жестов:
        // после него движение идёт с текущей точки. Наверстывание давало
        // скачок на старте и завышало оценку скорости, отчего ломались
        // проекция броска и подача (приёмка 20.08.2026).
        let raw = vertical
            ? event.scrollingDeltaY
            : (abs(event.scrollingDeltaX) > 0.01 ? event.scrollingDeltaX : event.scrollingDeltaY)
        // Колесо мыши шлёт дельту в строках, а не в точках: один щелчок — это
        // единица, и лента ползла на пиксель за щелчок.
        let delta = event.hasPreciseScrollingDeltas ? raw : raw * Self.wheelLineHeight
        // Трекпад шлёт фазы жеста и инерции; классическое колесо — нет.
        let hasPhases = event.phase != [] || event.momentumPhase != []
        // Пальцы на трекпаде: фаза самого жеста. Инерция приходит уже без них
        // (`momentumPhase`) — и это разные режимы для анимации щелчка.
        let fingersDown = event.phase != []

        if event.phase == .began {
            // `TR-41`: ступень открыта жесту, чьё НАЧАЛО пришлось на собранную
            // колоду или на убранную. Условие — собранность, а не защёлка: у
            // ленты из одного снимка хода нет, и защёлка не встаёт.
            // Новый жест — новая история скорости.
            scrollVelocity = 0
            lastScrollTimestamp = event.timestamp
            momentumHandedToSpring = false
            // Палец коснулся во время догона: длинная инерционная подача
            // пережимается в короткую от текущего значения — перенацеливание
            // вместо среза (скилл, прерываемость).
            if detentDipAnimating { runDetentSpring(profile: .underFinger) }
        }
        // Инерцию, уже переданную пружине границы, не читаем вовсе — и до
        // общего блока, где события отменяют аниматоры: иначе первое же её
        // событие глушило саму пружину (`TR-13`). Так же ведёт себя системный
        // скролл: после передачи границе затухание не применяется.
        if momentumHandedToSpring, event.momentumPhase != [] {
            if event.momentumPhase != [] {
            let carried = deckStep.handle(TrayStowGate.Input(
                kind: .momentum, delta: delta, velocity: scrollVelocity,
                verticalAxis: axisIsVertical,
                deckGathered: scrollModel.offset >= scrollModel.maximumOffset - 0.5))
            if case .ignore = carried { return }
        }
        if event.momentumPhase == .ended { momentumHandedToSpring = false }
            return
        }
        if hasPhases {
            // Новое событие отменяет отложенный возврат: жест продолжается.
            settleGeneration &+= 1
            scrollSettleAnimator.cancel()
            scrollSettleAnimating = false
            // Открытие актуатора внешнего трекпада стоит сотни миллисекунд
            // (Bluetooth): готовим дескриптор в фоне заранее, чтобы сам
            // щелчок стоил доли миллисекунды.
            TrayHaptics.logSink = { [weak self] line in self?.debugTrayLog("haptics: \(line)") }
            TrayHaptics.shared.arm()
            // Устройство берётся из самого события (`TR-29`). В инерции
            // HID-нагрузки может не быть, поэтому источник запоминается на
            // всё время жеста: защёлка часто срабатывает уже на инерции.
            if let device = TrayHaptics.shared.device(of: event) {
                if gestureDevice != device {
                    debugTrayLog("источник жеста: устройство=\(device)")
                }
                gestureDevice = device
            }
            if !scrollGestureActive {
                debugTrayLog("gesture offset=\(Int(scrollModel.offset)) max=\(Int(scrollModel.maximumOffset)) fits=\(TrayDetentModel.fits(scrollModel)) engaged=\(detent.engaged)")
            }
            scrollGestureActive = true
        }

        guard scrollModel.isScrollable || abs(delta) > 0.01 else { return }
        scrollIntent = .none
        // Резинка только у жестов с фазами: колесо упирается в край жёстко.
        // Содержимое идёт за пальцами: положительная дельта двигает карточки к
        // хабу. Обратный знак разворачивал ленту против жеста. Жест никогда не
        // прячет и не показывает трей — это делает только клик по кнопке;
        // перетягивание за край лишь пружинит и возвращается.
        if hasPhases {
            // `TR-29`: дельты жеста идут через защёлку — у полного сбора лента
            // проходит точку напряжения и защёлкивается со щелчком.
            if TrayDetentModel.isNearDetent(scrollModel) { TrayHaptics.shared.arm() }
            // Растягивает резинку только палец: инерция упирается в край,
            // иначе после отпускания лента продолжает уезжать, а возврат
            // приходит с задержкой (приёмка 19.08.2026).
            // Отскок решается ДО применения дельты, прямой проверкой края:
            // лента на границе и инерция толкает наружу. Скорость — из
            // текущего кадра (дельта/время), сглаженная оценка к этому
            // моменту уже испорчена зажатыми кадрами (`TR-13`).
            if TrayBoundaryHandoff.shouldBounce(model: scrollModel, delta: delta,
                                                fingersDown: fingersDown,
                                                isMomentum: event.momentumPhase != []) {
                let dt = max(0.001, event.timestamp - lastScrollTimestamp)
                let outward = delta / CGFloat(dt)
                lastScrollTimestamp = event.timestamp
                momentumHandedToSpring = true
                let boundary = scrollModel.offset
                runBoundarySpring(from: boundary, displacement: 0, velocity: outward) { [weak self] in
                    guard let self else { return }
                    self.detent.sync(with: self.scrollModel)
                }
                return
            }
            let before = scrollModel.offset
            // `TR-41`: решение принимает СТРУКТУРА ступени. Здесь только
            // передача события и применение ответа — своих веток и флагов у
            // обработчика нет.
            let outcome = deckStep.handle(TrayStowGate.Input(
                kind: .changed, delta: delta, velocity: scrollVelocity,
                verticalAxis: axisIsVertical,
                deckGathered: scrollModel.offset >= scrollModel.maximumOffset - 0.5))
            switch outcome {
            case .ignore:
                trackVelocity(movement: 0, at: event.timestamp)
                return
            case .tension(let shift):
                if deckStep.strain > TrayStow.threshold * 0.5 { TrayHaptics.shared.arm() }
                let anchor = deckStep.stowed ? scrollModel.stowedMaximumOffset
                                             : scrollModel.maximumOffset
                writeModel(deckStep.stowed ? anchor - shift : anchor + shift)
                applyScrollOffset()
                trackVelocity(movement: delta, at: event.timestamp)
                return
            case .fire(let velocity):
                scrollModel.stowed = true
                performDetentHaptic(.snapIn)
                animateStep(to: scrollModel.stowedMaximumOffset, velocity: velocity)
                return
            case .recall(let velocity):
                scrollModel.stowed = false
                performDetentHaptic(.release)
                animateStep(to: scrollModel.maximumOffset, velocity: velocity)
                return
            case .release:
                animateStep(to: scrollModel.phaseLimit, velocity: 0)
                return
            case .pass:
                break
            }
            let result = detent.apply(delta: delta, to: scrollModel, stretch: fingersDown,
                                      limit: scrollModel.phaseLimit)
            // Щелчок ПЕРЕНАЦЕЛИВАЕТ движение: прыжок модели поглощается
            // подачей, видимая позиция остаётся непрерывной. Сдвиг больше
            // порога восприятия за один кадр запрещён (`TR-29`).
            writeModel(result.model, absorbJump: result.click != nil)
            trackVelocity(movement: scrollModel.offset - before, at: event.timestamp)
            if let click = result.click {
                // Под пальцем догон короткий и без перелёта: палец сохраняет
                // контроль над моделью, затухает только разница. На инерции —
                // длиннее и с лёгкой осадкой.
                performDetentClick(click, profile: fingersDown ? .underFinger : .inertia)
            }
        } else {
            // Колесо шагает дискретно: защёлка следует за фактом без щелчка.
            // Пружину границы колесо гасит — иначе позицию пишут двое сразу.
            scrollSettleAnimator.cancel()
            scrollSettleAnimating = false
            writeModel(scrollModel.scrolled(by: delta, rubberBand: false))
            detent.sync(with: scrollModel)
        }

        applyScrollOffset()

        if !hasPhases {
            writeModel(scrollModel.settled())
            applyScrollOffset()
            return
        }
        if event.momentumPhase == .ended {
            // Инерция кончилась — жест завершён окончательно.
            scrollGestureActive = false
            settleScrollAnimated()
        } else if (event.phase == .ended || event.phase == .cancelled),
                  abs(scrollModel.overshoot) > 0.5 {
            // Отпустили за краем: пружина возврата стартует со скоростью
            // жеста, а вся последующая инерция игнорируется — иначе её
            // события отменяли пружину и схлопывали растяжение телепортом.
            // Системный скролл после отпускания за краем инерцию тоже не
            // читает (`TR-13`).
            scrollGestureActive = false
            momentumHandedToSpring = true
            settleScrollAnimated()
        } else if event.phase == .ended || event.phase == .cancelled {
            scrollGestureActive = false
            // Конец жеста тоже идёт ЧЕРЕЗ структуру: обнулять снаружи нечего.
            let ending = deckStep.handle(TrayStowGate.Input(
                kind: event.phase == .cancelled ? TrayStowGate.Kind.cancelled : .ended,
                verticalAxis: axisIsVertical,
                deckGathered: scrollModel.offset >= scrollModel.maximumOffset - 0.5))
            if case .release = ending {
                animateStep(to: scrollModel.phaseLimit, velocity: 0)
                return
            }
            if case .ignore = ending { return }
            // `TR-36`: уверенный бросок к сбору защёлкивает ПО НАМЕРЕНИЮ —
            // по точке, где лента остановилась бы сама, а не по факту
            // доезда. Иначе бросок, не дотянувший чуть-чуть, читается как
            // «не сработало».
            if !detent.engaged,
               TrayFlickProjection.shouldSnap(model: scrollModel, velocity: scrollVelocity) {
                snapByFlick()
                return
            }
            // Пальцы сняты, но следом может пойти инерция. Возврат из-за края
            // откладывается: запущенный сразу, он тут же отменялся первым же
            // событием инерции, которое снова тянуло ленту наружу — старт,
            // отмена, старт, и это читалось как дёрганье (приёмка 19.08.2026).
            scheduleSettleAfterGesture()
        }
    }

    /// Защёлкивание по броску (`TR-36`): лента доводится до посадочного места
    /// тем же перенацеливанием, что и обычный щелчок — прыжок поглощается
    /// подачей, движение остаётся непрерывным. Последующая инерция
    /// игнорируется: намерение уже прочитано.
    private func snapByFlick() {
        momentumHandedToSpring = true
        writeModel(scrollModel.maximumOffset, absorbJump: true)
        detent.sync(with: scrollModel)
        performDetentClick(.snapIn, profile: .inertia)
        applyScrollOffset()
        debugTrayLog("защёлка по броску: скорость=\(Int(scrollVelocity)) pt/с")
    }

    /// Отложенный возврат: любое следующее событие жеста или инерции его
    /// отменяет, потому что поднимает поколение.
    private func scheduleSettleAfterGesture() {
        settleGeneration &+= 1
        let generation = settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self, self.settleGeneration == generation else { return }
            self.settleScrollAnimated()
        }
    }

    /// Пружина ступени (`TR-41`): уводит ленту к пределу фазы. Без перелёта,
    /// отклик медленнее схлопывания колоды — убирание отдельное событие, а не
    /// продолжение сбора. Начальная скорость наследуется от жеста, иначе на
    /// месте срыва виден шов.
    private func animateStep(to target: CGFloat, velocity: CGFloat) {
        let from = scrollModel.offset
        guard abs(target - from) > 0.5 else {
            writeModel(target)
            applyScrollOffset()
            return
        }
        stepSettling = true
        let relative = min(4, abs(velocity) / max(1, TrayStow.threshold))
        stepAnimator.run(duration: TrayStowAnim.response, onFrame: { [weak self] progress in
            guard let self else { return }
            let eased = TrayStowAnim.curve(progress, initialVelocity: relative)
            self.writeModel(from + (target - from) * eased)
            self.applyScrollOffset()
        }, onDone: { [weak self] in
            guard let self else { return }
            self.stepSettling = false
            self.writeModel(target)
            self.applyScrollOffset()
        })
    }

    /// Оценка скорости ленты по событиям, pt/с. Сглаживание убирает выброс от
    /// одиночного рваного кадра, иначе он задал бы скорость передачи пружине.
    private func trackVelocity(movement: CGFloat, at timestamp: TimeInterval) {
        defer { lastScrollTimestamp = timestamp }
        let dt = timestamp - lastScrollTimestamp
        guard dt > 0.0005, dt < 0.2 else { return }
        let instant = movement / CGFloat(dt)
        let alpha: CGFloat = 0.3
        scrollVelocity = scrollVelocity * (1 - alpha) + instant * alpha
    }

    /// Возврат из-за края после отпускания: не мгновенный clamp, а короткий
    /// ease-out — лента отвечает движением, как системный rubber-band.
    private func settleScrollAnimated() {
        let from = scrollModel.offset
        // `TR-29`: жест, замерший в зоне напряжения, не остаётся на скате —
        // защёлка дожимает ленту домой (со щелчком) либо выпускает к началу
        // зоны. Движение — та же пружинная подача, что у щелчка в жесте: одно
        // непрерывное движение, никаких ease с осадкой вдогонку.
        if let detentTarget = detent.settleTarget(for: scrollModel) {
            let home = detentTarget >= scrollModel.maximumOffset - 0.5
            // Дотяжка недожатого выхода — не новое защёлкивание: щелчок
            // положен только на переходе состояния, иначе он звучал бы на
            // каждом коротком недоскролле (`TR-29`).
            let alreadySeated = detent.engaged
            // Дотяжка — перенацеливание: видимая позиция не прыгает.
            writeModel(detentTarget, absorbJump: true)
            detent.sync(with: scrollModel)
            if home, !alreadySeated {
                performDetentClick(.snapIn, profile: .inertia)
            } else {
                runDetentSpring(profile: .inertia)
            }
            applyScrollOffset()
            return
        }
        let target = scrollModel.settled().offset
        guard abs(target - from) > 0.5 else {
            writePresented(target)
            detent.sync(with: scrollModel)
            applyScrollOffset()
            return
        }
        // Возврат — пружина с параметрами Apple для перемещения объектов:
        // демпфирование 1.0 (без перелёта), отклик 0.4 с (`TR-13`).
        // Фиксированная кривая читалась резким переходом «без резины».
        // Пружина стартует со скоростью жеста. Оценка скорости протухает,
        // когда палец замер: событий нет, значение остаётся старым, и после
        // паузы пружина дёргала ленту. Пауза длиннее 0.1 с обнуляет передачу.
        let sinceLastEvent = ProcessInfo.processInfo.systemUptime - lastScrollTimestamp
        let releaseVelocity = sinceLastEvent < 0.1 ? scrollVelocity : 0
        runBoundarySpring(from: target, displacement: from - target, velocity: releaseVelocity,
                          onDone: { [weak self] in
            guard let self else { return }
            self.detent.sync(with: self.scrollModel)
        })
    }

    /// Пружина границы: лента возвращается к `boundary`, начиная со смещения
    /// `displacement` и скорости `velocity` (наружу — положительная). Один
    /// механизм и для возврата растянутой ленты, и для отскока от края.
    private func runBoundarySpring(from boundary: CGFloat,
                                   displacement: CGFloat,
                                   velocity: CGFloat,
                                   onDone: @escaping () -> Void) {
        guard abs(displacement) > 0.5 || abs(velocity) > 1 else {
            scrollSettleAnimating = false
            writePresented(boundary)
            applyScrollOffset()
            onDone()
            return
        }
        scrollSettleAnimating = true
        let duration = TrayBoundarySpring.duration
        scrollSettleAnimator.run(duration: duration, onFrame: { [weak self] progress in
            guard let self else { return }
            let x = TrayBoundarySpring.offset(displacement: displacement,
                                                  velocity: velocity,
                                                  time: progress * duration)
            self.writePresented(boundary + x)
            self.applyScrollOffset()
        }, onDone: { [weak self] in
            guard let self else { return }
            self.scrollSettleAnimating = false
            self.writePresented(boundary)
            self.applyScrollOffset()
            onDone()
        })
    }

    /// Щелчок защёлки (`TR-29`): тактильный отклик и пружинная подача в один
    /// кадр. Перед вызовом прыжок модели уже переложен в `detentDip` —
    /// пружина доводит презентацию до нового места с одним перелётом, который
    /// и есть осадка. Тактильно отвечает трекпад с Force Touch.
    /// Профиль догона подачи: под пальцем — короткий и без перелёта, на
    /// инерции — длиннее и с лёгкой осадкой.
    enum DipProfile {
        case underFinger
        case inertia
    }

    private func performDetentClick(_ click: TrayDetentModel.Click, profile: DipProfile) {
        debugTrayLog("click \(click == .snapIn ? "snapIn" : "release") offset=\(Int(scrollModel.offset)) dip=\(Int(detentDip)) profile=\(profile == .underFinger ? "палец" : "инерция")")
        performDetentHaptic(click)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            writeDip(0)
            applyScrollOffset()
            return
        }
        runDetentSpring(profile: profile)
    }

    private func performDetentHaptic(_ click: TrayDetentModel.Click) {
        TrayHaptics.logSink = { [weak self] line in self?.debugTrayLog("haptics: \(line)") }
        TrayHaptics.shared.click(click == .snapIn ? .firm : .light, device: gestureDevice)
    }

    /// Пружинная подача `detentDip` к нулю: недодемпфированная пружина, один
    /// видимый перелёт (~16% пути) — у входа он уходит глубже упора (осадка),
    /// у выхода — наружу (отдача). Живёт своим аниматором: события жеста её
    /// не отменяют, повторный щелчок перезапускает от текущей подачи.
    private func runDetentSpring(profile: DipProfile) {
        let d0 = detentDip
        guard abs(d0) > 0.5 else {
            writeDip(0)
            applyScrollOffset()
            return
        }
        detentDipAnimator.cancel()
        detentDipAnimating = true
        // Один характер подачи независимо от того, сняты ли пальцы: разные
        // длительность и демпфирование делали один и тот же щелчок разным на
        // ощупь (анализ 20.08.2026). Критическое демпфирование, без перелёта;
        // под пальцем чуть короче, чтобы не спорить с прямым управлением.
        let duration: CGFloat = profile == .underFinger ? 0.16 : 0.22
        let omega: CGFloat = 6 / duration
        detentDipAnimator.run(duration: duration, onFrame: { [weak self] progress in
            guard let self else { return }
            let t = progress * duration
            self.writeDip(d0 * (1 + omega * t) * exp(-omega * t))
            self.applyScrollOffset()
        }, onDone: { [weak self] in
            guard let self else { return }
            self.detentDipAnimating = false
            self.writeDip(0)
            self.applyScrollOffset()
        })
    }


    nonisolated private static let trayLogEnabled =
        ProcessInfo.processInfo.environment["QUICKSHOT_LOG_TRAY"] == "1"

    nonisolated private func debugTrayLog(_ line: String) {
        guard Self.trayLogEnabled else { return }
        let path = NSHomeDirectory() + "/Library/Logs/QuickShot-tray.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp) \(line)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(toFile: path, atomically: true, encoding: .utf8)
        }
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
    // MARK: единственная точка записи позиции ленты

    /// Видимая позиция ленты — ЕДИНСТВЕННОЕ значение, от которого зависит
    /// раскладка (`SPEC_SINGLE_SOURCE.md`). Читать модельную позицию мимо
    /// неё в раскладке запрещено.
    private var presentedOffset: CGFloat { scrollModel.offset + detentDip }

    /// Записать МОДЕЛЬНУЮ позицию. `absorbJump` — сохранить видимую позицию
    /// неизменной, переложив разницу в подачу: так механика перенацеливает
    /// движение, а не рвёт его.
    private func writeModel(_ value: CGFloat, absorbJump: Bool = false) {
        let visible = presentedOffset
        scrollModel.offset = value
        detentDip = absorbJump ? visible - value : 0
    }

    /// Записать модель, полученную механикой целиком (жест, резинка).
    private func writeModel(_ model: TrayScrollModel, absorbJump: Bool = false) {
        let visible = presentedOffset
        scrollModel = model
        detentDip = absorbJump ? visible - scrollModel.offset : 0
    }

    /// Кадр пружины: видимая позиция ставится напрямую, подача обнуляется —
    /// пружина и есть носитель движения на этом отрезке.
    private func writePresented(_ value: CGFloat) {
        scrollModel.offset = value
        detentDip = 0
    }

    /// Кадр подачи: гасим разницу, модель не трогаем.
    private func writeDip(_ value: CGFloat) {
        detentDip = value
    }

    private func applyScrollOffset() {
        guard let screen = anchorScreen ?? NSScreen.main, !cardsAreCollapsed else {
            layout()
            return
        }
        let (visible, hidden) = cardLayout(on: screen)
        // `TR-34`: колода схлопывается в самой раскладке — отдельного сдвига
        // здесь нет, поэтому закрытие живёт во всех местах раскладки, а не
        // только в кадре прокрутки.
        for item in hidden { item.hide() }
        for (item, slot) in visible {
            place(item, at: slot)
        }
        finishLayoutPass()
    }

    /// Общий хвост ЛЮБОГО прохода раскладки. Оба пути постановки карточек —
    /// `layout` и `applyScrollOffset` — обязаны заканчиваться им, иначе
    /// производные состояния расходятся с геометрией.
    ///
    /// Так и появлялись баги: `layout` не звал `updateCase`, поэтому при
    /// ресайзе ширины, смене экрана и смене позиции трея шкатулка оставалась
    /// от прежней геометрии; `applyScrollOffset` не звал
    /// `refreshHostPointerRouting`, и зона приёма мыши отставала от карточек
    /// (аудит 20.08.2026).
    private func finishLayoutPass() {
        // Снимков не осталось — ступени нечего держать, иначе следующая
        // колода появилась бы уже убранной.
        if items.isEmpty, deckStep.stowed || deckStep.strain > 0 {
            deckStep.reset()
            scrollModel.stowed = false
        }
        applyStackOrder()
        updateCase()
        refreshHoverUnderPointer()
        refreshHostPointerRouting()
    }

    /// Шкатулка (`TR-30`): видима строго когда лента защёлкнута; контур —
    /// объединение видимых карточек с отступом, панель кнопок сверху.
    private func updateCase() {
        let engaged = detent.engaged && !cardsAreCollapsed && !items.isEmpty
        guard engaged else {
            if caseVisible {
                caseVisible = false
                caseView.isHidden = true
                casePanel.isHidden = true
            }
            return
        }
        // Шкатулка строится по ВИДИМЫМ границам карточек: рамка контейнера
        // раздута полем под тень, по ней отступы выходили больше заданных.
        // В контур входит и самый нижний ярус стопки — 8 pt отсчитываются от
        // него (`TR-30`).
        var contour = CGRect.null
        for item in items where !item.hostView.isHidden {
            // Влетающая карточка входит в контур своим МЕСТОМ, а не текущим
            // положением: иначе шкатулка гонится за ней от края экрана.
            contour = contour.union(enteringTargets[ObjectIdentifier(item)] ?? item.visibleCardFrame)
        }
        // `TR-41`, третья фаза: видимых карточек нет, остаётся полоска с
        // командами. Низ шкатулки неподвижен по построению — колода
        // стягивается к основанию, — поэтому контуру достаточно вырожденной
        // высоты у самого основания.
        if contour.isNull || contour.height <= 1 {
            guard scrollModel.stowProgress > 0.0001, let base = caseBaseline else { return }
            // Ширина в третьей фазе — по ПАНЕЛИ: карточек нет, и обнимать
            // нечего, кроме ряда команд. Полоска встаёт правым краем там же,
            // где стояла шкатулка, — по горизонтали ничего не скачет.
            let panelWidth = max(1, casePanel.fittingSize.width)
            contour = CGRect(x: base.maxX - panelWidth, y: base.minY,
                             width: panelWidth, height: 1)
        } else if scrollModel.stowProgress < 0.0001 {
            caseBaseline = contour
        }
        guard !contour.isNull, contour.width > 1 else { return }
        casePanel.setCount(items.count)
        let panelSize = casePanel.fittingSize
        let side = TrayCaseView.sidePadding
        let gap = TrayCaseView.panelGap
        // 8 pt по периметру верхней карточки, сверху добавка под панель.
        let caseRect = NSRect(x: contour.minX - side,
                              y: contour.minY - side,
                              width: max(contour.width + side * 2, panelSize.width + side * 2),
                              height: side + contour.height + gap + panelSize.height + gap)
        caseView.frame = caseRect
        // Панель ставится по своему измеренному размеру: растянутая на всю
        // ширину, она рисовала ряд кнопок натуральной величины у левого края
        // и скомканно (приёмка 19.08.2026).
        let panelRect = NSRect(x: caseRect.minX + side,
                               y: caseRect.maxY - gap - panelSize.height,
                               width: panelSize.width,
                               height: panelSize.height)
        if casePanel.frame != panelRect {
            casePanel.frame = panelRect
            casePanel.needsLayout = true
        }
        caseView.needsLayout = true
        if !caseVisible {
            caseVisible = true
            caseView.isHidden = false
            casePanel.isHidden = false
        }
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
                           vertical: axisIsVertical)
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
            hostContent.addSubview(item.hostView, positioned: .below, relativeTo: casePanel)
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
        // Карточка с перекрытым верхом ховер не получает: кнопки живут в
        // верхних углах, и показывать их снизу — сюрприз для пользователя
        // (`TR-28`).
        if let candidate = hovered, candidate.topIsCovered {
            hovered = nil
        }
        for item in items { item.applyHover(item === hovered) }
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
                    to: thumbnailReflowOrigin(candidate: toLocal(slot.origin),
                                                      oldOuterFrame: oldFrame,
                                                      targetOuterSize: outerSize(of: item),
                                                      resizeBand: ThumbStyle.resizeBand,
                                                      vertical: axisIsVertical),
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
        enteringTargets.removeAll()
        for item in items {
            sessions.discard(item.artifact.id)
            editedImages.discard(item.artifact.id)
            stateStore.discard(for: item.artifact.id)
            closeAndRelease(item)
        }
        collectionModel.removeAll()
        itemByID.removeAll()
        updateCase()
        host.orderOut(nil)
        refreshHostPointerRouting()
    }

    /// Внешняя рамка полной карточки: сама карточка плюс поля под тень.
    /// По ней переезд отличает карточку, выходящую из стопки (её поперечный
    /// размер меняется), от той, что просто едет вдоль ленты.
    private func outerSize(of item: ThumbnailWindow) -> NSSize {
        NSSize(width: item.cardSize.width + 2 * ThumbStyle.resizeBand,
               height: item.cardSize.height + 2 * ThumbStyle.resizeBand)
    }

    private func closeAndRelease(_ item: ThumbnailWindow) {
        item.close()
        artifactStore.releaseCard(item.artifact)
    }

    // MARK: ресайз (общая ширина, сохраняется между сессиями)

    func updateWidthLive(_ w: CGFloat) {
        // Ресайз сохраняет СОСТОЯНИЕ ленты, а не абсолютное смещение. Крупнее
        // карточки — длиннее лента: у трёх карточек +20 pt ширины дают +30 pt
        // хода. Смещение оставалось прежним, оказывалось посреди новой ленты,
        // и собранная колода разваливалась от малейшей подтяжки за край
        // (приёмка 21.08.2026). Доля раскрытия при этом переносится целиком:
        // собранная остаётся собранной, раскрытая — раскрытой на ту же долю.
        let previousOffset = scrollModel.offset
        let previousMaximum = scrollModel.maximumOffset
        preferredCardWidth = min(ThumbStyle.maxWidth, max(ThumbStyle.minWidth, w))
        if let screen = anchorScreen ?? NSScreen.main {
            updateClampedCardWidth(on: screen)
        } else {
            cardWidth = preferredCardWidth
        }
        let h = anchorHeight
        for t in items { t.applyWidth(cardWidth, screenHeight: h) }
        if let screen = anchorScreen ?? NSScreen.main {
            // Размеры ленты обновляются ДО раскладки: иначе доля считалась бы
            // от старой длины.
            let metrics = stripMetrics(on: screen)
            applyStripMetrics(content: metrics.content, viewport: metrics.viewport, last: metrics.last)
            writeModel(trayOffsetPreservingShare(offset: previousOffset,
                                                 maximum: previousMaximum,
                                                 newMaximum: scrollModel.maximumOffset))
            detent.sync(with: scrollModel)
        }
        layout()
    }

    func persistWidth() { defaults.set(Double(preferredCardWidth), forKey: widthKey) }

    // MARK: сворачивание/разворачивание (растворение в хаб)

    /// Клик по кнопке хаба ведёт по ступеням (`TR-27`): развёрнутая лента
    /// сначала собирается в стопку у кнопки, и только повторный клик по уже
    /// собранной стопке прячет трей. Скрытый трей клик разворачивает.
    func toggleCollapse() {
        if collapsed {
            expand()
        } else if stackIsGatheredAtHub || !scrollModel.isScrollable {
            collapse()
        } else {
            gatherStackAtHub()
        }
    }

    /// Собрать ленту в стопку у кнопки.
    private func gatherStackAtHub() { animateScroll(to: scrollModel.maximumOffset, detentClick: .snapIn) }

    /// Программная прокрутка тем же пружинным возвратом, что и жест:
    /// отдельной кривой у программного сбора нет (`TR-26`).
    private func animateScroll(to target: CGFloat, detentClick: TrayDetentModel.Click? = nil) {
        scrollSettleAnimator.cancel()
        scrollSettleAnimating = false
        scrollGestureActive = false
        let from = scrollModel.offset
        guard abs(target - from) > 0.5 else {
            writePresented(target)
            detent.sync(with: scrollModel)
            applyScrollOffset()
            return
        }
        scrollSettleAnimating = true
        scrollSettleAnimator.run(duration: 0.32, onFrame: { [weak self] progress in
            guard let self else { return }
            let eased = 1 - pow(1 - progress, 3)
            self.writePresented(from + (target - from) * eased)
            self.applyScrollOffset()
        }, onDone: { [weak self] in
            guard let self else { return }
            self.scrollSettleAnimating = false
            self.writePresented(target)
            self.detent.sync(with: self.scrollModel)
            self.applyScrollOffset()
            // Кнопочный сбор садится своим ease: осадка вдогонку читалась бы
            // вторым движением, остаётся только тактильная посадка.
            if let detentClick { self.performDetentHaptic(detentClick) }
        })
    }

    /// Лента полностью собрана в стопку у кнопки: смещение на максимуме и
    /// ход реальный (`TR-27`).
    var stackIsGatheredAtHub: Bool {
        scrollModel.maximumOffset > 0.5
            && scrollModel.offset >= scrollModel.maximumOffset - 1
    }

    func collapse() {
        // Сворачиваем при любом count >= 1 (хаб теперь виден и при одном снимке — клик должен работать).
        guard !collapsed, !items.isEmpty, let screen = anchorScreen ?? NSScreen.main else { return }
        finishCollectionMotion()
        cancelCollapsedPeekDismiss()
        cancelHoverExit()
        collapsedPeekItem = nil
        trayHoverActive = false
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
        let travelOffset = thumbnailTrayTravelOffset(vertical: axisIsVertical)
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
            self.refreshHostPointerRouting()
        }, onDone: { [weak self] in
            guard let self else { return }
            self.trayProgress = target
            let isCollapsed = target == 1
            for item in cards { item.finishTrayTransition(collapsed: isCollapsed) }
            // Итоговый кадр разворота — из раскладки: кромки получают полосы
            // и перспективу, а не полные рамки.
            if !isCollapsed {
                self.applyScrollOffset()
            } else {
                // Свёрнутый трей прячет карточки поштучно, хост не гаснет
                // целиком — без этого подложка шкатулки и её панель команд
                // оставались висеть на экране (аудит 20.08.2026).
                self.updateCase()
                self.refreshHostPointerRouting()
            }
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
        updateClampedCardWidth(on: screen)
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
        finishLayoutPass()
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
    /// Размеры ленты по АКТИВНОЙ оси. Отделены от политики посадки: при
    /// смене оси размеры обязаны обновиться немедленно, даже посреди жеста,
    /// иначе лента живёт в координатах прежней оси.
    private func stripMetrics(on screen: NSScreen) -> (content: CGFloat, viewport: CGFloat, last: CGFloat) {
        let vertical = axisIsVertical
        let gap = ThumbStyle.gap
        let lengths = items.map { vertical ? $0.cardSize.height : $0.cardSize.width }
        let content = lengths.reduce(0, +) + gap * CGFloat(max(0, lengths.count - 1))
        let geometry = viewportGeometry(on: screen)
        let viewport = thumbnailTrayViewportLength(screenFrame: screen.frame,
                                                   edge: geometry.edge,
                                                   hubSize: geometry.hubSize,
                                                   margin: geometry.margin,
                                                   menuBarInset: menuBarInset(on: screen))
        return (content, viewport, lengths.last ?? 0)
    }

    private func applyStripMetrics(content: CGFloat, viewport: CGFloat, last: CGFloat) {
        scrollModel.contentLength = content
        scrollModel.viewportLength = max(1, viewport)
        scrollModel.lastCardLength = last
    }

    private func syncScrollModel(on screen: NSScreen) {
        let vertical = axisIsVertical
        let gap = ThumbStyle.gap
        let lengths = items.map { vertical ? $0.cardSize.height : $0.cardSize.width }
        let content = lengths.reduce(0, +) + gap * CGFloat(max(0, lengths.count - 1))
        let geometry = viewportGeometry(on: screen)
        let viewport = thumbnailTrayViewportLength(screenFrame: screen.frame,
                                                   edge: geometry.edge,
                                                   hubSize: geometry.hubSize,
                                                   margin: geometry.margin,
                                                   menuBarInset: menuBarInset(on: screen))
        applyStripMetrics(content: content, viewport: viewport, last: lengths.last ?? 0)
        // Пока идёт жест или пружинный возврат, смещение может законно жить за
        // границей — мгновенный clamp здесь и делал резинку невидимой.
        if scrollGestureActive || scrollSettleAnimating {
            if !scrollModel.isScrollable { writeModel(0) }
            return
        }
        // `TR-41`: третью фазу новый снимок НЕ прерывает. Фаза дискретна и
        // живёт в модели, поэтому достаточно вернуть ленту к пределу фазы —
        // он уже учитывает убранность.
        scrollModel.stowed = deckStep.stowed
        if scrollModel.stowed {
            writeModel(scrollModel.phaseLimit)
            scrollIntent = .none
            detent.sync(with: scrollModel)
            return
        }
        switch scrollIntent {
        case .stayCompressed:
            // `TR-5`: стопка была собрана — новый снимок молча ложится сверху,
            // лента остаётся полностью сжатой.
            writeModel(scrollModel.maximumOffset)
        case .revealNewest:
            // `TR-5`: развёрнутая лента докручивается ровно до видимости
            // нового снимка; если он и так виден — не трогаем положение.
            writeModel(max(min(scrollModel.offset, scrollModel.maximumOffset),
                           scrollModel.revealNewestOffset()))
        case .none:
            writeModel(scrollModel.settled())
        }
        scrollIntent = .none
        detent.sync(with: scrollModel)
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
                                         offset: presentedOffset,
                                         menuBarInset: menuBarInset(on: screen),
                                         // `TR-34`: степень схлопывания колоды
                                         // от той же видимой позиции.
                                         deckProgress: TrayDeckClosure.value(
                                             presented: presentedOffset, model: scrollModel),
                                         stow: scrollModel.stowProgress)
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
            ? ThumbStyle.margin
            : ThumbStyle.margin
        // `TR-30`: хаб-виджет упразднён, места под него лента не резервирует.
        // Край берётся из АКТИВНОЙ оси (`TR-38`), а не только из позиции трея:
        // жест решает, раскрывается колода вверх или влево.
        return (activeEdge,
                .zero,
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
            // Соотношение 3:4 держится строго (`TR-37`), поэтому потолок
            // высоты ограничивает ШИРИНУ: иначе карточка переросла бы экран.
            maximum: min(ThumbStyle.maxWidth,
                         CardSizing.maxWidth(screenHeight: screen.frame.height)))
    }
}
