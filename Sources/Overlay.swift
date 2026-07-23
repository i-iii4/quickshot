import AppKit
import CoreGraphics
import OSLog

/// Безрамочная selection-панель. Frozen-фон и selection chrome
/// живут в разных окнах, чтобы исключённый из capture интерфейс
/// QuickShot оставался виден между ними. Окна становятся key только
/// после готовности frozen pixels и фактической активации QuickShot.
final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // AppKit «подтягивает» окно так, чтобы титул остался на экране; для borderless-оверлея на
    // дисплее с отрицательным origin (монитор слева) это уносит окно на главный экран. Оверлей
    // обязан точно лежать на своём экране — возвращаем рамку без правок.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class BackdropView: NSView {
    init(image: CGImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Хром выделения поверх уже зафиксированного кадра. До drag он рисует только кастомный курсор.
/// После начала выделения появляется лёгкая внутренняя заливка выбранной области
/// и рамка; внешний экран не затемняется.
final class SelectionView: NSView {

    var onComplete: ((NSRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    var onPointerActivity: (() -> Void)?
    weak var screenRef: NSScreen?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var cursorTracking: NSTrackingArea?
    private let crosshair = SelectionView.makeCrosshair()
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
        let innerOverlayAlpha: CGFloat
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
        static let innerOverlayAlpha: CGFloat = 0.10
        static let innerOverlayColor = NSColor.white.withAlphaComponent(innerOverlayAlpha)

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
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(crosshair)
        crosshair.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // Nonactivating selector never becomes key. This lets its first click reach
    // the view directly on every display without changing source-app activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Системный курсор на всю сессию прячет один CursorLease. Здесь остаётся
    // только отслеживание позиции для кастомного векторного перекрестья.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = cursorTracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t); cursorTracking = t
    }

    override func mouseEntered(with event: NSEvent) { moveCrosshair(event) }
    override func mouseExited(with event: NSEvent) { crosshair.isHidden = true }
    override func mouseMoved(with event: NSEvent) { moveCrosshair(event) }

    private func moveCrosshair(_ event: NSEvent) {
        moveCrosshair(to: convert(event.locationInWindow, from: nil))
    }

    private func moveCrosshair(to p: NSPoint) {
        currentPoint = p
        onPointerActivity?()
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        let winRect = convert(rect, to: nil)
        let globalRect = win.convertToScreen(winRect)          // -> глобальные точки AppKit
        onComplete?(globalRect, screen)
    }

    func setInputLocked(_ locked: Bool) {
        inputLocked = locked
    }

    func hideCrosshair() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        crosshair.isHidden = true
        CATransaction.commit()
    }

#if TESTING
    static func debugMetrics() -> DebugMetrics {
        DebugMetrics(crosshairSize: Metrics.crosshairSize,
                     crosshairGap: Metrics.crosshairGap,
                     crosshairArm: Metrics.crosshairArm,
                     frameSeparator: Metrics.frameSeparator,
                     frameStartOffset: Metrics.frameStartOffset,
                     haloWidth: Metrics.haloWidth,
                     coreWidth: Metrics.coreWidth,
                     innerOverlayAlpha: Metrics.innerOverlayAlpha)
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
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)

        guard hasDrawableSelection else { return }

        Metrics.innerOverlayColor.setFill()
        currentRect.fill()

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

/// Создаёт и удерживает по одному frozen-оверлею на каждый экран. Статический
/// снимок и динамический selection chrome живут в разных слоях.
final class OverlayController {

    private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")

    private(set) var windows: [OverlayWindow] = []
    private var backdropWindows: [OverlayWindow] = []
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private let escapeHotKey = SessionEscapeHotKey()
    private var spaceObserver: Any?
    private var globalDragMonitor: Any?
    private let presentation = SelectionPresentationCoordinator()
    private var onComplete: ((NSRect, NSScreen) -> Void)?
    private var onCancel: (() -> Void)?
    private var selectionViews: [SelectionView] = []
    private weak var activeGlobalSelection: SelectionView?
    private var completedSelection = false
    private var isPresented = false
    private var isDismissed = false

    deinit {
        dismiss()
    }

    func beginFrozenSelection(screens: [NSScreen],
                              backdrops: [CGDirectDisplayID: CGImage],
                              pendingMouseDownAt: @escaping () -> NSPoint?,
                              onReady: @escaping () -> Void,
                              onComplete: @escaping (NSRect, NSScreen) -> Void,
                              onCancel: @escaping () -> Void) {
        begin(screens: screens,
              backdrops: backdrops,
              onReady: onReady,
              onComplete: onComplete,
              onCancel: onCancel,
              pendingMouseDownAt: pendingMouseDownAt)
    }

    private func begin(screens: [NSScreen],
                       backdrops: [CGDirectDisplayID: CGImage],
                       onReady: @escaping () -> Void,
                       onComplete: @escaping (NSRect, NSScreen) -> Void,
                       onCancel: @escaping () -> Void,
                       pendingMouseDownAt: @escaping () -> NSPoint?) {
        self.onComplete = onComplete
        self.onCancel = onCancel
        let sourceApplication = NSWorkspace.shared.frontmostApplication

        for screen in screens {
            let displayID = CGDirectDisplayID(
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
            guard let backdrop = backdrops[displayID] else {
                Self.log.error("overlay missing frozen backdrop display=\(displayID, privacy: .public)")
                continue
            }

            let bounds = NSRect(origin: .zero, size: screen.frame.size)

            let backdropView = BackdropView(image: backdrop)
            backdropView.frame = bounds
            backdropView.autoresizingMask = [.width, .height]

            let backdropWindow = makeWindow(for: screen,
                                            level: CaptureWindowLevels.backdrop,
                                            receivesPointer: false)
            backdropWindow.contentView = backdropView
            backdropWindow.displayIfNeeded()
            backdropWindows.append(backdropWindow)

            let chrome = SelectionView(frame: bounds)
            chrome.autoresizingMask = [.width, .height]
            chrome.screenRef = screen
            chrome.onComplete = { [weak self] rect, scr in self?.completeOnce(rect, scr) }
            chrome.onCancel = { [weak self] in self?.onCancel?() }
            chrome.onPointerActivity = { [weak self, weak chrome] in
                guard let chrome else { return }
                self?.activateCrosshair(chrome)
            }
            selectionViews.append(chrome)

            let chromeWindow = makeWindow(for: screen,
                                          level: CaptureWindowLevels.selectionChrome,
                                          receivesPointer: true)
            chromeWindow.contentView = chrome
            chromeWindow.displayIfNeeded()
            windows.append(chromeWindow)
        }

        for window in backdropWindows { window.orderFrontRegardless() }
        for window in windows { window.orderFrontRegardless() }
        windows.first?.makeKeyAndOrderFront(nil)
        Self.log.info("overlay begin screens=\(self.windows.count, privacy: .public) mode=frozen-activating")

        // Carbon owns Escape while QuickShot intentionally remains inactive. The NSEvent
        // monitors are fallback paths for environments that reject the Carbon registration.
        let escapeRegistered = escapeHotKey.register { [weak self] in self?.onCancel?() }
        if !escapeRegistered { Self.log.error("overlay escape hotkey registration failed") }
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.onCancel?(); return nil }
            return e
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.onCancel?() }
        }
        // Свайп между Spaces во время выделения — отменяем захват (иначе застреваешь: после свайпа
        // оверлей теряет key, локальный Esc-монитор до него не доходит, и выйти можно только сняв кадр).
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onCancel?()
        }

        presentation.begin(
            restoreActivation: Self.activationRestore(for: sourceApplication),
            onAcquired: { [weak self] in
                guard let self, !self.isDismissed else { return }
                Self.log.info("overlay cursor lease acquired")
                self.presentAfterOwnership(pendingMouseDownAt: pendingMouseDownAt(),
                                           onReady: onReady)
            },
            onFailure: { [weak self] failure in
                guard let self, !self.isDismissed else { return }
                switch failure {
                case .activationRejected:
                    Self.log.error("overlay activation rejected")
                case .activationTimedOut:
                    Self.log.error("overlay activation timed out")
                case .activationLost:
                    Self.log.error("overlay activation lost")
                case .cursorSuppressionFailed:
                    Self.log.error("overlay cursor suppression failed")
                }
                self.onCancel?()
            }
        )
    }

    private func makeWindow(for screen: NSScreen,
                            level: NSWindow.Level,
                            receivesPointer: Bool) -> OverlayWindow {
        // Do not pass `screen:` here: the content rect is already in global coordinates.
        let window = OverlayWindow(contentRect: screen.frame,
                                   styleMask: [.borderless],
                                   backing: .buffered,
                                   defer: false)
        window.setFrame(screen.frame, display: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.isReleasedWhenClosed = false
        window.level = level
        window.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = receivesPointer
        window.animationBehavior = .none
        window.alphaValue = 0
        WindowCaptureProtection.excludeFromScreenCapture(window)
        return window
    }

    private func presentAfterOwnership(pendingMouseDownAt: NSPoint?,
                                       onReady: () -> Void) {
        guard !isDismissed, !isPresented, presentation.ownsCursor else { return }
        isPresented = true
        windows.first?.makeKey()
        if let first = selectionViews.first {
            windows.first?.makeFirstResponder(first)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            for window in backdropWindows {
                window.alphaValue = 1
                window.displayIfNeeded()
            }
            for window in windows {
                window.ignoresMouseEvents = false
                window.alphaValue = 1
                window.displayIfNeeded()
            }
        }

        selectionView(containing: NSEvent.mouseLocation)?.moveCrosshair(atGlobalPoint: NSEvent.mouseLocation)
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]) {
                [weak self] event in self?.handleGlobalMouse(event)
            }
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            beginGlobalSelection(at: pendingMouseDownAt ?? NSEvent.mouseLocation)
            activeGlobalSelection?.updateSelection(atGlobalPoint: NSEvent.mouseLocation)
        } else {
            selectionView(containing: NSEvent.mouseLocation)?.moveCrosshair(atGlobalPoint: NSEvent.mouseLocation)
        }

        Self.log.info("overlay activation completed")
        onReady()
    }

    private static func activationRestore(for source: NSRunningApplication?) -> () -> Void {
        let quickShotPID = ProcessInfo.processInfo.processIdentifier
        return {
            guard let source,
                  !source.isTerminated,
                  source.processIdentifier != quickShotPID else { return }
            NSApp.yieldActivation(to: source)
            _ = source.activate(from: .current)
        }
    }

    private func selectionView(containing globalPoint: NSPoint) -> SelectionView? {
        selectionViews.first { $0.contains(globalPoint: globalPoint) }
    }

    private func activateCrosshair(_ active: SelectionView) {
        for selection in selectionViews where selection !== active {
            selection.hideCrosshair()
        }
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
        Self.log.info("overlay dismiss screens=\(self.windows.count, privacy: .public)")
        escapeHotKey.unregister()
        if let localEscapeMonitor {
            NSEvent.removeMonitor(localEscapeMonitor)
            self.localEscapeMonitor = nil
        }
        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
            self.globalEscapeMonitor = nil
        }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver); self.spaceObserver = nil }
        if let globalDragMonitor { NSEvent.removeMonitor(globalDragMonitor); self.globalDragMonitor = nil }
        let ownedCursor = presentation.ownsCursor
        let cursorRestored = presentation.finish { [self] in
            selectionViews.forEach { $0.hideCrosshair() }
            for window in windows + backdropWindows {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
        }
        if ownedCursor {
            if cursorRestored { Self.log.info("overlay cursor lease released") }
            else { Self.log.fault("overlay cursor lease restore failed") }
        }
        windows.removeAll()
        backdropWindows.removeAll()
        selectionViews.removeAll()
        activeGlobalSelection = nil
        completedSelection = false
        onComplete = nil
        onCancel = nil
    }
}
