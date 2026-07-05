import Foundation

@main
struct ScreenFrameCacheBehaviorTests {
    static func main() {
        run("pre-request stream frame is rejected", testPreRequestStreamFrameIsRejected)
        run("validated pre-request stream frame is rejected", testValidatedPreRequestStreamFrameIsRejected)
        run("static validation keeps its pixel-age ceiling", testStaticValidationKeepsPixelAgeCeiling)
        run("post-request frame is accepted", testPostRequestFrameIsAccepted)
        run("pre-request prepared frozen screen is rejected", testPreRequestPreparedFrozenScreenIsRejected)
        run("post-request prepared frozen screen is accepted", testPostRequestPreparedFrozenScreenIsAccepted)
        run("prepared frozen screen expires after bridge window", testPreparedFrozenScreenExpiresAfterBridgeWindow)
        run("snapshot fallback waits behind stream validation", testSnapshotFallbackWaitsBehindStreamValidation)
        run("rect snapshot recovery stays hot-path bounded", testRectSnapshotRecoveryStaysHotPathBounded)
        run("shareable display failure cooldown gates repeated enumeration", testShareableDisplayFailureCooldownGatesRepeatedEnumeration)
        run("rect snapshot failure cooldown gates repeated recovery", testRectSnapshotFailureCooldownGatesRepeatedRecovery)
        run("maintenance frame request starts before stream becomes suspect", testMaintenanceFrameRequestStartsBeforeStreamBecomesSuspect)
        run("stream restart waits for suspect frame age", testStreamRestartWaitsForSuspectFrameAge)
        print("ScreenFrameCacheBehaviorTests: passed")
    }

