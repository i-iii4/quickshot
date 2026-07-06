import Foundation

@main
struct ScreenFreezePipelineBehaviorTests {
    static func main() {
        run("persistent stream has a short fresh-frame deadline", testFreshFrameDeadlineIsShort)
        run("warm streams stay persistent", testWarmStreamsStayPersistent)
        run("stream path accepts complete frames or idle freshness heartbeats", testStreamPathAcceptsFreshCompleteFramesOrIdleHeartbeats)
        run("stream path falls back to latest active stream frame", testLatestActiveStreamFallback)
        run("hot path has no one-shot fallback", testHotPathHasNoOneShotFallback)
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

    private static func testFreshFrameDeadlineIsShort() throws {
        try require(ScreenFreezePipeline.debugFreshFrameDeadlineNanoseconds <= 150_000_000,
                    "Stream-backed capture must keep a short direct-manipulation fresh-frame deadline")
        try require(ScreenFreezePipeline.debugStreamFrameRate >= 60,
                    "Warm stream should target at least 60fps so a post-trigger frame arrives quickly")
    }

    private static func testWarmStreamsStayPersistent() throws {
        try require(ScreenFreezePipeline.debugHasNoIdleStop,
                    "No-half-measures stream mode must not stop warm streams on an idle timer")
        let source = try String(contentsOfFile: "Sources/ScreenFreezePipeline.swift", encoding: .utf8)
        try require(!source.contains("idleStopTask") && !source.contains("streamIdleStopNanoseconds"),
                    "Persistent stream mode must not keep the previous idle-stop implementation")
    }

    private static func testStreamPathAcceptsFreshCompleteFramesOrIdleHeartbeats() throws {
        let source = try String(contentsOfFile: "Sources/ScreenFreezePipeline.swift", encoding: .utf8)
        try require(source.contains("SCStream("),
                    "Freeze pipeline should keep a warm SCStream for low-latency frames")
        try require(source.contains("SCStreamOutput"),
                    "Warm stream frames must be received through SCStreamOutput")
        try require(source.contains("SCFrameStatus(rawValue: statusRawValue)") && source.contains("status == .complete"),
                    "Stream output must capture complete ScreenCaptureKit frames")
        try require(source.contains("status == .idle") && source.contains("recordIdleFrame"),
                    "Stream output must record idle frames as freshness heartbeats")
        try require(source.contains("CMSampleBufferGetImageBuffer"),
                    "Stream output must capture the IOSurface-backed pixel buffer")
        try require(source.contains("frame.receivedAt >= acceptedAfter"),
                    "Freshness gate must reject frames received before the trigger/hide boundary")
        try require(source.contains("idleAt >= acceptedAfter"),
                    "Freshness gate must accept an idle heartbeat after the trigger/hide boundary")
        try require(source.contains("latestIdleHeartbeats"),
                    "Idle heartbeats must be tracked separately from complete pixel buffers")
        try require(source.contains("capture stream fresh frame missed"),
                    "Fresh-frame misses must be observable before fallback")
        try require(source.contains("capture stream frame accepted"),
                    "Accepted stream frames must be observable")
        try require(source.contains("freshness=") && source.contains("pixelAgeMs="),
                    "Accepted frames must log whether freshness came from pixels or an idle heartbeat")
        try require(!source.contains("validatedAt"),
                    "Old validation-age cache semantics must not return")
        try require(!source.contains("preparedFrozenScreens"),
                    "Old prepared frozen screen bridge must not return")
        try require(!source.contains("CachedFrame"),
                    "Old stale-prone CachedFrame model must not return")
    }

    private static func testLatestActiveStreamFallback() throws {
        let source = try String(contentsOfFile: "Sources/ScreenFreezePipeline.swift", encoding: .utf8)
        try require(source.contains("latestActiveStreamFrame(display:"),
                    "Fallback must explicitly require an active stream frame")
        try require(source.contains("guard isWarm(display: display), let frame = latestFrames[display.id]"),
                    "Fallback must use only frames from a warm matching stream")
        try require(source.contains("freshness: .latestActiveStream"),
                    "Latest active stream frames must be distinguishable from post-hide fresh frames")
        try require(source.contains("capture stream latest active frame accepted"),
                    "Latest active stream fallback must be observable in logs")
        try require(source.contains("reason=missing-post-hide-heartbeat"),
                    "Fallback logs must explain that ScreenCaptureKit did not provide a post-hide heartbeat")
    }

    private static func testHotPathHasNoOneShotFallback() throws {
        let source = try String(contentsOfFile: "Sources/ScreenFreezePipeline.swift", encoding: .utf8)
        let captureBody = try functionBody(named: "captureFrozenScreens", in: source, after: "actor ScreenFreezePipeline")
        try require(!captureBody.contains("SCShareableContent.current"),
                    "Hot capture path must not enumerate shareable content")
        try require(!captureBody.contains("SCScreenshotManager.captureImage"),
                    "Hot capture path must not call one-shot screenshot capture")
        try require(!source.contains("SCScreenshotManager.captureImage"),
                    "No-half-measures stream freezer must not keep one-shot fallback")
        try require(!source.contains("capture freeze screens ready source=one-shot"),
                    "One-shot fallback completion token must not remain")
        try require(!source.contains("CaptureImageRace"),
                    "Stream freezer must not reintroduce the old timeout race wrapper")
        try require(!source.contains("excludingDesktopWindows(false, onScreenWindowsOnly: true)"),
                    "Stream freezer should not use the old window-list optimized path")
    }

    private static func functionBody(named name: String, in source: String, after marker: String) throws -> String {
        guard let markerRange = source.range(of: marker) else {
            throw Failure("Missing marker \(marker)")
        }
        let scoped = source[markerRange.upperBound...]
        guard let funcRange = scoped.range(of: "func \(name)(") else {
            throw Failure("Missing function \(name)")
        }
        guard let openBrace = scoped[funcRange.lowerBound...].firstIndex(of: "{") else {
            throw Failure("Missing function body for \(name)")
        }

        var depth = 0
        var end = openBrace
        var current = openBrace
        while current < scoped.endIndex {
            let character = scoped[current]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    end = scoped.index(after: current)
                    break
                }
            }
            current = scoped.index(after: current)
        }
        return String(scoped[openBrace..<end])
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
