import AppKit
import QuartzCore

// MARK: кривые сглаживания (нативный словарь: оседание, не симметрия)

private func easeOutCubic(_ f: CGFloat) -> CGFloat { 1 - pow(1 - f, 3) }
private func easeInOutCubic(_ f: CGFloat) -> CGFloat {
    f < 0.5 ? 4 * f * f * f : 1 - pow(-2 * f + 2, 3) / 2
}

/// Покадровая анимация поверх CADisplayLink (синхронно с дисплеем, корректно на ProMotion).
final class FrameAnimator: NSObject {
    private weak var hostView: NSView?
    private var link: CADisplayLink?
    private var begin: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var easing: (CGFloat) -> CGFloat = easeOutCubic
    private var onFrame: ((CGFloat) -> Void)?
    private var onDone: (() -> Void)?

    init(hostView: NSView) { self.hostView = hostView; super.init() }

    func run(duration: CFTimeInterval, delay: CFTimeInterval,
             easing: @escaping (CGFloat) -> CGFloat,
             onFrame: @escaping (CGFloat) -> Void, onDone: (() -> Void)? = nil) {
        cancel()
        self.duration = duration
        self.easing = easing
        self.onFrame = onFrame
        self.onDone = onDone
        self.begin = CACurrentMediaTime() + delay
        guard let hostView else { return }
        let l = hostView.displayLink(target: self, selector: #selector(step(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func step(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard now >= begin else { return }
        let t = duration <= 0 ? 1 : min(1, (now - begin) / duration)
        onFrame?(easing(CGFloat(t)))
        if t >= 1 { let done = onDone; cancel(); done?() }
    }

    func cancel() {
        link?.invalidate(); link = nil
        onFrame = nil; onDone = nil
    }
    deinit { link?.invalidate() }
}

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

/// Тело карточки: сам скриншот (скруглённый) и контролы — нативные Liquid Glass кнопки
/// [Копировать] [закрыть] в верхнем ряду, появляются/исчезают плавным fade. Ресайз — НЕ здесь
/// (краевая ручка `EdgeHandle`); тело отвечает за drag-out и даблклик. Курсор не трогаем.
private final class ThumbnailView: NSView, NSDraggingSource {

    static let feedbackHold: TimeInterval = 1.2     // сколько держать галочку «Скопировано»
    static let fade: TimeInterval = 0.09            // почти незаметный fade кнопок

    weak var owner: ThumbnailWindow?
    weak var manager: ThumbnailManager?
    var collapsed = false { didSet { if collapsed { setControlsVisible(false, animated: false) } } }

    private let image: CGImage
    private let nsImage: NSImage
    private var displayNSImage: NSImage
    private let displayView = PassthroughImageView()
    private let copyButton = GlassButton(symbol: "doc.on.doc", title: "Копировать", a11y: "Скопировать в буфер обмена")
    private let closeButton = GlassButton(symbol: "xmark", a11y: "Отбросить снимок")
    private var trackingArea: NSTrackingArea?

    private var startMouse: NSPoint = .zero
    private var movedFar = false
    private var titleResetWork: DispatchWorkItem?

