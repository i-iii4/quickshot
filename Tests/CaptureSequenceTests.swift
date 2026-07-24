import Foundation

@main
struct CaptureSequenceTests {
    static func main() {
        testMonotonicGenerator()
        testNewestReadyCaptureWins()
        testFailedNewerCaptureReleasesBarrier()
        testStaleCompletionCannotReplaceClipboard()
        testOrderedInsertion()
        testHundredRandomizedCompletionOrders()
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

    private static func testHundredRandomizedCompletionOrders() {
        for iteration in 0..<100 {
            var state = CaptureDeliveryState()
            let sequences = (1...100).map {
                CaptureSequence(rawValue: UInt64($0))
            }
            sequences.forEach { state.accept($0) }

            var random = DeterministicRandom(seed: UInt64(iteration + 1))
            var completions = sequences
            random.shuffle(&completions)
            let successful = Set(sequences.filter { sequence in
                (sequence.rawValue + UInt64(iteration)) % 7 != 0
            })
            var commits: [CaptureSequence] = []

            for sequence in completions {
                let commit = successful.contains(sequence)
                    ? state.markReady(sequence)
                    : state.markFailed(sequence)
                if let commit { commits.append(commit) }
            }

            require(zip(commits, commits.dropFirst()).allSatisfy(<),
                    "clipboard commits moved backwards in iteration \(iteration)")
            require(state.lastClipboardCommit == successful.max(),
                    "random completion order lost the newest successful capture")
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("CaptureSequenceTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}

private struct DeterministicRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func shuffle<T>(_ values: inout [T]) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let target = Int(state % UInt64(index + 1))
            values.swapAt(index, target)
        }
    }
}
