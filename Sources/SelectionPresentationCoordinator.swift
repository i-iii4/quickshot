import AppKit

enum SelectionPresentationFailure: Equatable {
    case activationRejected
    case activationTimedOut
    case activationLost
    case cursorSuppressionFailed
}

/// Owns the foreground and cursor transaction for one selector session. Frozen
/// pixels are already immutable before this starts, so activation cannot change
/// the captured hover state. Presentation is revealed only after foreground
/// ownership and cursor suppression are both confirmed.
final class SelectionPresentationCoordinator {
    enum State: Equatable {
        case idle
        case awaitingActivation
        case acquired
        case failed(SelectionPresentationFailure)
        case finished
    }

    private let cursorLease: CursorLease
    private let isApplicationActive: () -> Bool
    private let requestActivation: () -> Bool
    private let notificationCenter: NotificationCenter
    private let activationTimeout: TimeInterval
    private var activationObserver: Any?
    private var deactivationObserver: Any?
    private var timeoutWorkItem: DispatchWorkItem?
    private var restoreActivation: (() -> Void)?
    private var onAcquired: (() -> Void)?
    private var onFailure: ((SelectionPresentationFailure) -> Void)?
    private(set) var state: State = .idle
    var ownsCursor: Bool { cursorLease.isAcquired }

    init(cursorLease: CursorLease = CursorLease(),
         isApplicationActive: @escaping () -> Bool = { NSApp.isActive },
         requestActivation: @escaping () -> Bool = {
             // A global screenshot hotkey is an explicit user request. The modern
             // cooperative API cannot succeed unless the arbitrary source app
             // yields first, so this compatibility boundary uses the public force
             // option and still waits for didBecomeActive before cursor ownership.
             NSApp.activate(ignoringOtherApps: true)
             return true
         },
         notificationCenter: NotificationCenter = .default,
         activationTimeout: TimeInterval = 0.5) {
        self.cursorLease = cursorLease
        self.isApplicationActive = isApplicationActive
        self.requestActivation = requestActivation
        self.notificationCenter = notificationCenter
        self.activationTimeout = activationTimeout
    }

    func begin(restoreActivation: @escaping () -> Void,
               onAcquired: @escaping () -> Void,
               onFailure: @escaping (SelectionPresentationFailure) -> Void) {
        guard state == .idle else { return }
        self.restoreActivation = restoreActivation
        self.onAcquired = onAcquired
        self.onFailure = onFailure

        if isApplicationActive() {
            acquireAfterActivation()
            return
        }

        state = .awaitingActivation
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                self?.applicationDidActivate()
            }
        scheduleTimeout()
        guard requestActivation() else {
            fail(.activationRejected)
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.applicationDidActivate()
        }
    }

    func applicationDidActivate() {
        guard state == .awaitingActivation, isApplicationActive() else { return }
        acquireAfterActivation()
    }

    func activationTimedOut() {
        guard state == .awaitingActivation else { return }
        fail(.activationTimedOut)
    }

    private func acquireAfterActivation() {
        guard state == .idle || state == .awaitingActivation,
              isApplicationActive() else { return }
        clearActivationWait()
        guard cursorLease.acquire() else {
            fail(.cursorSuppressionFailed)
            return
        }
        state = .acquired
        deactivationObserver = notificationCenter.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                self?.applicationDidResign()
            }
        let callback = onAcquired
        onAcquired = nil
        callback?()
    }

    func applicationDidResign() {
        guard state == .acquired else { return }
        fail(.activationLost)
    }

    private func scheduleTimeout() {
        let work = DispatchWorkItem { [weak self] in self?.activationTimedOut() }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + activationTimeout, execute: work)
    }

    private func fail(_ failure: SelectionPresentationFailure) {
        guard state != .finished else { return }
        clearObservers()
        state = .failed(failure)
        let callback = onFailure
        onFailure = nil
        callback?(failure)
    }

    private func clearActivationWait() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        if let activationObserver {
            notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func clearObservers() {
        clearActivationWait()
        if let deactivationObserver {
            notificationCenter.removeObserver(deactivationObserver)
            self.deactivationObserver = nil
        }
    }

    /// Removes visible presentation before restoring the system cursor.
    @discardableResult
    func finish(afterHidingPresentation hidePresentation: () -> Void) -> Bool {
        guard state != .finished else { return true }
        hidePresentation()
        clearObservers()
        let restored = !cursorLease.isAcquired || cursorLease.release()
        state = restored ? .finished : .failed(.cursorSuppressionFailed)
        let restore = restoreActivation
        restoreActivation = nil
        onAcquired = nil
        onFailure = nil
        restore?()
        return restored
    }

    deinit {
        clearObservers()
    }
}
