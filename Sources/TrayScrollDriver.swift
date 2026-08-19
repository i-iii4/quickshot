import AppKit

/// Двигатель прокрутки трея на системном `NSScrollView` (`TR-13`).
///
/// Собственную физику лента больше не считает. Резинка за краями, возврат,
/// инерция и реакция на системные настройки прокрутки — всё это AppKit уже
/// умеет, и умеет ровно так, как в остальной системе. Самодельная формула
/// сопротивления и подбор её чисел были изобретением велосипеда: сначала
/// лента дёргалась, потом «свободно каталась», и каждый набор чисел
/// приходилось проверять руками пользователя (приёмка 19.08.2026).
///
/// Карточки внутрь скролл-вью не переносятся: он работает ИСТОЧНИКОМ
/// СМЕЩЕНИЯ. События прокрутки уходят в него, он двигает свой пустой
/// документ, а трей на каждое изменение читает позицию и раскладывает ленту
/// прежним кодом. Так родная физика получена без переписывания раскладки.
@MainActor
final class TrayScrollDriver {
    /// Текущее смещение ленты, включая уход за край во время резинки.
    private(set) var offset: CGFloat = 0
    /// Зовётся на каждом кадре движения — и во время жеста, и во время
    /// инерции, и во время возврата резинки.
    var onChange: (() -> Void)?

    private let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    private let document = NSView(frame: .zero)
    private var vertical = true
    private var contentLength: CGFloat = 0
    private var viewportLength: CGFloat = 1
    /// Смещение выставляется программно (сбор стопки, вставка снимка): такие
    /// изменения не должны выглядеть как жест пользователя.
    private var suppressNotifications = false

    init() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        // Резинка на обеих осях — родная, включая её отключение системными
        // настройками пользователя.
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.usesPredominantAxisScrolling = false
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundsChanged() }
        }
    }

    /// Скролл-вью живёт в панели трея нулевого размера: он невидим, но обязан
    /// быть в иерархии, иначе AppKit не считает его прокручиваемым.
    func attach(to container: NSView) {
        guard scrollView.superview !== container else { return }
        scrollView.removeFromSuperview()
        scrollView.frame = NSRect(x: -10_000, y: -10_000, width: 100, height: 100)
        container.addSubview(scrollView, positioned: .below, relativeTo: nil)
    }

    /// Размеры ленты. Документ длиннее окна ровно на возможный ход, поэтому
    /// системная механика упирается там же, где упирается лента.
    func update(contentLength: CGFloat, viewportLength: CGFloat, vertical: Bool) {
        let travel = max(0, contentLength)
        guard travel != self.contentLength
                || viewportLength != self.viewportLength
                || vertical != self.vertical else { return }
        self.contentLength = travel
        self.viewportLength = max(1, viewportLength)
        self.vertical = vertical

        let saved = offset
        suppressNotifications = true
        let viewport = NSSize(width: 100, height: 100)
        scrollView.frame = NSRect(origin: scrollView.frame.origin, size: viewport)
        document.frame = vertical
            ? NSRect(x: 0, y: 0, width: viewport.width, height: viewport.height + travel)
            : NSRect(x: 0, y: 0, width: viewport.width + travel, height: viewport.height)
        suppressNotifications = false
        setOffset(saved)
    }

    /// Событие прокрутки уходит в системный скролл: он сам разбирается с
    /// фазами, инерцией и резинкой.
    func handle(_ event: NSEvent) {
        scrollView.scrollWheel(with: event)
    }

    /// Программная установка смещения — без анимации и без уведомления
    /// раскладки: её вызывает тот, кто и так перекладывает ленту.
    func setOffset(_ value: CGFloat) {
        let clamped = min(max(0, value), contentLength)
        offset = clamped
        suppressNotifications = true
        let point = vertical
            ? NSPoint(x: 0, y: clamped)
            : NSPoint(x: clamped, y: 0)
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        suppressNotifications = false
    }

    /// Плавный переход к смещению средствами системы: тот же путь, которым
    /// AppKit докручивает содержимое.
    func animateOffset(to value: CGFloat) {
        let clamped = min(max(0, value), contentLength)
        let point = vertical
            ? NSPoint(x: 0, y: clamped)
            : NSPoint(x: clamped, y: 0)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.contentView.animator().setBoundsOrigin(point)
        }
    }

    private func boundsChanged() {
        let origin = scrollView.contentView.bounds.origin
        let value = vertical ? origin.y : origin.x
        guard abs(value - offset) > 0.001 else { return }
        offset = value
        guard !suppressNotifications else { return }
        onChange?()
    }
}
