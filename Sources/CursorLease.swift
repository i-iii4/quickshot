import AppKit

/// Owns exactly one balanced AppKit cursor suppression for one capture session.
/// The lease may only be acquired after QuickShot becomes foreground; AppKit and
/// CoreGraphics do not guarantee cursor replacement for a background process.
final class CursorLease {
    typealias CursorOperation = () -> Bool

    private let hideCursor: CursorOperation
    private let showCursor: CursorOperation
    private(set) var isAcquired = false

    init(hideCursor: @escaping CursorOperation = {
             NSCursor.hide()
             return true
         },
         showCursor: @escaping CursorOperation = {
             NSCursor.unhide()
             return true
         }) {
        self.hideCursor = hideCursor
        self.showCursor = showCursor
    }

    @discardableResult
    func acquire() -> Bool {
        guard !isAcquired else { return false }
        guard hideCursor() else { return false }
        isAcquired = true
        return true
    }

    @discardableResult
    func release() -> Bool {
        guard isAcquired else { return false }
        guard showCursor() else { return false }
        isAcquired = false
        return true
    }

    deinit {
        if isAcquired {
            _ = showCursor()
        }
    }
}
