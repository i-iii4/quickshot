import AppKit
import Darwin

@main
struct ThumbnailMotionTests {
    static func main() {
        run("tray dissolve has bounded travel", testBoundedTravel)
        run("first frame cannot teleport or half-fade", testFirstFramePerception)
        run("opacity remains coordinated with master progress", testPerceptualOpacity)
        run("retarget preserves presentation velocity", testRetargetVelocity)
        run("shadow is absolute for every progress", testAbsoluteShadow)
        run("reduced motion removes travel but keeps fade", testReducedMotion)
        run("group has one shared state without stagger", testSharedGroupState)
        run("motion endpoints and budget are finite", testEndpointsAndBudget)
        run("collection insertion and removal have canonical endpoints", testCollectionEndpoints)
        run("removal resolves before layout reflow", testRemovalLeadsReflow)
        run("odometer rolls vertically in the count direction", testOdometerDirection)
        run("odometer honors reduced motion", testOdometerReducedMotion)
        run("collapsed capture acknowledgement stays brief", testCollapsedCaptureTiming)
        run("collapsed hover changes presentation without changing intent", testCollapsedHoverPresentation)
        run("collection motion stays on the tray axis", testCollectionAxis)
        print("ThumbnailMotionTests: passed")
    }

    private static func testBoundedTravel() throws {
        try require(TrayAnim.maxTravel <= 10,
                    "Tray cards must never imitate a morph with long-distance travel")
        let hidden = thumbnailTrayVisualState(progress: 1, reduceMotion: false)
        try require(abs(hidden.travelProgress * TrayAnim.maxTravel - TrayAnim.maxTravel) <= 0.001,
                    "Collapsed endpoint must use exactly the bounded travel token")
    }

    private static func testFirstFramePerception() throws {
        let duration = CGFloat(TrayAnim.transition)
        let sample = motionSpringStep(value: 0,
                                      velocity: 0,
                                      target: 1,
                                      angularFrequency: 5 / duration,
                                      deltaTime: 0.018)
        let visual = thumbnailTrayVisualState(progress: sample.value, reduceMotion: false)
        let pixelTravel = visual.travelProgress * TrayAnim.maxTravel
        try require(pixelTravel < 3,
                    "First 18ms moved the card \(pixelTravel)pt; motion reads as teleportation")
        try require(visual.alpha > 0.95,
                    "First 18ms reduced opacity to \(visual.alpha); fade is too front-loaded")
    }

    private static func testPerceptualOpacity() throws {
        let p10 = thumbnailTrayVisualState(progress: 0.10, reduceMotion: false)
        let p20 = thumbnailTrayVisualState(progress: 0.20, reduceMotion: false)
        let p50 = thumbnailTrayVisualState(progress: 0.50, reduceMotion: false)
        let p80 = thumbnailTrayVisualState(progress: 0.80, reduceMotion: false)
        try require(p10.alpha > 0.99, "Opacity changed before the movement became legible")
        try require(p20.alpha > 0.95, "Opacity is still too aggressive at 20% progress")
        try require(p50.alpha > 0.5 && p50.alpha < 0.7,
                    "Midpoint opacity must remain perceptually centered, got \(p50.alpha)")
        try require(p80.alpha > 0.08 && p80.alpha < 0.2,
                    "Late opacity must resolve without a long invisible tail, got \(p80.alpha)")
    }

    private static func testRetargetVelocity() throws {
        let omega = CGFloat(5 / TrayAnim.transition)
        let forward = motionSpringStep(value: 0,
                                       velocity: 0,
                                       target: 1,
                                       angularFrequency: omega,
                                       deltaTime: 0.02)
        let reversed = motionSpringStep(value: forward.value,
                                        velocity: forward.velocity,
                                        target: 0,
                                        angularFrequency: omega,
                                        deltaTime: 0.001)
        try require(reversed.value >= forward.value,
                    "Retarget must preserve forward presentation velocity before decelerating")
        try require(reversed.velocity > 0 && reversed.velocity < forward.velocity,
                    "Retarget restarted easing instead of preserving velocity")
    }

    private static func testAbsoluteShadow() throws {
        for progress: CGFloat in stride(from: 0, through: 1, by: 0.05) {
            let first = thumbnailTrayVisualState(progress: progress, reduceMotion: false)
            let reversed = thumbnailTrayVisualState(progress: progress, reduceMotion: false)
            try require(abs(first.shadowOpacity - reversed.shadowOpacity) <= 0.0001,
                        "Shadow depends on transition direction at \(progress)")
        }
        try require(thumbnailTrayVisualState(progress: 0.36, reduceMotion: false).shadowOpacity <= 0.0001,
                    "Shadow must be gone before silhouettes can visually overlap")
    }

