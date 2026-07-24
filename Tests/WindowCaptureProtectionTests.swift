import AppKit
import Darwin

@MainActor
@main
struct WindowCaptureProtectionTests {
    static func main() {
        testUnavailableAuditFailsClosed()
        testUnprotectedWindowFailsClosed()
        testProtectedWindowPasses()
        print("WindowCaptureProtectionTests: passed")
    }

    private static func testUnavailableAuditFailsClosed() {
        do {
            try WindowCaptureProtection.auditOnScreenWindows { nil }
            fail("nil WindowServer audit must fail closed")
        } catch WindowCaptureProtectionError.auditUnavailable {
            return
        } catch {
            fail("unexpected unavailable-audit error: \(error)")
        }
    }

    private static func testUnprotectedWindowFailsClosed() {
        let info = windowInfo(number: 77,
                              sharingState: Int(NSWindow.SharingType.readOnly.rawValue))
        do {
            try WindowCaptureProtection.auditOnScreenWindows { [info] }
            fail("visible unprotected QuickShot window must fail capture")
        } catch WindowCaptureProtectionError.unprotectedWindows(let numbers) {
            require(numbers == [77], "audit returned wrong unprotected window IDs")
        } catch {
            fail("unexpected unprotected-window error: \(error)")
        }
    }

    private static func testProtectedWindowPasses() {
        let info = windowInfo(number: 88,
                              sharingState: Int(NSWindow.SharingType.none.rawValue))
        do {
            try WindowCaptureProtection.auditOnScreenWindows { [info] }
        } catch {
            fail("protected QuickShot window failed audit: \(error)")
        }
    }

    private static func windowInfo(number: UInt32, sharingState: Int) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: getpid()),
            kCGWindowNumber as String: NSNumber(value: number),
            kCGWindowSharingState as String: NSNumber(value: sharingState)
        ]
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("WindowCaptureProtectionTests failed: \(message)\n", stderr)
        exit(1)
    }
}
