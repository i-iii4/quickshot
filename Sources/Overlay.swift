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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true                 // своя прозрачная backing-store для .copy-дыры над бэкдропом
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // Без этого первый клик по оверлею экрана, который не key (на втором мониторе оверлеи кроме
    // главного — не key), тратится на активацию окна и не доходит до вью. С true mouseDown
    // приходит сразу — выделение работает на любом экране независимо от key-статуса.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Курсор-перекрестье. resetCursorRects плохо держится у сабвью на каждый mouse-moved —
    // система перебивает стрелкой. Через cursorUpdate (приложение в оверлее активно) держится
    // надёжно; во время drag cursorUpdate не приходит, поэтому ставим явно в mouseDragged.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = cursorTracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .cursorUpdate],
                               owner: self, userInfo: nil)
        addTrackingArea(t); cursorTracking = t
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.crosshair.set()
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.crosshair.set()                       // удержать перекрестье во время выделения
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
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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

        // Escape отменяет независимо от того, какое окно key (мульти-монитор).
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.onCancel?(); return nil }
            return e
        }
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
