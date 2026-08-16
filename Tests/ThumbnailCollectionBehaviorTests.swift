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
        run("drag session pins and restores tray pointer routing", testDragSessionLifecycle)
        run("preview stays large enough for the widest card", testPreviewCoversWidestCard)
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

    private static func testDragSessionLifecycle() throws {
        let fixture = try makeDragFixture()
        guard let payload = fixture.manager.beginDrag(fixture.thumbnail) else {
            throw Failure("Manager rejected a retained screenshot drag")
        }
        try require(fixture.manager.debugActiveDragSessionCount == 0,
                    "Preparing drag data changed routing before AppKit began the session")
        fixture.manager.dragSessionWillBegin(payload)
        try require(fixture.manager.debugActiveDragSessionCount == 1,
                    "Drag start did not pin tray pointer routing")

        fixture.manager.finishDrag(payload)
        try require(fixture.manager.debugActiveDragSessionCount == 0,
                    "Drag completion left tray pointer routing pinned")

        fixture.manager.finishDrag(payload)
        try require(fixture.manager.debugActiveDragSessionCount == 0,
                    "Duplicate drag completion corrupted routing state")
        fixture.manager.shutdown()
        fixture.store.shutdown()
    }

    private static func makeDragFixture() throws -> (
        thumbnail: ThumbnailWindow,
        manager: ThumbnailManager,
        store: CaptureArtifactStore
    ) {
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
        let sequence = CaptureSequence(rawValue: UInt64.random(in: 1...UInt64.max))
        let store = CaptureArtifactStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickShotDragTests-\(UUID().uuidString)"),
            currentPasteboardFiles: { Set<URL>() },
            publishClipboard: { _ in })
        store.registerCapture(sequence)
        let artifact = try store.admit(sequence: sequence, image: image)
        let manager = ThumbnailManager(artifactStore: store)
        let thumbnail = ThumbnailWindow(
            artifact: artifact,
            screen: screen,
            manager: manager,
            width: 240,
            screenHeight: screen.frame.height)
        return (thumbnail, manager, store)
    }

    /// Экономия памяти не имеет права портить картинку: превью обязано быть не
    /// мельче самой широкой карточки в пикселях, иначе растянутая карточка
    /// покажет мыло. Слой при этом волен держать копию под свой текущий
    /// размер — это уже деталь показа, а не источник.
    private static func testPreviewCoversWidestCard() throws {
        guard let screen = NSScreen.main else { throw Failure("No screen available") }
        let scale = screen.backingScaleFactor
        let needed = Int((ThumbStyle.maxWidth * scale).rounded())
        // Исходник заведомо крупнее нужного: проверяется потолок превью, а не
        // размер тестовой картинки.
        let sourceWidth = needed * 3
        let context = CGContext(data: nil, width: sourceWidth, height: sourceWidth * 2 / 3,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        guard let image = context.makeImage() else { throw Failure("Could not create test image") }

        let sequence = CaptureSequence(rawValue: UInt64.random(in: 1...UInt64.max))
        let store = CaptureArtifactStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickShotPreviewTests-\(UUID().uuidString)"),
            currentPasteboardFiles: { Set<URL>() },
            publishClipboard: { _ in })
        store.registerCapture(sequence)
        let artifact = try store.admit(sequence: sequence, image: image)
        let thumbnail = ThumbnailWindow(artifact: artifact,
                                        screen: screen,
                                        manager: ThumbnailManager(artifactStore: store),
                                        width: ThumbStyle.defaultWidth,
                                        screenHeight: screen.frame.height)
        let preview = thumbnail.debugPreviewPixelWidth
        try require(preview >= needed,
                    "превью \(preview) px мельче самой широкой карточки \(needed) px")
        store.shutdown()
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
        let sequence = CaptureSequence(rawValue: UInt64.random(in: 1...UInt64.max))
        let store = CaptureArtifactStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickShotThumbnailTests-\(UUID().uuidString)"),
            currentPasteboardFiles: { Set<URL>() },
            publishClipboard: { _ in })
        store.registerCapture(sequence)
        let artifact = try store.admit(sequence: sequence, image: image)
        return ThumbnailWindow(artifact: artifact,
                               screen: screen,
                               manager: ThumbnailManager(artifactStore: store),
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
