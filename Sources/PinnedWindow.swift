import AppKit

/// Содержимое пиннованного окна: полный кадр + Native SDK-кнопка Copy из того же
/// House Dark-регистра, что и контролы карточек/хаба. Закрытие — системными «светофорами» окна и Esc;
/// отдельный крестик не плодим (он дублировал бы traffic-light close). Копирование — ⌘C.
@MainActor
private final class PinnedContentView: NSView {

    private let artifact: CaptureArtifact
    private let artifactStore: CaptureArtifactStore
    private let imageView = NSImageView()
    private let copyButton = NativePinnedCopyButtonView(frame: .zero)
    private var trackingArea: NSTrackingArea?
    var onClose: (() -> Void)?
    private var titleResetWork: DispatchWorkItem?

    init(artifact: CaptureArtifact, artifactStore: CaptureArtifactStore) {
        self.artifact = artifact
        self.artifactStore = artifactStore
        let image = artifact.fullImage() ?? artifact.previewImage
        super.init(frame: .zero)
        wantsLayer = true

        imageView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        copyButton.onCopy = { [weak self] in self?.doCopy() }
        copyButton.toolTip = "Скопировать (⌘C)"
        copyButton.isHidden = true
        addSubview(copyButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?(); return }          // Esc
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            doCopy()
            return
        }
        super.keyDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let inset = QS.s2
        let cs = copyButton.fittingSize
        let h = ceil(cs.height)
        copyButton.frame = NSRect(x: inset, y: bounds.height - h - inset, width: ceil(cs.width), height: h)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()           // после свайпа Spaces окно теряет key и стекло гаснет — оживляем
        copyButton.isHidden = false
    }
    override func mouseExited(with event: NSEvent) { copyButton.isHidden = true }

    private func doCopy() {
        copyButton.isHidden = false
        artifactStore.copy(artifact) { [weak self] in
            self?.publishCopyFeedback()
        }
    }

    private func publishCopyFeedback() {
        copyButton.isHidden = false
        copyButton.showCheck(true)
        titleResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.copyButton.showCheck(false) }
        titleResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

}

/// Полноразмерный кадр в отдельном ресайзибельном always-on-top окне (аналог Pin в
/// CleanShot/Shottr). Открывается даблкликом или кнопкой «развернуть». Удерживает себя сам.
@MainActor
final class PinnedWindowController: NSObject, NSWindowDelegate {

    private static var live = Set<PinnedWindowController>()
    private var window: NSWindow?
    private var artifact: CaptureArtifact?
    private var artifactStore: CaptureArtifactStore?

    static func show(artifact: CaptureArtifact,
                     on screen: NSScreen,
                     artifactStore: CaptureArtifactStore) {
        let c = PinnedWindowController()
        c.build(artifact: artifact, on: screen, artifactStore: artifactStore)
        live.insert(c)
    }

    private func build(artifact: CaptureArtifact,
                       on screen: NSScreen,
                       artifactStore: CaptureArtifactStore) {
        let image = artifact.fullImage() ?? artifact.previewImage
        let scale = max(1, screen.backingScaleFactor)
        let ptW = CGFloat(image.width) / scale
        let ptH = CGFloat(image.height) / scale
        let maxW = screen.visibleFrame.width * 0.7
        let maxH = screen.visibleFrame.height * 0.7
        let k = min(1, min(maxW / max(1, ptW), maxH / max(1, ptH)))
        let w = max(240, (ptW * k).rounded())
        let h = max(160, (ptH * k).rounded())

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "QuickShot — полный кадр"
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.delegate = self
        WindowCaptureProtection.excludeFromScreenCapture(win)

        let content = PinnedContentView(artifact: artifact, artifactStore: artifactStore)
        content.onClose = { [weak win] in win?.performClose(nil) }
        win.contentView = content

        win.center()
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(content)            // Esc/⌘C доходят до контента
        NSApp.activate(ignoringOtherApps: true)
        window = win
        self.artifact = artifact
        self.artifactStore = artifactStore
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        if let artifact {
            artifactStore?.releasePin(artifact)
        }
        artifact = nil
        artifactStore = nil
        Self.live.remove(self)
    }
}
