import AppKit
import CoreGraphics
import OSLog

/// Безрамочная панель поверх всего. Она принимает мышь сразу; приложение активируем при старте
/// overlay, чтобы CoreGraphics стабильно скрывал системную стрелку, пока мы рисуем свой
/// курсор-слой.
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // AppKit «подтягивает» окно так, чтобы титул остался на экране; для borderless-оверлея на
    // дисплее с отрицательным origin (монитор слева) это уносит окно на главный экран. Оверлей
    // обязан точно лежать на своём экране — возвращаем рамку без правок.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Статический бэкдроп — замороженный кадр в слое. Выставляется ОДИН раз, не перерисовывается:
/// GPU композитит его пиксель-в-пиксель, поэтому он не «доезжает» и не дрожит. Мышь пропускаем
/// хрому, лежащему сверху.
private final class BackdropView: NSView {
    init(image: CGImage? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.contents = image
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setImage(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }
}

/// Хром выделения поверх бэкдропа: затемнение + рамка. Лёгкая перерисовка (без изображения),
/// поэтому перетаскивание рамки не гоняет полноэкранную картинку. Слоёвый и непрозрачный частично:
/// `.copy`-clear пробивает прозрачную «дыру» в затемнении — сквозь неё бэкдроп виден на полном
/// контрасте.
final class SelectionView: NSView {

    var onComplete: ((NSRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    weak var screenRef: NSScreen?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var cursorTracking: NSTrackingArea?
    private let crosshair = SelectionView.makeCrosshair()
    private static let invisibleSystemCursor = SelectionView.makeInvisibleSystemCursor()
    private var inputLocked = false
    private var finished = false
    private var hasDrawableSelection: Bool {
        currentRect.width >= 2 && currentRect.height >= 2 && isFinite(currentRect)
    }

#if TESTING
    struct DebugMetrics {
        let crosshairSize: CGFloat
        let crosshairGap: CGFloat
        let crosshairArm: CGFloat
        let frameSeparator: CGFloat
        let frameStartOffset: CGFloat
        let haloWidth: CGFloat
        let coreWidth: CGFloat
    }

    struct DebugCrosshairLayer {
        let lineWidth: CGFloat
        let lineCap: CAShapeLayerLineCap
        let bounds: CGRect
    }

    struct DebugSnapshot {
        let currentRect: NSRect
        let crosshairPosition: CGPoint
        let crosshairBounds: CGRect
        let crosshairHidden: Bool
        let crosshairLayers: [DebugCrosshairLayer]
        let outlinePoints: [NSPoint]
    }
#endif

    private enum Metrics {
        static let crosshairSize: CGFloat = 44
        static let crosshairGap: CGFloat = 4
        static let crosshairArm: CGFloat = 9
        // Centerline distance between the cursor arm endpoint and the frame start.
        // With round caps and a 3.5pt halo this leaves a small visible separator.
        static let frameSeparator: CGFloat = 5
        static let haloWidth: CGFloat = 3.5
        static let coreWidth: CGFloat = 1.5
        static let haloColor = NSColor.black.withAlphaComponent(0.6)
        static let coreColor = NSColor.white

        static var frameStartOffset: CGFloat {
            crosshairGap + crosshairArm + frameSeparator
        }
    }

    private enum ActiveCorner {
        case bottomLeft
        case bottomRight
        case topRight
        case topLeft
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true                 // своя прозрачная backing-store для .copy-дыры над бэкдропом
        layer?.addSublayer(crosshair)
        crosshair.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // Без этого первый клик по оверлею экрана, который не key (на втором мониторе оверлеи кроме
    // главного — не key), тратится на активацию окна и не доходит до вью. С true mouseDown
    // приходит сразу — выделение работает на любом экране независимо от key-статуса.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Системный курсор прячет OverlayController; перекрестье рисуем сами слоем и двигаем по
    // событиям мыши. Так per-move сброс cursor rect активным приложением нас не касается.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = cursorTracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t); cursorTracking = t
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: Self.invisibleSystemCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.invisibleSystemCursor.set()
        moveCrosshair(event)
    }

    override func mouseEntered(with event: NSEvent) { moveCrosshair(event) }
    override func mouseExited(with event: NSEvent) { crosshair.isHidden = true }
    override func mouseMoved(with event: NSEvent) { moveCrosshair(event) }

    private func moveCrosshair(_ event: NSEvent) {
        moveCrosshair(to: convert(event.locationInWindow, from: nil))
    }

    private func moveCrosshair(to p: NSPoint) {
        currentPoint = p
        Self.invisibleSystemCursor.set()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        crosshair.position = p
        crosshair.isHidden = false
        CATransaction.commit()
        needsDisplay = true
    }

    /// Перекрестье: белый «+» с тёмным ореолом (читается на любом фоне), векторно — резко на Retina.
    /// Во время drag форма и размер не меняются: рамка сама делает разрыв под курсором.
    private static func makeCrosshair() -> CALayer {
        let s = Metrics.crosshairSize
        let c = s / 2
        let gap = Metrics.crosshairGap
        let arm = Metrics.crosshairArm
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c - gap - arm, y: c)); path.addLine(to: CGPoint(x: c - gap, y: c))
        path.move(to: CGPoint(x: c + gap, y: c));       path.addLine(to: CGPoint(x: c + gap + arm, y: c))
        path.move(to: CGPoint(x: c, y: c - gap - arm)); path.addLine(to: CGPoint(x: c, y: c - gap))
        path.move(to: CGPoint(x: c, y: c + gap));       path.addLine(to: CGPoint(x: c, y: c + gap + arm))
        func shape(_ color: CGColor, _ w: CGFloat) -> CAShapeLayer {
            let l = CAShapeLayer()
            l.frame = CGRect(x: 0, y: 0, width: s, height: s)
            l.path = path; l.strokeColor = color; l.fillColor = nil; l.lineWidth = w; l.lineCap = .round
            return l
        }
        let container = CALayer()
        container.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        container.addSublayer(shape(Metrics.haloColor.cgColor, Metrics.haloWidth))
        container.addSublayer(shape(Metrics.coreColor.cgColor, Metrics.coreWidth))
        return container
    }

