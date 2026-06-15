import AppKit
import QuartzCore

// MARK: кривые сглаживания (нативный словарь: оседание, не симметрия)

private func easeOutCubic(_ f: CGFloat) -> CGFloat { 1 - pow(1 - f, 3) }
private func easeInOutCubic(_ f: CGFloat) -> CGFloat {
    f < 0.5 ? 4 * f * f * f : 1 - pow(-2 * f + 2, 3) / 2
}
private func easeOutBack(_ f: CGFloat) -> CGFloat {        // лёгкий overshoot + settle
    let c1: CGFloat = 1.70158, c3 = c1 + 1
    return 1 + c3 * pow(f - 1, 3) + c1 * pow(f - 1, 2)
}

/// Покадровая анимация поверх CADisplayLink (синхронно с дисплеем, корректно на ProMotion).
/// Нужна, потому что panel.animator().setFrame не двигает borderless .nonactivatingPanel.
final class FrameAnimator: NSObject {
    private weak var hostView: NSView?
    private var link: CADisplayLink?
    private var begin: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var started = false
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
        self.started = false
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

/// Панель одной миниатюры. Одна санкционированная тень плавающего слоя (hasShadow).
final class ThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Тело карточки: только сам скриншот, скруглённый на radiusCard, без рамки. Контролы —
/// нативные Liquid Glass кнопки (NSButton .glass) в верхнем ряду: [Копировать] [развернуть]
/// [закрыть]. Появляются по ховеру через isHidden (чётко, на полном контрасте). Копирование
/// только по кнопке, даблклик и кнопка «развернуть» — полный кадр. Жесты: drag-out, ресайз
/// за левый/правый край. Сворачивание — хабом.
private final class ThumbnailView: NSView, NSDraggingSource {

    static let feedbackHold: TimeInterval = 1.2     // сколько держать галочку «Скопировано»

    weak var owner: ThumbnailWindow?
    weak var manager: ThumbnailManager?
    var collapsed = false { didSet { if collapsed { setControlsVisible(false) } } }

    private let image: CGImage
    private let nsImage: NSImage
    private var displayNSImage: NSImage
    private let displayView = PassthroughImageView()
    private let fade = PassthroughView()
    private let fadeGradient = CAGradientLayer()
    private let copyButton = GlassButton(symbol: "doc.on.doc", title: "Копировать", a11y: "Скопировать в буфер обмена")
    private let closeButton = GlassButton(symbol: "xmark", a11y: "Отбросить снимок")
    private var trackingArea: NSTrackingArea?

    private var cropEdge: CropEdge = .none

    private enum Mode { case none, body, resize }
    private enum Edge { case none, left, right }
    private var mode: Mode = .none
    private var edge: Edge = .none
    private var startMouse: NSPoint = .zero
    private var startWidth: CGFloat = 0
    private var movedFar = false
    private var titleResetWork: DispatchWorkItem?