    init(image: CGImage) {
        self.image = image
        self.nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        self.displayNSImage = nsImage
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = QS.radiusCard
        layer?.masksToBounds = true

        displayView.imageScaling = .scaleAxesIndependently
        displayView.wantsLayer = true
        addSubview(displayView)

        copyButton.onClick = { [weak self] in self?.doCopy() }
        copyButton.toolTip = "Скопировать в буфер обмена"
        closeButton.onClick = { [weak self] in
            guard let s = self, let o = s.owner else { return }
            let mgr = s.manager
            DispatchQueue.main.async { mgr?.remove(o) }
        }
        closeButton.toolTip = "Отбросить снимок"
        for b in [copyButton, closeButton] { b.alphaValue = 0; b.isHidden = true; addSubview(b) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        displayView.image = displayNSImage
    }

    /// Раскладка внутренних элементов по текущему `bounds` (frame вью ставит обёртка).
    func layoutContents() {
        displayView.frame = bounds
        let inset = QS.s2, gap = QS.s2
        let rowH = ceil(max(copyButton.fittingSize.height, closeButton.fittingSize.height))
        let rowY = bounds.height - inset - rowH
        let closeX = bounds.width - inset - rowH
        closeButton.frame = NSRect(x: closeX, y: rowY, width: rowH, height: rowH)

        copyButton.setCompact(false)
        let availForCopy = closeX - gap - inset
        copyButton.setCompact(copyButton.fittingSize.width > availForCopy)
        let cw = copyButton.isCompact ? rowH : ceil(copyButton.fittingSize.width)
        copyButton.frame = NSRect(x: inset, y: rowY, width: cw, height: rowH)
    }

    // MARK: ховер кнопок (плавный fade)

    override func mouseEntered(with event: NSEvent) {
        guard !collapsed else { return }
        manager?.hostBecomeKey()
        setControlsVisible(true)
    }
    override func mouseExited(with event: NSEvent) { setControlsVisible(false) }

    private func setControlsVisible(_ visible: Bool, animated: Bool = true) {
        let buttons = [copyButton, closeButton]
        if visible {
            for b in buttons { b.isHidden = false }
            guard animated else { for b in buttons { b.alphaValue = 1 }; return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fade
                for b in buttons { b.animator().alphaValue = 1 }
            }
        } else {
            guard animated else { for b in buttons { b.alphaValue = 0; b.isHidden = true }; return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.fade
                for b in buttons { b.animator().alphaValue = 0 }
            }, completionHandler: {
                for b in buttons where b.alphaValue == 0 { b.isHidden = true }
            })
        }
    }

    // MARK: мышь тела (drag-out + даблклик; ресайз — краевая ручка)

    override func mouseDown(with event: NSEvent) {
        movedFar = false
        startMouse = NSEvent.mouseLocation
        if collapsed { return }
        if event.clickCount == 2 { openFull() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !collapsed, !movedFar else { return }
        let now = NSEvent.mouseLocation
        guard hypot(now.x - startMouse.x, now.y - startMouse.y) > ThumbStyle.dragThreshold else { return }
        movedFar = true
        beginDragOut(with: event)
    }

    // MARK: действия

    private func doCopy() { if let owner { manager?.copy(owner) } }

    private func openFull() {
        guard let screen = owner?.screen ?? NSScreen.main else { return }
        PinnedWindowController.show(image: image, on: screen)
    }

    func flashCopied() {
        copyButton.isHidden = false
        copyButton.alphaValue = 1
        copyButton.showCheck(true)
        titleResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.copyButton.showCheck(false)
            if !self.isMouseInside() { self.setControlsVisible(false) }
        }
        titleResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.feedbackHold, execute: work)
    }