    private static func makeInvisibleSystemCursor() -> NSCursor {
        let size = 16
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: size,
                                   pixelsHigh: size,
                                   bitsPerSample: 8,
                                   samplesPerPixel: 4,
                                   hasAlpha: true,
                                   isPlanar: false,
                                   colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0,
                                   bitsPerPixel: 0)!
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return NSCursor(image: image, hotSpot: NSPoint(x: size / 2, y: size / 2))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.invalidateCursorRects(for: self)
        let scale = window?.backingScaleFactor ?? 2
        crosshair.contentsScale = scale
        crosshair.sublayers?.forEach { $0.contentsScale = scale }
        if let win = window {
            let vp = convert(win.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if bounds.contains(vp) { moveCrosshair(to: vp) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !inputLocked else { return }
        window?.makeKey()
        beginSelection(atLocalPoint: convert(event.locationInWindow, from: nil))
    }

    private func beginSelection(atLocalPoint p: NSPoint) {
        guard !inputLocked else { return }
        window?.makeKey()
        finished = false
        moveCrosshair(to: p)
        startPoint = p
        currentPoint = p
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !inputLocked else { return }
        updateSelection(toLocalPoint: convert(event.locationInWindow, from: nil))
    }

    private func updateSelection(toLocalPoint p: NSPoint) {
        guard !inputLocked else { return }
        guard let s = startPoint else { return }
        currentPoint = p
        currentRect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                             width: abs(p.x - s.x), height: abs(p.y - s.y))
        moveCrosshair(to: p)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !inputLocked else { return }
        updateSelection(toLocalPoint: convert(event.locationInWindow, from: nil))
        completeSelection()
    }

    func contains(globalPoint: NSPoint) -> Bool {
        guard let win = window else { return false }
        return bounds.contains(convert(win.convertPoint(fromScreen: globalPoint), from: nil))
    }

    @discardableResult
    func beginSelection(atGlobalPoint globalPoint: NSPoint) -> Bool {
        guard !inputLocked else { return false }
        guard let win = window else { return false }
        let p = convert(win.convertPoint(fromScreen: globalPoint), from: nil)
        beginSelection(atLocalPoint: p)
        return true
    }

    @discardableResult
    func updateSelection(atGlobalPoint globalPoint: NSPoint) -> Bool {
        guard !inputLocked else { return false }
        guard let win = window else { return false }
        let p = convert(win.convertPoint(fromScreen: globalPoint), from: nil)
        if startPoint == nil { beginSelection(atLocalPoint: p) }
        else { updateSelection(toLocalPoint: p) }
        return true
    }

    func finishSelection(atGlobalPoint globalPoint: NSPoint) {
        guard !inputLocked else { return }
        _ = updateSelection(atGlobalPoint: globalPoint)
        completeSelection()
    }

    func moveCrosshair(atGlobalPoint globalPoint: NSPoint) {
        guard let win = window else { return }
        let p = convert(win.convertPoint(fromScreen: globalPoint), from: nil)
        if bounds.contains(p) { moveCrosshair(to: p) }
    }

    private func completeSelection() {
        guard !finished else { return }
        finished = true
        inputLocked = true
        crosshair.isHidden = true
        guard let win = window, let screen = screenRef else { onCancel?(); return }
        let rect = currentRect
        // Слишком маленькое выделение (или простой клик) трактуем как отмену.
        guard rect.width >= 3, rect.height >= 3 else { onCancel?(); return }
        let winRect = convert(rect, to: nil)
        let globalRect = win.convertToScreen(winRect)          // -> глобальные точки AppKit
        onComplete?(globalRect, screen)
    }

    func setInputLocked(_ locked: Bool) {
        inputLocked = locked
    }

#if TESTING
    static func debugMetrics() -> DebugMetrics {
        DebugMetrics(crosshairSize: Metrics.crosshairSize,
                     crosshairGap: Metrics.crosshairGap,
                     crosshairArm: Metrics.crosshairArm,
                     frameSeparator: Metrics.frameSeparator,
                     frameStartOffset: Metrics.frameStartOffset,
                     haloWidth: Metrics.haloWidth,
                     coreWidth: Metrics.coreWidth)
    }

    func debugBeginAndDrag(from start: NSPoint, to current: NSPoint) {
        beginSelection(atLocalPoint: start)
        updateSelection(toLocalPoint: current)
    }

    func debugMoveCrosshair(to point: NSPoint) {
        moveCrosshair(to: point)
    }

    func debugSnapshot() -> DebugSnapshot {
        let layers = (crosshair.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.map {
            DebugCrosshairLayer(lineWidth: $0.lineWidth,
                                lineCap: $0.lineCap,
                                bounds: $0.bounds)
        }
        let activeCorner = self.activeCorner(in: currentRect)
        let outline = selectionOutlinePath(currentRect, activeCorner: activeCorner)
        return DebugSnapshot(currentRect: currentRect,
                             crosshairPosition: crosshair.position,
                             crosshairBounds: crosshair.bounds,
                             crosshairHidden: crosshair.isHidden,
                             crosshairLayers: layers,
                             outlinePoints: Self.debugPoints(in: outline))
    }

    private static func debugPoints(in path: NSBezierPath) -> [NSPoint] {
        var points: [NSPoint] = []
        var buffer = Array(repeating: NSPoint.zero, count: 3)
        for i in 0..<path.elementCount {
            let element = path.element(at: i, associatedPoints: &buffer)
            switch element {
            case .moveTo, .lineTo:
                points.append(buffer[0])
            case .curveTo, .cubicCurveTo:
                points.append(buffer[0])
                points.append(buffer[1])
                points.append(buffer[2])
            case .quadraticCurveTo:
                points.append(buffer[0])
                points.append(buffer[1])
            case .closePath:
                break
            @unknown default:
                break
            }
        }
        return points
    }
#endif

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }                 // Escape
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.30).setFill()
        bounds.fill()

