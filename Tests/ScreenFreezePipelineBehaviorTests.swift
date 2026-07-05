import Foundation

@main
struct ScreenFreezePipelineBehaviorTests {
    static func main() {
        run("Mio-style prewarm is tiny", testPrewarmIsTiny)
        run("full-display capture uses Mio ScreenCaptureKit path", testFullDisplayCaptureUsesMioPath)
        run("display batch stays capped", testDisplayBatchStaysCapped)
        print("ScreenFreezePipelineBehaviorTests: passed")
    }

    private static func run(_ name: String, _ test: () throws -> Void) {
        do {
            try test()
        } catch {
            fputs("ScreenFreezePipelineBehaviorTests: \(name) failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testPrewarmIsTiny() throws {
        try require(ScreenFreezePipeline.debugPrewarmPixelSize == 2,
                    "Prewarm must keep Mio's tiny 2x2 ScreenCaptureKit warmup")
    }

    private static func testFullDisplayCaptureUsesMioPath() throws {
        let source = try String(contentsOfFile: "Sources/ScreenFreezePipeline.swift", encoding: .utf8)
        try require(source.contains("SCShareableContent.current"),
                    "Full-display freeze should use Mio's SCShareableContent.current path")
        try require(source.contains("SCScreenshotManager.captureImage"),
                    "Full-display freeze should use SCScreenshotManager.captureImage directly")
        try require(!source.contains("CaptureImageRace"),
                    "Mio-style full-display capture must not use the hybrid timeout race wrapper")
        try require(!source.contains("excludingDesktopWindows(false, onScreenWindowsOnly: true)"),
                    "Full-display freeze should not use the window-list optimized path as its primary display path")
    }

    private static func testDisplayBatchStaysCapped() throws {
        try require(ScreenFreezePipeline.debugCaptureBatchSize == 3,
                    "Full-display captures should keep Mio's explicit batch cap of 3")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
