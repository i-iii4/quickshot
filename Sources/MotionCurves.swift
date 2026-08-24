import CoreGraphics

struct MotionSpringSample {
    let value: CGFloat
    let velocity: CGFloat
}

func motionSpringStep(value: CGFloat,
                      velocity: CGFloat,
                      target: CGFloat,
                      angularFrequency: CGFloat,
                      deltaTime: CGFloat) -> MotionSpringSample {
    let displacement = value - target
    let c2 = velocity + angularFrequency * displacement
    let decay = exp(-angularFrequency * deltaTime)
    let nextDisplacement = (displacement + c2 * deltaTime) * decay
    let nextVelocity = (c2 - angularFrequency * (displacement + c2 * deltaTime)) * decay
    return MotionSpringSample(value: target + nextDisplacement,
                              velocity: nextVelocity)
}

private func motionClampedUnit(_ value: CGFloat) -> CGFloat {
    min(1, max(0, value))
}

private func motionCubicBezierComponent(_ t: CGFloat, _ p1: CGFloat, _ p2: CGFloat) -> CGFloat {
    let inverse = 1 - t
    return 3 * inverse * inverse * t * p1 + 3 * inverse * t * t * p2 + t * t * t
}

func motionCubicBezier(_ progress: CGFloat,
                       x1: CGFloat,
                       y1: CGFloat,
                       x2: CGFloat,
                       y2: CGFloat) -> CGFloat {
    let x = motionClampedUnit(progress)
    var lower: CGFloat = 0
    var upper: CGFloat = 1
    var parameter = x
    for _ in 0..<14 {
        let estimate = motionCubicBezierComponent(parameter, x1, x2)
        if estimate < x { lower = parameter } else { upper = parameter }
        parameter = (lower + upper) / 2
    }
    return motionCubicBezierComponent(parameter, y1, y2)
}

/// cubic-bezier(0.23, 1, 0.32, 1): strong response for UI fades and entrances.
func motionStrongEaseOut(_ progress: CGFloat) -> CGFloat {
    motionCubicBezier(progress, x1: 0.23, y1: 1, x2: 0.32, y2: 1)
}

/// A compact ease-in-out for spatial reflow: readable acceleration without a long landing tail.
func motionCrispEaseInOut(_ progress: CGFloat) -> CGFloat {
    motionCubicBezier(progress, x1: 0.4, y1: 0, x2: 0.2, y2: 1)
}

/// Symmetric movement curve for a value that remains on screen throughout the transition.
func motionStrongEaseInOut(_ progress: CGFloat) -> CGFloat {
    motionCubicBezier(progress, x1: 0.77, y1: 0, x2: 0.175, y2: 1)
}

struct OdometerMotionState {
    let outgoingOffset: CGFloat
    let incomingOffset: CGFloat
}

func odometerMotionState(progress: CGFloat,
                         increasing: Bool,
                         distance: CGFloat) -> OdometerMotionState {
    let p = motionStrongEaseInOut(min(1, max(0, progress)))
    let direction: CGFloat = increasing ? 1 : -1
    return OdometerMotionState(outgoingOffset: direction * distance * p,
                               incomingOffset: -direction * distance * (1 - p))
}

func odometerPresentationState(progress: CGFloat,
                               increasing: Bool,
                               distance: CGFloat,
                               reduceMotion: Bool) -> OdometerMotionState {
    reduceMotion
        ? OdometerMotionState(outgoingOffset: 0, incomingOffset: 0)
        : odometerMotionState(progress: progress, increasing: increasing, distance: distance)
}