        guard hasDrawableSelection else { return }

        // Прозрачная «дыра» на месте выделения: сквозь неё бэкдроп виден без затемнения.
        NSColor.clear.set()
        currentRect.fill(using: .copy)

        let activeCorner = self.activeCorner(in: currentRect)
        strokeSelectionOutline(currentRect, activeCorner: activeCorner)
    }

    private func activeCorner(in rect: NSRect) -> NSPoint? {
        guard let startPoint, let currentPoint else { return nil }
        return NSPoint(
            x: currentPoint.x >= startPoint.x ? rect.maxX : rect.minX,
            y: currentPoint.y >= startPoint.y ? rect.maxY : rect.minY)
    }

    private func strokeSelectionOutline(_ rect: NSRect, activeCorner: NSPoint?) {
        let outline = selectionOutlinePath(rect, activeCorner: activeCorner)
        stroke(outline, color: Metrics.haloColor, width: Metrics.haloWidth)
        stroke(outline, color: Metrics.coreColor, width: Metrics.coreWidth)
    }

    private func selectionOutlinePath(_ rect: NSRect, activeCorner: NSPoint?) -> NSBezierPath {
        guard isFinite(rect), rect.width > 0, rect.height > 0 else { return NSBezierPath() }

        let bl = NSPoint(x: rect.minX, y: rect.minY)
        let br = NSPoint(x: rect.maxX, y: rect.minY)
        let tr = NSPoint(x: rect.maxX, y: rect.maxY)
        let tl = NSPoint(x: rect.minX, y: rect.maxY)
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        guard let activeCorner, let corner = activeCornerKind(activeCorner, in: rect) else {
            path.move(to: bl)
            path.line(to: br)
            path.line(to: tr)
            path.line(to: tl)
            path.close()
            return path
        }

        let xBreak = min(Metrics.frameStartOffset, rect.width)
        let yBreak = min(Metrics.frameStartOffset, rect.height)

        switch corner {
        case .bottomLeft:
            path.move(to: NSPoint(x: rect.minX + xBreak, y: rect.minY))
            path.line(to: br)
            path.line(to: tr)
            path.line(to: tl)
            path.line(to: NSPoint(x: rect.minX, y: rect.minY + yBreak))
        case .bottomRight:
            path.move(to: NSPoint(x: rect.maxX, y: rect.minY + yBreak))
            path.line(to: tr)
            path.line(to: tl)
            path.line(to: bl)
            path.line(to: NSPoint(x: rect.maxX - xBreak, y: rect.minY))
        case .topRight:
            path.move(to: NSPoint(x: rect.maxX - xBreak, y: rect.maxY))
            path.line(to: tl)
            path.line(to: bl)
            path.line(to: br)
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - yBreak))
        case .topLeft:
            path.move(to: NSPoint(x: rect.minX, y: rect.maxY - yBreak))
            path.line(to: bl)
            path.line(to: br)
            path.line(to: tr)
            path.line(to: NSPoint(x: rect.minX + xBreak, y: rect.maxY))
        }

        return path
    }

    private func activeCornerKind(_ point: NSPoint, in rect: NSRect) -> ActiveCorner? {
        guard isFinite(point), isFinite(rect) else { return nil }
        let isRight = abs(point.x - rect.maxX) <= abs(point.x - rect.minX)
        let isTop = abs(point.y - rect.maxY) <= abs(point.y - rect.minY)
        switch (isRight, isTop) {
        case (false, false): return .bottomLeft
        case (true, false): return .bottomRight
        case (true, true): return .topRight
        case (false, true): return .topLeft
        }
    }

    private func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
        color.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    private func isFinite(_ point: NSPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private func isFinite(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
    }
}

