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
        run("hover expansion keeps core anchored for every tray edge", testExpansionAnchorsEveryTrayEdge)
        run("visible controls stay inside shell bounds", testVisibleControlsStayInsideShellBounds)
        run("intermediate expansion frames stay contained and anchored", testIntermediateExpansionFrames)
        run("action labels are never visibly clipped", testActionLabelsAreNeverVisiblyClipped)
        run("layout metrics stay mathematically consistent", testLayoutMetricsStayConsistent)
        run("action labels stay short and intentional", testActionLabelsStayShort)
        run("compact shell uses one stroke", testCompactShellUsesOneStroke)
        run("blank shell area is inert", testBlankShellAreaIsInert)
        run("action pill click invokes action without toggling tray", testActionClickDoesNotToggle)
        run("interactive action pills click during reveal", testInteractiveActionPillsClickDuringReveal)
        run("action press survives shell mouse exit", testActionPressSurvivesShellMouseExit)
        run("every action pill is clickable in both expansion directions", testEveryActionPillIsClickable)

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

    private static func testEveryActionPillIsClickable() throws {
        for position in [TrayPosition.right, .left] {
            for title in ["Delete", "Save", "Copy"] {
                let harness = Harness(position: position)
                harness.hub.debugSetExpansionProgress(1)
                let point = try harness.actionPoint(title: title)

                try harness.click(at: point)

                try require(harness.toggleCount == 0,
                            "\(position) \(title): action click must not toggle tray")
                switch title {
                case "Delete":
                    try require(harness.deleteCount == 1, "\(position): Delete did not fire")
                    try require(harness.saveAsCount == 0 && harness.copyAllCount == 0,
                                "\(position): Delete fired another action")
                case "Save":
                    try require(harness.saveAsCount == 1, "\(position): Save did not fire")
                    try require(harness.deleteCount == 0 && harness.copyAllCount == 0,
                                "\(position): Save fired another action")
                case "Copy":
                    try require(harness.copyAllCount == 1, "\(position): Copy did not fire")
                    try require(harness.deleteCount == 0 && harness.saveAsCount == 0,
                                "\(position): Copy fired another action")
                default:
                    throw Failure("Unexpected action title \(title)")
                }
            }
        }
    }

    private static func testExpansionAnchorsEveryTrayEdge() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            let compactFrame = harness.hub.view.frame
            let compactCenter = harness.hub.center

            harness.hoverHub()

            let expandedFrame = harness.hub.view.frame
            try require(expandedFrame.width > compactFrame.width, "\(position) did not expand")
            try require(pointsEqual(harness.hub.center, compactCenter),
                        "\(position) moved core center from \(compactCenter) to \(harness.hub.center)")

            if position == .left {
                try require(abs(expandedFrame.minX - compactFrame.minX) <= 0.5,
                            "\(position) should keep shell minX anchored: \(compactFrame) -> \(expandedFrame)")
                try require(expandedFrame.maxX > compactFrame.maxX,
                            "\(position) should expand to the right: \(compactFrame) -> \(expandedFrame)")
            } else {
                try require(abs(expandedFrame.maxX - compactFrame.maxX) <= 0.5,
                            "\(position) should keep shell maxX anchored: \(compactFrame) -> \(expandedFrame)")
                try require(expandedFrame.minX < compactFrame.minX,
                            "\(position) should expand to the left: \(compactFrame) -> \(expandedFrame)")
            }
        }
    }

    private static func testVisibleControlsStayInsideShellBounds() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            try harness.requireVisibleDescendantsInsideShell()

            harness.hoverHub()
            try harness.requireVisibleDescendantsInsideShell()
        }
    }

    private static func testIntermediateExpansionFrames() throws {
        let progressFrames: [CGFloat] = [0, 0.08, 0.18, 0.33, 0.55, 0.78, 1]

        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            let compactFrame = harness.hub.view.frame
            let compactCenter = harness.hub.center

            for progress in progressFrames {
                harness.hub.debugSetExpansionProgress(progress)
                try harness.requireVisibleDescendantsInsideShell()
                try require(pointsEqual(harness.hub.center, compactCenter),
                            "\(position) moved core center at progress \(progress)")

                let frame = harness.hub.view.frame
                if position == .left {
                    try require(abs(frame.minX - compactFrame.minX) <= 0.5,
                                "\(position) minX drifted at progress \(progress): \(compactFrame) -> \(frame)")
                } else {
                    try require(abs(frame.maxX - compactFrame.maxX) <= 0.5,
                                "\(position) maxX drifted at progress \(progress): \(compactFrame) -> \(frame)")
                }
            }
        }
    }

    private static func testActionLabelsAreNeverVisiblyClipped() throws {
        let progressFrames: [CGFloat] = [0, 0.04, 0.08, 0.14, 0.22, 0.33, 0.48, 0.64, 0.78, 0.92, 1]

        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            for progress in progressFrames {
                harness.hub.debugSetExpansionProgress(progress)
                try harness.requireVisibleLabelsAreUnclipped()
            }
        }
    }

    private static func testLayoutMetricsStayConsistent() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            for count in [1, 2, 120] {
                let harness = Harness(position: position, count: count)
                harness.hub.debugSetExpansionProgress(1)
                let snapshot = harness.hub.debugSnapshot()

                try require(abs(snapshot.coreFrame.minY - snapshot.shellInset) <= 0.5,
                            "\(position) count \(count): core Y inset drifted")
                try require(abs(snapshot.coreFrame.height - snapshot.actionClipFrame.height) <= 0.5,
                            "\(position) count \(count): core/action heights differ")
                try require(abs(snapshot.coreCornerRadius - snapshot.coreFrame.height / 2) <= 0.5,
                            "\(position) count \(count): core radius is not half-height")
                try require(abs(snapshot.actionClipCornerRadius - snapshot.actionClipFrame.height / 2) <= 0.5,
                            "\(position) count \(count): clip radius is not half-height")

                let coreActionGap: CGFloat
                if position == .left {
                    coreActionGap = snapshot.actionClipFrame.minX - snapshot.coreFrame.maxX
                } else {
                    coreActionGap = snapshot.coreFrame.minX - snapshot.actionClipFrame.maxX
                }
                try require(abs(coreActionGap - snapshot.groupGap) <= 0.5,
                            "\(position) count \(count): core/action gap \(coreActionGap) != \(snapshot.groupGap)")

                let pills = snapshot.actionPills
                try require(pills.count == 3, "\(position) count \(count): expected 3 action pills")
                for pill in pills {
                    try require(abs(pill.frame.height - snapshot.coreFrame.height) <= 0.5,
                                "\(position) count \(count): \(pill.title) height differs")
                    try require(abs(pill.cornerRadius - pill.frame.height / 2) <= 0.5,
                                "\(position) count \(count): \(pill.title) radius is not half-height")
                    try require(pill.labelAlpha == 1 && pill.isInteractive,
                                "\(position) count \(count): fully expanded \(pill.title) should be visible and interactive")
                }
                for index in 1..<pills.count {
                    let gap = pills[index].frame.minX - pills[index - 1].frame.maxX
                    try require(abs(gap - snapshot.actionGap) <= 0.5,
                                "\(position) count \(count): action gap \(gap) != \(snapshot.actionGap)")
                }
            }
        }
    }

    private static func testActionLabelsStayShort() throws {
        let harness = Harness(position: .right)
        harness.hub.debugSetExpansionProgress(1)
        let titles = harness.hub.debugSnapshot().actionPills.map(\.title)
        try require(titles == ["Delete", "Save", "Copy"], "Unexpected action labels: \(titles)")
        try require(titles.allSatisfy { $0.count <= 6 }, "Action labels must stay compact: \(titles)")
    }

    private static func testCompactShellUsesOneStroke() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            harness.hub.debugSetExpansionProgress(0)
            let snapshot = harness.hub.debugSnapshot()

            try require(abs(snapshot.shellBorderWidth - 1) <= 0.001,
                        "\(position): compact shell must use exactly one layer border")
            try require(snapshot.shellSublayerCount == 0,
                        "\(position): compact shell must not stack decorative ring sublayers")
        }
    }

    private static func testBlankShellAreaIsInert() throws {
        let progressFrames: [CGFloat] = [0.08, 0.18, 0.33]

        for position in [TrayPosition.right, .left, .bottom, .top] {
            let harness = Harness(position: position)
            var checkedPoints = 0
            for progress in progressFrames {
                harness.hub.debugSetExpansionProgress(progress)
                guard let blankPoint = harness.blankShellPoint() else { continue }
                checkedPoints += 1
                harness.dispatchClickIfPossible(at: blankPoint)
                try require(harness.toggleCount == 0,
                            "\(position) progress \(progress): blank shell click toggled tray")
                try require(harness.deleteCount == 0 && harness.saveAsCount == 0 && harness.copyAllCount == 0,
                            "\(position) progress \(progress): blank shell click triggered action")
            }
            try require(checkedPoints > 0, "\(position): no blank shell point was available to test")
        }
    }

    private static func testInteractiveActionPillsClickDuringReveal() throws {
        let progressFrames: [CGFloat] = [0.33, 0.55, 0.78, 0.95]

        for position in [TrayPosition.right, .left, .bottom, .top] {
            var partialTitles = Set<String>()
            for progress in progressFrames {
                for title in ["Delete", "Save", "Copy"] {
                    let harness = Harness(position: position)
                    harness.hub.debugSetExpansionProgress(progress)
                    let snapshot = harness.hub.debugSnapshot()
                    guard snapshot.actionPills.first(where: { $0.title == title })?.isInteractive == true else {
                        continue
                    }

                    let point = try harness.actionPoint(title: title)
                    try harness.click(at: point)
                    partialTitles.insert(title)
                    try requireOnlyAction(title, in: harness, context: "\(position) progress \(progress)")
                }
            }

            try require(partialTitles == Set(["Delete", "Save", "Copy"]),
                        "\(position): every action should become clickable before the fully expanded frame, got \(partialTitles)")
        }
    }

    private static func testActionPressSurvivesShellMouseExit() throws {
        for position in [TrayPosition.right, .left, .bottom, .top] {
            for title in ["Delete", "Save", "Copy"] {
                let harness = Harness(position: position)
                harness.hub.debugSetExpansionProgress(1)
                let point = try harness.actionPoint(title: title)

                try harness.pressThenShellExitAndRelease(at: point)

                try requireOnlyAction(title, in: harness, context: "\(position) \(title)")
            }
        }
    }

    private static func pointsEqual(_ a: NSPoint, _ b: NSPoint, tolerance: CGFloat = 0.5) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    private static func rectContains(_ outer: NSRect, _ inner: NSRect, tolerance: CGFloat = 0.5) -> Bool {
        inner.minX >= outer.minX - tolerance
            && inner.minY >= outer.minY - tolerance
            && inner.maxX <= outer.maxX + tolerance
            && inner.maxY <= outer.maxY + tolerance
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private static func requireOnlyAction(_ title: String, in harness: Harness, context: String) throws {
        try require(harness.toggleCount == 0, "\(context): action click must not toggle tray")
        switch title {
        case "Delete":
            try require(harness.deleteCount == 1, "\(context): Delete did not fire once")
            try require(harness.saveAsCount == 0 && harness.copyAllCount == 0,
                        "\(context): Delete fired another action")
        case "Save":
            try require(harness.saveAsCount == 1, "\(context): Save did not fire once")
            try require(harness.deleteCount == 0 && harness.copyAllCount == 0,
                        "\(context): Save fired another action")
        case "Copy":
            try require(harness.copyAllCount == 1, "\(context): Copy did not fire once")
            try require(harness.deleteCount == 0 && harness.saveAsCount == 0,
                        "\(context): Copy fired another action")
        default:
            throw Failure("\(context): unexpected action title \(title)")
        }
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

        init(position: TrayPosition, count: Int = 2) {
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
            hub.setState(count: count, collapsed: false)
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

        func dispatchClickIfPossible(at point: NSPoint) {
            let pointInHub = hub.view.convert(point, from: root)
            guard let hit = hub.view.hitTest(pointInHub) else { return }
            hit.mouseDown(with: event(.leftMouseDown, at: point))
            hit.mouseUp(with: event(.leftMouseUp, at: point))
            root.layoutSubtreeIfNeeded()
        }

        func pressThenShellExitAndRelease(at point: NSPoint) throws {
            let pointInHub = hub.view.convert(point, from: root)
            guard let hit = hub.view.hitTest(pointInHub), hit !== hub.view else {
                throw Failure("No interactive view at \(point)")
            }

            hit.mouseDown(with: event(.leftMouseDown, at: point))
            hub.view.mouseExited(with: event(.mouseMoved, at: NSPoint(x: -20, y: -20)))
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

        func actionPoint(title: String) throws -> NSPoint {
            let snapshot = hub.debugSnapshot()
            guard let pill = snapshot.actionPills.first(where: { $0.title == title }) else {
                throw Failure("No action pill named \(title)")
            }
            try require(pill.labelAlpha == 1 && pill.isInteractive,
                        "\(title) is not fully visible and interactive")
            let pointInHub = NSPoint(x: snapshot.actionClipFrame.minX + pill.frame.midX,
                                     y: snapshot.actionClipFrame.minY + pill.frame.midY)
            return hub.view.convert(pointInHub, to: root)
        }

        func blankShellPoint() -> NSPoint? {
            let snapshot = hub.debugSnapshot()
            let clip = snapshot.actionClipFrame.insetBy(dx: 2, dy: 2)
            guard clip.width > 0, clip.height > 0 else { return nil }

            var x = clip.minX
            while x <= clip.maxX {
                let pointInHub = NSPoint(x: x, y: clip.midY)
                let hit = hub.view.hitTest(pointInHub)
                if hit == nil || hit === hub.view {
                    return hub.view.convert(pointInHub, to: root)
                }
                x += 2
            }

            return nil
        }

        func requireVisibleDescendantsInsideShell() throws {
            let shellBounds = hub.view.bounds.insetBy(dx: -0.5, dy: -0.5)
            for view in visibleDescendants(of: hub.view) {
                guard let rect = visibleRectInShell(for: view) else { continue }
                try require(rectContains(shellBounds, rect),
                            "\(type(of: view)) visibly escapes shell bounds: \(rect) not inside \(shellBounds)")
            }
        }

        func requireVisibleLabelsAreUnclipped() throws {
            for label in visibleDescendants(of: hub.view) where label is NSTextField && label.alphaValue > 0.01 {
                let fullRect = label.convert(label.bounds, to: hub.view)
                guard let visibleRect = visibleRectInShell(for: label) else {
                    throw Failure("Visible label has no visible rect: \(label)")
                }
                try require(abs(fullRect.width - visibleRect.width) <= 0.5,
                            "Visible label is horizontally clipped: \(visibleRect) of \(fullRect)")
                try require(abs(fullRect.height - visibleRect.height) <= 0.5,
                            "Visible label is vertically clipped: \(visibleRect) of \(fullRect)")
            }
        }

        private func visibleRectInShell(for view: NSView) -> NSRect? {
            var rect = view.convert(view.bounds, to: hub.view)
            var ancestor = view.superview

            while let current = ancestor, current !== hub.view {
                if current.layer?.masksToBounds == true {
                    let clip = current.convert(current.bounds, to: hub.view)
                    rect = rect.intersection(clip)
                    if rect.isNull || rect.width <= 0 || rect.height <= 0 { return nil }
                }
                ancestor = current.superview
            }
            return rect
        }

        private func visibleDescendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { child -> [NSView] in
                guard !child.isHidden, child.alphaValue > 0.01 else { return [] }
                let descendants = visibleDescendants(of: child)
                return [child] + descendants
            }
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