    private static func run(_ name: String, _ test: () throws -> Void) {
        do {
            try test()
        } catch {
            fputs("ScreenFrameCacheBehaviorTests: \(name) failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testPreRequestStreamFrameIsRejected() throws {
        let now: TimeInterval = 100
        let requestedAt = now
        let updatedAt = now - 0.01
        try require(!ScreenFrameCache.debugShouldServeCachedFrame(updatedAt: updatedAt,
                                                                  requestedAt: requestedAt,
                                                                  now: now),
                    "A stream frame produced before the capture request must not become the screenshot source")
        try require(ScreenFrameCache.debugCachedFrameAcceptance(updatedAt: updatedAt,
                                                                requestedAt: requestedAt,
                                                                now: now) == nil,
                    "A pre-request stream frame must have no acceptance reason")
    }

    private static func testValidatedPreRequestStreamFrameIsRejected() throws {
        let now: TimeInterval = 100
        let requestedAt = now
        let updatedAt = now - 1.0
        let validatedAt = now - 0.1
        try require(ScreenFrameCache.debugShouldValidateStaticFrame(updatedAt: updatedAt, now: now),
                    "A recent pixel buffer may still be valid for maintenance decisions")
        try require(!ScreenFrameCache.debugShouldServeCachedFrame(updatedAt: updatedAt,
                                                                  validatedAt: validatedAt,
                                                                  requestedAt: requestedAt,
                                                                  now: now),
                    "Static-stream validation must not authorize pre-request pixels for active capture")
        try require(ScreenFrameCache.debugCachedFrameAcceptance(updatedAt: updatedAt,
                                                                validatedAt: validatedAt,
                                                                requestedAt: requestedAt,
                                                                now: now) == nil,
                    "Validation-backed pre-request pixels must have no acceptance reason")
    }

    private static func testStaticValidationKeepsPixelAgeCeiling() throws {
        let now: TimeInterval = 100
        let updatedAt = now - ScreenFrameCache.debugValidatedFrameMaxPixelAge - 0.01
        try require(!ScreenFrameCache.debugShouldValidateStaticFrame(updatedAt: updatedAt, now: now),
                    "A too-old pixel buffer must not be renewed by validation alone")
    }

    private static func testPostRequestFrameIsAccepted() throws {
        let now: TimeInterval = 100
        let requestedAt = now - 0.05
        let updatedAt = now - 0.02
        try require(ScreenFrameCache.debugShouldServeCachedFrame(updatedAt: updatedAt,
                                                                 requestedAt: requestedAt,
                                                                 now: now),
                    "A frame delivered after the current capture request must be accepted")
        try require(ScreenFrameCache.debugCachedFrameAcceptance(updatedAt: updatedAt,
                                                                requestedAt: requestedAt,
                                                                now: now) == "post-request",
                    "A frame delivered after the request must be explicitly classified as post-request")
    }

    private static func testPreRequestPreparedFrozenScreenIsRejected() throws {
        let now: TimeInterval = 100
        let requestedAt = now
        let updatedAt = now - 0.01
        try require(!ScreenFrameCache.debugShouldServePreparedFrozenScreen(updatedAt: updatedAt,
                                                                           requestedAt: requestedAt,
                                                                           now: now),
                    "A prepared image produced before the request must not become the screenshot source")
    }

    private static func testPostRequestPreparedFrozenScreenIsAccepted() throws {
        let now: TimeInterval = 100
        let requestedAt = now - 0.05
        let updatedAt = now - 0.02
        try require(ScreenFrameCache.debugShouldServePreparedFrozenScreen(updatedAt: updatedAt,
                                                                          requestedAt: requestedAt,
                                                                          now: now),
                    "A prepared image produced after the current capture request must be accepted")
    }

    private static func testPreparedFrozenScreenExpiresAfterBridgeWindow() throws {
        let now: TimeInterval = 100
        let recent = now - ScreenFrameCache.debugPreparedFrozenScreenRetentionAge + 0.01
        let old = now - ScreenFrameCache.debugPreparedFrozenScreenRetentionAge - 0.01
        try require(!ScreenFrameCache.debugShouldExpirePreparedFrozenScreen(updatedAt: recent, now: now),
                    "A prepared image must remain retained inside the retention window")
        try require(ScreenFrameCache.debugShouldExpirePreparedFrozenScreen(updatedAt: old, now: now),
                    "A prepared image must be removed after the retention window")
    }

    private static func testSnapshotFallbackWaitsBehindStreamValidation() throws {
        try require(ScreenFrameCache.debugStreamSnapshotDelayNanoseconds
                    > ScreenFrameCache.debugRefreshEscalationDelayNanoseconds,
                    "One-shot snapshot fallback must not start before the stream validation grace can finish")
        try require(ScreenFrameCache.debugStreamSnapshotDelayNanoseconds <= 600_000_000,
                    "Snapshot fallback should remain bounded so a truly missing stream fails visibly")
    }

    private static func testRectSnapshotRecoveryStaysHotPathBounded() throws {
        try require(ScreenFrameCache.debugRectSnapshotTimeoutNanoseconds <= 700_000_000,
                    "Rect snapshot recovery runs on the active capture path and must not recreate a 2-3 second mouse-up delay")
        try require(ScreenFrameCache.debugRectSnapshotTimeoutNanoseconds
                    > ScreenFrameCache.debugStreamSnapshotDelayNanoseconds,
                    "Rect snapshot recovery should still give the stream-validation grace a chance before timing out")
        try require(ScreenFrameCache.debugRectSnapshotProbeJoinNanoseconds <= 150_000_000,
                    "Active capture may join an in-flight health probe only briefly")
        try require(ScreenFrameCache.debugRectSnapshotProbeJoinNanoseconds
                    < ScreenFrameCache.debugRectSnapshotTimeoutNanoseconds,
                    "Probe join must be shorter than starting a duplicate rect snapshot fallback")
    }

    private static func testRectSnapshotFailureCooldownGatesRepeatedRecovery() throws {
        let now: TimeInterval = 100
        let recent = now - ScreenFrameCache.debugRectSnapshotFailureCooldown + 0.01
        let expired = now - ScreenFrameCache.debugRectSnapshotFailureCooldown - 0.01
        try require(ScreenFrameCache.debugHasRecentRectSnapshotFailure(updatedAt: recent, now: now),
                    "A recent rect snapshot failure must suppress repeated active-path fallback attempts")
        try require(!ScreenFrameCache.debugHasRecentRectSnapshotFailure(updatedAt: expired, now: now),
                    "Rect snapshot recovery must be allowed to retry after the cooldown")
    }

    private static func testShareableDisplayFailureCooldownGatesRepeatedEnumeration() throws {
        let now: TimeInterval = 100
        let recent = now - ScreenFrameCache.debugShareableDisplayFailureCooldown + 0.01
        let expired = now - ScreenFrameCache.debugShareableDisplayFailureCooldown - 0.01
        try require(ScreenFrameCache.debugHasRecentShareableDisplayFailure(updatedAt: recent, now: now),
                    "A recent empty display listing must suppress repeated SCShareableContent enumeration")
        try require(!ScreenFrameCache.debugHasRecentShareableDisplayFailure(updatedAt: expired, now: now),
                    "Shareable-content enumeration must retry after its health cooldown")
    }

    private static func testMaintenanceFrameRequestStartsBeforeStreamBecomesSuspect() throws {
        let now: TimeInterval = 100
        let recent = now - ScreenFrameCache.debugMaintenanceRefreshAge + 0.01
        let oldEnoughForMaintenance = now - ScreenFrameCache.debugMaintenanceRefreshAge - 0.01
        try require(ScreenFrameCache.debugMaintenanceRefreshAge < ScreenFrameCache.debugValidatedFrameMaxPixelAge,
                    "Maintenance should request a fresh frame before the cached pixels become suspect")
        try require(ScreenFrameCache.debugMaintenanceRefreshAge < ScreenFrameCache.debugStreamRestartAge,
                    "Maintenance should leave room for a soft refresh before destructive restart")
        try require(!ScreenFrameCache.debugShouldRequestMaintenanceFrame(validatedAt: recent, now: now),
                    "Very fresh cached frames must not churn the stream")
        try require(ScreenFrameCache.debugShouldRequestMaintenanceFrame(validatedAt: oldEnoughForMaintenance, now: now),
                    "A frame past the maintenance age should request a fresh stream frame in the background")
    }

    private static func testStreamRestartWaitsForSuspectFrameAge() throws {
        let now: TimeInterval = 100
        let maintenanceOnly = now - ScreenFrameCache.debugMaintenanceRefreshAge - 0.01
        let suspectValidation = now - ScreenFrameCache.debugStreamRestartAge - 0.01
        let suspectPixels = now - ScreenFrameCache.debugValidatedFrameMaxPixelAge - 0.01
        try require(!ScreenFrameCache.debugShouldRestartCachedStream(validatedAt: maintenanceOnly, now: now),
                    "Maintenance refresh should stay soft before the stream is suspect")
        try require(ScreenFrameCache.debugShouldRestartCachedStream(validatedAt: suspectValidation, now: now),
                    "A stream with old validation should restart in the background")
        try require(ScreenFrameCache.debugShouldRestartCachedStream(updatedAt: suspectPixels,
                                                                    validatedAt: now - 0.1,
                                                                    now: now),
                    "A stream with too-old pixels should restart even if validation is recent")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
