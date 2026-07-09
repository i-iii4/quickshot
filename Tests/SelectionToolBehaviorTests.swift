import AppKit
import Darwin

@MainActor
@main
struct SelectionToolBehaviorTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)

        run("metrics define one cursor-frame system", testMetrics)
        run("crosshair stays stable while dragging", testCrosshairStaysStable)
        run("frame gap continues cursor arms in every drag quadrant", testFrameGapForEveryQuadrant)
        run("small selections keep a clean bounded gap", testSmallSelectionsStayBounded)

        print("SelectionToolBehaviorTests: passed")
    }

    private static func run(_ name: String, _ test: () throws -> Void) {
        do {
            try test()
        } catch {
            fputs("SelectionToolBehaviorTests: \(name) failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testMetrics() throws {
        let metrics = SelectionView.debugMetrics()

        try require(metrics.crosshairSize == 44, "Crosshair size changed unexpectedly")
        try require(metrics.crosshairGap == 4, "Crosshair gap changed unexpectedly")
        try require(metrics.crosshairArm == 9, "Crosshair arm changed unexpectedly")
        try require(metrics.frameSeparator == 5, "Frame separator changed unexpectedly")
        try require(metrics.frameStartOffset == 18, "Frame start offset must be gap + arm + separator")
        try require(metrics.haloWidth == 3.5, "Halo width changed unexpectedly")
        try require(metrics.coreWidth == 1.5, "Core width changed unexpectedly")
        try require(metrics.innerOverlayAlpha == 0.10, "Inner overlay alpha changed unexpectedly")
        try require(metrics.frameSeparator > metrics.haloWidth,
                    "Frame separator must visually separate the cursor caps from the frame")
        try require(metrics.innerOverlayAlpha < 0.16,
                    "Inner overlay must stay lightweight and content-preserving")
    }

    private static func testCrosshairStaysStable() throws {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
        view.debugMoveCrosshair(to: NSPoint(x: 120, y: 140))
        let idle = view.debugSnapshot()

        view.debugBeginAndDrag(from: NSPoint(x: 120, y: 140), to: NSPoint(x: 300, y: 250))
        let dragging = view.debugSnapshot()

        try require(!idle.crosshairHidden, "Crosshair should be visible after move")
        try require(!dragging.crosshairHidden, "Crosshair should remain visible while dragging")
        try require(idle.crosshairBounds == dragging.crosshairBounds,
                    "Crosshair bounds changed during drag: \(idle.crosshairBounds) vs \(dragging.crosshairBounds)")
        try require(dragging.crosshairPosition == CGPoint(x: 300, y: 250),
                    "Crosshair should be anchored at current drag point")

        try require(dragging.crosshairLayers.count == 2,
                    "Crosshair must be exactly halo + core layers, got \(dragging.crosshairLayers.count)")
        let widths = dragging.crosshairLayers.map(\.lineWidth).sorted()
        try require(widths == [1.5, 3.5], "Crosshair stroke widths changed: \(widths)")
        try require(dragging.crosshairLayers.allSatisfy { $0.lineCap == .round },
                    "Crosshair layers must use round caps")
        try require(dragging.crosshairLayers.allSatisfy { $0.bounds.width == 44 && $0.bounds.height == 44 },
                    "Crosshair shape layer bounds must remain fixed at 44x44")
    }

    private static func testFrameGapForEveryQuadrant() throws {
        let start = NSPoint(x: 200, y: 160)
        let samples: [(current: NSPoint, expected: [NSPoint])] = [
            (NSPoint(x: 320, y: 260),
             [NSPoint(x: 302, y: 260), NSPoint(x: 200, y: 260), NSPoint(x: 200, y: 160),
              NSPoint(x: 320, y: 160), NSPoint(x: 320, y: 242)]),
            (NSPoint(x: 90, y: 260),
             [NSPoint(x: 90, y: 242), NSPoint(x: 90, y: 160), NSPoint(x: 200, y: 160),
              NSPoint(x: 200, y: 260), NSPoint(x: 108, y: 260)]),
            (NSPoint(x: 320, y: 80),
             [NSPoint(x: 320, y: 98), NSPoint(x: 320, y: 160), NSPoint(x: 200, y: 160),
              NSPoint(x: 200, y: 80), NSPoint(x: 302, y: 80)]),
            (NSPoint(x: 90, y: 80),
             [NSPoint(x: 108, y: 80), NSPoint(x: 200, y: 80), NSPoint(x: 200, y: 160),
              NSPoint(x: 90, y: 160), NSPoint(x: 90, y: 98)]),
        ]

        for sample in samples {
            let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 500, height: 360))
            view.debugBeginAndDrag(from: start, to: sample.current)
            let snapshot = view.debugSnapshot()

            try require(snapshot.outlinePoints.count == sample.expected.count,
                        "Unexpected outline point count for current \(sample.current): \(snapshot.outlinePoints)")
            for (actual, expected) in zip(snapshot.outlinePoints, sample.expected) {
                try require(pointsEqual(actual, expected),
                            "Expected outline point \(expected), got \(actual) for current \(sample.current)")
            }
        }
    }

    private static func testSmallSelectionsStayBounded() throws {
        let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        view.debugBeginAndDrag(from: NSPoint(x: 40, y: 40), to: NSPoint(x: 52, y: 51))
        let snapshot = view.debugSnapshot()

        try require(snapshot.currentRect.width == 12 && snapshot.currentRect.height == 11,
                    "Unexpected small selection rect: \(snapshot.currentRect)")
        try require(snapshot.outlinePoints.allSatisfy { snapshot.currentRect.insetBy(dx: -0.001, dy: -0.001).contains($0) },
                    "Small-selection outline escaped its rect: \(snapshot.outlinePoints)")
    }

    private static func pointsEqual(_ a: NSPoint, _ b: NSPoint, epsilon: CGFloat = 0.001) -> Bool {
        abs(a.x - b.x) <= epsilon && abs(a.y - b.y) <= epsilon
    }
}

private enum TestError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestError.failed(message) }
}
