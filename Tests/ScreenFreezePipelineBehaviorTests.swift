import Foundation

@main
struct ScreenFreezePipelineBehaviorTests {
    static func main() {
        run("Mio-style prewarm is tiny", testPrewarmIsTiny)
        run("capture timeout stays bounded", testCaptureTimeoutStaysBounded)
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
        try require(ScreenFreezePipeline.debugPrewarmTimeoutNanoseconds <= 500_000_000,
                    "Prewarm must not turn app launch into a visible capture wait")
    }

    private static func testCaptureTimeoutStaysBounded() throws {
        try require(ScreenFreezePipeline.debugCaptureTimeoutNanoseconds <= 900_000_000,
                    "Fresh freeze capture must fail within a direct-manipulation budget, not after several seconds")
        try require(ScreenFreezePipeline.debugCaptureTimeoutNanoseconds > ScreenFreezePipeline.debugPrewarmTimeoutNanoseconds,
                    "Active capture can spend more time than tiny startup prewarm")
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
