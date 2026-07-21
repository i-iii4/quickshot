import Foundation

@main
struct CursorLeaseTests {
    static func main() {
        run("acquire and release are idempotent", testIdempotentLifecycle)
        run("deinit restores an acquired cursor", testDeinitRestoresCursor)
        print("CursorLeaseTests: passed")
    }

    private static func testIdempotentLifecycle() {
        var hideCount = 0
        var showCount = 0
        let lease = CursorLease(
            hideCursor: { hideCount += 1 },
            showCursor: { showCount += 1 })

        expect(lease.acquire(), "first acquire must own the cursor")
        expect(!lease.acquire(), "second acquire must be ignored")
        expect(hideCount == 1, "cursor must be hidden exactly once")
        expect(lease.isAcquired, "lease must report acquired state")

        expect(lease.release(), "first release must restore the cursor")
        expect(!lease.release(), "second release must be ignored")
        expect(showCount == 1, "cursor must be restored exactly once")
        expect(!lease.isAcquired, "lease must report released state")
    }

    private static func testDeinitRestoresCursor() {
        var hideCount = 0
        var showCount = 0
        var lease: CursorLease? = CursorLease(
            hideCursor: { hideCount += 1 },
            showCursor: { showCount += 1 })

        lease?.acquire()
        lease = nil

        expect(hideCount == 1, "lease must acquire once")
        expect(showCount == 1, "deinit must restore an outstanding lease")
    }

    private static func run(_ name: String, _ body: () -> Void) {
        body()
        print("  \(name): passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) {
        guard condition() else {
            fputs("CursorLeaseTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
