import Foundation

@main
struct ThumbnailCollectionModelTests {
    static func main() {
        testSequenceOrder()
        testRemovalBeforeViewport()
        testFollowNewestAndManualScroll()
        testRemoveAllResetsState()
        print("ThumbnailCollectionModelTests: passed")
    }

    private static func testSequenceOrder() {
        var model = ThumbnailCollectionModel()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        model.insert(id: first, sequence: .init(rawValue: 1))
        model.insert(id: third, sequence: .init(rawValue: 3))
        model.insert(id: second, sequence: .init(rawValue: 2))
        require(model.ids == [first, second, third],
                "late delivery changed chronological card order")
    }

    private static func testRemovalBeforeViewport() {
        var model = ThumbnailCollectionModel()
        let ids = (0..<5).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            model.insert(id: id, sequence: .init(rawValue: UInt64(index + 1)))
        }
        _ = model.resolveFirstVisibleIndex(maximumStart: 3)
        _ = model.shiftViewport(by: -1, maximumStart: 3)
        require(model.firstVisibleIndex == 2, "test precondition failed")
        model.remove(ids: [ids[0]])
        require(model.firstVisibleIndex == 1,
                "removing hidden content before the viewport changed the visible cards")
    }

    private static func testFollowNewestAndManualScroll() {
        var model = ThumbnailCollectionModel()
        for value in 1...4 {
            model.insert(id: UUID(), sequence: .init(rawValue: UInt64(value)))
        }
        require(model.resolveFirstVisibleIndex(maximumStart: 2) == 2,
                "new captures must follow the newest viewport")
        require(model.shiftViewport(by: -1, maximumStart: 2),
                "manual viewport move was ignored")
        require(!model.followsNewest && model.firstVisibleIndex == 1,
                "manual move must suspend follow-newest")
        require(model.resolveFirstVisibleIndex(maximumStart: 2) == 1,
                "layout recomputation unexpectedly jumped back to newest")

        model.insert(id: UUID(), sequence: .init(rawValue: 5))
        require(model.followsNewest
                && model.resolveFirstVisibleIndex(maximumStart: 3) == 3,
                "a new capture must make its newest card discoverable")
    }

    private static func testRemoveAllResetsState() {
        var model = ThumbnailCollectionModel()
        model.insert(id: UUID(), sequence: .init(rawValue: 1))
        model.removeAll()
        require(model.isEmpty && model.firstVisibleIndex == 0 && model.followsNewest,
                "empty model retained stale viewport state")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("ThumbnailCollectionModelTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
