import AppKit
import OSLog
import QuartzCore

@MainActor
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Ручка ресайза по ВНУТРЕННЕЙ стороне карточки — той, что смотрит к центру экрана (внешняя
/// сторона приколочена раскладкой к краю экрана). Тянем внутренний край — он идёт за курсором,
/// внешний стоит на месте; направление само согласуется с позицией трея.
///
/// Курсор НЕ трогаем намеренно: фоновому приложению macOS менять курсор над своим окном не даёт
/// (подтверждено Apple DevForums), любой `set/push` система перебивает стрелкой. Поэтому
/// findability обеспечивает не вид курсора, а сама крупная предсказуемая зона вдоль всего края.
@MainActor
private final class EdgeHandle: NSView {
    enum Edge { case left, right, top, bottom }
    var edge: Edge = .left

    var beginSize: (() -> (w: CGFloat, h: CGFloat))?
    var liveWidth: ((CGFloat) -> Void)?
    var endResize: (() -> Void)?

    private var start: NSPoint = .zero
    private var startW: CGFloat = 0
    private var startH: CGFloat = 1

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let s = beginSize?() ?? (w: ThumbStyle.defaultWidth, h: ThumbStyle.defaultWidth)
        startW = s.w; startH = max(1, s.h)
        start = NSEvent.mouseLocation
    }
    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let newW: CGFloat
        switch edge {
        case .left:   newW = startW + (start.x - now.x)                          // влево → шире
        case .right:  newW = startW + (now.x - start.x)                          // вправо → шире
        case .bottom: newW = startW * ((startH + (start.y - now.y)) / startH)    // вниз → выше → шире (аспект)
        case .top:    newW = startW * ((startH + (now.y - start.y)) / startH)    // вверх → выше → шире
        }
        liveWidth?(newW)
    }
    override func mouseUp(with event: NSEvent) { endResize?() }
}

