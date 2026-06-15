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
