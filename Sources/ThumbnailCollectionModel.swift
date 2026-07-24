import Foundation

struct ThumbnailCollectionModel {
    struct Entry: Equatable {
        let id: UUID
        let sequence: CaptureSequence
    }

    private(set) var entries: [Entry] = []
    private(set) var firstVisibleIndex = 0
    private(set) var followsNewest = true

    var ids: [UUID] { entries.map(\.id) }
    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    @discardableResult
    mutating func insert(id: UUID, sequence: CaptureSequence) -> Int {
        if let existing = entries.firstIndex(where: { $0.id == id }) {
            return existing
        }
        let index = captureInsertionIndex(for: sequence,
                                          in: entries,
                                          sequenceOf: { $0.sequence })
        entries.insert(.init(id: id, sequence: sequence), at: index)
        followsNewest = true
        return index
    }

    mutating func remove(ids removedIDs: Set<UUID>) {
        guard !removedIDs.isEmpty else { return }
        let removedBeforeViewport = entries.prefix(firstVisibleIndex)
            .filter { removedIDs.contains($0.id) }
            .count
        entries.removeAll { removedIDs.contains($0.id) }
        firstVisibleIndex = max(0, firstVisibleIndex - removedBeforeViewport)
        if entries.isEmpty {
            firstVisibleIndex = 0
            followsNewest = true
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        firstVisibleIndex = 0
        followsNewest = true
    }

    mutating func resolveFirstVisibleIndex(maximumStart: Int) -> Int {
        let maximum = max(0, maximumStart)
        if followsNewest {
            firstVisibleIndex = maximum
        } else {
            firstVisibleIndex = min(max(0, firstVisibleIndex), maximum)
        }
        return firstVisibleIndex
    }

    @discardableResult
    mutating func shiftViewport(by delta: Int, maximumStart: Int) -> Bool {
        let maximum = max(0, maximumStart)
        let target = min(max(0, firstVisibleIndex + delta), maximum)
        guard target != firstVisibleIndex else { return false }
        firstVisibleIndex = target
        followsNewest = target == maximum
        return true
    }
}
