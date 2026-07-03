import AppKit

/// Хаб-счётчик — тёмная «пуля» в стиле Vercel/Geist: чёрный фон, subtle-обводка,
/// белый моноширинный счётчик и шеврон. Это простой рабочий вариант без liquid-эксперимента:
/// сначала возвращаем надёжное сворачивание/разворачивание и корректную раскладку.
private final class HubView: NSView {
    var onClick: (() -> Void)?
    let barHeight: CGFloat

    private let hPad: CGFloat
    private let gap: CGFloat
    private let side: CGFloat
    private let label = NSTextField(labelWithString: "0")
    private let chevron = CAShapeLayer()

    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private var vertical = true
    private var collapsed = false
    private var appliedAngle: CGFloat?

    init(height: CGFloat, font: NSFont) {
        self.barHeight = height
        self.hPad = ceil(height * 0.34)
        self.gap = ceil(height * 0.16)
        self.side = ceil(height * 0.34)
        super.init(frame: NSRect(x: 0, y: 0, width: height, height: height))

        wantsLayer = true
        layer?.backgroundColor = Self.backgroundColor(pressed: false, hovered: false).cgColor
        layer?.borderColor = Self.borderColor(pressed: false, hovered: false).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = height / 2
        layer?.masksToBounds = true

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
        chevron.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        chevron.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        chevron.path = Self.chevronPath(side: side)
        chevron.contentsScale = 2
        layer?.addSublayer(chevron)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        resizeToFit()
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func backgroundColor(pressed: Bool, hovered: Bool) -> NSColor {
        if pressed { return NSColor(calibratedWhite: 0.13, alpha: 1) }
        if hovered { return NSColor(calibratedWhite: 0.08, alpha: 1) }
        return .black
    }

    private static func borderColor(pressed: Bool, hovered: Bool) -> NSColor {
        let alpha: CGFloat = pressed ? 0.30 : (hovered ? 0.22 : 0.14)
        return NSColor.white.withAlphaComponent(alpha)
    }

    private func updateChrome(animated: Bool = true) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.12 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer?.backgroundColor = Self.backgroundColor(pressed: isPressed, hovered: isHovered).cgColor
        layer?.borderColor = Self.borderColor(pressed: isPressed, hovered: isHovered).cgColor
        CATransaction.commit()
    }

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
        let angle = Self.angle(vertical: vertical, collapsed: collapsed)
        let smooth = appliedAngle != nil && vertical == self.vertical && collapsed != self.collapsed
        self.vertical = vertical
        self.collapsed = collapsed
        resizeToFit()
        rotate(to: angle, animated: smooth)
    }

    private static func angle(vertical: Bool, collapsed: Bool) -> CGFloat {
        if vertical { return collapsed ? 0 : 180 }
        else        { return collapsed ? 90 : -90 }
    }

    private func rotate(to angle: CGFloat, animated: Bool) {
        if appliedAngle == angle { return }
        let from = appliedAngle ?? angle
        appliedAngle = angle
        let toRad = angle * .pi / 180
        chevron.transform = CATransform3DMakeRotation(toRad, 0, 0, 1)
        if animated {
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = from * .pi / 180
            a.toValue = toRad
            a.duration = 0.2
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            chevron.add(a, forKey: "rot")
        }
    }

    private func resizeToFit() {
        label.sizeToFit()
        let w = hPad + ceil(label.frame.width) + gap + side + hPad
        if abs(frame.width - w) > 0.5 { setFrameSize(NSSize(width: w, height: barHeight)) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        label.sizeToFit()
        let lw = ceil(label.frame.width), lh = ceil(label.frame.height)
        label.frame = NSRect(x: hPad, y: (bounds.height - lh) / 2, width: lw, height: lh)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chevron.position = CGPoint(x: hPad + lw + gap + side / 2, y: bounds.height / 2)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        chevron.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateChrome()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if !isPressed { updateChrome() }
    }

    override func mouseMoved(with event: NSEvent) {
        isHovered = true
        updateChrome()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        isHovered = true
        updateChrome()
    }

    override func mouseDragged(with event: NSEvent) {
        isHovered = bounds.contains(convert(event.locationInWindow, from: nil))
        updateChrome()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        isHovered = inside
        updateChrome()
        if inside { onClick?() }
    }
}

/// Обёртка над хабом-пулей для менеджера трея. Внешний API сохранён.
final class HubWindow {
    private let hub: HubView
    private static let hubHeight: CGFloat = 34

    var view: NSView { hub }
    var onClick: (() -> Void)? { didSet { hub.onClick = onClick } }
    var width: CGFloat { hub.frame.width }
    var height: CGFloat { hub.barHeight }
    var center: NSPoint { NSPoint(x: hub.frame.midX, y: hub.frame.midY) }

    init() {
        let h = Self.hubHeight
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
