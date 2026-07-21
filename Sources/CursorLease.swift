import AppKit

/// Owns exactly one balanced system-cursor suppression for one capture session.
/// AppKit keeps the cursor hidden even when its shape changes, so no cursor rect
/// or repeated hide call is needed while the lease is active.
final class CursorLease {
    private let hideCursor: () -> Void
    private let showCursor: () -> Void
    private(set) var isAcquired = false

    init(hideCursor: @escaping () -> Void = { NSCursor.hide() },
         showCursor: @escaping () -> Void = { NSCursor.unhide() }) {
        self.hideCursor = hideCursor
        self.showCursor = showCursor
    }

    @discardableResult
    func acquire() -> Bool {
        guard !isAcquired else { return false }
        hideCursor()
        isAcquired = true
        return true
    }

    @discardableResult
    func release() -> Bool {
        guard isAcquired else { return false }
        isAcquired = false
        showCursor()
        return true
    }

    deinit {
        if isAcquired {
            showCursor()
        }
    }
}