    init(image: CGImage) {
        self.image = image
        self.nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        self.displayNSImage = nsImage
        super.init(frame: .zero)

        // Карточка = сам скриншот, скруглённый. Без рамки/подложки.
        wantsLayer = true
        layer?.cornerRadius = QS.radiusCard
        layer?.masksToBounds = true

        displayView.imageScaling = .scaleAxesIndependently
        displayView.wantsLayer = true
        addSubview(displayView)

        // Фейд на обрезанном крае (постоянный сигнал «есть ещё»).
        fade.wantsLayer = true
        fade.layer?.masksToBounds = true
        fadeGradient.colors = [NSColor.black.withAlphaComponent(0).cgColor,
                               NSColor.black.withAlphaComponent(0.08).cgColor,
                               NSColor.black.withAlphaComponent(0.38).cgColor]
        fadeGradient.locations = [0, 0.6, 1]
        fade.layer?.addSublayer(fadeGradient)
        fade.isHidden = true
        addSubview(fade)

        // Кнопки всегда в иерархии; видимость — через isHidden (скрытая вью не ловит клики
        // и выпадает из tab/a11y сама, костыли с alpha-хит-тестом не нужны).
        copyButton.onClick = { [weak self] in self?.doCopy() }
        copyButton.toolTip = "Скопировать в буфер обмена"
        copyButton.isHidden = true
        addSubview(copyButton)

        // remove() рвёт единственную сильную ссылку на ThumbnailWindow и синхронно
        // деаллоцирует кнопку прямо в её же mouseUp — откладываем на следующий тик.
        closeButton.onClick = { [weak self] in
            guard let s = self, let o = s.owner else { return }
            let mgr = s.manager
            DispatchQueue.main.async { mgr?.remove(o) }
        }
        closeButton.toolTip = "Отбросить снимок"
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setDisplay(image displayImage: CGImage, cropped: Bool, edge: CropEdge) {
        displayNSImage = NSImage(cgImage: displayImage,
                                 size: NSSize(width: displayImage.width, height: displayImage.height))
        displayView.image = displayNSImage
        cropEdge = edge
        fade.isHidden = !cropped
    }

    func layoutCard(width: CGFloat, height: CGFloat) {
        frame = NSRect(x: 0, y: 0, width: width, height: height)
        displayView.frame = bounds

        // Фейд у обрезанного края.
        let fb: CGFloat = 34
        switch cropEdge {
        case .bottom:
            fade.frame = NSRect(x: 0, y: 0, width: width, height: fb)
            fadeGradient.startPoint = CGPoint(x: 0.5, y: 1); fadeGradient.endPoint = CGPoint(x: 0.5, y: 0)
        case .right:
            fade.frame = NSRect(x: width - fb, y: 0, width: fb, height: height)
            fadeGradient.startPoint = CGPoint(x: 0, y: 0.5); fadeGradient.endPoint = CGPoint(x: 1, y: 0.5)
        case .none:
            fade.frame = .zero
        }
        fadeGradient.frame = fade.bounds

        // Верхний ряд: [Копировать] слева … [закрыть] справа. Размеры — нативные (fittingSize).
        // Круглая кнопка квадратная rowH×rowH (диаметр из её собственной метрики, не из чужой).
        // Развернуть на полный кадр — двойным кликом по телу (отдельная кнопка не нужна).
        let inset = QS.s2, gap = QS.s2
        let rowH = ceil(max(copyButton.fittingSize.height, closeButton.fittingSize.height))
        let rowY = height - inset - rowH
        let closeX = width - inset - rowH
        closeButton.frame = NSRect(x: closeX, y: rowY, width: rowH, height: rowH)

        copyButton.setCompact(false)
        let availForCopy = closeX - gap - inset
        copyButton.setCompact(copyButton.fittingSize.width > availForCopy)
        let cw = copyButton.isCompact ? rowH : ceil(copyButton.fittingSize.width)
        copyButton.frame = NSRect(x: inset, y: rowY, width: cw, height: rowH)

        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    // MARK: ховер (reveal через isHidden — глиф всегда полный контраст, без alpha-ramp)

    override func mouseEntered(with event: NSEvent) {
        guard !collapsed else { return }
        window?.makeKey()             // nonactivating key: кнопки рисуются активными сразу, не по клику
        setControlsVisible(true)
    }
    override func mouseExited(with event: NSEvent) { setControlsVisible(false) }

    private func setControlsVisible(_ visible: Bool) {
        copyButton.isHidden = !visible
        closeButton.isHidden = !visible
    }

    // MARK: курсор у краёв (ресайз меняет только ширину — курсор только горизонтальный)

    override func resetCursorRects() {
        let b = ThumbStyle.edgeBand
        addCursorRect(NSRect(x: 0, y: 0, width: b, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - b, y: 0, width: b, height: bounds.height), cursor: .resizeLeftRight)
    }

    private func edgeAt(_ p: NSPoint) -> Edge {
        let b = ThumbStyle.edgeBand
        if p.x <= b { return .left }
        if p.x >= bounds.width - b { return .right }
        return .none
    }

    // MARK: мышь (кнопки обрабатываются сами; тело — drag-out/ресайз, без копирования)

    override func mouseDown(with event: NSEvent) {
        movedFar = false
        startMouse = NSEvent.mouseLocation
        if collapsed { mode = .none; return }
        let p = convert(event.locationInWindow, from: nil)
        edge = edgeAt(p)
        if edge == .none && event.clickCount == 2 { mode = .none; openFull(); return }   // даблклик — полный кадр
        mode = edge != .none ? .resize : .body
        if mode == .resize { startWidth = owner?.cardWidth ?? ThumbStyle.defaultWidth }
    }

    override func mouseDragged(with event: NSEvent) {
        if collapsed { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x, dy = now.y - startMouse.y
        switch mode {
        case .resize:
            var w = startWidth
            switch edge {
            case .left:  w = startWidth + (startMouse.x - now.x)
            case .right: w = startWidth + (now.x - startMouse.x)
            case .none:  break
            }
            manager?.updateWidthLive(w)
        case .body:
            guard !movedFar, hypot(dx, dy) > ThumbStyle.dragThreshold else { return }
            movedFar = true
            beginDragOut(with: event)
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if collapsed { mode = .none; return }          // свёрнутые карточки невидимы и неинтерактивны
        if mode == .resize { manager?.persistWidth() }
        mode = .none                                   // клик по телу ничего не копирует
    }

    // MARK: действия

    private func doCopy() { if let owner { manager?.copy(owner) } }

    private func openFull() {
        guard let screen = owner?.screen ?? NSScreen.main else { return }
        PinnedWindowController.show(image: image, on: screen)
    }

    /// Фидбэк копирования: галочка + «Скопировано» на стеклянной кнопке (единственный сигнал).
    func flashCopied() {
        copyButton.isHidden = false
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

/// Обёртка над панелью. Геометрия по варианту D (CardSizing).
final class ThumbnailWindow {

    let image: CGImage
    let screen: NSScreen
    private(set) var cardWidth: CGFloat
    private(set) var cardHeight: CGFloat = 0
    private let panel: ThumbnailPanel
    private let view: ThumbnailView
    private let animator: FrameAnimator

    var cardSize: NSSize { NSSize(width: cardWidth, height: cardHeight) }

    init(image: CGImage, screen: NSScreen, manager: ThumbnailManager, width: CGFloat, screenHeight: CGFloat) {
        self.image = image
        self.screen = screen
        self.cardWidth = width

        view = ThumbnailView(image: image)
        panel = ThumbnailPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: width),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        animator = FrameAnimator(hostView: view)

        view.owner = self
        view.manager = manager
        applyWidth(width, screenHeight: screenHeight)
    }

    func applyWidth(_ w: CGFloat, screenHeight: CGFloat) {
        cardWidth = w
        let layout = CardSizing.layout(imageW: image.width, imageH: image.height,
                                       width: cardWidth, screenHeight: screenHeight)
        cardHeight = layout.height
        let display = image.cropping(to: layout.cropRect) ?? image
        view.setDisplay(image: display, cropped: layout.cropped, edge: layout.cropEdge)
        panel.setContentSize(cardSize)
        view.layoutCard(width: cardWidth, height: cardHeight)
        panel.invalidateShadow()
    }

    func setCollapsed(_ b: Bool) { view.collapsed = b }
    func flashCopied() { view.flashCopied() }

    // MARK: анимация (CADisplayLink + кривые с оседанием)

    private func animate(toFrame target: NSRect, toAlpha targetAlpha: CGFloat,
                         duration: Double, delay: Double,
                         easing: @escaping (CGFloat) -> CGFloat = easeOutCubic,
                         completion: (() -> Void)? = nil) {
        let startFrame = panel.frame
        let startAlpha = panel.alphaValue
        animator.run(duration: duration, delay: delay, easing: easing, onFrame: { [weak self] e in
            guard let self else { return }
            let fr = NSRect(x: startFrame.minX + (target.minX - startFrame.minX) * e,
                            y: startFrame.minY + (target.minY - startFrame.minY) * e,
                            width: startFrame.width + (target.width - startFrame.width) * e,
                            height: startFrame.height + (target.height - startFrame.height) * e)
            self.panel.setFrame(fr, display: true)
            self.panel.alphaValue = max(0, min(1, startAlpha + (targetAlpha - startAlpha) * e))
        }, onDone: completion)
    }

    /// Мгновенно поставить карточку на место (alpha 1).
    func placeInstant(origin: NSPoint) {
        animator.cancel()
        panel.setFrame(NSRect(origin: origin, size: cardSize), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    /// Влёт новой карточки: scale (0.92 → 1) + fade, с лёгким оседанием.
    func appear(at origin: NSPoint) {
        animator.cancel()
        let final = NSRect(origin: origin, size: cardSize)
        let startSize = NSSize(width: cardSize.width * 0.92, height: cardSize.height * 0.92)
        let startOrigin = NSPoint(x: final.midX - startSize.width / 2, y: final.midY - startSize.height / 2)
        panel.setFrame(NSRect(origin: startOrigin, size: startSize), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        animate(toFrame: final, toAlpha: 1, duration: 0.32, delay: 0, easing: easeOutBack)
    }

    /// Свернуть: растворить карточку в точку хаба (уменьшение + затухание).
    func dissolve(toHubCenter c: NSPoint, duration: Double, delay: Double) {
        let tiny = NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
        animate(toFrame: tiny, toAlpha: 0, duration: duration, delay: delay, easing: easeInOutCubic) { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    /// Развернуть: появиться из точки хаба на своё место с оседанием.
    func emerge(fromHubCenter c: NSPoint, toOrigin o: NSPoint, duration: Double, delay: Double) {
        animator.cancel()
        panel.setFrame(NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        animate(toFrame: NSRect(origin: o, size: cardSize), toAlpha: 1, duration: duration, delay: delay, easing: easeOutBack)
    }

    func orderFront() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func close() { animator.cancel(); panel.orderOut(nil) }
}
