import Foundation

struct CaptureSequence: RawRepresentable, Comparable, Hashable, Sendable {
    let rawValue: UInt64

    static func < (lhs: CaptureSequence, rhs: CaptureSequence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct CaptureSequenceGenerator {
    private var lastValue: UInt64 = 0

    mutating func next() -> CaptureSequence {
        precondition(lastValue < UInt64.max, "Capture sequence exhausted")
        lastValue += 1
        return CaptureSequence(rawValue: lastValue)
    }
}

struct CaptureDeliveryState {
    private enum Status {
        case accepted
        case ready
    }

    private var statuses: [CaptureSequence: Status] = [:]
    private(set) var lastClipboardCommit: CaptureSequence?

    mutating func accept(_ sequence: CaptureSequence) {
        guard lastClipboardCommit.map({ sequence > $0 }) ?? true else { return }
        statuses[sequence] = .accepted
    }

    mutating func markReady(_ sequence: CaptureSequence) -> CaptureSequence? {
        guard statuses[sequence] != nil else { return nil }
        statuses[sequence] = .ready
        return resolveClipboardCommit()
    }

    mutating func markFailed(_ sequence: CaptureSequence) -> CaptureSequence? {
        statuses.removeValue(forKey: sequence)
        return resolveClipboardCommit()
    }

    mutating func invalidateAll() {
        statuses.removeAll()
    }

    private mutating func resolveClipboardCommit() -> CaptureSequence? {
        guard let newest = statuses.keys.max(),
              statuses[newest] == .ready,
              lastClipboardCommit.map({ newest > $0 }) ?? true else {
            return nil
        }

        lastClipboardCommit = newest
        statuses = statuses.filter { $0.key > newest }
        return newest
    }
}

func captureInsertionIndex<T>(
    for sequence: CaptureSequence,
    in values: [T],
    sequenceOf: (T) -> CaptureSequence
) -> Int {
    values.firstIndex { sequence < sequenceOf($0) } ?? values.endIndex
}
