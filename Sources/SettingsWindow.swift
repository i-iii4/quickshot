import AppKit

/// Окно настроек. Контролы отрисованы Native SDK surface-ом: `button-group`
/// внутри `.native`, без AppKit segmented/button replica.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var content: NativeSettingsContentView?
    private weak var library: ScreenshotLibrary?

    func attach(library: ScreenshotLibrary) {
        self.library = library
    }

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
        nativeContent.onRetentionSelected = { [weak self] rawValue in
            guard let retention = ScreenshotRetention(rawValue: rawValue) else { return }
            self?.library?.setRetention(retention)
        }
        nativeContent.onAutosaveChanged = { [weak self] enabled in
            self?.library?.setAutosaveEnabled(enabled)
        }
        nativeContent.onOpenFolder = { [weak self] in
            self?.openFolder()
        }
        // Скрытие блока срока меняет высоту содержимого, и окно обязано
        // следовать за ним, иначе контролы окажутся за краем.
        nativeContent.onFittingSizeChanged = { [weak self] size in
            self?.window?.setContentSize(size)
        }
        content = nativeContent

        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "QuickShot Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        WindowCaptureProtection.excludeFromScreenCapture(w)
        w.contentView = nativeContent
        w.setContentSize(nativeContent.fittingSize)
        window = w
    }

    private func syncSelection() {
        content?.setSelectedPosition(TrayPosition.current.rawValue)
        guard let library else { return }
        content?.setAutosaveEnabled(library.settings.autosaveEnabled)
        content?.setSelectedRetention(library.settings.retention.rawValue)
    }

    /// `ST-11`: быстрый переход к папке. Папка создаётся, если её ещё нет, —
    /// иначе кнопка молча ничего не делает до первого снимка.
    private func openFolder() {
        guard let library else { return }
        let url = library.settings.folderURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
