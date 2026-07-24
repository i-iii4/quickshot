import AppKit
import QuartzCore

enum TrayAnim {
    static let insertion: Double = 0.15
    static let removalAndReflow: Double = 0.17
    static let collapsedPeekExit: Double = 0.13
    static let collapsedPeekHold: Double = 1.2
    static let hoverExitGrace: Double = 0.18
    static let collectionOffset: CGFloat = 6
    static let transition: Double = 0.16
    static let reducedTransition: Double = 0.12
    static let maxTravel: CGFloat = 9
    static let restingShadowOpacity: CGFloat = 0.32

    static func response(reduceMotion: Bool) -> Double {
        reduceMotion ? reducedTransition : transition
    }
}

/// The persisted tray state and its current presentation are intentionally separate:
/// hover may reveal a collapsed tray without changing what the next click means.
func thumbnailTrayCollapseTarget(userCollapsed: Bool, hoverExpanded: Bool) -> CGFloat {
    userCollapsed && !hoverExpanded ? 1 : 0
}

struct ThumbnailCollectionVisualState {
    let movementProgress: CGFloat
    let alpha: CGFloat
    let shadowOpacity: CGFloat
}

func thumbnailInsertionState(progress: CGFloat, reduceMotion: Bool) -> ThumbnailCollectionVisualState {
    let p = motionStrongEaseOut(progress)
    return ThumbnailCollectionVisualState(
        movementProgress: p,
        alpha: p,
        shadowOpacity: TrayAnim.restingShadowOpacity * traySmoothstep(0.12, 0.82, progress)
    )
}

func thumbnailRemovalState(progress: CGFloat, reduceMotion: Bool) -> ThumbnailCollectionVisualState {
    // The removed silhouette resolves before the remaining cards finish reflowing.
    // Both channels still share one transaction clock, so count and layout stay synchronized.
    let p = traySmoothstep(0, 0.8, progress)
    return ThumbnailCollectionVisualState(
        movementProgress: p,
        alpha: 1 - p,
        shadowOpacity: TrayAnim.restingShadowOpacity * (1 - traySmoothstep(0, 0.44, progress))
    )
}

func thumbnailReflowProgress(_ progress: CGFloat, reduceMotion: Bool) -> CGFloat {
    reduceMotion ? 1 : motionCrispEaseInOut(progress)
}

func thumbnailCollectionOffset(vertical: Bool) -> NSPoint {
    vertical
        ? NSPoint(x: 0, y: -TrayAnim.collectionOffset)
        : NSPoint(x: TrayAnim.collectionOffset, y: 0)
}

/// Tray cards preserve their shared edge while dissolving toward the hub. A center-to-center
/// vector makes a wide card drift sideways toward a narrow button even when their edges align.
func thumbnailTrayTravelOffset(vertical: Bool) -> NSPoint {
    vertical
        ? NSPoint(x: 0, y: -TrayAnim.maxTravel)
        : NSPoint(x: TrayAnim.maxTravel, y: 0)
}

func thumbnailAxisLockedOrigin(candidate: NSPoint,
                               oldOuterFrame: NSRect,
                               resizeBand: CGFloat,
                               vertical: Bool) -> NSPoint {
    vertical
        ? NSPoint(x: oldOuterFrame.minX + resizeBand, y: candidate.y)
        : NSPoint(x: candidate.x, y: oldOuterFrame.minY + resizeBand)
}

/// One finite display-linked clock for a discrete collection transaction. Visual channels
/// derive their own curves from this raw progress, avoiding compounded easing and idle tails.
@MainActor
final class CollectionProgressAnimator: NSObject {
    private weak var hostView: NSView?
    private var link: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0
    private var onFrame: ((CGFloat) -> Void)?
    private var onDone: (() -> Void)?

    init(hostView: NSView) {
        self.hostView = hostView
        super.init()
    }

