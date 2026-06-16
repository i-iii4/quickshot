import AppKit

/// Безрамочное прозрачное окно поверх всего. Borderless-окно по умолчанию возвращает
/// canBecomeKey == false, из-за чего до него не доходят клавиши (в т.ч. Escape) —
/// поэтому переопределяем.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // AppKit по умолчанию «подтягивает» окно так, чтобы титул остался на экране, и для
    // borderless-оверлея на дисплее с отрицательным origin (монитор слева) это уносит окно
    // обратно на главный экран — второй монитор остаётся без оверлея, скриншоты там не делаются.
    // Оверлей обязан точно лежать на своём экране — возвращаем рамку без правок.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Вид, рисующий затемнение и «вырезанную» рамку выделения, и обрабатывающий
/// перетаскивание мышью.
final class SelectionView: NSView {

    var onComplete: ((NSRect, NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    weak var screenRef: NSScreen?

    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }

    // Без этого первый клик по оверлею экрана, который не является key-окном (на втором мониторе
    // оверлеи всех экранов кроме главного — не key), тратится на активацию окна и НЕ доходит до
    // вью: startPoint не ставится, выделение не начинается — «ничего не происходит». С true
    // mouseDown приходит сразу, выделение работает на любом экране независимо от key-статуса.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
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

        // Пробиваем «дыру» в затемнении на месте выделения: .copy кладёт прозрачность.
        NSColor.clear.set()
        currentRect.fill(using: .copy)

        // Двойной контур: тёмный снаружи + белый внутри — читается и на светлом, и на тёмном.
        // lineWidth не домножаем на scale: 1pt в CG уже = 2 физпикселя на Retina.
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

/// Создаёт и удерживает по одному оверлею на КАЖДЫЙ экран (origin и backingScaleFactor
/// у дисплеев разные — одно окно на всё нельзя). Один экран = одно окно.
final class OverlayController {

    private(set) var windows: [OverlayWindow] = []
    private var escMonitor: Any?
    private var onComplete: ((NSRect, NSScreen) -> Void)?
    private var onCancel: (() -> Void)?

    func begin(onComplete: @escaping (NSRect, NSScreen) -> Void,
               onCancel: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onCancel = onCancel

        for screen in NSScreen.screens {
            // БЕЗ параметра screen: — иначе contentRect трактуется относительно origin экрана,
            // и на дисплее с отрицательным origin смещение применяется дважды (окно улетает за
            // экран). Тут contentRect глобальный; точную посадку добиваем явным setFrame ниже.
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            w.setFrame(screen.frame, display: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))   // выше строки меню
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.ignoresMouseEvents = false
            w.acceptsMouseMovedEvents = true

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenRef = screen
            view.onComplete = { [weak self] rect, scr in self?.onComplete?(rect, scr) }
            view.onCancel = { [weak self] in self?.onCancel?() }
            w.contentView = view
            windows.append(w)
        }

        for w in windows { w.orderFrontRegardless() }
        windows.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Escape должен отменять независимо от того, какое окно key (мульти-монитор).
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.onCancel?(); return nil }
            return e
        }
    }

    /// Спрятать всю «обвязку» перед захватом, не разрушая окна.
    func orderOutAll() {
        for w in windows { w.orderOut(nil) }
    }

    func dismiss() {
        if let escMonitor { NSEvent.removeMonitor(escMonitor); self.escMonitor = nil }
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        onComplete = nil
        onCancel = nil
    }

    deinit { if let escMonitor { NSEvent.removeMonitor(escMonitor) } }
}