    private static func testReducedMotion() throws {
        let normal = thumbnailTrayVisualState(progress: 0.5, reduceMotion: false)
        let reduced = thumbnailTrayVisualState(progress: 0.5, reduceMotion: true)
        try require(reduced.travelProgress == 0,
                    "Reduce Motion must remove translation")
        try require(abs(reduced.alpha - normal.alpha) <= 0.0001,
                    "Reduce Motion must preserve state comprehension through opacity")
    }

    private static func testSharedGroupState() throws {
        let progress: CGFloat = 0.42
        let states = (0..<20).map { _ in
            thumbnailTrayVisualState(progress: progress, reduceMotion: false)
        }
        guard let first = states.first else { throw Failure("Missing group state") }
        try require(states.allSatisfy {
            abs($0.travelProgress - first.travelProgress) <= 0.0001
                && abs($0.alpha - first.alpha) <= 0.0001
                && abs($0.shadowOpacity - first.shadowOpacity) <= 0.0001
        }, "Cards diverged from the shared tray progress")
    }

    private static func testEndpointsAndBudget() throws {
        let visible = thumbnailTrayVisualState(progress: 0, reduceMotion: false)
        let hidden = thumbnailTrayVisualState(progress: 1, reduceMotion: false)
        try require(visible.alpha == 1
                    && abs(visible.shadowOpacity - TrayAnim.restingShadowOpacity) <= 0.0001,
                    "Visible endpoint is not canonical")
        try require(hidden.alpha == 0 && hidden.shadowOpacity == 0,
                    "Hidden endpoint is not canonical")
        try require(TrayAnim.transition < 0.3 && TrayAnim.reducedTransition < 0.3,
                    "Tray transition exceeded the UI duration budget")
    }

    private static func testCollectionEndpoints() throws {
        let insertedStart = thumbnailInsertionState(progress: 0, reduceMotion: false)
        let insertedEnd = thumbnailInsertionState(progress: 1, reduceMotion: false)
        let removedStart = thumbnailRemovalState(progress: 0, reduceMotion: false)
        let removedEnd = thumbnailRemovalState(progress: 1, reduceMotion: false)
        try require(insertedStart.alpha <= 0.001 && insertedEnd.alpha >= 0.999,
                    "Insertion does not resolve from hidden to the canonical resting state")
        try require(removedStart.alpha == 1 && removedEnd.alpha == 0,
                    "Removal does not resolve from visible to hidden")
        try require(removedEnd.shadowOpacity == 0,
                    "Removed card retains a shadow after its silhouette is gone")
    }

    private static func testRemovalLeadsReflow() throws {
        let removed = thumbnailRemovalState(progress: 0.8, reduceMotion: false)
        let reflow = thumbnailReflowProgress(0.8, reduceMotion: false)
        try require(removed.alpha <= 0.001 && removed.movementProgress >= 0.999,
                    "Removed silhouette must resolve within its shorter exit phase")
        try require(reflow < 0.999,
                    "Reflow must retain a short settling phase after the removed card is gone")
    }

    private static func testOdometerDirection() throws {
        let up = odometerMotionState(progress: 0.5, increasing: true, distance: 24)
        let down = odometerMotionState(progress: 0.5, increasing: false, distance: 24)
        try require(up.outgoingOffset > 0 && up.incomingOffset < 0,
                    "Increasing count must move old digits up and bring new digits from below")
        try require(down.outgoingOffset < 0 && down.incomingOffset > 0,
                    "Decreasing count must move old digits down and bring new digits from above")
        let end = odometerMotionState(progress: 1, increasing: true, distance: 24)
        try require(abs(end.incomingOffset) < 0.001,
                    "Incoming count does not settle at its baseline")
    }

    private static func testOdometerReducedMotion() throws {
        let reduced = odometerPresentationState(progress: 0.5,
                                                increasing: true,
                                                distance: 24,
                                                reduceMotion: true)
        try require(reduced.outgoingOffset == 0 && reduced.incomingOffset == 0,
                    "Reduce Motion must replace vertical rolling with a stationary crossfade")
    }

    private static func testCollapsedCaptureTiming() throws {
        let total = TrayAnim.insertion + TrayAnim.collapsedPeekHold + TrayAnim.collapsedPeekExit
        try require(TrayAnim.collapsedPeekHold >= 1.1 && TrayAnim.collapsedPeekHold <= 1.3,
                    "Collapsed capture hold must leave enough time to acquire the card with the pointer")
        try require(total < 1.6,
                    "Collapsed capture acknowledgement occupies the screen for too long")
        try require(TrayAnim.insertion <= 0.16 && TrayAnim.removalAndReflow <= 0.18,
                    "Frequent collection motion exceeds the crisp interaction budget")
    }

