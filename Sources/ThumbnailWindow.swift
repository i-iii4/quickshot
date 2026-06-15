import AppKit

/// Панель-миниатюра. nonactivatingPanel позволяет стать key без активации всего
/// приложения, чтобы keyEquivalent (Return/Escape) работали, не воруя фокус грубо.
final class ThumbnailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Миниатюра в правом нижнем углу активного экрана с кнопкой «Копировать».
/// Висит до действия пользователя: «Копировать» (Return) кладёт в буфер и закрывает,
/// крестик или Escape — закрывают без копирования.
final class ThumbnailController: NSObject {

    private let image: CGImage
    private let screen: NSScreen
    private var panel: ThumbnailPanel?
    var onClose: (() -> Void)?

    init(image: CGImage, screen: NSScreen) {
        self.image = image
        self.screen = screen
        super.init()
    }

    func show() {
        let maxW: CGFloat = 240
        let pad: CGFloat = 12
        let buttonH: CGFloat = 30
        let gap: CGFloat = 8

        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let aspect = imgH / max(1, imgW)
        let thumbW = min(maxW, imgW)
        let thumbH = max(1, (thumbW * aspect).rounded())

        let contentW = thumbW + pad * 2
        let contentH = thumbH + pad * 2 + buttonH + gap

        let panel = ThumbnailPanel(
            contentRect: NSRect(x: 0, y: 0, width: contentW, height: contentH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: contentW, height: contentH))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.masksToBounds = true

        let nsImage = NSImage(cgImage: image, size: NSSize(width: imgW, height: imgH))
        let imageView = NSImageView(frame: NSRect(x: pad, y: pad + buttonH + gap,
                                                  width: thumbW, height: thumbH))
        imageView.image = nsImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        container.addSubview(imageView)

        let copyButton = NSButton(frame: NSRect(x: pad, y: pad, width: thumbW, height: buttonH))
        copyButton.title = "Копировать"
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"            // Return = копировать
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        container.addSubview(copyButton)

        let closeButton = NSButton(frame: NSRect(x: contentW - 26, y: contentH - 26,
                                                 width: 20, height: 20))
        closeButton.title = "✕"
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 13, weight: .bold)
        closeButton.keyEquivalent = "\u{1b}"       // Escape = закрыть без копирования
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        container.addSubview(closeButton)

        panel.contentView = container

        // Якорь в правом нижнем углу видимой области экрана (с учётом Dock/строки меню).
        let vf = screen.visibleFrame
        let margin: CGFloat = 16
        panel.setFrameOrigin(NSPoint(x: vf.maxX - contentW - margin,
                                     y: vf.minY + margin))

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    @objc private func copyTapped() {
        Clipboard.copy(cgImage: image)
        close()                                    // копирование закрывает миниатюру
    }

    @objc private func closeTapped() { close() }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        onClose?()
    }
}
