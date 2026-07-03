import AppKit

private enum HubExpansionDirection {
    case left
    case right
}

private enum HubAction: CaseIterable {
    case delete
    case saveAs
    case copyAll

    var title: String {
        switch self {
        case .delete: return "Delete"
        case .saveAs: return "Save As"
        case .copyAll: return "Copy All Screenshots"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .delete: return "Delete screenshots"
        case .saveAs: return "Save screenshots as PNG"
        case .copyAll: return "Copy all screenshots"
        }
    }

    var isDestructive: Bool { self == .delete }
}

private enum HubMetrics {
    static let coreHeight: CGFloat = 34
    static let shellInset: CGFloat = 3
    static let shellHeight: CGFloat = coreHeight + shellInset * 2
    static let actionHeight: CGFloat = coreHeight
    static let groupGap: CGFloat = 7
    static let actionGap: CGFloat = 7
    static let actionHPad: CGFloat = 13
    static let animationDuration: Double = 0.145
}

#if TESTING
struct HubDebugPillSnapshot {
    let title: String
    let frame: NSRect
    let cornerRadius: CGFloat
    let labelAlpha: CGFloat
    let isInteractive: Bool
}

struct HubDebugSnapshot {
    let shellBounds: NSRect
    let shellInset: CGFloat
    let groupGap: CGFloat
    let actionGap: CGFloat
    let progress: CGFloat
    let coreFrame: NSRect
    let coreCornerRadius: CGFloat
    let actionClipFrame: NSRect
    let actionClipCornerRadius: CGFloat
    let actionPills: [HubDebugPillSnapshot]
}
#endif

private func hubEaseOutCubic(_ f: CGFloat) -> CGFloat { 1 - pow(1 - f, 3) }
private func hubEaseOutQuad(_ f: CGFloat) -> CGFloat { 1 - (1 - f) * (1 - f) }
private func hubEaseInOutCubic(_ f: CGFloat) -> CGFloat {
    f < 0.5 ? 4 * f * f * f : 1 - pow(-2 * f + 2, 3) / 2
}

private final class HubActionPill: NSView {
    var onClick: (() -> Void)?

    private let action: HubAction
    private let label = NSTextField(labelWithString: "")
    private var isHovered = false
    private var isPressed = false
    private var isInteractive = false

    init(action: HubAction, font: NSFont) {
        self.action = action
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = HubMetrics.actionHeight / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true

        label.stringValue = action.title
        label.font = font
        label.textColor = action.isDestructive ? Self.deleteTextColor(hovered: false, pressed: false) : .white
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.setAccessibilityElement(false)
        addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(action.accessibilityLabel)
        updateChrome(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat {
        label.sizeToFit()
        return ceil(label.frame.width) + HubMetrics.actionHPad * 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isInteractive, alphaValue > 0.45, bounds.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        label.sizeToFit()
        label.frame = NSRect(x: HubMetrics.actionHPad,
                             y: (bounds.height - ceil(label.frame.height)) / 2,
                             width: max(0, bounds.width - HubMetrics.actionHPad * 2),
                             height: ceil(label.frame.height))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateChrome()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if !isPressed { updateChrome() }
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

    func setReveal(chrome: CGFloat, title: CGFloat) {
        alphaValue = chrome
        label.alphaValue = title
        isInteractive = title > 0.98 && chrome > 0.72
    }

#if TESTING
    func debugSnapshot() -> HubDebugPillSnapshot {
        HubDebugPillSnapshot(title: action.title,
                             frame: frame,
                             cornerRadius: layer?.cornerRadius ?? 0,
                             labelAlpha: label.alphaValue,
                             isInteractive: isInteractive)
    }
#endif

    private static func deleteTextColor(hovered: Bool, pressed: Bool) -> NSColor {
        if pressed { return NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.72, alpha: 1) }
        if hovered { return NSColor(calibratedRed: 1.0, green: 0.60, blue: 0.60, alpha: 1) }
        return NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.48, alpha: 1)
    }

    private func updateChrome(animated: Bool = true) {
        let bg: NSColor
        let border: NSColor
        if action.isDestructive {
            bg = isPressed
                ? NSColor(calibratedRed: 0.30, green: 0.030, blue: 0.040, alpha: 0.90)
                : (isHovered
                   ? NSColor(calibratedRed: 0.23, green: 0.025, blue: 0.032, alpha: 0.82)
                   : NSColor(calibratedRed: 0.18, green: 0.018, blue: 0.024, alpha: 0.64))
            border = NSColor(calibratedRed: 1, green: 0.22, blue: 0.24, alpha: isPressed ? 0.46 : (isHovered ? 0.34 : 0.24))
            label.textColor = Self.deleteTextColor(hovered: isHovered, pressed: isPressed)
        } else {
            bg = isPressed
                ? NSColor.white.withAlphaComponent(0.135)
                : (isHovered ? NSColor.white.withAlphaComponent(0.095) : NSColor.white.withAlphaComponent(0.052))
            border = NSColor.white.withAlphaComponent(isPressed ? 0.24 : (isHovered ? 0.18 : 0.11))
            label.textColor = .white
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.12 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer?.backgroundColor = bg.cgColor
        layer?.borderColor = border.cgColor
        CATransaction.commit()
    }
}

private final class HubActionClipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.05, bounds.contains(point) else { return nil }
        for child in subviews.reversed() {
            let p = convert(point, to: child)
            if let hit = child.hitTest(p) { return hit }
        }
        return nil
    }
}

