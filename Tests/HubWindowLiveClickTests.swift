import AppKit
import QuartzCore

enum TrayPosition: String {
    case right, left, bottom, top

    var isVertical: Bool { self == .right || self == .left }

    @MainActor static var testCurrent: TrayPosition = .right
    @MainActor static var current: TrayPosition { testCurrent }
}

private func liveEaseOutCubic(_ f: CGFloat) -> CGFloat { 1 - pow(1 - f, 3) }

@MainActor
final class FrameAnimator: NSObject {
    private weak var hostView: NSView?
    private var link: CADisplayLink?
    private var begin: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var easing: (CGFloat) -> CGFloat = liveEaseOutCubic
    private var onFrame: ((CGFloat) -> Void)?
    private var onDone: (() -> Void)?

    init(hostView: NSView) { self.hostView = hostView; super.init() }

    func run(duration: CFTimeInterval,
             delay: CFTimeInterval,
             easing: @escaping (CGFloat) -> CGFloat,
             onFrame: @escaping (CGFloat) -> Void,
             onDone: (() -> Void)? = nil) {
        cancel()
        self.duration = duration
        self.easing = easing
        self.onFrame = onFrame
        self.onDone = onDone
        begin = CACurrentMediaTime() + delay
        guard let hostView else { return }
        let displayLink = hostView.displayLink(target: self, selector: #selector(step(_:)))
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
    }

    @objc private func step(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard now >= begin else { return }
        let t = duration <= 0 ? 1 : min(1, (now - begin) / duration)
        onFrame?(easing(CGFloat(t)))
        if t >= 1 {
            let done = onDone
            cancel()
            done?()
        }
    }

    func cancel() {
        link?.invalidate()
        link = nil
        onFrame = nil
        onDone = nil
    }

    // `cancel()` уже инвалидировал линк при завершении; деинициализация на
    // MainActor-классе не может трогать не-Sendable поле — и не обязана:
    // тестовый аниматор всегда доигрывает до конца или отменяется явно.
}

private final class LiveClickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class HubWindowLiveClickTests: NSObject, NSApplicationDelegate {
    private var failures: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        run()
        NSApp.terminate(nil)
    }

    private func run() {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            for title in ["Close", "Save As", "Copy All"] {
                runLiveClick(position: position, title: title)
            }
        }

        if failures.isEmpty {
            print("HubWindowLiveClickTests: passed")
        } else {
            failures.forEach { fputs("HubWindowLiveClickTests: \($0)\n", stderr) }
            exit(1)
        }
    }

    private func runLiveClick(position: TrayPosition, title: String) {
        guard let screen = NSScreen.main else {
            failures.append("no main screen")
            return
        }

        let panelWidth: CGFloat = 960
        let panelHeight: CGFloat = 240
        TrayPosition.testCurrent = position
        let panel = LiveClickPanel(contentRect: NSRect(x: screen.frame.midX - panelWidth / 2,
                                                       y: screen.frame.midY - panelHeight / 2,
                                                       width: panelWidth,
                                                       height: panelHeight),
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered,
                                   defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let root = TrayHostContentView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight))
        panel.contentView = root

        let hub = HubWindow()
        var deleteCount = 0
        var saveCount = 0
        var copyCount = 0
        hub.onDelete = { deleteCount += 1 }
        hub.onSaveAs = { saveCount += 1 }
        hub.onCopyAll = { copyCount += 1 }
        hub.setState(count: 2, collapsed: false)
        root.addSubview(hub.view)
        hub.setOrigin(NSPoint(x: floor((panelWidth - hub.width) / 2), y: 100))
        hub.show()
        root.layoutSubtreeIfNeeded()

        panel.orderFrontRegardless()
        panel.makeKey()
        spin(0.08)

        hub.debugSetExpansionProgress(1)
        root.layoutSubtreeIfNeeded()

        guard let actionPoint = actionWindowPoint(title: title, hub: hub) else {
            failures.append("\(position) \(title): action point not visible/interactable after hover")
            panel.orderOut(nil)
            return
        }

        postMouse(.mouseMoved, at: actionPoint, panel: panel)
        spin(0.03)
        postMouse(.leftMouseDown, at: actionPoint, panel: panel)
        spin(0.03)
        postMouse(.leftMouseUp, at: actionPoint, panel: panel)
        spin(0.12)

        let counts = ["Close": deleteCount, "Save As": saveCount, "Copy All": copyCount]
        if counts[title] != 1 {
            failures.append("\(position) \(title): expected one live click callback, got \(counts); \(hitDescription(atWindowPoint: actionPoint, root: root, hub: hub))")
        }
        let otherCallbacks = counts.filter { $0.key != title }.values.reduce(0, +)
        if otherCallbacks != 0 {
            failures.append("\(position) \(title): live click fired wrong callback, got \(counts)")
        }
        panel.orderOut(nil)
        spin(0.04)
    }

    private func actionWindowPoint(title: String, hub: HubWindow) -> NSPoint? {
        let snapshot = hub.debugSnapshot()
        guard let pill = snapshot.actionPills.first(where: { $0.title == title }),
              pill.labelAlpha == 1,
              pill.isInteractive else { return nil }
        let pointInHub = NSPoint(x: snapshot.actionClipFrame.minX + pill.frame.midX,
                                 y: snapshot.actionClipFrame.minY + pill.frame.midY)
        return hub.view.convert(pointInHub, to: nil)
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

    private func hitDescription(atWindowPoint windowPoint: NSPoint, root: NSView, hub: HubWindow) -> String {
        let rootPoint = root.convert(windowPoint, from: nil)
        let rootHitView = root.hitTest(rootPoint)
        let rootHit = rootHitView.map { view in
            if view === root { return "root" }
            if view === hub.view { return "hub.view" }
            return String(describing: type(of: view))
        } ?? "nil"
        let hubPoint = hub.view.convert(rootPoint, from: root)
        let hubHit = hub.view.hitTest(hubPoint).map { String(describing: type(of: $0)) } ?? "nil"
        return "rootHit=\(rootHit) hubHit=\(hubHit) windowPoint=\(windowPoint) rootPoint=\(rootPoint) hubPoint=\(hubPoint) hubFrame=\(hub.view.frame) hubHidden=\(hub.view.isHidden)"
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

@main
private struct HubWindowLiveClickRunner {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = HubWindowLiveClickTests()
        app.delegate = delegate
        app.run()
    }
}
