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

    private func runCloseClick(position: TrayPosition) {
        guard let screen = NSScreen.main,
              let image = makeImage(width: 360, height: 220) else {
            failures.append("\(position): cannot create test image")
            return
        }

        let panel = ThumbnailLivePanel(contentRect: NSRect(x: screen.frame.midX - 260,
                                                           y: screen.frame.midY - 170,
                                                           width: 520,
                                                           height: 340),
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered,
                                       defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = false

        let root = TrayHostContentView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))
        panel.contentView = root

        let manager = ThumbnailManager()
        let thumbnail = ThumbnailWindow(image: image,
                                        screen: screen,
                                        manager: manager,
                                        width: 240,
                                        screenHeight: screen.frame.height)
        root.addSubview(thumbnail.hostView)
        thumbnail.configureResize(for: position)
        thumbnail.placeInstant(origin: NSPoint(x: 120, y: 80))
        thumbnail.debugShowControls()
        root.layoutSubtreeIfNeeded()

        panel.orderFrontRegardless()
        panel.makeKey()
        spin(0.05)

        let point = thumbnail.debugCloseButtonCenterInHost()
        let hitBefore = hitDescription(at: point, root: root, thumbnail: thumbnail)
        postMouse(.leftMouseDown, at: point, panel: panel)
        spin(0.02)
        postMouse(.leftMouseUp, at: point, panel: panel)
        spin(0.08)

        if thumbnail.hostView.superview != nil {
            failures.append("\(position): close button did not remove thumbnail; \(hitBefore); \(thumbnail.debugCloseButtonState())")
        }
        panel.orderOut(nil)
        spin(0.03)
    }

    private func runCopyClick(position: TrayPosition) {
        guard let screen = NSScreen.main,
              let image = makeImage(width: 360, height: 220) else {
            failures.append("\(position): cannot create test image")
            return
        }

        let panel = ThumbnailLivePanel(contentRect: NSRect(x: screen.frame.midX - 260,
                                                           y: screen.frame.midY - 170,
                                                           width: 520,
                                                           height: 340),
                                       styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered,
                                       defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = false

        let root = TrayHostContentView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))
        panel.contentView = root

        let manager = ThumbnailManager()
        let thumbnail = ThumbnailWindow(image: image,
                                        screen: screen,
                                        manager: manager,
                                        width: 240,
                                        screenHeight: screen.frame.height)
        root.addSubview(thumbnail.hostView)
        thumbnail.configureResize(for: position)
        thumbnail.placeInstant(origin: NSPoint(x: 120, y: 80))
        thumbnail.debugShowControls()
        root.layoutSubtreeIfNeeded()

        panel.orderFrontRegardless()
        panel.makeKey()
        spin(0.05)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let changeCount = pasteboard.changeCount

        let point = thumbnail.debugCopyButtonCenterInHost()
        let hitBefore = hitDescription(at: point, root: root, thumbnail: thumbnail)
        postMouse(.leftMouseDown, at: point, panel: panel)
        spin(0.02)
        postMouse(.leftMouseUp, at: point, panel: panel)
        spinUntil(0.7) {
            pasteboard.changeCount != changeCount && pasteboard.data(forType: .png) != nil
        }

        if thumbnail.hostView.superview == nil {
            failures.append("\(position): copy button removed thumbnail; \(hitBefore); \(thumbnail.debugCopyButtonState())")
        }
        if pasteboard.changeCount == changeCount || pasteboard.data(forType: .png) == nil {
            failures.append("\(position): copy button did not publish PNG to pasteboard; \(hitBefore); \(thumbnail.debugCopyButtonState())")
        }
        panel.orderOut(nil)
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
        let hostPoint = thumbnail.hostView.convert(rootPoint, from: root)
        let hostHit = thumbnail.hostView.hitTest(hostPoint).map { String(describing: type(of: $0)) } ?? "nil"
        return "rootHit=\(rootHit) hostHit=\(hostHit) windowPoint=\(windowPoint) hostPoint=\(hostPoint) hostFrame=\(thumbnail.hostView.frame)"
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
