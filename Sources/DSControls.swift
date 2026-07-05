import AppKit

/// Нативная Liquid Glass кнопка: NSButton с bezelStyle .glass (macOS 26). Систему рисует
/// стекло, ховер, нажатие-с-подъёмом, фокус по HIG — мы только конфигурируем контент.
/// Может быть капсулой (иконка + текст) или кругом (только иконка / только цифра).
///
/// Видимостью по ховеру управляем через isHidden, а НЕ через alpha: у нативного .glass
/// нельзя отделить глиф от подложки публичным API, поэтому глиф никогда не держим на
/// частичном контрасте — кнопка либо есть целиком (полный контраст), либо скрыта.
class GlassButton: NSButton {

    var onClick: (() -> Void)?
    private let symbolName: String?
    private let baseTitle: String?
    // Размер символа берём из метрики шрифта large-контрола, а не из магического числа.
    private let symbolConfig = NSImage.SymbolConfiguration(
        pointSize: NSFont.systemFontSize(for: .large), weight: .medium)

    init(symbol: String? = nil, title titleText: String? = nil, a11y: String) {
        symbolName = symbol
        baseTitle = titleText
        super.init(frame: .zero)
        wantsLayer = true
        bezelStyle = .glass
        isBordered = true
        controlSize = .large
        imageScaling = .scaleProportionallyDown
        imageHugsTitle = true
        focusRingType = .none           // в плавающих панелях кнопки мышиные — синий фокус-ринг не нужен
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: a11y)?
                .withSymbolConfiguration(symbolConfig)
        }
        self.title = titleText ?? ""
        let hasTitle = !(titleText ?? "").isEmpty
        imagePosition = hasTitle ? .imageLeading : .imageOnly
        borderShape = hasTitle ? .capsule : .circle
        setAccessibilityLabel(a11y)
        target = self
        action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onClick?() }

    // В неактивной панели первый клик должен срабатывать сразу.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, isEnabled, bounds.contains(point) else { return nil }
        return self
    }

    var isCompact: Bool { imagePosition == .imageOnly }

    func setCompact(_ c: Bool) {
        if c { title = ""; imagePosition = .imageOnly; borderShape = .circle }
        else if let t = baseTitle { title = t; imagePosition = .imageLeading; borderShape = .capsule }
        invalidateIntrinsicContentSize()
    }

    /// Краткий фидбэк копирования: галочка + согласованная подпись «Скопировано».
    /// Восстановление уважает текущее compact-состояние (кнопка могла сжаться по ширине).
    func showCheck(_ on: Bool) {
        let name = on ? "checkmark" : (symbolName ?? "doc.on.doc")
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        guard !isCompact, baseTitle != nil else { return }   // в compact достаточно сменить глиф
        title = on ? "Скопировано" : (baseTitle ?? "")
    }
}

/// Кастомная кнопка QuickShot в стиле текущей Vercel/Geist-подобной command surface:
/// тёмная pill/circle, тонкая обводка, template SF Symbol и явные hover/pressed состояния.
/// Используется там, где системный Liquid Glass конфликтует с собственной дизайн-системой трея.
final class DesignSystemButton: NSControl {

    enum Role {
        case normal
        case destructive
    }

    var onClick: (() -> Void)?

    private static let height: CGFloat = 30
    private static let hPad: CGFloat = 11
    private static let gap: CGFloat = 6
    private static let iconSide: CGFloat = 15

    private let symbolName: String
    private let baseTitle: String?
    private let role: Role
    private let imageView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)

    private var compact = false
    private var showsCheck = false
    private var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init(symbol: String, title titleText: String? = nil, a11y: String, role: Role = .normal) {
        self.symbolName = symbol
        self.baseTitle = titleText
        self.role = role
        self.compact = titleText == nil
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        imageView.imageScaling = .scaleProportionallyDown
        imageView.setAccessibilityElement(false)
        addSubview(imageView)

        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.lineBreakMode = .byClipping
        label.setAccessibilityElement(false)
        addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(a11y)
        syncContent()
        updateChrome(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: Self.height)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    var isCompact: Bool { compact }

    func setCompact(_ compact: Bool) {
        self.compact = compact || baseTitle == nil
        syncContent()
    }

    func showCheck(_ on: Bool) {
        showsCheck = on
        syncContent()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, isEnabled, bounds.contains(point) else { return nil }
        return self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2

        let iconX: CGFloat
        if compact {
            iconX = (bounds.width - Self.iconSide) / 2
            label.frame = .zero
        } else {
            iconX = Self.hPad
            label.sizeToFit()
            let labelX = iconX + Self.iconSide + Self.gap
            label.frame = NSRect(x: labelX,
                                 y: (bounds.height - ceil(label.frame.height)) / 2,
                                 width: max(0, bounds.width - labelX - Self.hPad),
                                 height: ceil(label.frame.height))
        }

        imageView.frame = NSRect(x: iconX,
                                 y: (bounds.height - Self.iconSide) / 2,
                                 width: Self.iconSide,
                                 height: Self.iconSide)
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

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    private var preferredWidth: CGFloat {
        if compact { return Self.height }
        label.sizeToFit()
        return ceil(Self.hPad + Self.iconSide + Self.gap + label.frame.width + Self.hPad)
    }

    private func syncContent() {
        let iconName = showsCheck ? "checkmark" : symbolName
        let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        image?.isTemplate = true
        imageView.image = image

        if compact {
            label.stringValue = ""
            label.isHidden = true
        } else {
            label.stringValue = showsCheck ? "Скопировано" : (baseTitle ?? "")
            label.isHidden = false
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
        updateChrome()
    }

    private func updateChrome(animated: Bool = true) {
        let bg: NSColor
        let border: NSColor
        let content: NSColor

        switch (role, isPressed, isHovered) {
        case (.destructive, true, _):
            bg = NSColor(calibratedRed: 0.30, green: 0.025, blue: 0.030, alpha: 0.96)
            border = NSColor(calibratedRed: 1, green: 0.22, blue: 0.24, alpha: 0.44)
            content = NSColor(calibratedRed: 1, green: 0.70, blue: 0.70, alpha: 1)
        case (.destructive, _, true):
            bg = NSColor(calibratedRed: 0.20, green: 0.018, blue: 0.024, alpha: 0.92)
            border = NSColor(calibratedRed: 1, green: 0.22, blue: 0.24, alpha: 0.34)
            content = NSColor(calibratedRed: 1, green: 0.58, blue: 0.58, alpha: 1)
        case (.normal, true, _):
            bg = NSColor(calibratedWhite: 0.13, alpha: 0.96)
            border = NSColor.white.withAlphaComponent(0.28)
            content = .white
        case (.normal, _, true):
            bg = NSColor(calibratedWhite: 0.08, alpha: 0.94)
            border = NSColor.white.withAlphaComponent(0.22)
            content = .white
        default:
            bg = NSColor.black.withAlphaComponent(0.84)
            border = NSColor.white.withAlphaComponent(0.16)
            content = role == .destructive
                ? NSColor.white.withAlphaComponent(0.96)
                : NSColor.white.withAlphaComponent(0.94)
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.12 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        layer?.backgroundColor = bg.cgColor
        layer?.borderColor = border.cgColor
        CATransaction.commit()

        label.textColor = content
        imageView.contentTintColor = content
    }
}
