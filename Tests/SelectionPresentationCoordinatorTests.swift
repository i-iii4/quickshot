import Foundation

@main
struct SelectionPresentationCoordinatorTests {
    static func main() {
        run("cursor waits for foreground ownership", testCursorWaitsForActivation)
        run("activation rejection is explicit", testActivationRejection)
        run("activation timeout never reveals a cursor", testActivationTimeout)
        run("suppression failure is explicit", testSuppressionFailure)
        run("activation loss fails the active session", testActivationLoss)
        run("teardown precedes cursor restoration and focus return", testTeardownOrdering)
        run("duplicate finish is idempotent", testDuplicateFinish)
        print("SelectionPresentationCoordinatorTests: passed")
    }

    private static func testCursorWaitsForActivation() {
        let state = HarnessState()
        let coordinator = makeCoordinator(state)
        var acquired = 0
        coordinator.begin(restoreActivation: { state.restore += 1 },
                          onAcquired: { acquired += 1 },
                          onFailure: { _ in fail("activation unexpectedly failed") })

        expect(coordinator.state == .awaitingActivation,
               "inactive app did not enter the activation boundary")
        expect(state.request == 1 && state.hide == 0,
               "cursor changed before foreground ownership")

        state.active = true
        coordinator.applicationDidActivate()
        expect(coordinator.state == .acquired && coordinator.ownsCursor,
               "foreground ownership did not acquire the cursor")
        expect(acquired == 1 && state.hide == 1,
               "cursor was not acquired exactly once after activation")
        _ = coordinator.finish {}
    }

    private static func testActivationRejection() {
        let state = HarnessState()
        state.activationAccepted = false
        let coordinator = makeCoordinator(state)
        var failures: [SelectionPresentationFailure] = []
        coordinator.begin(restoreActivation: { state.restore += 1 },
                          onAcquired: { fail("rejected activation acquired") },
                          onFailure: { failures.append($0) })

        expect(coordinator.state == .failed(.activationRejected),
               "rejected activation has no terminal state")
        expect(failures == [.activationRejected] && state.hide == 0,
               "rejected activation touched cursor ownership")
        _ = coordinator.finish {}
        expect(state.restore == 1, "failed activation did not run focus cleanup")
    }

    private static func testActivationTimeout() {
        let state = HarnessState()
        let coordinator = makeCoordinator(state)
        var failures: [SelectionPresentationFailure] = []
        coordinator.begin(restoreActivation: { state.restore += 1 },
                          onAcquired: { fail("timed-out activation acquired") },
                          onFailure: { failures.append($0) })
        coordinator.activationTimedOut()

        expect(coordinator.state == .failed(.activationTimedOut),
               "timeout did not stop activation")
        expect(failures == [.activationTimedOut] && state.hide == 0,
               "timeout revealed or hid a cursor")
        _ = coordinator.finish {}
    }

    private static func testSuppressionFailure() {
        let state = HarnessState()
        state.active = true
        state.hideSucceeds = false
        let coordinator = makeCoordinator(state)
        var failures: [SelectionPresentationFailure] = []
        coordinator.begin(restoreActivation: { state.restore += 1 },
                          onAcquired: { fail("failed suppression acquired") },
                          onFailure: { failures.append($0) })

        expect(coordinator.state == .failed(.cursorSuppressionFailed),
               "suppression failure has no explicit state")
        expect(failures == [.cursorSuppressionFailed] && !coordinator.ownsCursor,
               "failed suppression claimed cursor ownership")
        _ = coordinator.finish {}
    }

    private static func testActivationLoss() {
        let state = HarnessState()
        state.active = true
        let coordinator = makeCoordinator(state)
        var failures: [SelectionPresentationFailure] = []
        coordinator.begin(restoreActivation: { state.restore += 1 },
                          onAcquired: {},
                          onFailure: { failures.append($0) })
        coordinator.applicationDidResign()

        expect(coordinator.state == .failed(.activationLost),
               "foreground loss left selector active")
        expect(failures == [.activationLost], "foreground loss callback was not exact")
        _ = coordinator.finish {}
        expect(state.show == 1, "foreground loss did not restore the cursor")
    }

    private static func testTeardownOrdering() {
        let state = HarnessState()
        state.active = true
        let coordinator = makeCoordinator(state)
        coordinator.begin(restoreActivation: { state.restore += 1 },
                          onAcquired: {},
                          onFailure: { _ in fail("ownership failed") })
        var presentationHidden = false

        let restored = coordinator.finish {
            presentationHidden = true
            expect(state.show == 0 && state.restore == 0,
                   "cursor or focus returned before presentation was hidden")
        }

        expect(restored, "cursor restoration failed")
        expect(presentationHidden && state.show == 1 && state.restore == 1,
               "teardown was not balanced")
        expect(coordinator.state == .finished, "coordinator did not finish")
    }

    private static func testDuplicateFinish() {
        let state = HarnessState()
        state.active = true
        let coordinator = makeCoordinator(state)
        coordinator.begin(restoreActivation: { state.restore += 1 },
                          onAcquired: {},
                          onFailure: { _ in fail("ownership failed") })
        _ = coordinator.finish {}
        _ = coordinator.finish { fail("duplicate finish reran presentation teardown") }
        expect(state.show == 1 && state.restore == 1,
               "duplicate finish restored ownership twice")
    }

    private static func makeCoordinator(_ state: HarnessState) -> SelectionPresentationCoordinator {
        SelectionPresentationCoordinator(
            cursorLease: CursorLease(
                hideCursor: { state.hide += 1; return state.hideSucceeds },
                showCursor: { state.show += 1; return true }),
            isApplicationActive: { state.active },
            requestActivation: { state.request += 1; return state.activationAccepted },
            notificationCenter: NotificationCenter(),
            activationTimeout: 60)
    }

    private static func run(_ name: String, _ body: () -> Void) {
        body()
        print("  \(name): passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("SelectionPresentationCoordinatorTests failed: \(message)\n", stderr)
        exit(1)
    }
}

private final class HarnessState {
    var active = false
    var activationAccepted = true
    var hideSucceeds = true
    var request = 0
    var hide = 0
    var show = 0
    var restore = 0
}
