import Foundation

@main
struct CaptureSequenceTests {
    static func main() {
        testMonotonicGenerator()
        testNewestReadyCaptureWins()
        testFailedNewerCaptureReleasesBarrier()
        testStaleCompletionCannotReplaceClipboard()
        testOrderedInsertion()
        print("CaptureSequenceTests: passed")
    }

    private static func testMonotonicGenerator() {
        var generator = CaptureSequenceGenerator()
        require(generator.next().rawValue == 1, "first sequence must be one")
        require(generator.next().rawValue == 2, "sequence must increase monotonically")
    }

    private static func testNewestReadyCaptureWins() {
        var state = CaptureDeliveryState()
        let first = CaptureSequence(rawValue: 1)
        let second = CaptureSequence(rawValue: 2)
        state.accept(first)
        state.accept(second)
        require(state.markReady(first) == nil,
                "an older ready capture must wait behind a newer accepted capture")
        require(state.markReady(second) == second,
                "the newest ready capture must own automatic clipboard delivery")
    }

    private static func testFailedNewerCaptureReleasesBarrier() {
        var state = CaptureDeliveryState()
        let first = CaptureSequence(rawValue: 1)
        let second = CaptureSequence(rawValue: 2)
        state.accept(first)
        state.accept(second)
        require(state.markReady(first) == nil, "older capture must initially wait")
        require(state.markFailed(second) == first,
                "failure of the newer capture must release the older ready result")
    }

    private static func testStaleCompletionCannotReplaceClipboard() {
        var state = CaptureDeliveryState()
        let first = CaptureSequence(rawValue: 1)
        let second = CaptureSequence(rawValue: 2)
        state.accept(first)
        state.accept(second)
        require(state.markReady(second) == second, "newest capture should commit")
        require(state.markReady(first) == nil, "stale completion must be ignored")
        require(state.lastClipboardCommit == second, "clipboard order must never move backwards")
    }

    private static func testOrderedInsertion() {
        let existing = [CaptureSequence(rawValue: 1), CaptureSequence(rawValue: 3)]
        let index = captureInsertionIndex(for: CaptureSequence(rawValue: 2),
                                          in: existing,
                                          sequenceOf: { $0 })
        require(index == 1, "late delivery must be inserted by capture sequence")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("CaptureSequenceTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
