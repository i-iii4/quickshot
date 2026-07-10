import AppKit
import Darwin

@main
struct ThumbnailLayoutTests {
    static func main() {
        run("append preserves every existing slot", testAppendPreservesExistingSlots)
        run("newest card grows away from hub", testNewestGrowsAwayFromHub)
        run("overflow does not displace visible cards", testOverflowDoesNotDisplaceVisibleCards)
        print("ThumbnailLayoutTests: passed")
    }

    private static let baseFrame = NSRect(x: 0, y: 0, width: 1200, height: 900)
    private static let hub = NSSize(width: 132, height: 40)

    private static func layout(_ edge: ThumbnailLayoutEdge,
                               heights: [CGFloat],
                               frame: NSRect = baseFrame) -> ThumbnailLayoutResult {
        thumbnailLayout(screenFrame: frame,
                        edge: edge,
                        cardWidth: 240,
                        cardHeights: heights,
                        hubSize: hub,
                        margin: 16,
                        gap: 12)
    }

    private static func testAppendPreservesExistingSlots() throws {
        for edge in ThumbnailLayoutEdge.allCases {
            let before = layout(edge, heights: [120, 140])
            let after = layout(edge, heights: [120, 140, 160])
            try require(Array(after.visible.prefix(2)) == before.visible,
                        "\(edge): appending changed existing slots: \(before.visible) -> \(after.visible)")
            try require(after.visible.last?.index == 2, "\(edge): newest index did not take the new slot")
        }
    }

    private static func testNewestGrowsAwayFromHub() throws {
        for edge in ThumbnailLayoutEdge.allCases {
            let slots = layout(edge, heights: [120, 140, 160]).visible
            guard let previous = slots.dropLast().last, let newest = slots.last else {
                throw Failure("\(edge): missing layout slots")
            }
            if edge.isVertical {
                try require(newest.origin.y > previous.origin.y,
                            "\(edge): newest card must occupy the upper free slot")
            } else {
                try require(newest.origin.x < previous.origin.x,
                            "\(edge): newest card must occupy the free slot left of the row")
            }
        }
    }

    private static func testOverflowDoesNotDisplaceVisibleCards() throws {
        let smallFrame = NSRect(x: 0, y: 0, width: 600, height: 360)
        let before = layout(.right, heights: [100, 100], frame: smallFrame)
        let after = layout(.right, heights: [100, 100, 100], frame: smallFrame)
        try require(after.visible == before.visible,
                    "Appending beyond capacity displaced visible cards")
        try require(after.hidden == [2], "Newest overflowing card must be hidden without reflow")
    }

    private static func run(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            fputs("ThumbnailLayoutTests: \(name) failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
