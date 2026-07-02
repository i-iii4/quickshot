import AppKit

/// Хаб-счётчик — тёмная «пуля» в стиле дизайн-системы Vercel (Geist): чёрный фон, тонкая subtle-
/// обводка, белый текст, форма-пилюля. Уходим от `.glass`: сплошная заливка стабильна независимо от
/// key/фокуса окна (приглушение снято по построению).
///
/// Справа от цифры — шеврон-индикатор. Он показывает, КУДА раскроется трей, и при клике плавно
/// доворачивается. Направление берётся из позиции кнопки (через `isVertical`) — трей раскрывается:
///   вертикальный (справа/слева): карточки идут ВВЕРХ  → свёрнуто ↑, развёрнуто ↓;
///   горизонтальный (снизу/сверху): карточки идут ВЛЕВО → свёрнуто ←, развёрнуто →.
/// Поворот живёт на отдельном `CAShapeLayer` (вектор, чёткий; `anchorPoint 0.5` — вокруг центра),
/// поэтому `layout()` его не затирает и анимация не дёргается. Анимируем только на настоящем
/// сворачивании/разворачивании, а не на каждом `setState`.
private final class HubView: NSView {
    var onClick: (() -> Void)?
    let barHeight: CGFloat

    private let hPad: CGFloat
    private let gap: CGFloat
    private let side: CGFloat                       // сторона квадратного слота шеврона
    private let label = NSTextField(labelWithString: "0")
    private let chevron = CAShapeLayer()

    private var vertical = true
    private var collapsed = false
    private var appliedAngle: CGFloat?             // текущий угол (градусы); nil — ещё не задан

    init(height: CGFloat, font: NSFont) {
        self.barHeight = height
        self.hPad = ceil(height * 0.34)
        self.gap = ceil(height * 0.16)
        self.side = ceil(height * 0.34)
        super.init(frame: NSRect(x: 0, y: 0, width: height, height: height))

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor    // subtle-обводка Vercel
        layer?.borderWidth = 1
        layer?.cornerRadius = height / 2                                        // пилюля

        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.setAccessibilityElement(false)
        addSubview(label)

        chevron.fillColor = NSColor.clear.cgColor
        chevron.strokeColor = NSColor.white.withAlphaComponent(0.72).cgColor
        chevron.lineWidth = max(1.5, side * 0.15)
        chevron.lineCap = .round
        chevron.lineJoin = .round
        chevron.anchorPoint = CGPoint(x: 0.5, y: 0.5)                          // поворот вокруг центра
        chevron.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        chevron.path = HubView.chevronPath(side: side)                          // «^» вверх (0°)
        chevron.contentsScale = 2
        layer?.addSublayer(chevron)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// «^» с апексом вверх в квадрате side×side (система координат y-вверх, non-flipped view).
    private static func chevronPath(side S: CGFloat) -> CGPath {
        let dx = S * 0.30, dy = S * 0.15, cx = S / 2, cy = S / 2
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx - dx, y: cy - dy))
        p.addLine(to: CGPoint(x: cx, y: cy + dy))
        p.addLine(to: CGPoint(x: cx + dx, y: cy - dy))
        return p
    }

    func set(count: Int, collapsed: Bool, vertical: Bool) {
        label.stringValue = count > 99 ? "99+" : "\(count)"
        let angle = HubView.angle(vertical: vertical, collapsed: collapsed)
        // Плавно доворачиваем только на настоящем сворачивании/разворачивании (та же ось).
        // Смена позиции трея (меняется ось) и первичная установка — мгновенно.
        let smooth = appliedAngle != nil && vertical == self.vertical && collapsed != self.collapsed
        self.vertical = vertical
        self.collapsed = collapsed
        resizeToFit()
        rotate(to: angle, animated: smooth)
    }

    /// Угол шеврона (градусы). База «^» смотрит вверх (0°). Положительный — против часовой.
    private static func angle(vertical: Bool, collapsed: Bool) -> CGFloat {
        if vertical { return collapsed ? 0 : 180 }        // ↑ развернётся вверх / ↓ свернётся вниз
        else        { return collapsed ? 90 : -90 }       // ← развернётся влево / → свернётся вправо
    }

    private func rotate(to angle: CGFloat, animated: Bool) {
        if appliedAngle == angle { return }
        let from = appliedAngle ?? angle
        appliedAngle = angle
        let toRad = angle * .pi / 180
        chevron.transform = CATransform3DMakeRotation(toRad, 0, 0, 1)          // модель
        if animated {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = from * .pi / 180
            a.toValue = toRad
            a.duration = 0.2
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            chevron.add(a, forKey: "rot")
        }
    }

    /// Ширина пули под содержимое: [pad][цифра][gap][шеврон][pad].
    private func resizeToFit() {
        label.sizeToFit()
        let w = hPad + ceil(label.frame.width) + gap + side + hPad
        if abs(frame.width - w) > 0.5 { setFrameSize(NSSize(width: w, height: barHeight)) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        let lw = ceil(label.frame.width), lh = ceil(label.frame.height)
        label.frame = NSRect(x: hPad, y: (bounds.height - lh) / 2, width: lw, height: lh)
        // Двигаем только позицию шеврона, поворот не трогаем; без неявной анимации сдвига.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        chevron.position = CGPoint(x: hPad + lw + gap + side / 2, y: bounds.height / 2)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        chevron.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { alphaValue = 0.7 }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Обёртка над хабом-пулей для менеджера трея. Внешний API сохранён.
final class HubWindow {

    private let hub: HubView

    var view: NSView { hub }
    var onClick: (() -> Void)? { didSet { hub.onClick = onClick } }
    var width: CGFloat { hub.frame.width }         // переменная (под содержимое)
    var height: CGFloat { hub.barHeight }          // фиксированная
    var center: NSPoint { NSPoint(x: hub.frame.midX, y: hub.frame.midY) }

    init() {
        // Высота = стандартная высота large-контрола (системная метрика), а не магическое число.
        let sizer = GlassButton(title: "0", a11y: "")
        sizer.borderShape = .circle
        let h = ceil(sizer.fittingSize.height)
        let font = NSFont.monospacedDigitSystemFont(ofSize: ceil(h * 0.44), weight: .medium)
        hub = HubView(height: h, font: font)
    }

    func setState(count: Int, collapsed: Bool) {
        hub.set(count: count, collapsed: collapsed, vertical: TrayPosition.current.isVertical)
        hub.setAccessibilityValue("\(count)")
        hub.setAccessibilityLabel(collapsed ? "Развернуть скриншоты" : "Свернуть скриншоты")
        hub.setAccessibilityHelp("Нажмите, чтобы развернуть или свернуть трей")
    }

    func setOrigin(_ p: NSPoint) { hub.setFrameOrigin(p) }
    func show() { hub.isHidden = false }
    func hide() { hub.isHidden = true }
}
