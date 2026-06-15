import AppKit

/// Окно настроек. Пока один параметр — положение трея миниатюр (слева/справа/снизу/сверху).
/// Выбор сохраняется в UserDefaults и сразу применяется (через TrayPosition.set).
/// Раскладка — Auto Layout с системными отступами, окно подгоняется под контент.
final class SettingsController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var segmented: NSSegmentedControl?

    // Порядок сегментов соответствует этому массиву.
    private let order: [TrayPosition] = [.left, .right, .bottom, .top]
    private let labels = ["Слева", "Справа", "Снизу", "Сверху"]

    func show() {
        if window == nil { build() }
        syncSelection()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let title = NSTextField(labelWithString: "Положение трея миниатюр")
        title.font = .preferredFont(forTextStyle: .headline)

        let seg = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
                                     target: self, action: #selector(segChanged))
        seg.segmentDistribution = .fillEqually
        segmented = seg

        let hint = NSTextField(wrappingLabelWithString: "Новый снимок появляется у соответствующего угла экрана.")
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, seg, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = QS.s2
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        // Системные края диалога (20pt) и явная ширина сегментов/подсказки.
        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
            seg.widthAnchor.constraint(equalTo: stack.widthAnchor),
            content.widthAnchor.constraint(equalToConstant: 360),
        ])

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Настройки QuickShot"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = content
        w.setContentSize(content.fittingSize)       // окно по контенту, без магических размеров
        window = w
    }

    private func syncSelection() {
        guard let seg = segmented, let idx = order.firstIndex(of: TrayPosition.current) else { return }
        seg.selectedSegment = idx
    }

    @objc private func segChanged() {
        guard let seg = segmented, seg.selectedSegment >= 0, seg.selectedSegment < order.count else { return }
        TrayPosition.set(order[seg.selectedSegment])
    }
}