/// Создаёт и удерживает по одному оверлею на КАЖДЫЙ экран (origin и backingScaleFactor у дисплеев
/// разные — одно окно на всё нельзя). Каждый оверлей = бэкдроп-слой (заморозка) + хром выделения.
final class OverlayController {

    private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")

    private(set) var windows: [OverlayWindow] = []
    private var escMonitor: Any?
    private var spaceObserver: Any?
    private var globalDragMonitor: Any?
    private var cursorSuppressionActive = false
    private var cursorHideDepth = 0
    private var deferredCursorHide: DispatchWorkItem?
    private var onComplete: ((NSRect, NSScreen) -> Void)?
    private var onCancel: (() -> Void)?
    private var selectionViews: [SelectionView] = []
    private var backdropViews: [CGDirectDisplayID: BackdropView] = [:]
    private weak var activeGlobalSelection: SelectionView?
    private var completedSelection = false
    private var isDismissed = false

    deinit {
        dismiss()
    }

    /// Показать live selection chrome немедленно. Frozen backdrop будет установлен позже через
    /// `installFrozenBackdrops`: рамка и курсор уже работают, а картинка под ними догружается.
    func beginLiveSelection(screens: [NSScreen],
                            initialMouseDownAt: NSPoint?,
                            onComplete: @escaping (NSRect, NSScreen) -> Void,
                            onCancel: @escaping () -> Void) {
        begin(screens: screens,
              backdrops: [:],
              onComplete: onComplete,
              onCancel: onCancel,
              pendingMouseDownAt: initialMouseDownAt)
    }