/// Тело карточки: сам скриншот (скруглённый) и Native SDK-контролы
/// [Copy] [Dismiss] в верхнем ряду, появляются/исчезают плавным fade. Ресайз — НЕ здесь
/// (краевая ручка `EdgeHandle`); тело отвечает за drag-out и даблклик. Курсор не трогаем.
@MainActor
private final class ThumbnailView: NSView, NSDraggingSource {

    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot",
                                                category: "drag")
    static let feedbackHold: TimeInterval = 1.2     // сколько держать галочку «Скопировано»
    static let fade: TimeInterval = 0.09            // почти незаметный fade кнопок

    weak var owner: ThumbnailWindow?
    weak var manager: ThumbnailManager?
    var collapsed = false { didSet { if collapsed { setControlsVisible(false, animated: false) } } }

    private let artifact: CaptureArtifact
    private var image: CGImage { artifact.previewImage }
    private let nsImage: NSImage
    private var displayNSImage: NSImage
    /// Показ картинки слоем: `NSImageView` кэширует отрисовку в натуральном
    /// размере изображения и держит вторую копию превью на каждой карточке.
    private let displayView = PassthroughImageView()
    /// Создаётся при первом наведении: собственный рантайм Native SDK стоит
    /// несколько мегабайт, а большинству карточек он никогда не понадобится.
    private var controls: NativeThumbnailControlsView?
    private var trackingArea: NSTrackingArea?

    /// Кадр, из которого делается картинка слоя. Превью остаётся нетронутым:
    /// оно нужно в полном размере для перетаскивания, закрепления и редактора.
    private var sourceForDisplay: CGImage
    private var displayedContentsWidth = 0

    private var startMouse: NSPoint = .zero
    private var movedFar = false
    private var activeDragPayload: CaptureArtifactDragPayload?
    private var titleResetWork: DispatchWorkItem?

    init(artifact: CaptureArtifact) {
        self.artifact = artifact
        let image = artifact.previewImage
        self.nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        self.displayNSImage = nsImage
        self.sourceForDisplay = image
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = QS.radiusCard
        layer?.masksToBounds = true

        // Картинкой владеет сам NSImageView. Ручной `layer.contents` у этого
        // класса не живёт дольше одного прохода отрисовки: контрол рисует себя
        // сам и затирает подложенное — карточка превращалась в одну тень.
        displayView.imageScaling = .scaleAxesIndependently
        displayView.wantsLayer = true
        displayView.image = nsImage
        displayedContentsWidth = image.width
        addSubview(displayView)

    }

    /// Контролы карточки по требованию.
    @discardableResult
    private func makeControlsIfNeeded() -> NativeThumbnailControlsView {
        if let controls { return controls }
        let view = NativeThumbnailControlsView(frame: .zero)
        view.onCopy = { [weak self] in self?.doCopy() }
        view.toolTip = "Copy"
        view.onDismiss = { [weak self] in
            guard let s = self, let o = s.owner else { return }
            let mgr = s.manager
            DispatchQueue.main.async { mgr?.remove(o) }
        }
        view.alphaValue = 0
        view.isHidden = true
        addSubview(view)
        controls = view
        layoutContents()
        return view
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard !isHidden, alphaValue > 0.01, bounds.contains(local) else { return nil }
        if let controls, !controls.isHidden, controls.alphaValue > 0.01 {
            if let hit = controls.hitTest(local) { return hit }
        }
        return self
    }

    // Tracking-область — только ховер кнопок.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t); trackingArea = t
    }

    func setDisplay(image displayImage: CGImage) {
        displayNSImage = NSImage(cgImage: displayImage,
                                 size: NSSize(width: displayImage.width, height: displayImage.height))
        sourceForDisplay = displayImage
        displayedContentsWidth = 0
        updateDisplayImage()
    }

    /// Раскладка внутренних элементов по текущему `bounds` (frame вью ставит обёртка).
    func layoutContents() {
        displayView.frame = bounds
        layer?.cornerRadius = QS.radiusCard
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        displayView.layer?.cornerRadius = 0
        displayView.layer?.masksToBounds = false
        updateDisplayImage()
        guard let controls else { return }
        let inset = QS.s2
        let rowH = ceil(controls.fittingSize.height)
        let rowY = bounds.height - inset - rowH
        let availableWidth = max(rowH, bounds.width - inset * 2)

        controls.setCompact(false)
        let fullGroupWidth = ceil(controls.fittingSize.width)
        controls.setCompact(fullGroupWidth > availableWidth)

        let groupWidth = min(availableWidth, ceil(controls.fittingSize.width))
        controls.frame = NSRect(x: inset, y: rowY, width: groupWidth, height: rowH)
    }

    /// Срез карточки в стопке (`TR-23`): вью — прямоугольное ОКНО в карточку,
    /// а скругление принадлежит самой карточке (слою изображения). Карточка
    /// раскладывается в масштаб глубины и сдвигается на `cardStartOffset`:
    /// её скруглённый край, уехавший за границу окна, срезается клипом
    /// постепенно, а не выключается скачком.
    func layoutSlice(cardSize: NSSize, vertical: Bool, cardStartOffset: CGFloat,
                     cornerRadius: CGFloat) {
        if vertical {
            let fullW = bounds.width
            let fullH = cardSize.height * (fullW / max(1, cardSize.width))
            displayView.frame = NSRect(x: 0, y: cardStartOffset,
                                       width: fullW, height: fullH)
        } else {
            let fullH = bounds.height
            let fullW = cardSize.width * (fullH / max(1, cardSize.height))
            // Ось ленты идёт от кнопки (справа) влево: начало карточки — её
            // правый край.
            displayView.frame = NSRect(x: bounds.width - fullW - cardStartOffset,
                                       y: 0,
                                       width: fullW, height: fullH)
        }
        // Окно клипует прямыми линиями; родные углы карточки несёт слой
        // изображения, радиус — в масштабе глубины.
        layer?.cornerRadius = 0
        layer?.maskedCorners = []
        displayView.layer?.cornerRadius = cornerRadius
        displayView.layer?.masksToBounds = true
        updateDisplayImage()
        controls?.isHidden = true
    }

    /// Картинка вью под текущий размер карточки: выигрыш памяти остаётся —
    /// NSImageView получает уменьшенную копию, а не превью целиком.
    /// Пересобирается только когда нужная ширина заметно изменилась: ресайз
    /// тянут мышью, и пересчёт на каждый кадр был бы дороже самой экономии.
    private func updateDisplayImage() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // Срез стопки может держать изображение шире собственных границ.
        let logicalWidth = max(bounds.width, displayView.frame.width)
        let neededWidth = max(1, Int((logicalWidth * scale).rounded()))
        guard neededWidth > 0 else { return }
        let sourceWidth = sourceForDisplay.width
        // Мельче исходника не бывает; запас в четверть, чтобы не пересобирать
        // на каждое движение ручки ресайза.
        let target = min(sourceWidth, Int(Double(neededWidth) * 1.25))
        if displayedContentsWidth > 0,
           abs(displayedContentsWidth - target) < max(32, target / 8) {
            return
        }
        displayedContentsWidth = target
        let cg = target >= sourceWidth
            ? sourceForDisplay
            : (Self.scaled(sourceForDisplay, toWidth: target) ?? sourceForDisplay)
        displayView.image = NSImage(cgImage: cg,
                                    size: NSSize(width: CGFloat(cg.width) / scale,
                                                 height: CGFloat(cg.height) / scale))
    }

    private static func scaled(_ image: CGImage, toWidth width: Int) -> CGImage? {
        let height = max(1, Int((Double(width) * Double(image.height) / Double(image.width)).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: ховер кнопок (плавный fade)

    override func mouseEntered(with event: NSEvent) {
        guard !collapsed else { return }
        manager?.hostBecomeKey()
        setControlsVisible(true)
    }
    override func mouseExited(with event: NSEvent) {
        setControlsVisible(false)
    }

    /// Показ контролов по решению менеджера. При прокрутке карточка уезжает
    /// из-под курсора, не получая `mouseExited`, и её кнопки оставались
    /// видимыми — сразу на нескольких карточках.
    func applyHover(_ active: Bool) {
        guard !collapsed || !active else { return }
        // Повторное назначение того же состояния запускало бы анимацию
        // прозрачности на каждом кадре прокрутки.
        guard controlsVisible != active else { return }
        setControlsVisible(active)
    }

    var controlsVisible: Bool {
        guard let controls else { return false }
        return !controls.isHidden && controls.alphaValue > 0.01
    }

    private func setControlsVisible(_ visible: Bool, animated: Bool = true) {
        if visible {
            let controls = makeControlsIfNeeded()
            controls.isHidden = false
            guard animated else { controls.alphaValue = 1; return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fade
                controls.animator().alphaValue = 1
            }
        } else {
            guard let controls else { return }
            guard animated else {
                controls.alphaValue = 0
                controls.isHidden = true
                return
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.fade
                controls.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let controls = self.controls, controls.alphaValue == 0 { controls.isHidden = true }
                }
            })
        }
    }

    // MARK: мышь тела (drag-out + даблклик; ресайз — краевая ручка)

    override func mouseDown(with event: NSEvent) {
        movedFar = false
        startMouse = NSEvent.mouseLocation
        if collapsed { return }
        // Двойной клик отдан редактору (`ED-1`); закрепление снимка переехало
        // на Option — оно нужно реже, чем правка.
        if event.clickCount == 2 {
            if event.modifierFlags.contains(.option) { openFull() } else { openEditor() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !collapsed, !movedFar else { return }
        let now = NSEvent.mouseLocation
        guard hypot(now.x - startMouse.x, now.y - startMouse.y) > ThumbStyle.dragThreshold else { return }
        movedFar = beginDragOut(with: event)
    }

    // MARK: действия

    private func doCopy() { if let owner { manager?.copy(owner) } }

    private func openFull() {
        guard let owner else { return }
        manager?.pin(owner)
    }

    private func openEditor() {
        guard let owner else { return }
        manager?.openEditor(owner)
    }

    func flashCopied() {
        let controls = makeControlsIfNeeded()
        controls.isHidden = false
        controls.alphaValue = 1
        controls.showCheck(true)
        layoutContents()
        titleResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.controls?.showCheck(false)
            self.layoutContents()
            if !self.isMouseInside() { self.setControlsVisible(false) }
        }
        titleResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.feedbackHold, execute: work)
    }

    private func isMouseInside() -> Bool {
        guard let win = window else { return false }
        return bounds.contains(convert(win.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

#if TESTING
    func debugShowControls() {
        setControlsVisible(true, animated: false)
        layoutContents()
    }

    func debugCloseButtonCenterInSelf() -> NSPoint {
        convert(makeControlsIfNeeded().buttonCenterInSelf { $0 == "Dismiss screenshot" },
                from: makeControlsIfNeeded())
    }

    func debugCopyButtonCenterInSelf() -> NSPoint {
        convert(makeControlsIfNeeded().buttonCenterInSelf { $0 == "Copy screenshot" || $0 == "Copied screenshot" },
                from: makeControlsIfNeeded())
    }

    func debugCloseButtonState() -> String {
        let superHit = hitTest(debugCloseButtonCenterInSelf()).map { String(describing: type(of: $0)) } ?? "nil"
        return "\(makeControlsIfNeeded().debugState(label: "Dismiss screenshot")) thumbHit=\(superHit)"
    }

    func debugCopyButtonState() -> String {
        let superHit = hitTest(debugCopyButtonCenterInSelf()).map { String(describing: type(of: $0)) } ?? "nil"
        return "\(makeControlsIfNeeded().debugState(label: "Copy")) thumbHit=\(superHit)"
    }
#endif

    // MARK: drag-out

    private func beginDragOut(with event: NSEvent) -> Bool {
        guard let owner else { return false }
        // `ED-4`: перетаскивание после сохранения отдаёт изменённую версию.
        // Она уже подготовлена, поэтому promise-путь здесь не нужен.
        if let edited = manager?.preparedImageForDelivery(owner.artifact),
           let item = Clipboard.pasteboardItem(preparedImage: edited) {
            let dragItem = NSDraggingItem(pasteboardWriter: item)
            dragItem.setDraggingFrame(displayView.frame, contents: displayNSImage)
            beginDraggingSession(with: [dragItem], event: event, source: self)
            return true
        }
        guard let payload = manager?.beginDrag(owner) else { return false }
        activeDragPayload = payload
        let dragItem = NSDraggingItem(pasteboardWriter: payload.pasteboardWriter)
        dragItem.setDraggingFrame(displayView.frame, contents: displayNSImage)
        beginDraggingSession(with: [dragItem], event: event, source: self)
        return true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint) {
        guard let payload = activeDragPayload else { return }
        manager?.dragSessionWillBegin(payload)
        Self.log.info(
            "drag session began sequence=\(session.draggingSequenceNumber, privacy: .public)")
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        guard let payload = activeDragPayload else { return }
        activeDragPayload = nil
        manager?.finishDrag(payload)
        Self.log.info(
            "drag session ended sequence=\(session.draggingSequenceNumber, privacy: .public) operation=\(operation.rawValue, privacy: .public)")
    }
}

/// Контейнер карточки: больше карточки на `resizeBand` с каждой стороны (поле под краевую ручку,
/// которая центрирована на крае и слегка выходит наружу). Несёт тень слоем. Пустые поля
/// (не ручка, не карточка) пропускают клики сквозь — иначе поля стали бы мёртвой зоной.
@MainActor
private final class CardContainer: NSView {
    var interactionsEnabled = true
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard interactionsEnabled, !isHidden, alphaValue > 0.01, bounds.contains(local) else { return nil }
        for child in subviews.reversed() where !child.isHidden && child.alphaValue > 0.01 {
            if let hit = child.hitTest(local) { return hit }
        }
        return nil          // ловят только сабвью (ручка/карточка); поля — сквозь
    }
}

/// Обёртка над одной карточкой — САБВЬЮ общего окна-хоста трея. `hostView` (контейнер) на
/// `resizeBand` больше карточки с каждой стороны; вдоль внутренней стороны сидит одна краевая
/// ручка ресайза. Motion держит layout-frame неподвижным и меняет только transform/opacity.
@MainActor
final class ThumbnailWindow {

    private struct VisualState {
        var translationX: CGFloat
        var translationY: CGFloat
        var alpha: CGFloat
        var shadowOpacity: CGFloat

        static let resting = VisualState(translationX: 0,
                                         translationY: 0,
                                         alpha: 1,
                                         shadowOpacity: TrayAnim.restingShadowOpacity)
    }

    let artifact: CaptureArtifact
    var image: CGImage { artifact.previewImage }
    let screen: NSScreen
    private(set) var cardWidth: CGFloat
    private(set) var cardHeight: CGFloat = 0

    private let band = ThumbStyle.resizeBand
    private let container = CardContainer()
    private let view: ThumbnailView
    private let edgeHandle = EdgeHandle()
    private let editedBadge = EditedBadgeView(frame: .zero)
    private var resizeEdge: EdgeHandle.Edge = .left
    private var restingFrame: NSRect = .zero
    private var visualState = VisualState.resting
    private var collectionOffset: NSPoint = .zero

    var hostView: NSView { container }
    var cardSize: NSSize { NSSize(width: cardWidth, height: cardHeight) }
    var layoutFrame: NSRect { container.frame }

    /// `ED-3`: карточка помечается изменённой после сохранения из редактора.
    /// Отредактированная версия показывается на карточке: пользователь видит
    /// то, что уйдёт в буфер и в перетаскивание.
    func setDisplayImage(_ image: CGImage) {
        view.setDisplay(image: image)
    }

    var isEdited = false {
        didSet {
            guard isEdited != oldValue else { return }
            editedBadge.isHidden = !isEdited
            positionEditedBadge()
        }
    }

    /// Интерактивная геометрия карточки в координатах хоста: сама карточка и
    /// краевая ручка. Поля контейнера сюда не входят — они пропускают клики
    /// насквозь, и остров наведения обязан повторять это, а не расширять.
    var interactiveFramesInHost: [NSRect] {
        let outer = container.frame
        let card = outer.insetBy(dx: band, dy: band)
        guard card.width > 0, card.height > 0 else { return [] }
        var frames = [card]
        if !edgeHandle.isHidden, edgeHandle.alphaValue > 0.01 {
            frames.append(edgeHandle.frame.offsetBy(dx: outer.minX, dy: outer.minY))
        }
        return frames
    }
    var onHoverChanged: ((Bool) -> Void)? {
        get { container.onHoverChanged }
        set { container.onHoverChanged = newValue }
    }

    init(artifact: CaptureArtifact,
         screen: NSScreen,
         manager: ThumbnailManager,
         width: CGFloat,
         screenHeight: CGFloat) {
        self.artifact = artifact
        self.screen = screen
        self.cardWidth = width

        view = ThumbnailView(artifact: artifact)

        container.wantsLayer = true
        if let l = container.layer {
            l.masksToBounds = false
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = Float(TrayAnim.restingShadowOpacity)
            l.shadowRadius = 11
            l.shadowOffset = CGSize(width: 0, height: -5)
        }
        container.addSubview(view)                       // карточка под ручкой
        editedBadge.isHidden = true
        container.addSubview(editedBadge)                // признак Edited поверх карточки
        container.addSubview(edgeHandle)                 // ручка поверх (вдоль внутреннего края)

        edgeHandle.beginSize = { [weak self] in
            (self?.cardWidth ?? ThumbStyle.defaultWidth, self?.cardHeight ?? ThumbStyle.defaultWidth)
        }
        edgeHandle.liveWidth = { [weak self] w in self?.view.manager?.updateWidthLive(w) }
        edgeHandle.endResize = { [weak self] in self?.view.manager?.persistWidth() }

        view.owner = self
        view.manager = manager
        applyWidth(width, screenHeight: screenHeight)
    }

    /// Назначить внутренний край под ресайз по позиции трея (внешний приколочен к краю экрана).
    func configureResize(for pos: TrayPosition) {
        switch pos {
        case .right:  resizeEdge = .left
        case .left:   resizeEdge = .right
        case .top:    resizeEdge = .bottom
        case .bottom: resizeEdge = .top
        }
        edgeHandle.edge = resizeEdge
        positionHandle()
    }

    /// Ручка-полоса вдоль внутреннего края: центрирована на крае (±band), длиной во всю сторону.
    private func positionEditedBadge() {
        guard isEdited else { return }
        let card = NSRect(x: band, y: band, width: cardWidth, height: cardHeight)
        editedBadge.frame = EditedBadgeView.frame(inCard: card,
                                                  badgeSize: editedBadge.intrinsicSize)
        editedBadge.needsLayout = true
    }

    private func positionHandle() {
        let b = band, z = 2 * band
        switch resizeEdge {
        case .left:   edgeHandle.frame = NSRect(x: 0,         y: b, width: z, height: cardHeight)
        case .right:  edgeHandle.frame = NSRect(x: cardWidth, y: b, width: z, height: cardHeight)
        case .bottom: edgeHandle.frame = NSRect(x: b, y: 0,          width: cardWidth, height: z)
        case .top:    edgeHandle.frame = NSRect(x: b, y: cardHeight, width: cardWidth, height: z)
        }
    }

    private func outerRect(cardOrigin o: NSPoint) -> NSRect {
        NSRect(x: o.x - band, y: o.y - band, width: cardWidth + 2 * band, height: cardHeight + 2 * band)
    }

    /// Карточка занимает контейнер минус поля `band`; во время анимации размер клампим.
    private func layoutCardInContainer() {
        isSliceBand = false
        let iw = max(0, container.bounds.width - 2 * band)
        let ih = max(0, container.bounds.height - 2 * band)
        view.frame = NSRect(x: band, y: band, width: iw, height: ih)
        // Содержимое карточки следует за её рамкой по любому пути размещения,
        // а не только при смене ширины.
        view.layoutContents()
    }

    func applyWidth(_ w: CGFloat, screenHeight: CGFloat) {
        cardWidth = w
        let layout = CardSizing.layout(imageW: image.width, imageH: image.height,
                                       width: cardWidth, screenHeight: screenHeight)
        cardHeight = layout.height
        let display = image.cropping(to: layout.cropRect) ?? image
        view.setDisplay(image: display)
        container.setFrameSize(NSSize(width: cardWidth + 2 * band, height: cardHeight + 2 * band))
        restingFrame.size = container.frame.size
        layoutCardInContainer()
        view.layoutContents()
        positionHandle()
        positionEditedBadge()
        container.layer?.shadowPath = CGPath(roundedRect: view.frame, cornerWidth: QS.radiusCard,
                                             cornerHeight: QS.radiusCard, transform: nil)
    }

    func setCollapsed(_ b: Bool) { view.collapsed = b }
    func flashCopied() { view.flashCopied() }
#if TESTING
    struct CollectionDebugSnapshot {
        let isHidden: Bool
        let alpha: CGFloat
        let translationX: CGFloat
        let translationY: CGFloat
    }

    func debugCollectionSnapshot() -> CollectionDebugSnapshot {
        CollectionDebugSnapshot(isHidden: container.isHidden,
                                alpha: visualState.alpha,
                                translationX: visualState.translationX,
                                translationY: visualState.translationY)
    }

    func debugShowControls() { view.debugShowControls() }

    func debugCloseButtonCenterInHost() -> NSPoint {
        let pointInView = view.debugCloseButtonCenterInSelf()
        let pointInContainer = view.convert(pointInView, to: container)
        return container.convert(pointInContainer, to: container.superview)
    }

    func debugCopyButtonCenterInHost() -> NSPoint {
        let pointInView = view.debugCopyButtonCenterInSelf()
        let pointInContainer = view.convert(pointInView, to: container)
        return container.convert(pointInContainer, to: container.superview)
    }

    func debugCloseButtonState() -> String { view.debugCloseButtonState() }
    func debugCopyButtonState() -> String { view.debugCopyButtonState() }
    var debugControlsVisible: Bool { view.controlsVisible }
    /// Видимая рамка карточки в координатах хоста: контейнер шире неё на поля
    /// ресайза, и зазор между карточками лежит именно между этими рамками.
    var debugCardFrame: NSRect { container.convert(view.frame, to: container.superview) }
    var debugStackOrder: CGFloat { stackOrder }
    /// Ширина превью в пикселях: источник показа карточки.
    var debugPreviewPixelWidth: Int { artifact.previewImage.width }

    /// Видимость и живость карточки так, как их видит пользователь: карточка
    /// в стопке может быть отрисована, но не принимать мышь.
    var debugIsInteractive: Bool { container.interactionsEnabled }
    var debugOpacity: CGFloat { container.alphaValue }
#endif

    // MARK: motion

    private func applyVisualState(_ state: VisualState) {
        visualState = state
        var transform = CATransform3DIdentity
        transform.m41 = state.translationX
        transform.m42 = state.translationY

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer?.transform = transform
        container.layer?.shadowOpacity = Float(state.shadowOpacity)
        container.alphaValue = max(0, min(1, state.alpha))
        CATransaction.commit()
    }

    /// Порядок наложения карточки: больше — ближе к зрителю. Значение хранится
    /// само по себе, а на экране его исполняет порядок сабвью: у layer-backed
    /// вью `zPosition` ломает отрисовку содержимого.
    private(set) var stackDepth: CGFloat = 0
    var stackOrder: CGFloat { stackDepth }
    /// Карточка сейчас показана кромкой стопки: такой полосе не положены ни
    /// ховер, ни контролы — ими владеет верхняя развёрнутая карточка.
    private(set) var isSliceBand = false

    func placeInstant(origin: NSPoint) {
        stackDepth = 0
        restingFrame = outerRect(cardOrigin: origin)
        container.frame = restingFrame
        layoutCardInContainer()
        applyVisualState(.resting)
        container.interactionsEnabled = true
        container.isHidden = false
    }

    /// Полоса карточки в стопке (`TR-23`…`TR-26`): видимая часть ЦЕЛОЙ
    /// карточки в масштабе её глубины. Размер задаётся РАМКОЙ, а не
    /// трансформацией слоя: у layer-backed вью AppKit сам ведёт геометрию слоя,
    /// и своя трансформация ломает отрисовку содержимого.
    func placeBand(origin: NSPoint,
                   length: CGFloat,
                   scale: CGFloat,
                   cardStartOffset: CGFloat,
                   roundsStart: Bool,
                   roundsEnd: Bool,
                   opacity: CGFloat,
                   shadowFraction: CGFloat,
                   stackOrder: CGFloat,
                   vertical: Bool) {
        stackDepth = stackOrder
        isSliceBand = true
        // Перспектива: карточка уменьшена целиком, полоса центрирована
        // поперёк оси ленты.
        let crossInset = vertical
            ? cardWidth * (1 - scale) / 2
            : cardHeight * (1 - scale) / 2
        let bandWidth = vertical ? max(1, cardWidth * scale) : max(1, length)
        let bandHeight = vertical ? max(1, length) : max(1, cardHeight * scale)
        let bandOrigin = vertical
            ? NSPoint(x: origin.x + crossInset, y: origin.y)
            : NSPoint(x: origin.x, y: origin.y + crossInset)
        restingFrame = NSRect(x: bandOrigin.x - band, y: bandOrigin.y - band,
                              width: bandWidth + 2 * band, height: bandHeight + 2 * band)
        container.frame = restingFrame
        view.frame = NSRect(x: band, y: band, width: bandWidth, height: bandHeight)
        view.layoutSlice(cardSize: NSSize(width: cardWidth * scale,
                                          height: cardHeight * scale),
                         vertical: vertical,
                         cardStartOffset: cardStartOffset,
                         cornerRadius: QS.radiusCard * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer?.transform = CATransform3DIdentity
        // Тень привязана к оставшейся высоте кромки (`TR-26`): исчезающая
        // полоса не оставляет тень висеть в воздухе и не мигает ею.
        container.layer?.shadowOpacity = Float(TrayAnim.restingShadowOpacity
                                               * max(0, min(1, shadowFraction))
                                               * max(0, min(1, opacity)))
        // Тень повторяет форму видимой части КАРТОЧКИ: скругления только на
        // её настоящих краях, срезы прямые. Прямоугольная тень с клампованным
        // радиусом обводила кромку тёмной рамкой — глаз читал её как
        // квадратную обрезку.
        let shadowRadius = QS.radiusCard * scale
        let corners: (bl: Bool, br: Bool, tl: Bool, tr: Bool) = vertical
            ? (roundsStart, roundsStart, roundsEnd, roundsEnd)
            : (roundsEnd, roundsStart, roundsEnd, roundsStart)
        container.layer?.shadowPath = Self.bandShadowPath(rect: view.frame,
                                                          radius: shadowRadius,
                                                          bottomLeft: corners.bl,
                                                          bottomRight: corners.br,
                                                          topLeft: corners.tl,
                                                          topRight: corners.tr)
        container.alphaValue = max(0, min(1, opacity))
        CATransaction.commit()
        // Кромка остаётся живой: клик достаётся верхней карточке по z-порядку,
        // а гашение интерактивности убивало и прокрутку, потому что события
        // колеса доходят до трея только через карточку.
        container.interactionsEnabled = true
        container.isHidden = false
    }

    /// Контур видимой части карточки для тени: скругление только на её
    /// настоящих краях, обрезанные края — прямые. Радиус клампится по
    /// фактическим размерам полосы, чтобы дуги не пересекались.
    private static func bandShadowPath(rect: CGRect, radius: CGFloat,
                                       bottomLeft: Bool, bottomRight: Bool,
                                       topLeft: Bool, topRight: Bool) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height))
        let blR = bottomLeft ? r : 0
        let brR = bottomRight ? r : 0
        let tlR = topLeft ? r : 0
        let trR = topRight ? r : 0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + blR, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - brR, y: rect.minY))
        if brR > 0 {
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + brR),
                              control: CGPoint(x: rect.maxX, y: rect.minY))
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - trR))
        if trR > 0 {
            path.addQuadCurve(to: CGPoint(x: rect.maxX - trR, y: rect.maxY),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX + tlR, y: rect.maxY))
        if tlR > 0 {
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - tlR),
                              control: CGPoint(x: rect.minX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + blR))
        if blR > 0 {
            path.addQuadCurve(to: CGPoint(x: rect.minX + blR, y: rect.minY),
                              control: CGPoint(x: rect.minX, y: rect.minY))
        }
        path.closeSubpath()
        return path
    }

    func prepareInsertion(at origin: NSPoint, from offset: NSPoint, reduceMotion: Bool) {
        restingFrame = outerRect(cardOrigin: origin)
        container.frame = restingFrame
        layoutCardInContainer()
        collectionOffset = reduceMotion ? .zero : offset
        setCollapsed(false)
        container.interactionsEnabled = false
        container.isHidden = false
        applyInsertion(progress: 0, reduceMotion: reduceMotion)
    }

    func applyInsertion(progress: CGFloat, reduceMotion: Bool) {
        let state = thumbnailInsertionState(progress: progress, reduceMotion: reduceMotion)
        applyVisualState(VisualState(translationX: collectionOffset.x * (1 - state.movementProgress),
                                     translationY: collectionOffset.y * (1 - state.movementProgress),
                                     alpha: state.alpha,
                                     shadowOpacity: state.shadowOpacity))
    }

    func prepareRemoval(toward offset: NSPoint, reduceMotion: Bool) {
        collectionOffset = reduceMotion ? .zero : offset
        container.interactionsEnabled = false
        container.isHidden = false
    }

    func applyRemoval(progress: CGFloat, reduceMotion: Bool) {
        let state = thumbnailRemovalState(progress: progress, reduceMotion: reduceMotion)
        applyVisualState(VisualState(translationX: collectionOffset.x * state.movementProgress,
                                     translationY: collectionOffset.y * state.movementProgress,
                                     alpha: state.alpha,
                                     shadowOpacity: state.shadowOpacity))
    }

    func prepareReflow(from oldFrame: NSRect, to origin: NSPoint, reduceMotion: Bool) {
        restingFrame = outerRect(cardOrigin: origin)
        container.frame = restingFrame
        layoutCardInContainer()
        container.interactionsEnabled = false
        container.isHidden = false
        let dx = reduceMotion ? 0 : oldFrame.minX - restingFrame.minX
        let dy = reduceMotion ? 0 : oldFrame.minY - restingFrame.minY
        applyVisualState(VisualState(translationX: dx,
                                     translationY: dy,
                                     alpha: 1,
                                     shadowOpacity: TrayAnim.restingShadowOpacity))
    }

    func applyReflow(progress: CGFloat, from oldFrame: NSRect, reduceMotion: Bool) {
        let p = thumbnailReflowProgress(progress, reduceMotion: reduceMotion)
        let dx = reduceMotion ? 0 : (oldFrame.minX - restingFrame.minX) * (1 - p)
        let dy = reduceMotion ? 0 : (oldFrame.minY - restingFrame.minY) * (1 - p)
        applyVisualState(VisualState(translationX: dx,
                                     translationY: dy,
                                     alpha: 1,
                                     shadowOpacity: TrayAnim.restingShadowOpacity))
    }

    func finishCollectionMotion(hidden: Bool = false) {
        if hidden {
            container.interactionsEnabled = false
            container.isHidden = true
            return
        }
        applyVisualState(.resting)
        container.interactionsEnabled = true
        container.isHidden = false
    }

    func prepareTrayTransition(progress: CGFloat,
                               travelOffset: NSPoint,
                               restingOrigin: NSPoint,
                               expanding: Bool,
                               reduceMotion: Bool) {
        restingFrame = outerRect(cardOrigin: restingOrigin)
        container.frame = restingFrame
        layoutCardInContainer()
        if expanding { setCollapsed(false) }
        applyTrayTransition(progress: progress,
                            travelOffset: travelOffset,
                            reduceMotion: reduceMotion)
        container.interactionsEnabled = false
        container.isHidden = false
    }

    func applyTrayTransition(progress: CGFloat,
                             travelOffset: NSPoint,
                             reduceMotion: Bool) {
        let state = thumbnailTrayVisualState(progress: progress, reduceMotion: reduceMotion)
        applyVisualState(VisualState(translationX: travelOffset.x * state.travelProgress,
                                     translationY: travelOffset.y * state.travelProgress,
                                     alpha: state.alpha,
                                     shadowOpacity: state.shadowOpacity))
    }

    func finishTrayTransition(collapsed: Bool) {
        setCollapsed(collapsed)
        if collapsed {
            container.interactionsEnabled = false
            container.isHidden = true
        } else {
            applyVisualState(.resting)
            container.interactionsEnabled = true
            container.isHidden = false
        }
    }

    /// Ховер карточки, назначенный менеджером.
    func applyHover(_ active: Bool) { view.applyHover(active) }

    func hide() {
        container.interactionsEnabled = false
        container.isHidden = true
    }

    func close() {
        container.interactionsEnabled = false
        container.removeFromSuperview()
    }
}