/// Основная кнопка-счётчик — тёмная «пуля» в стиле Vercel/Geist: чёрный фон,
/// subtle-обводка, белый моноширинный счётчик и шеврон-индикатор.
private final class HubCoreView: NSView {
    var onClick: (() -> Void)?
    let barHeight: CGFloat

    private let hPad: CGFloat
    private let gap: CGFloat
    private let side: CGFloat
    private let label = NSTextField(labelWithString: "0")
    private let chevron = CAShapeLayer()

    private var isGroupHovered = false
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
        layer?.borderWidth = 1
        layer?.cornerRadius = height / 2
        layer?.cornerCurve = .continuous
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
        updateChrome(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat {
        label.sizeToFit()
        return hPad + ceil(label.frame.width) + gap + side + hPad
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setGroupHovered(_ hovered: Bool) {
        guard isGroupHovered != hovered else { return }
        isGroupHovered = hovered
        updateChrome()
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
        layer?.backgroundColor = Self.backgroundColor(pressed: isPressed, hovered: isGroupHovered).cgColor
        layer?.borderColor = Self.borderColor(pressed: isPressed, hovered: isGroupHovered).cgColor
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
        let w = preferredWidth
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

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateChrome()
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
        updateChrome()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        updateChrome()
        if inside { onClick?() }
    }
}

/// Hover-shell вокруг основной кнопки. В покое это круглая дополнительная обводка;
/// по hover она растягивается в pill и раскрывает action pills рядом с исходной кнопкой.
private final class HubShellView: NSView {
    var onToggle: (() -> Void)? { didSet { core.onClick = onToggle } }
    var onAction: ((HubAction) -> Void)?

    private let ringFill = CAShapeLayer()
    private let ringHalo = CAShapeLayer()
    private let ringLine = CAShapeLayer()
    private let core: HubCoreView
    private let actionClip = HubActionClipView()
    private let actionButtons: [(action: HubAction, view: HubActionPill)]
    private var trackingArea: NSTrackingArea?
    private var direction: HubExpansionDirection = .left
    private var collapsedOrigin: NSPoint = .zero
    private var progress: CGFloat = 0
    private lazy var animator = FrameAnimator(hostView: self)

    init(font: NSFont, actionFont: NSFont) {
        core = HubCoreView(height: HubMetrics.coreHeight, font: font)
        actionButtons = HubAction.allCases.map { action in
            (action, HubActionPill(action: action, font: actionFont))
        }
        super.init(frame: .zero)

        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        [ringFill, ringHalo, ringLine].forEach { layer?.addSublayer($0) }
        ringFill.fillColor = NSColor(calibratedWhite: 0.018, alpha: 0.96).cgColor
        ringFill.strokeColor = NSColor.clear.cgColor
        ringHalo.fillColor = NSColor.clear.cgColor
        ringHalo.strokeColor = NSColor.black.withAlphaComponent(0.48).cgColor
        ringHalo.lineWidth = 1.6
        ringLine.fillColor = NSColor.clear.cgColor
        ringLine.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        ringLine.lineWidth = 1

        actionClip.wantsLayer = true
        actionClip.layer?.masksToBounds = true
        actionClip.layer?.cornerRadius = HubMetrics.actionHeight / 2
        actionClip.layer?.cornerCurve = .continuous
        actionClip.alphaValue = 0
        actionClip.isHidden = true
        addSubview(actionClip)

        for item in actionButtons {
            item.view.alphaValue = 0
            item.view.isHidden = true
            item.view.onClick = { [weak self] in
                guard let self else { return }
                self.setExpanded(false)
                self.onAction?(item.action)
            }
            actionClip.addSubview(item.view)
        }
        addSubview(core)
        setFrameSize(NSSize(width: compactWidth, height: compactHeight))
        layoutForProgress(0)
    }
    required init?(coder: NSCoder) { fatalError() }

    var compactHeight: CGFloat { HubMetrics.shellHeight }
    var compactWidth: CGFloat { ceil(core.preferredWidth) + HubMetrics.shellInset * 2 }
    var coreCenter: NSPoint {
        NSPoint(x: frame.minX + core.frame.midX, y: frame.minY + core.frame.midY)
    }

    private var actionWidth: CGFloat {
        actionButtons.reduce(CGFloat.zero) { partial, item in partial + item.view.preferredWidth }
            + HubMetrics.actionGap * CGFloat(max(0, actionButtons.count - 1))
    }

    private var expandedWidth: CGFloat {
        compactWidth + HubMetrics.groupGap + actionWidth
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        for child in subviews.reversed() {
            let p = convert(point, to: child)
            if let hit = child.hitTest(p) { return hit }
        }
        return self
    }

    func set(count: Int, collapsed: Bool, vertical: Bool, direction: HubExpansionDirection) {
        self.direction = direction
        core.set(count: count, collapsed: collapsed, vertical: vertical)
        updateFrameForCurrentProgress()
        needsLayout = true
    }

    func setCollapsedOrigin(_ origin: NSPoint) {
        collapsedOrigin = origin
        updateFrameForCurrentProgress()
    }

    func setAccessibilityValue(_ value: String) { core.setAccessibilityValue(value) }
    func setAccessibilityLabel(_ label: String) { core.setAccessibilityLabel(label) }
    func setAccessibilityHelp(_ help: String) { core.setAccessibilityHelp(help) }

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

    override func mouseEntered(with event: NSEvent) { setExpanded(true) }
    override func mouseMoved(with event: NSEvent) { setExpanded(true) }
    override func mouseExited(with event: NSEvent) { setExpanded(false) }

    private func setExpanded(_ expanded: Bool) {
        let target: CGFloat = expanded ? 1 : 0
        guard abs(progress - target) > 0.001 else { return }
        if expanded {
            actionClip.isHidden = false
            for item in actionButtons { item.view.isHidden = false }
        }
        core.setGroupHovered(expanded)

        let start = progress
        animator.run(duration: HubMetrics.animationDuration,
                     delay: 0,
                     easing: expanded ? hubEaseOutQuad : hubEaseInOutCubic,
                     onFrame: { [weak self] t in
            guard let self else { return }
            self.progress = start + (target - start) * t
            self.layoutForProgress(self.progress)
        }, onDone: { [weak self] in
            guard let self else { return }
            self.progress = target
            self.layoutForProgress(target)
            if !expanded {
                self.actionClip.isHidden = true
                for item in self.actionButtons { item.view.isHidden = true }
            }
        })
    }

    private func updateFrameForCurrentProgress() {
        layoutForProgress(progress)
    }

#if TESTING
    func debugSetExpansionProgress(_ value: CGFloat) {
        progress = max(0, min(1, value))
        actionClip.isHidden = progress == 0
        for item in actionButtons { item.view.isHidden = progress == 0 }
        core.setGroupHovered(progress > 0)
        layoutForProgress(progress)
    }

    func debugSnapshot() -> HubDebugSnapshot {
        HubDebugSnapshot(shellBounds: bounds,
                         shellInset: HubMetrics.shellInset,
                         groupGap: HubMetrics.groupGap,
                         actionGap: HubMetrics.actionGap,
                         progress: progress,
                         coreFrame: core.frame,
                         coreCornerRadius: core.layer?.cornerRadius ?? 0,
                         actionClipFrame: actionClip.frame,
                         actionClipCornerRadius: actionClip.layer?.cornerRadius ?? 0,
                         actionPills: actionButtons.map { $0.view.debugSnapshot() })
    }
#endif

    private func layoutForProgress(_ p: CGFloat) {
        let currentWidth = compactWidth + (expandedWidth - compactWidth) * p
        let originX: CGFloat
        switch direction {
        case .left:
            originX = collapsedOrigin.x - (currentWidth - compactWidth)
        case .right:
            originX = collapsedOrigin.x
        }
        frame = NSRect(x: originX, y: collapsedOrigin.y, width: currentWidth, height: compactHeight)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let eased = hubEaseOutCubic(p)
        let ringRect = bounds.insetBy(dx: 0.75, dy: 0.75)
        let ringPath = CGPath(roundedRect: ringRect, cornerWidth: ringRect.height / 2, cornerHeight: ringRect.height / 2, transform: nil)
        ringFill.path = ringPath
        ringHalo.path = ringPath
        ringLine.path = ringPath
        ringFill.opacity = Float(0.22 + 0.78 * min(1, p / 0.14))
        ringHalo.strokeColor = NSColor.black.withAlphaComponent(0.48 + 0.16 * eased).cgColor
        ringLine.strokeColor = NSColor.white.withAlphaComponent(0.18 + 0.06 * eased).cgColor
        layer?.shadowPath = ringPath
        layer?.shadowOpacity = 0.16 + Float(0.10 * eased)
        layer?.shadowRadius = 9 + 4 * eased
        CATransaction.commit()

        let coreX: CGFloat
        switch direction {
        case .left:
            coreX = currentWidth - HubMetrics.shellInset - core.preferredWidth
        case .right:
            coreX = HubMetrics.shellInset
        }
        core.frame = NSRect(x: coreX,
                            y: HubMetrics.shellInset,
                            width: core.preferredWidth,
                            height: HubMetrics.coreHeight)

        let clipX: CGFloat
        let clipW: CGFloat
        switch direction {
        case .left:
            clipX = HubMetrics.shellInset
            clipW = max(0, coreX - HubMetrics.groupGap - HubMetrics.shellInset)
        case .right:
            clipX = coreX + core.preferredWidth + HubMetrics.groupGap
            clipW = max(0, currentWidth - HubMetrics.shellInset - clipX)
        }
        actionClip.frame = NSRect(x: clipX,
                                  y: (compactHeight - HubMetrics.actionHeight) / 2,
                                  width: clipW,
                                  height: HubMetrics.actionHeight)
        actionClip.layer?.cornerRadius = HubMetrics.actionHeight / 2
        actionClip.alphaValue = max(0, min(1, (p - 0.08) / 0.92))

        let groupX: CGFloat = direction == .left ? clipW - actionWidth : 0
        var x: CGFloat = 0
        for item in actionButtons {
            let w = item.view.preferredWidth
            let itemX = groupX + x
            item.view.frame = NSRect(x: itemX,
                                     y: 0,
                                     width: w,
                                     height: HubMetrics.actionHeight)
            let visibleW = max(0, min(clipW, itemX + w) - max(0, itemX))
            let chromeReveal = max(0, min(1, visibleW / max(1, w * 0.42)))
            let labelLeft = itemX + HubMetrics.actionHPad
            let labelRight = itemX + w - HubMetrics.actionHPad
            let labelFullyVisible = labelLeft >= -0.5 && labelRight <= clipW + 0.5
            item.view.setReveal(chrome: chromeReveal, title: labelFullyVisible ? 1 : 0)
            item.view.layer?.transform = CATransform3DIdentity
            x += w + HubMetrics.actionGap
        }
    }
}

/// Обёртка над хабом-пулей для менеджера трея. Внешний API сохранён; hover-action group
/// расширяется внутри этой view, не двигая карточки при наведении.
final class HubWindow {
    private let shell: HubShellView

    var view: NSView { shell }
    var onClick: (() -> Void)? { didSet { shell.onToggle = onClick } }
    var onDelete: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onCopyAll: (() -> Void)?

    var width: CGFloat { shell.compactWidth }
    var height: CGFloat { shell.compactHeight }
    var center: NSPoint { shell.coreCenter }

    init() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: ceil(HubMetrics.coreHeight * 0.44), weight: .medium)
        let actionFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        shell = HubShellView(font: font, actionFont: actionFont)
        shell.onAction = { [weak self] action in
            switch action {
            case .delete: self?.onDelete?()
            case .saveAs: self?.onSaveAs?()
            case .copyAll: self?.onCopyAll?()
            }
        }
    }

    func setState(count: Int, collapsed: Bool) {
        let direction: HubExpansionDirection = TrayPosition.current == .left ? .right : .left
        shell.set(count: count, collapsed: collapsed, vertical: TrayPosition.current.isVertical, direction: direction)
        shell.setAccessibilityValue("\(count)")
        shell.setAccessibilityLabel(collapsed ? "Развернуть скриншоты" : "Свернуть скриншоты")
        shell.setAccessibilityHelp("Нажмите, чтобы развернуть или свернуть трей")
    }

    func setOrigin(_ p: NSPoint) { shell.setCollapsedOrigin(p) }
    func show() { shell.isHidden = false }
    func hide() { shell.isHidden = true }

#if TESTING
    func debugSetExpansionProgress(_ progress: CGFloat) { shell.debugSetExpansionProgress(progress) }
    func debugSnapshot() -> HubDebugSnapshot { shell.debugSnapshot() }
#endif
}