    func run(duration: CFTimeInterval,
             onFrame: @escaping (CGFloat) -> Void,
             onDone: @escaping () -> Void) {
        cancel()
        self.duration = max(1.0 / 240.0, duration)
        self.onFrame = onFrame
        self.onDone = onDone
        startedAt = CACurrentMediaTime()
        onFrame(0)
        guard let hostView else {
            finish()
            return
        }
        let displayLink = hostView.displayLink(target: self, selector: #selector(step(_:)))
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
    }

    @objc private func step(_ sender: CADisplayLink) {
        let progress = CGFloat(min(1, max(0, (CACurrentMediaTime() - startedAt) / duration)))
        onFrame?(progress)
        if progress >= 1 { finish() }
    }

    private func finish() {
        let frame = onFrame
        let completion = onDone
        cancel()
        frame?(1)
        completion?()
    }

    func cancel() {
        link?.invalidate()
        link = nil
        onFrame = nil
        onDone = nil
    }

    isolated deinit { link?.invalidate() }
}

struct ThumbnailTrayVisualState {
    let travelProgress: CGFloat
    let alpha: CGFloat
    let shadowOpacity: CGFloat
}

private func trayClampedUnit(_ value: CGFloat) -> CGFloat {
    min(1, max(0, value))
}

private func traySmoothstep(_ lower: CGFloat, _ upper: CGFloat, _ value: CGFloat) -> CGFloat {
    guard upper > lower else { return value >= upper ? 1 : 0 }
    let t = trayClampedUnit((value - lower) / (upper - lower))
    return t * t * (3 - 2 * t)
}

/// Absolute visual state derived from one collapse progress. Reversing at any
/// point produces the same pixels for the same progress, including the shadow.
func thumbnailTrayVisualState(progress: CGFloat, reduceMotion: Bool) -> ThumbnailTrayVisualState {
    let p = trayClampedUnit(progress)
    let travel = reduceMotion ? 0 : traySmoothstep(0, 1, p)
    let fade = traySmoothstep(0.12, 1, p)
    let shadowFade = traySmoothstep(0.04, 0.36, p)
    return ThumbnailTrayVisualState(
        travelProgress: travel,
        alpha: 1 - fade,
        shadowOpacity: TrayAnim.restingShadowOpacity * (1 - shadowFade)
    )
}

/// One display clock for the complete tray. Retargeting keeps both the current
/// presentation value and velocity, so Hide/Show can reverse without a stop.
@MainActor
final class TrayProgressAnimator: NSObject {
    private weak var hostView: NSView?
    private var link: CADisplayLink?
    private var value: CGFloat = 0
    private var velocity: CGFloat = 0
    private var target: CGFloat = 0
    private var angularFrequency: CGFloat = 1
    private var lastTimestamp: CFTimeInterval = 0
    private var deadline: CFTimeInterval = 0
    private var onFrame: ((CGFloat) -> Void)?
    private var onDone: (() -> Void)?

    init(hostView: NSView) {
        self.hostView = hostView
        super.init()
    }

    var presentationValue: CGFloat { trayClampedUnit(value) }
    var presentationVelocity: CGFloat { velocity }

    func synchronize(_ value: CGFloat) {
        cancel()
        self.value = trayClampedUnit(value)
        target = self.value
        velocity = 0
    }

    func retarget(to target: CGFloat,
                  response: CFTimeInterval,
                  onFrame: @escaping (CGFloat) -> Void,
                  onDone: (() -> Void)? = nil) {
        self.target = trayClampedUnit(target)
        self.onFrame = onFrame
        self.onDone = onDone
        let distance = abs(self.target - value)
        guard distance > 0.001, response > 0, let hostView else {
            finish(at: self.target)
            return
        }

        let now = CACurrentMediaTime()
        let segmentDuration = max(1.0 / 240.0, response * CFTimeInterval(distance))
        angularFrequency = CGFloat(5 / segmentDuration)
        lastTimestamp = now
        deadline = now + segmentDuration
        if link == nil {
            let displayLink = hostView.displayLink(target: self, selector: #selector(step(_:)))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        }
    }

    @objc private func step(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        if now >= deadline {
            finish(at: target)
            return
        }
        let deltaTime = CGFloat(max(0, min(now - lastTimestamp, 1.0 / 30.0)))
        lastTimestamp = now
        guard deltaTime > 0 else { return }

        let sample = motionSpringStep(value: value,
                                      velocity: velocity,
                                      target: target,
                                      angularFrequency: angularFrequency,
                                      deltaTime: deltaTime)
        value = sample.value
        velocity = sample.velocity
        onFrame?(presentationValue)
    }

    private func finish(at value: CGFloat) {
        self.value = value
        target = value
        velocity = 0
        let frame = onFrame
        let completion = onDone
        cancel()
        frame?(value)
        completion?()
    }

    func cancel() {
        link?.invalidate()
        link = nil
        onFrame = nil
        onDone = nil
    }

    isolated deinit { link?.invalidate() }
}
