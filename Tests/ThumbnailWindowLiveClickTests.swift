import AppKit
import CoreGraphics

private final class ThumbnailLivePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class ThumbnailWindowLiveClickTests: NSObject, NSApplicationDelegate {
    private var failures: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        run()
        NSApp.terminate(nil)
    }

    private func run() {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            TrayPosition.set(position)
            runCloseClick(position: position)
            runCopyClick(position: position)
        }

        if failures.isEmpty {
            print("ThumbnailWindowLiveClickTests: passed")
        } else {
            failures.forEach { fputs("ThumbnailWindowLiveClickTests: \($0)\n", stderr) }
            exit(1)
        }
    }

    /// Реальный поток: менеджер сам создаёт карточку в своём окне-хосте,
    /// клик уходит через sendEvent этого окна, буфер обмена — настоящий.
    private func makeFixture(position: TrayPosition)
        -> (manager: ThumbnailManager, store: CaptureArtifactStore, thumbnail: ThumbnailWindow, host: NSWindow)? {
        guard let screen = NSScreen.main, let image = makeImage(width: 360, height: 220) else {
            failures.append("\(position): cannot create test image")
            return nil
        }
        let sequence = CaptureSequence(rawValue: UInt64.random(in: 1...UInt64.max))
        let store = CaptureArtifactStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickShotLiveClickTests-\(UUID().uuidString)"))
        store.registerCapture(sequence)
        guard let artifact = try? store.admit(sequence: sequence, image: image) else {
            failures.append("\(position): cannot admit test artifact")
            return nil
        }
        let manager = ThumbnailManager(artifactStore: store)
        manager.add(artifact: artifact, on: screen)
        guard let thumbnail = manager.debugThumbnail(for: artifact.id),
              let host = thumbnail.hostView.window else {
            failures.append("\(position): manager did not present the card")
            manager.shutdown()
            store.shutdown()
            return nil
        }
        // Окно хоста в тестовой сессии может числиться occluded — display-link
        // тогда не тикает; анимации достраиваются явно.
        manager.debugFinishMotions()
        spinUntil(0.5) { thumbnail.hostView.alphaValue > 0.99 }
        if thumbnail.hostView.alphaValue < 0.99 {
            failures.append("\(position): card never faded in (alpha=\(thumbnail.hostView.alphaValue))")
        }
        thumbnail.debugShowControls()
        thumbnail.hostView.superview?.layoutSubtreeIfNeeded()
        spin(0.05)
        return (manager, store, thumbnail, host)
    }

    private func runCloseClick(position: TrayPosition) {
        guard let fixture = makeFixture(position: position) else { return }
        let (manager, store, thumbnail, host) = fixture

        let inWindow = thumbnail.debugCloseButtonCenterInHost()
        let hitBefore = hitDescription(at: inWindow, root: host.contentView!, thumbnail: thumbnail)
        postMouse(.leftMouseDown, at: inWindow, panel: host)
        spin(0.02)
        postMouse(.leftMouseUp, at: inWindow, panel: host)
        spinUntil(1.2) {
            manager.debugFinishMotions()
            return thumbnail.hostView.superview == nil
        }

        if thumbnail.hostView.superview != nil {
            failures.append("\(position): close button did not remove thumbnail; \(hitBefore); \(thumbnail.debugCloseButtonState())")
        }
        manager.shutdown()
        store.shutdown()
        spin(0.03)
    }

    private func runCopyClick(position: TrayPosition) {
        guard let fixture = makeFixture(position: position) else { return }
        let (manager, store, thumbnail, host) = fixture

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let changeCount = pasteboard.changeCount

        let inWindow = thumbnail.debugCopyButtonCenterInHost()
        let hitBefore = hitDescription(at: inWindow, root: host.contentView!, thumbnail: thumbnail)
        postMouse(.leftMouseDown, at: inWindow, panel: host)
        spin(0.02)
        postMouse(.leftMouseUp, at: inWindow, panel: host)
        spinUntil(1.5) {
            pasteboard.changeCount != changeCount && pasteboard.data(forType: .png) != nil
        }

        if thumbnail.hostView.superview == nil {
            failures.append("\(position): copy button removed thumbnail; \(hitBefore); \(thumbnail.debugCopyButtonState())")
        }
        if pasteboard.changeCount == changeCount || pasteboard.data(forType: .png) == nil {
            failures.append("\(position): copy button did not publish PNG to pasteboard; \(hitBefore); \(thumbnail.debugCopyButtonState())")
        }
        manager.shutdown()
        store.shutdown()
        spin(0.03)
    }

    private func postMouse(_ type: NSEvent.EventType, at windowPoint: NSPoint, panel: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: type,
                                             location: windowPoint,
                                             modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber,
                                             context: nil,
                                             eventNumber: 0,
                                             clickCount: 1,
                                             pressure: type == .leftMouseDown ? 1 : 0) else { return }
        panel.sendEvent(event)
    }

    private func hitDescription(at windowPoint: NSPoint,
                                root: NSView,
                                thumbnail: ThumbnailWindow) -> String {
        let rootPoint = root.convert(windowPoint, from: nil)
        let rootHit = root.hitTest(rootPoint).map { String(describing: type(of: $0)) } ?? "nil"
        // hitTest ждёт координаты СУПЕРВЬЮ цели: для hostView это root.
        let hostHit = thumbnail.hostView.hitTest(rootPoint).map { String(describing: type(of: $0)) } ?? "nil"
        let children = root.subviews.map {
            "\(type(of: $0))@\($0.frame) hidden=\($0.isHidden) alpha=\($0.alphaValue)"
        }.joined(separator: "; ")
        return "rootHit=\(rootHit) hostHit=\(hostHit) windowPoint=\(windowPoint) rootBounds=\(root.bounds) rootPoint=\(rootPoint) hostFrame=\(thumbnail.hostView.frame) children=[\(children)]"
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.18, green: 0.62, blue: 0.34, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func spinUntil(_ timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

@main
private struct ThumbnailWindowLiveClickRunner {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = ThumbnailWindowLiveClickTests()
        app.delegate = delegate
        app.run()
    }
}
