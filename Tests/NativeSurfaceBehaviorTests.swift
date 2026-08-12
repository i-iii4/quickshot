import AppKit
import Darwin

@MainActor
@main
struct NativeSurfaceBehaviorTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)

        run("House metrics come from Native SDK", testHouseMetrics)
        run("floating surfaces have transparent canvas gaps", testFloatingSurfaceTransparency)
        run("thumbnail controls fit, hover, and click", testThumbnailControls)
        run("compact thumbnail controls fit and click", testCompactThumbnailControls)
        run("pinned copy control fits, hovers, and clicks", testPinnedControl)
        run("settings controls fit, hover, and dispatch", testSettingsControls)

        print("NativeSurfaceBehaviorTests: passed")
    }

    private static func run(_ name: String, _ test: () throws -> Void) {
        do {
            try test()
        } catch {
            fputs("NativeSurfaceBehaviorTests: \(name) failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testHouseMetrics() throws {
        let expected: [(NativeSDKMetric, CGFloat)] = [
            (.controlHeight, 28),
            (.controlRadius, 8),
            (.controlInset, 10),
            (.iconSide, 16),
            (.iconGap, 6),
            (.buttonFontSize, 14),
            (.groupGap, 8),
            (.shellInset, 6),
            (.bubbleRadius, 14),
            (.animationDurationMilliseconds, 120),
            (.reducedAnimationDurationMilliseconds, 0),
        ]
        for (metric, value) in expected {
            let actual = CGFloat(quickshot_native_ui_metric(metric.rawValue))
            try require(abs(actual - value) <= 0.001,
                        "\(metric) drifted from pinned House tokens: \(actual) != \(value)")
        }
    }

    private static func testFloatingSurfaceTransparency() throws {
        let thumbnail = NativeThumbnailControlsView(frame: .zero)
        _ = Host(view: thumbnail, size: thumbnail.fittingSize)
        let thumbnailButtons = thumbnail.debugButtons().sorted { $0.frame.minX < $1.frame.minX }
        let gap = NSPoint(x: (thumbnailButtons[0].frame.maxX + thumbnailButtons[1].frame.minX) / 2,
                          y: thumbnail.bounds.midY)
        try require(alpha(thumbnail.debugPixel(at: NSPoint(x: 1, y: 1))) == 0,
                    "Thumbnail canvas corner must be transparent")
        try require(alpha(thumbnail.debugPixel(at: gap)) == 0,
                    "Thumbnail canvas gap between buttons must be transparent")
        try require(alpha(thumbnail.debugPixel(at: center(of: thumbnailButtons[0].frame))) > 0,
                    "Thumbnail button pixels must remain visible")

        let pinned = NativePinnedCopyButtonView(frame: .zero)
        _ = Host(view: pinned, size: pinned.fittingSize)
        try require(alpha(pinned.debugPixel(at: NSPoint(x: 1, y: 1))) == 0,
                    "Pinned-control canvas corner must be transparent")
        try require(alpha(pinned.debugPixel(at: center(of: pinned.debugButtons()[0].frame))) > 0,
                    "Pinned button pixels must remain visible")

        let settings = NativeSettingsContentView(frame: .zero)
        _ = Host(view: settings, size: settings.fittingSize)
        try require(alpha(settings.debugPixel(at: NSPoint(x: 1, y: 1))) == 255,
                    "Settings canvas must remain an opaque application surface")
    }

    private static func testThumbnailControls() throws {
        let view = NativeThumbnailControlsView(frame: .zero)
        var copyCount = 0
        var dismissCount = 0
        view.onCopy = { copyCount += 1 }
        view.onDismiss = { dismissCount += 1 }
        let host = Host(view: view, size: view.fittingSize)

        let buttons = view.debugButtons()
        try require(buttons.map(\.title) == ["Copy screenshot", "Dismiss screenshot"],
                    "Unexpected thumbnail controls: \(buttons.map(\.title))")
        try require(buttons.map(\.identifier) == ["Copy screenshot", "Dismiss screenshot"],
                    "Thumbnail identifiers are not stable: \(buttons.map(\.identifier))")
        try requireContainedAndSeparated(buttons, in: view.bounds, context: "thumbnail")

        let copyFrame = buttons.first { $0.title == "Copy screenshot" }!.frame
        let pixelProbes = stride(from: view.bounds.minX, through: view.bounds.maxX - 1, by: 2).flatMap { x in
            stride(from: view.bounds.minY, through: view.bounds.maxY - 1, by: 2).map { y in NSPoint(x: x, y: y) }
        }
        let restPixels = pixelProbes.map(view.debugPixel)
        view.debugHoverButton(title: "Copy screenshot")
        try require(view.debugButtons().filter(\.isHovered).map(\.title) == ["Copy screenshot"],
                    "Native SDK did not own thumbnail hover")
        let hoverPixels = pixelProbes.map(view.debugPixel)
        try require(hoverPixels != restPixels, "Thumbnail hover state did not repaint control pixels")

        let press = try host.press(copyFrame, in: view)
        try require(view.debugButtons().filter(\.isPressed).map(\.title) == ["Copy screenshot"],
                    "Native SDK did not own thumbnail pressed state")
        let pressedPixels = pixelProbes.map(view.debugPixel)
        try require(pressedPixels != hoverPixels, "Thumbnail pressed state did not repaint control pixels")
        host.release(press)
        try require(copyCount == 1 && dismissCount == 0, "Copy click dispatched the wrong thumbnail action")
        try host.click(view.debugButtons().first { $0.title == "Dismiss screenshot" }!.frame, in: view)
        try require(copyCount == 1 && dismissCount == 1, "Dismiss click dispatched the wrong thumbnail action")
    }

    private static func testCompactThumbnailControls() throws {
        let view = NativeThumbnailControlsView(frame: .zero)
        view.setCompact(true)
        var copyCount = 0
        var dismissCount = 0
        view.onCopy = { copyCount += 1 }
        view.onDismiss = { dismissCount += 1 }
        let host = Host(view: view, size: view.fittingSize)
        let buttons = view.debugButtons()

        try require(buttons.map(\.identifier) == ["Copy screenshot", "Dismiss screenshot"],
                    "Compact controls lost their semantic names")
        try requireContainedAndSeparated(buttons, in: view.bounds, context: "compact thumbnail")
        try host.click(buttons[0].frame, in: view)
        try host.click(view.debugButtons()[1].frame, in: view)
        try require(copyCount == 1 && dismissCount == 1, "Compact thumbnail actions are not both clickable")
    }

    private static func testPinnedControl() throws {
        let view = NativePinnedCopyButtonView(frame: .zero)
        var copyCount = 0
        view.onCopy = { copyCount += 1 }
        let host = Host(view: view, size: view.fittingSize)
        let buttons = view.debugButtons()

        try require(buttons.map(\.title) == ["Copy screenshot"], "Pinned surface must expose one Copy button")
        try requireContainedAndSeparated(buttons, in: view.bounds, context: "pinned")
        view.debugHoverButton(title: "Copy screenshot")
        try require(view.debugButtons().first?.isHovered == true, "Native SDK did not own pinned hover")
        try host.click(view.debugButtons()[0].frame, in: view)
        try require(copyCount == 1, "Pinned Copy did not dispatch")
    }

    private static func testSettingsControls() throws {
        let view = NativeSettingsContentView(frame: .zero)
        var selections: [String] = []
        view.onPositionSelected = { selections.append($0) }
        let host = Host(view: view, size: view.fittingSize)
        let expectedTitles = ["Tray left", "Tray right", "Tray bottom", "Tray top"]
        let expectedIdentifiers = ["Tray left", "Tray right", "Tray bottom", "Tray top"]

        try require(view.debugButtons().map(\.title) == expectedTitles, "Unexpected settings controls")
        try require(view.debugButtons().map(\.identifier) == expectedIdentifiers,
                    "Settings identifiers are not stable")
        try requireContainedAndSeparated(view.debugButtons(), in: view.bounds, context: "settings")
        view.debugHoverButton(title: "Tray left")
        try require(view.debugButtons().filter(\.isHovered).map(\.title) == ["Tray left"],
                    "Native SDK did not own settings hover")

        for title in expectedTitles {
            let button = view.debugButtons().first { $0.title == title }!
            try host.click(button.frame, in: view)
        }
        try require(selections == ["left", "right", "bottom", "top"],
                    "Settings dispatch order is wrong: \(selections)")

        let points = [
            NSPoint(x: 1, y: 1),
            NSPoint(x: view.bounds.midX, y: 1),
            NSPoint(x: 1, y: view.bounds.maxY - 1),
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
        ]
        view.debugSetAppearance(dark: false)
        let darkWhileSystemIsLight = points.map(view.debugPixel)
        view.debugSetAppearance(dark: true)
        let dark = points.map(view.debugPixel)
        view.debugSetAppearance(dark: false)
        let restored = points.map(view.debugPixel)
        try require(darkWhileSystemIsLight == dark && dark == restored,
                    "House Dark must remain fixed across system Light/Dark changes")
    }

    private static func requireContainedAndSeparated(_ buttons: [NativeControlDebugButtonSnapshot],
                                                     in bounds: NSRect,
                                                     context: String) throws {
        try require(!buttons.isEmpty, "\(context): no buttons rendered")
        let outer = bounds.insetBy(dx: -0.5, dy: -0.5)
        for button in buttons {
            try require(outer.contains(button.frame),
                        "\(context): \(button.title) escapes \(bounds): \(button.frame)")
            try require(abs(button.frame.height - 28) <= 0.5,
                        "\(context): \(button.title) is not on the House sm register: \(button.frame.height)")
        }
        for leftIndex in buttons.indices {
            for rightIndex in buttons.indices where rightIndex > leftIndex {
                let overlap = buttons[leftIndex].frame.intersection(buttons[rightIndex].frame)
                try require(overlap.isNull || overlap.width <= 0.01 || overlap.height <= 0.01,
                            "\(context): controls overlap: \(buttons[leftIndex].title), \(buttons[rightIndex].title)")
            }
        }
    }

    private static func alpha(_ pixel: UInt32) -> UInt8 {
        UInt8(pixel & 0xff)
    }

    private static func center(of rect: NSRect) -> NSPoint {
        NSPoint(x: rect.midX, y: rect.midY)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor
    private final class Host {
        struct Press {
            let hit: NSView
            let location: NSPoint
        }

        let window: NSWindow
        let root: NSView

        init(view: NSView, size: NSSize) {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            root = NSView(frame: NSRect(origin: .zero, size: size))
            window.contentView = root
            view.frame = root.bounds
            root.addSubview(view)
            root.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
        }

        func click(_ buttonFrame: NSRect, in view: NSView) throws {
            let press = try press(buttonFrame, in: view)
            release(press)
        }

        func press(_ buttonFrame: NSRect, in view: NSView) throws -> Press {
            let point = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
            guard let hit = view.hitTest(point), hit !== view else {
                throw Failure("No interactive Native SDK control at \(point)")
            }
            guard hit.acceptsFirstMouse(for: nil) else {
                throw Failure("Native SDK control does not accept the first click in a non-key panel")
            }
            let location = view.convert(point, to: nil)
            hit.mouseDown(with: event(.leftMouseDown, at: location))
            return Press(hit: hit, location: location)
        }

        func release(_ press: Press) {
            press.hit.mouseUp(with: event(.leftMouseUp, at: press.location))
            root.layoutSubtreeIfNeeded()
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