    /// Показать selection overlay уже поверх готовых frozen snapshots. Это Mio-style
    /// путь: сначала свежая заморозка, затем интерактивная рамка и кастомный курсор.
    func beginFrozenSelection(screens: [NSScreen],
                              backdrops: [CGDirectDisplayID: CGImage],
                              initialMouseDownAt: NSPoint?,
                              onComplete: @escaping (NSRect, NSScreen) -> Void,
                              onCancel: @escaping () -> Void) {
        begin(screens: screens,
              backdrops: backdrops,
              onComplete: onComplete,
              onCancel: onCancel,
              pendingMouseDownAt: initialMouseDownAt)
    }

    private func begin(screens: [NSScreen],
                       backdrops: [CGDirectDisplayID: CGImage],
                       onComplete: @escaping (NSRect, NSScreen) -> Void,
                       onCancel: @escaping () -> Void,
                       pendingMouseDownAt: NSPoint?) {
        self.onComplete = onComplete
        self.onCancel = onCancel

        for screen in screens {
            let did = CGDirectDisplayID(
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)

            // БЕЗ параметра screen: — иначе contentRect трактуется относительно origin экрана, и на
            // дисплее с отрицательным origin смещение применяется дважды. contentRect глобальный.
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.isFloatingPanel = true
            w.hidesOnDeactivate = false
            w.becomesKeyOnlyIfNeeded = false
            w.isReleasedWhenClosed = false
            WindowCaptureProtection.excludeFromScreenCapture(w)
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))   // выше строки меню
            // Без режима all-spaces: оверлей выделения привязан к своему Space (модальный момент),
            // а не таскается за свайпом, показывая протухший замороженный кадр. Свайп Spaces —
            // отменяем захват (наблюдатель ниже).
            w.collectionBehavior = [.fullScreenAuxiliary, .stationary]
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.animationBehavior = .none                  // без влёта/fade — заморозка появляется разом

            let bounds = NSRect(origin: .zero, size: screen.frame.size)
            let backdropView = BackdropView(image: backdrops[did])
            backdropView.frame = bounds
            backdropView.autoresizingMask = [.width, .height]
            backdropViews[did] = backdropView

            let chrome = SelectionView(frame: bounds)
            chrome.autoresizingMask = [.width, .height]
            chrome.screenRef = screen
            chrome.onComplete = { [weak self] rect, scr in self?.completeOnce(rect, scr) }
            chrome.onCancel = { [weak self] in self?.onCancel?() }
            selectionViews.append(chrome)

