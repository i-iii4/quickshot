import AppKit

/// Окно настроек. Положение трея отрисовано Native SDK surface-ом:
/// `button-group` внутри `.native`, без AppKit segmented/button replica.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var content: NativeSettingsContentView?

    func show() {
        if window == nil { build() }
        syncSelection()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let nativeContent = NativeSettingsContentView(frame: NSRect(origin: .zero,
                                                                    size: NSSize(width: 360, height: 140)))
        nativeContent.onPositionSelected = { rawValue in
            guard let position = TrayPosition(rawValue: rawValue) else { return }
            TrayPosition.set(position)
        }
        content = nativeContent

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "Настройки QuickShot"
        w.isReleasedWhenClosed = false
        w.delegate = self
        WindowCaptureProtection.excludeFromScreenCapture(w)
        w.contentView = nativeContent
        w.setContentSize(nativeContent.fittingSize)
        window = w
    }

    private func syncSelection() {
        content?.setSelectedPosition(TrayPosition.current.rawValue)
    }
}
