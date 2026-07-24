import AppKit

@MainActor
enum TrayPosition: String {
    case right, left, bottom, top

    var isVertical: Bool { self == .right || self == .left }

    static var testCurrent: TrayPosition = .right
    static var current: TrayPosition { testCurrent }
}

@MainActor
final class FrameAnimator {
    init(hostView: NSView) {}

    func run(duration: CFTimeInterval,
             delay: CFTimeInterval,
             easing: @escaping (CGFloat) -> CGFloat,
             onFrame: @escaping (CGFloat) -> Void,
             onDone: (() -> Void)? = nil) {
        onFrame(easing(1))
        onDone?()
    }

    func cancel() {}
}
