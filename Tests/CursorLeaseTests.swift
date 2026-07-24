import Foundation

@main
@MainActor
struct CursorLeaseTests {
    static func main() {
        run("acquire and release are idempotent", testIdempotentLifecycle)
        run("failed suppression never claims ownership", testAcquireFailure)
        run("failed restoration remains retryable", testReleaseFailure)
        run("deinit restores an acquired cursor", testDeinitRestoresCursor)
        print("CursorLeaseTests: passed")
    }

    private static func testIdempotentLifecycle() {
        var hideCount = 0
        var showCount = 0
        let lease = CursorLease(
            hideCursor: { hideCount += 1; return true },
            showCursor: { showCount += 1; return true })

        expect(lease.acquire(), "first acquire must own the cursor")
        expect(!lease.acquire(), "second acquire must be ignored")
        expect(hideCount == 1, "cursor must be hidden exactly once")
        expect(lease.isAcquired, "lease must report acquired state")

        expect(lease.release(), "first release must restore the cursor")
        expect(!lease.release(), "second release must be ignored")
        expect(showCount == 1, "cursor must be restored exactly once")
        expect(!lease.isAcquired, "lease must report released state")
    }

    private static func testAcquireFailure() {
        var showCount = 0
        let lease = CursorLease(hideCursor: { false },
                                showCursor: { showCount += 1; return true })
        expect(!lease.acquire(), "failed backend must reject ownership")
        expect(!lease.isAcquired, "failed backend reported cursor ownership")
        expect(showCount == 0, "unowned cursor was restored")
    }

    private static func testReleaseFailure() {
        var canRestore = false
        let lease = CursorLease(hideCursor: { true },
                                showCursor: { canRestore })
        expect(lease.acquire(), "test lease did not acquire")
        expect(!lease.release(), "failed restore was reported as successful")
        expect(lease.isAcquired, "failed restore discarded retry ownership")
        canRestore = true
        expect(lease.release(), "retry did not restore cursor")
        expect(!lease.isAcquired, "successful retry retained ownership")
    }

    private static func testDeinitRestoresCursor() {
        var hideCount = 0
        var showCount = 0
        var lease: CursorLease? = CursorLease(
            hideCursor: { hideCount += 1; return true },
            showCursor: { showCount += 1; return true })

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
