import AppKit

/// Пункт в строке меню. NSStatusItem остается системной точкой входа, а раскрываемое
/// меню отрисовано Native SDK surface-ом вместо системного AppKit-меню.
@MainActor
final class StatusItemController {

    private let statusItem: NSStatusItem
    private let onCapture: () -> Void
    private let onSettings: () -> Void
    private var menuPanel: NSPanel?
    private var outsideMonitor: Any?

    init(onCapture: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.onCapture = onCapture
        self.onSettings = onSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            WindowCaptureProtection.registerExternalWindow { [weak button] in button?.window }
            // Простой значок камеры.
            button.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "QuickShot")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(toggleMenu)
            if let window = button.window {
                WindowCaptureProtection.excludeFromScreenCapture(window)
            }
        }
    }

    @objc private func toggleMenu() {
        if menuPanel?.isVisible == true {
            hideMenu()
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        let content = NativeStatusMenuContentView(frame: NSRect(origin: .zero,
                                                                size: NSSize(width: 260, height: 184)))
        content.onAction = { [weak self] action in
            guard let self else { return }
            self.hideMenu()
            switch action {
            case .capture:
                self.onCapture()
            case .settings:
                self.onSettings()
            case .access:
                self.openAccessAction()
            case .quit:
                NSApp.terminate(nil)
            }
        }

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: content.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        WindowCaptureProtection.excludeFromScreenCapture(panel)

        if let button = statusItem.button, let window = button.window {
            WindowCaptureProtection.excludeFromScreenCapture(window)
            let buttonFrame = window.convertToScreen(button.frame)
            let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? buttonFrame
            panel.setFrameOrigin(StatusMenuLayout.origin(buttonFrame: buttonFrame,
                                                         menuSize: content.fittingSize,
                                                         visibleFrame: visibleFrame))
        }

        menuPanel = panel
        panel.orderFrontRegardless()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideMenu()
        }
    }

    private func hideMenu() {
        menuPanel?.orderOut(nil)
        menuPanel = nil
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
            self.outsideMonitor = nil
        }
    }

    private func openAccessAction() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