            let container = NSView(frame: bounds)
            container.addSubview(backdropView)           // статичный фон снизу
            container.addSubview(chrome)                 // лёгкий хром сверху
            w.contentView = container
            windows.append(w)
        }

        for w in windows { w.orderFrontRegardless() }
        Self.log.info("overlay begin windows=\(self.windows.count, privacy: .public) frozenBackdrops=\(backdrops.count, privacy: .public)")
        hideSystemCursor()
        selectionView(containing: NSEvent.mouseLocation)?.moveCrosshair(atGlobalPoint: NSEvent.mouseLocation)

        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]) {
            [weak self] e in self?.handleGlobalMouse(e)
        }
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            beginGlobalSelection(at: pendingMouseDownAt ?? NSEvent.mouseLocation)
            activeGlobalSelection?.updateSelection(atGlobalPoint: NSEvent.mouseLocation)
        } else {
            selectionView(containing: NSEvent.mouseLocation)?.moveCrosshair(atGlobalPoint: NSEvent.mouseLocation)
        }

        // Escape отменяет независимо от того, какое окно key (мульти-монитор).
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.onCancel?(); return nil }
            return e
        }
        // Свайп между Spaces во время выделения — отменяем захват (иначе застреваешь: после свайпа
        // оверлей теряет key, локальный Esc-монитор до него не доходит, и выйти можно только сняв кадр).
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onCancel?()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.windows.isEmpty else { return }
            self.windows.first?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Self.log.info("overlay activation completed")
        }
    }

    func installFrozenBackdrops(_ backdrops: [CGDirectDisplayID: CGImage]) {
        for (did, image) in backdrops {
            backdropViews[did]?.setImage(image)
        }
    }

    private func hideSystemCursor() {
        guard !cursorSuppressionActive else { return }
        cursorSuppressionActive = true
        hideSystemCursorOnce()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.cursorSuppressionActive else { return }
            self.hideSystemCursorOnce()
        }
        deferredCursorHide = work
        DispatchQueue.main.async(execute: work)
    }

    private func showSystemCursor() {
        deferredCursorHide?.cancel()
        deferredCursorHide = nil
        let restored = cursorHideDepth
        while cursorHideDepth > 0 {
            let result = CGDisplayShowCursor(CGMainDisplayID())
            if result != .success {
                NSLog("QuickShot: CGDisplayShowCursor failed: \(result.rawValue)")
            }
            cursorHideDepth -= 1
        }
        if restored > 0 {
            Self.log.info("overlay cursor restored count=\(restored, privacy: .public)")
        }
        cursorSuppressionActive = false
    }

    private func hideSystemCursorOnce() {
        let result = CGDisplayHideCursor(CGMainDisplayID())
        if result == .success {
            cursorHideDepth += 1
            Self.log.info("overlay cursor hidden depth=\(self.cursorHideDepth, privacy: .public)")
        } else {
            NSLog("QuickShot: CGDisplayHideCursor failed: \(result.rawValue)")
            Self.log.error("overlay cursor hide failed code=\(result.rawValue, privacy: .public)")
        }
    }

    private func selectionView(containing globalPoint: NSPoint) -> SelectionView? {
        selectionViews.first { $0.contains(globalPoint: globalPoint) }
    }

    private func beginGlobalSelection(at globalPoint: NSPoint) {
        guard !completedSelection else { return }
        guard activeGlobalSelection == nil,
              let selection = selectionView(containing: globalPoint) else { return }
        activeGlobalSelection = selection
        selection.beginSelection(atGlobalPoint: globalPoint)
    }

    private func handleGlobalMouse(_ event: NSEvent) {
        guard !completedSelection else { return }
        let point = NSEvent.mouseLocation
        switch event.type {
        case .mouseMoved:
            if activeGlobalSelection == nil {
                selectionView(containing: point)?.moveCrosshair(atGlobalPoint: point)
            }
        case .leftMouseDown:
            beginGlobalSelection(at: point)
        case .leftMouseDragged:
            if activeGlobalSelection == nil { beginGlobalSelection(at: point) }
            activeGlobalSelection?.updateSelection(atGlobalPoint: point)
        case .leftMouseUp:
            activeGlobalSelection?.finishSelection(atGlobalPoint: point)
            activeGlobalSelection = nil
        default:
            break
        }
    }

    private func completeOnce(_ rect: NSRect, _ screen: NSScreen) {
        guard !completedSelection else { return }
        completedSelection = true
        selectionViews.forEach { $0.setInputLocked(true) }
        onComplete?(rect, screen)
    }

    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        Self.log.info("overlay dismiss windows=\(self.windows.count, privacy: .public)")
        showSystemCursor()
        if let escMonitor { NSEvent.removeMonitor(escMonitor); self.escMonitor = nil }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver); self.spaceObserver = nil }
        if let globalDragMonitor { NSEvent.removeMonitor(globalDragMonitor); self.globalDragMonitor = nil }
        for w in windows {
            w.orderOut(nil)
            w.contentView = nil
            w.close()
        }
        windows.removeAll()
        selectionViews.removeAll()
        backdropViews.removeAll()
        activeGlobalSelection = nil
        completedSelection = false
        onComplete = nil
        onCancel = nil
    }
}