    private static func testCollapsedHoverPresentation() throws {
        try require(thumbnailTrayCollapseTarget(userCollapsed: true, hoverExpanded: false) == 1,
                    "A manually collapsed tray must stay hidden at rest")
        try require(thumbnailTrayCollapseTarget(userCollapsed: true, hoverExpanded: true) == 0,
                    "Hover must reveal cards without mutating the persisted collapsed intent")
        try require(thumbnailTrayCollapseTarget(userCollapsed: false, hoverExpanded: false) == 0,
                    "An expanded tray must remain visible without hover")
        try require(TrayAnim.hoverExitGrace >= 0.14 && TrayAnim.hoverExitGrace <= 0.24,
                    "Hover exit grace must bridge the hub-card gap without feeling sticky")
    }

    private static func testCollectionAxis() throws {
        let verticalOffset = thumbnailCollectionOffset(vertical: true)
        let horizontalOffset = thumbnailCollectionOffset(vertical: false)
        try require(verticalOffset.x == 0 && verticalOffset.y < 0,
                    "Vertical tray feedback contains an unnecessary horizontal component")
        try require(horizontalOffset.x > 0 && horizontalOffset.y == 0,
                    "Horizontal tray feedback contains an unnecessary vertical component")

        let verticalTrayTravel = thumbnailTrayTravelOffset(vertical: true)
        let horizontalTrayTravel = thumbnailTrayTravelOffset(vertical: false)
        try require(verticalTrayTravel.x == 0 && verticalTrayTravel.y < 0,
                    "Vertical tray collapse contains center-directed sideways drift")
        try require(horizontalTrayTravel.x > 0 && horizontalTrayTravel.y == 0,
                    "Horizontal tray collapse contains center-directed vertical drift")

        let old = NSRect(x: 100, y: 300, width: 240, height: 160)
        let candidate = NSPoint(x: 128, y: 120)
        let vertical = thumbnailAxisLockedOrigin(candidate: candidate,
                                                 oldOuterFrame: old,
                                                 resizeBand: 12,
                                                 vertical: true)
        try require(vertical.x == 112 && vertical.y == 120,
                    "Vertical reflow changed the orthogonal X anchor")
        let horizontal = thumbnailAxisLockedOrigin(candidate: candidate,
                                                   oldOuterFrame: old,
                                                   resizeBand: 12,
                                                   vertical: false)
        try require(horizontal.x == 128 && horizontal.y == 312,
                    "Horizontal reflow changed the orthogonal Y anchor")

        // Переезд ВДОЛЬ ленты держит поперечную ось: карточка не дрейфует вбок.
        let sameWidth = NSSize(width: old.width, height: old.height)
        let held = thumbnailReflowOrigin(candidate: candidate,
                                         oldOuterFrame: old,
                                         targetOuterSize: sameWidth,
                                         resizeBand: 12,
                                         vertical: true)
        try require(held.x == 112 && held.y == 120,
                    "Reflow along the strip lost its cross-axis anchor")

        // Карточка, ВЫХОДЯЩАЯ ИЗ СТОПКИ, меняет поперечный размер: перспектива
        // больше не сжимает её. Такая обязана переехать и поперёк, иначе
        // встанет в стороне и там останется — по перекосу на каждое удаление.
        let grown = NSSize(width: old.width + 20, height: old.height)
        let freed = thumbnailReflowOrigin(candidate: candidate,
                                          oldOuterFrame: old,
                                          targetOuterSize: grown,
                                          resizeBand: 12,
                                          vertical: true)
        try require(freed.x == candidate.x && freed.y == candidate.y,
                    "Card leaving the stack was pinned to its old cross-axis position")

        // То же для горизонтальной ленты: там поперечная ось — Y.
        let taller = NSSize(width: old.width, height: old.height + 20)
        let freedH = thumbnailReflowOrigin(candidate: candidate,
                                           oldOuterFrame: old,
                                           targetOuterSize: taller,
                                           resizeBand: 12,
                                           vertical: false)
        try require(freedH.x == candidate.x && freedH.y == candidate.y,
                    "Horizontal card leaving the stack was pinned to its old Y")

        // `TR-38`: ось раскрытия выбирает жест.
        try require(trayAxisPick(accumulatedX: 4, accumulatedY: 6, threshold: 10) == nil,
                    "Axis was picked before the threshold")
        try require(trayAxisPick(accumulatedX: 2, accumulatedY: 14, threshold: 10) == true,
                    "Pulling up did not open the vertical axis")
        try require(trayAxisPick(accumulatedX: -14, accumulatedY: 2, threshold: 10) == false,
                    "Pulling left did not open the horizontal axis")
        // Направление хода значения не имеет — только ось.
        try require(trayAxisPick(accumulatedX: 0, accumulatedY: -14, threshold: 10) == true,
                    "Pulling down picked a different axis than pulling up")
        // Ровная диагональ достаётся вертикали: она основная.
        try require(trayAxisPick(accumulatedX: 12, accumulatedY: 12, threshold: 10) == true,
                    "A clean diagonal did not fall back to the vertical axis")
    }

    private static func run(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            fputs("ThumbnailMotionTests: \(name) failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
