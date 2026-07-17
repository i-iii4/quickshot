import AppKit
import Darwin

@MainActor
@main
struct ThumbnailCollectionBehaviorTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        run("insertion uses one-axis fade and reaches resting state", testInsertion)
        run("hidden removal never restores an opaque frame", testHiddenRemovalTerminalState)
        run("tray transition preserves the orthogonal card anchor", testAxisLockedTrayTransition)
        print("ThumbnailCollectionBehaviorTests: passed")
    }

    private static func testInsertion() throws {
        let thumbnail = try makeThumbnail()
        let offset = thumbnailCollectionOffset(vertical: true)
        thumbnail.prepareInsertion(at: NSPoint(x: 100, y: 100),
                                   from: offset,
                                   reduceMotion: false)
        let start = thumbnail.debugCollectionSnapshot()
        try require(!start.isHidden && start.alpha <= 0.001,
                    "Insertion must start visible to layout but fully transparent")
        try require(start.translationX == offset.x && start.translationY == offset.y,
                    "Vertical insertion introduced an orthogonal transform")

        thumbnail.applyInsertion(progress: 1, reduceMotion: false)
        thumbnail.finishCollectionMotion()
        let end = thumbnail.debugCollectionSnapshot()
        try require(!end.isHidden && end.alpha == 1,
                    "Insertion did not settle into one canonical visible state")
        try require(end.translationX == 0 && end.translationY == 0,
                    "Insertion retained a transform after completion")
    }

    private static func testHiddenRemovalTerminalState() throws {
        let thumbnail = try makeThumbnail()
        thumbnail.placeInstant(origin: NSPoint(x: 100, y: 100))
        thumbnail.prepareRemoval(toward: thumbnailCollectionOffset(vertical: true), reduceMotion: false)
        thumbnail.applyRemoval(progress: 1, reduceMotion: false)
        let exited = thumbnail.debugCollectionSnapshot()
        try require(exited.alpha == 0,
                    "Removal endpoint must be fully transparent before hiding")

        thumbnail.finishCollectionMotion(hidden: true)
        let terminal = thumbnail.debugCollectionSnapshot()
        try require(terminal.isHidden,
                    "Collapsed acknowledgement remained mounted after exit")
        try require(terminal.alpha == 0,
                    "Hidden completion restored alpha=1 and can flash for one frame")
    }

    private static func testAxisLockedTrayTransition() throws {
        let vertical = try makeThumbnail()
        let verticalOffset = thumbnailTrayTravelOffset(vertical: true)
        vertical.prepareTrayTransition(progress: 0,
                                       travelOffset: verticalOffset,
                                       restingOrigin: NSPoint(x: 100, y: 100),
                                       expanding: false,
                                       reduceMotion: false)
        vertical.applyTrayTransition(progress: 0.5,
                                     travelOffset: verticalOffset,
                                     reduceMotion: false)
        let verticalSnapshot = vertical.debugCollectionSnapshot()
        try require(verticalSnapshot.translationX == 0 && verticalSnapshot.translationY < 0,
                    "Vertical tray transition drifted toward the hub center")

        let horizontal = try makeThumbnail()
        let horizontalOffset = thumbnailTrayTravelOffset(vertical: false)
        horizontal.prepareTrayTransition(progress: 0,
                                         travelOffset: horizontalOffset,
                                         restingOrigin: NSPoint(x: 100, y: 100),
                                         expanding: false,
                                         reduceMotion: false)
        horizontal.applyTrayTransition(progress: 0.5,
                                       travelOffset: horizontalOffset,
                                       reduceMotion: false)
        let horizontalSnapshot = horizontal.debugCollectionSnapshot()
        try require(horizontalSnapshot.translationX > 0 && horizontalSnapshot.translationY == 0,
                    "Horizontal tray transition drifted off its layout axis")
    }

    private static func makeThumbnail() throws -> ThumbnailWindow {
        guard let screen = NSScreen.main else { throw Failure("No screen available") }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil,
                                      width: 320,
                                      height: 180,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 320 * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else {
            throw Failure("Could not create test image")
        }
        return ThumbnailWindow(image: image,
                               screen: screen,
                               manager: ThumbnailManager(),
                               width: 240,
                               screenHeight: screen.frame.height)
    }

    private static func run(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            fputs("ThumbnailCollectionBehaviorTests: \(name) failed: \(error)\n", stderr)
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
