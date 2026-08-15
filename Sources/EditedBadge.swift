import AppKit

/// Бейдж `Edited` в правом нижнем углу карточки (`ED-3`).
///
/// Признак означает «отличается от захваченного», а не число правок, поэтому у
/// него нет счётчика и он не накапливается (`ED-9`). Бейдж не перехватывает
/// указатель: он сообщает состояние, а не предлагает действие.
@MainActor
final class EditedBadgeView: NSView {
    private static let inset: CGFloat = 6
    private static let horizontalPadding: CGFloat = 6
    private static let verticalPadding: CGFloat = 3

    private let label = NSTextField(labelWithString: "Edited")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 0.92).cgColor
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var intrinsicSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: ceil(size.width) + Self.horizontalPadding * 2,
                      height: ceil(size.height) + Self.verticalPadding * 2)
    }

    /// Положение бейджа внутри карточки: правый нижний угол с отступом.
    static func frame(inCard card: NSRect, badgeSize: NSSize) -> NSRect {
        NSRect(x: card.maxX - badgeSize.width - inset,
               y: card.minY + inset,
               width: badgeSize.width,
               height: badgeSize.height)
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding)
    }
}
