import CoreGraphics
import Foundation

@main
struct CaptureGestureBufferTests {
    static func main() {
        testIdlePointer()
        testHeldGesture()
        testCompletedGestureSurvivesRelease()
        testMonitorAttachmentDuringDrag()
        testCancellationIsTerminal()
        print("CaptureGestureBufferTests: passed")
    }

    private static func testIdlePointer() {
        var buffer = CaptureGestureBuffer(initialPointer: CGPoint(x: 10, y: 20),
                                          timestamp: 1,
                                          leftButtonDown: false)
        buffer.updateIdlePointer(to: CGPoint(x: 12, y: 24), timestamp: 2)
        expect(buffer.resolution == .idle(pointer: .init(point: CGPoint(x: 12, y: 24),
                                                         timestamp: 2)),
               "idle pointer did not update")
    }

    private static func testHeldGesture() {
        var buffer = CaptureGestureBuffer(initialPointer: CGPoint(x: 20, y: 30),
                                          timestamp: 1,
                                          leftButtonDown: true)
        buffer.recordMouseDragged(to: CGPoint(x: 80, y: 90), timestamp: 2)
        expect(buffer.resolution == .dragging(
            start: .init(point: CGPoint(x: 20, y: 30), timestamp: 1),
            current: .init(point: CGPoint(x: 80, y: 90), timestamp: 2)),
            "held gesture lost its original anchor")
    }

    private static func testCompletedGestureSurvivesRelease() {
        var buffer = CaptureGestureBuffer(initialPointer: CGPoint(x: 5, y: 8),
                                          timestamp: 1,
                                          leftButtonDown: false)
        buffer.recordMouseDown(at: CGPoint(x: 40, y: 50), timestamp: 2)
        buffer.recordMouseDragged(to: CGPoint(x: 10, y: 90), timestamp: 3)
        buffer.recordMouseUp(at: CGPoint(x: 10, y: 90), timestamp: 4)

        expect(buffer.resolution.selectionRect == CGRect(x: 10, y: 50, width: 30, height: 40),
               "completed gesture did not retain its crop after mouse-up")
        buffer.recordMouseDown(at: CGPoint(x: 1, y: 1), timestamp: 5)
        expect(buffer.resolution.selectionRect == CGRect(x: 10, y: 50, width: 30, height: 40),
               "a later event mutated a completed gesture")
    }

    private static func testMonitorAttachmentDuringDrag() {
        var buffer = CaptureGestureBuffer(initialPointer: .zero,
                                          timestamp: 1,
                                          leftButtonDown: false)
        buffer.recordMouseDragged(to: CGPoint(x: 30, y: 35), timestamp: 2)
        buffer.recordMouseUp(at: CGPoint(x: 60, y: 75), timestamp: 3)
        expect(buffer.resolution.selectionRect == CGRect(x: 30, y: 35, width: 30, height: 40),
               "first observed drag did not seed a recoverable gesture")
    }

    private static func testCancellationIsTerminal() {
        var buffer = CaptureGestureBuffer(initialPointer: CGPoint(x: 1, y: 2),
                                          timestamp: 1,
                                          leftButtonDown: true)
        buffer.cancel()
        buffer.recordMouseUp(at: CGPoint(x: 50, y: 60), timestamp: 2)
        expect(buffer.resolution == .cancelled,
               "mouse-up revived a cancelled gesture")
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) {
        guard condition() else {
            fputs("CaptureGestureBufferTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
