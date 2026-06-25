import AppKit

/// Безрамочное окно поверх всего. Borderless по умолчанию возвращает canBecomeKey == false,
/// из-за чего до него не доходят клавиши (в т.ч. Escape) — переопределяем.
final class OverlayWindow: NSWindow {
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
    init(image: CGImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    private var currentRect: NSRect = .zero
    private var cursorTracking: NSTrackingArea?
    private let crosshair = SelectionView.makeCrosshair()

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
    // событиям мыши. Так пер-move сброс курсора window server'ом нас не касается (прятать нечего),
    // и зависимости от cursor-rect/cursorUpdate/«кто последний set()» нет.
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
        let p = convert(event.locationInWindow, from: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)   // следовать мгновенно, без анимации
        crosshair.position = p
        crosshair.isHidden = false
        CATransaction.commit()
    }

    /// Перекрестье: белый «+» с тёмным ореолом (читается на любом фоне), векторно — резко на Retina.
    private static func makeCrosshair() -> CALayer {
        let s: CGFloat = 44, c = s / 2, gap: CGFloat = 4, arm: CGFloat = 9
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
        container.addSublayer(shape(NSColor.black.withAlphaComponent(0.6).cgColor, 3.5))   // ореол
        container.addSublayer(shape(NSColor.white.cgColor, 1.5))                           // ядро
        return container
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        let scale = window?.backingScaleFactor ?? 2
        crosshair.contentsScale = scale
        crosshair.sublayers?.forEach { $0.contentsScale = scale }
        if let win = window {                                   // показать перекрестье сразу, если курсор уже над этим экраном
            let vp = convert(win.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if bounds.contains(vp) { crosshair.position = vp; crosshair.isHidden = false }
        }
    }

    override func mouseDown(with event: NSEvent) {
        moveCrosshair(event)
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        moveCrosshair(event)
        guard let s = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(x: min(s.x, p.x), y: min(s.y, p.y),
                             width: abs(p.x - s.x), height: abs(p.y - s.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let win = window, let screen = screenRef else { onCancel?(); return }
        let rect = currentRect
        // Слишком маленькое выделение (или простой клик) трактуем как отмену.
        guard rect.width >= 3, rect.height >= 3 else { onCancel?(); return }
        let winRect = convert(rect, to: nil)
        let globalRect = win.convertToScreen(winRect)          // -> глобальные точки AppKit
        onComplete?(globalRect, screen)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }                 // Escape
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.30).setFill()
        bounds.fill()

        guard currentRect != .zero else { return }

        // Прозрачная «дыра» на месте выделения: сквозь неё бэкдроп виден без затемнения.
        NSColor.clear.set()
        currentRect.fill(using: .copy)

        // Двойной контур: тёмный снаружи + белый внутри — читается и на светлом, и на тёмном.
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let outer = NSBezierPath(rect: currentRect.insetBy(dx: -0.5, dy: -0.5))
        outer.lineWidth = 1
        outer.stroke()

        NSColor.white.withAlphaComponent(0.95).setStroke()
        let inner = NSBezierPath(rect: currentRect.insetBy(dx: 0.5, dy: 0.5))
        inner.lineWidth = 1
        inner.stroke()
    }
}

/// Создаёт и удерживает по одному оверлею на КАЖДЫЙ экран (origin и backingScaleFactor у дисплеев
/// разные — одно окно на всё нельзя). Каждый оверлей = бэкдроп-слой (заморозка) + хром выделения.
final class OverlayController {

    private(set) var windows: [OverlayWindow] = []
    private var escMonitor: Any?
    private var spaceObserver: Any?
    private var cursorHidden = false
    private var onComplete: ((NSRect, NSScreen) -> Void)?
    private var onCancel: (() -> Void)?

    /// `backdrops` — замороженный кадр на дисплей (по displayID). Оверлей создаём только для
    /// экранов, у которых снимок есть.
    func begin(backdrops: [CGDirectDisplayID: CGImage],
               onComplete: @escaping (NSRect, NSScreen) -> Void,
               onCancel: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onCancel = onCancel

        for screen in NSScreen.screens {
            let did = CGDirectDisplayID(
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
            guard let backdrop = backdrops[did] else { continue }

            // БЕЗ параметра screen: — иначе contentRect трактуется относительно origin экрана, и на
            // дисплее с отрицательным origin смещение применяется дважды. contentRect глобальный.
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))   // выше строки меню
            // БЕЗ .canJoinAllSpaces: оверлей выделения привязан к своему Space (модальный момент),
            // а не таскается за свайпом, показывая протухший замороженный кадр. Свайп Spaces —
            // отменяем захват (наблюдатель ниже).
            w.collectionBehavior = [.fullScreenAuxiliary, .stationary]
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true
            w.animationBehavior = .none                  // без влёта/fade — заморозка появляется разом

            let bounds = NSRect(origin: .zero, size: screen.frame.size)
            let backdropView = BackdropView(image: backdrop)
            backdropView.frame = bounds
            backdropView.autoresizingMask = [.width, .height]

            let chrome = SelectionView(frame: bounds)
            chrome.autoresizingMask = [.width, .height]
            chrome.screenRef = screen
            chrome.onComplete = { [weak self] rect, scr in self?.onComplete?(rect, scr) }
            chrome.onCancel = { [weak self] in self?.onCancel?() }

            let container = NSView(frame: bounds)
            container.addSubview(backdropView)           // статичный фон снизу
            container.addSubview(chrome)                 // лёгкий хром сверху
            w.contentView = container
            w.displayIfNeeded()                          // отрисовать содержимое ДО показа — атомарно
            windows.append(w)
        }

        for w in windows { w.orderFrontRegardless() }
        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }   // системный курсор прячем — рисуем своё перекрестье

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
    }

    func dismiss() {
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        if let escMonitor { NSEvent.removeMonitor(escMonitor); self.escMonitor = nil }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver); self.spaceObserver = nil }
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        onComplete = nil
        onCancel = nil
    }

    deinit {
        if cursorHidden { NSCursor.unhide() }                      // защита: не оставить курсор скрытым
        if let escMonitor { NSEvent.removeMonitor(escMonitor) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }
}
