import AppKit
import Darwin

@MainActor
@main
struct HubWindowBehaviorTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)

        run("core click toggles in compact state", testCoreClickTogglesCompact)
        run("core remains clickable after right-edge hover expansion", testRightEdgeExpansionKeepsCoreClickable)
        run("core remains clickable after left-edge hover expansion", testLeftEdgeExpansionKeepsCoreClickable)
        run("action pill click invokes action without toggling tray", testActionClickDoesNotToggle)

        print("HubWindowBehaviorTests: passed")
    }

    private static func run(_ name: String, _ test: () throws -> Void) {
        do {
            try test()
        } catch {
            fputs("HubWindowBehaviorTests: \(name) failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testCoreClickTogglesCompact() throws {
        let harness = Harness(position: .right)

        try harness.click(at: harness.hub.center)

        try require(harness.toggleCount == 1, "Expected compact core click to toggle once, got \(harness.toggleCount)")
        try require(harness.deleteCount == 0, "Core click must not trigger Delete")
    }

    private static func testRightEdgeExpansionKeepsCoreClickable() throws {
        let harness = Harness(position: .right)
        let compactCenter = harness.hub.center
        let compactFrame = harness.hub.view.frame

        harness.hoverHub()

        try require(harness.hub.view.frame.width > compactFrame.width, "Hover must expand the action shell")
        try require(pointsEqual(harness.hub.center, compactCenter),
                    "Core center moved during right-edge expansion: \(harness.hub.center) vs \(compactCenter)")

        try harness.click(at: compactCenter)

        try require(harness.toggleCount == 1, "Expanded right-edge core click should toggle once")
        try require(harness.deleteCount == 0, "Expanded core click must not trigger Delete")
    }

    private static func testLeftEdgeExpansionKeepsCoreClickable() throws {
        let harness = Harness(position: .left)
        let compactCenter = harness.hub.center
        let compactFrame = harness.hub.view.frame

        harness.hoverHub()

        try require(harness.hub.view.frame.width > compactFrame.width, "Hover must expand the action shell")
        try require(pointsEqual(harness.hub.center, compactCenter),
                    "Core center moved during left-edge expansion: \(harness.hub.center) vs \(compactCenter)")

        try harness.click(at: compactCenter)

        try require(harness.toggleCount == 1, "Expanded left-edge core click should toggle once")
        try require(harness.deleteCount == 0, "Expanded core click must not trigger Delete")
    }

    private static func testActionClickDoesNotToggle() throws {
        let harness = Harness(position: .right)

        harness.hoverHub()
        let actionPoint = try harness.firstActionPoint()
        try harness.click(at: actionPoint)

        try require(harness.deleteCount == 1, "Delete action should fire once, got \(harness.deleteCount)")
        try require(harness.toggleCount == 0, "Action click must not toggle tray, got \(harness.toggleCount)")
    }

    private static func pointsEqual(_ a: NSPoint, _ b: NSPoint, tolerance: CGFloat = 0.5) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor
    private final class Harness {
        let window: NSWindow
        let root: NSView
        let hub: HubWindow

        var toggleCount = 0
        var deleteCount = 0
        var saveAsCount = 0
        var copyAllCount = 0

        init(position: TrayPosition) {
            TrayPosition.testCurrent = position

            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
            root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 420))
            root.autoresizingMask = [.width, .height]
            window.contentView = root

            hub = HubWindow()
            hub.onClick = { [weak self] in self?.toggleCount += 1 }
            hub.onDelete = { [weak self] in self?.deleteCount += 1 }
            hub.onSaveAs = { [weak self] in self?.saveAsCount += 1 }
            hub.onCopyAll = { [weak self] in self?.copyAllCount += 1 }
            hub.setState(count: 2, collapsed: false)
            root.addSubview(hub.view)
            hub.setOrigin(NSPoint(x: 300, y: 40))
            hub.show()
            root.layoutSubtreeIfNeeded()
        }

        func hoverHub() {
            hub.view.mouseMoved(with: event(.mouseMoved, at: hub.center))
            root.layoutSubtreeIfNeeded()
        }

        func click(at point: NSPoint) throws {
            let pointInHub = hub.view.convert(point, from: root)
            guard let hit = hub.view.hitTest(pointInHub), hit !== hub.view else {
                throw Failure("No interactive view at \(point)")
            }
            hit.mouseDown(with: event(.leftMouseDown, at: point))
            hit.mouseUp(with: event(.leftMouseUp, at: point))
            root.layoutSubtreeIfNeeded()
        }

        func firstActionPoint() throws -> NSPoint {
            let y = hub.center.y
            var x = hub.view.frame.minX + 2
            while x <= hub.view.frame.maxX - 2 {
                let point = NSPoint(x: x, y: y)
                let pointInHub = hub.view.convert(point, from: root)
                if let hit = hub.view.hitTest(pointInHub),
                   String(describing: type(of: hit)).contains("HubActionPill") {
                    return point
                }
                x += 2
            }
            throw Failure("No action pill hit target found in expanded hub frame \(hub.view.frame)")
        }

        private func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type,
                               location: point,
                               modifierFlags: [],
                               timestamp: 0,
                               windowNumber: window.windowNumber,
                               context: nil,
                               eventNumber: 0,
                               clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)!
        }
    }
}
