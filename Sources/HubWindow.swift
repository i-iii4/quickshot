import AppKit

/// Круглый/капсульный хаб-счётчик — САБВЬЮ общего окна-хоста трея. НЕ системная `.glass`-кнопка:
/// её активный вид следует за key/active-состоянием окна, а трей — фоновая nonactivating-панель,
/// почти всегда не key, поэтому стекло гасло в «disabled». Публичного способа форсировать активный
/// вид системного контрола в не-key окне нет.
///
/// Поэтому вид отвязан от состояния окна: фон — `NSVisualEffectView` с `state = .active` (пин
/// активного вида материала — НЕ гаснет при потере фокуса/key/Spaces), пин тёмной темы (белая цифра
/// читаема всегда), цифру и клик рисуем/обрабатываем сами.
///
/// Форма: круг при коротком числе, плавно растёт в капсулу под широкое («99+»). Высота фиксирована.
private final class HubView: NSView {
    var onClick: (() -> Void)?
    let diameter: CGFloat                                  // = высота, фиксированная
    private let hPad: CGFloat
    private let blur = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "0")

    init(diameter: CGFloat, font: NSFont) {
        self.diameter = diameter
        self.hPad = ceil(diameter * 0.22)
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active                                  // пин активного вида — не гаснет вне key
        blur.appearance = NSAppearance(named: .darkAqua)      // консистентно тёмный фрост → белая цифра читаема
        addSubview(blur)

        label.font = font
        label.textColor = .white
        label.alignment = .center
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.setAccessibilityElement(false)                  // a11y — на самом хабе
        addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateMask()
    }
    required init?(coder: NSCoder) { fatalError() }

    var count: String {
        get { label.stringValue }
        set { label.stringValue = newValue; resizeToFit() }
    }

    /// Ширина под текст: круг при коротком числе (минимум = диаметр), капсула при широком.
    private func resizeToFit() {
        label.sizeToFit()
        let w = max(diameter, ceil(label.frame.width) + 2 * hPad)
        if abs(frame.width - w) > 0.5 {
            setFrameSize(NSSize(width: w, height: diameter))
            updateMask()
        }
        needsLayout = true
    }

    /// Маска по текущему размеру: roundedRect с радиусом = высота/2 даёт круг (w==h) или капсулу (w>h).
    private func updateMask() {
        let sz = bounds.size
        blur.maskImage = NSImage(size: sz, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: sz.height / 2, yRadius: sz.height / 2).fill()
            return true
        }
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        label.sizeToFit()
        label.frame = NSRect(x: 0, y: (bounds.height - label.frame.height) / 2,
                             width: bounds.width, height: label.frame.height)
    }

    // Клик обрабатываем сами: acceptsFirstMouse → срабатывает и в не-key окне; лёгкий press-фидбэк.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { alphaValue = 0.7 }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

/// Обёртка над хабом для менеджера трея. Хаб переменной ширины (капсула), высота фиксирована —
/// поэтому раздаём `width`/`height` раздельно (раскладка использует высоту для вертикали, ширину
/// для горизонтали).
final class HubWindow {

    private let hub: HubView

    /// Сабвью, которую хост добавляет в свою иерархию и позиционирует.
    var view: NSView { hub }

    var onClick: (() -> Void)? { didSet { hub.onClick = onClick } }
    var width: CGFloat { hub.frame.width }     // переменная (капсула)
    var height: CGFloat { hub.diameter }       // фиксированная
    /// Центр в координатах хоста (для растворения/появления карточек в точку хаба).
    var center: NSPoint { NSPoint(x: hub.frame.midX, y: hub.frame.midY) }

    init() {
        let base = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .large), weight: .semibold)
        let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor,
                          size: base.pointSize) ?? base
        // Диаметр = стандартная высота large-контрола (системная метрика), а не магическое число.
        let sizer = GlassButton(title: "0", a11y: "")
        sizer.borderShape = .circle
        hub = HubView(diameter: ceil(sizer.fittingSize.height), font: font)
    }

    /// Обновить счётчик и озвучку. Потолок «99+» — держит ширину ограниченной и предсказуемой.
    func setState(count: Int, collapsed: Bool) {
        hub.count = count > 99 ? "99+" : "\(count)"
        hub.setAccessibilityValue("\(count)")
        hub.setAccessibilityLabel(collapsed ? "Развернуть скриншоты" : "Свернуть скриншоты")
        hub.setAccessibilityHelp("Нажмите, чтобы развернуть или свернуть трей")
    }

    /// Позиция в координатах хоста.
    func setOrigin(_ p: NSPoint) { hub.setFrameOrigin(p) }
    func show() { hub.isHidden = false }
    func hide() { hub.isHidden = true }
}