    private func isMouseInside() -> Bool {
        guard let win = window else { return false }
        return bounds.contains(convert(win.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    // MARK: drag-out

    private func beginDragOut(with event: NSEvent) {
        let item = NSPasteboardItem()
        if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickShot-\(UUID().uuidString.prefix(8)).png")
            if (try? png.write(to: url)) != nil { item.setString(url.absoluteString, forType: .fileURL) }
        }
        if let tiff = nsImage.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(displayView.frame, contents: displayNSImage)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// Контейнер карточки: больше карточки на `resizeBand` с каждой стороны (поле под краевую ручку,
/// которая центрирована на крае и слегка выходит наружу). Несёт тень слоем. Пустые поля
/// (не ручка, не карточка) пропускают клики сквозь — иначе поля стали бы мёртвой зоной.
private final class CardContainer: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let v = super.hitTest(point)
        return v === self ? nil : v          // ловят только сабвью (ручка/карточка); поля — сквозь
    }
}

/// Обёртка над одной карточкой — САБВЬЮ общего окна-хоста трея. `hostView` (контейнер) на
/// `resizeBand` больше карточки с каждой стороны; вдоль внутренней стороны сидит одна краевая
/// ручка ресайза. Анимации двигают frame/alpha контейнера.
final class ThumbnailWindow {

    let image: CGImage
    let screen: NSScreen
    private(set) var cardWidth: CGFloat
    private(set) var cardHeight: CGFloat = 0

    private let band = ThumbStyle.resizeBand
    private let container = CardContainer()
    private let view: ThumbnailView
    private let edgeHandle = EdgeHandle()
    private let animator: FrameAnimator
    private var resizeEdge: EdgeHandle.Edge = .left

    var hostView: NSView { container }
    var cardSize: NSSize { NSSize(width: cardWidth, height: cardHeight) }

    init(image: CGImage, screen: NSScreen, manager: ThumbnailManager, width: CGFloat, screenHeight: CGFloat) {
        self.image = image
        self.screen = screen
        self.cardWidth = width

        view = ThumbnailView(image: image)
        animator = FrameAnimator(hostView: view)         // до замыканий с self ниже

        container.wantsLayer = true
        if let l = container.layer {
            l.masksToBounds = false
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.32
            l.shadowRadius = 11
            l.shadowOffset = CGSize(width: 0, height: -5)
        }
        container.addSubview(view)                       // карточка под ручкой
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
        let iw = max(0, container.bounds.width - 2 * band)
        let ih = max(0, container.bounds.height - 2 * band)
        view.frame = NSRect(x: band, y: band, width: iw, height: ih)
    }

    func applyWidth(_ w: CGFloat, screenHeight: CGFloat) {
        cardWidth = w
        let layout = CardSizing.layout(imageW: image.width, imageH: image.height,
                                       width: cardWidth, screenHeight: screenHeight)
        cardHeight = layout.height
        let display = image.cropping(to: layout.cropRect) ?? image
        view.setDisplay(image: display)
        container.setFrameSize(NSSize(width: cardWidth + 2 * band, height: cardHeight + 2 * band))
        layoutCardInContainer()
        view.layoutContents()
        positionHandle()
        container.layer?.shadowPath = CGPath(roundedRect: view.frame, cornerWidth: QS.radiusCard,
                                             cornerHeight: QS.radiusCard, transform: nil)
    }

    func setCollapsed(_ b: Bool) { view.collapsed = b }
    func flashCopied() { view.flashCopied() }

    // MARK: анимация (CADisplayLink, ease-out без overshoot) — двигаем контейнер

    private func animate(toFrame target: NSRect, toAlpha targetAlpha: CGFloat,
                         duration: Double, delay: Double,
                         easing: @escaping (CGFloat) -> CGFloat = easeOutCubic,
                         completion: (() -> Void)? = nil) {
        let startFrame = container.frame
        let startAlpha = container.alphaValue
        animator.run(duration: duration, delay: delay, easing: easing, onFrame: { [weak self] e in
            guard let self else { return }
            self.container.frame = NSRect(
                x: startFrame.minX + (target.minX - startFrame.minX) * e,
                y: startFrame.minY + (target.minY - startFrame.minY) * e,
                width: startFrame.width + (target.width - startFrame.width) * e,
                height: startFrame.height + (target.height - startFrame.height) * e)
            self.layoutCardInContainer()
            self.container.alphaValue = max(0, min(1, startAlpha + (targetAlpha - startAlpha) * e))
        }, onDone: completion)
    }

    func placeInstant(origin: NSPoint) {
        animator.cancel()
        container.frame = outerRect(cardOrigin: origin)
        layoutCardInContainer()
        container.alphaValue = 1
        container.isHidden = false
    }

    /// Влёт новой карточки: scale (0.92 → 1) + fade. Быстро, ease-out без перелёта.
    func appear(at origin: NSPoint) {
        animator.cancel()
        let final = outerRect(cardOrigin: origin)
        let startSize = NSSize(width: final.width * 0.92, height: final.height * 0.92)
        container.frame = NSRect(x: final.midX - startSize.width / 2, y: final.midY - startSize.height / 2,
                                 width: startSize.width, height: startSize.height)
        layoutCardInContainer()
        container.alphaValue = 0
        container.isHidden = false
        animate(toFrame: final, toAlpha: 1, duration: TrayAnim.move, delay: 0, easing: easeOutCubic)
    }

    func dissolve(toHubCenter c: NSPoint, duration: Double, delay: Double) {
        let tiny = NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
        animate(toFrame: tiny, toAlpha: 0, duration: duration, delay: delay, easing: easeInOutCubic) { [weak self] in
            self?.container.isHidden = true
        }
    }

    func emerge(fromHubCenter c: NSPoint, toOrigin o: NSPoint, duration: Double, delay: Double) {
        animator.cancel()
        container.frame = NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
        layoutCardInContainer()
        container.alphaValue = 0
        container.isHidden = false
        animate(toFrame: outerRect(cardOrigin: o), toAlpha: 1, duration: duration, delay: delay, easing: easeOutCubic)
    }

    func hide() { animator.cancel(); container.isHidden = true }
    func close() { animator.cancel(); container.removeFromSuperview() }
}
