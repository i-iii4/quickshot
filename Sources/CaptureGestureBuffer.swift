import CoreGraphics
import Foundation

struct CaptureGestureSample: Equatable, Sendable {
    let point: CGPoint
    let timestamp: TimeInterval
}

enum CaptureGestureResolution: Equatable, Sendable {
    case idle(pointer: CaptureGestureSample)
    case dragging(start: CaptureGestureSample, current: CaptureGestureSample)
    case completed(start: CaptureGestureSample, end: CaptureGestureSample)
    case cancelled

    var selectionRect: CGRect? {
        guard case .completed(let start, let end) = self else { return nil }
        return CGRect(x: min(start.point.x, end.point.x),
                      y: min(start.point.y, end.point.y),
                      width: abs(end.point.x - start.point.x),
                      height: abs(end.point.y - start.point.y))
    }
}

/// Session-owned pointer history between hotkey acceptance and selector input
/// ownership. A completed gesture remains complete even after the physical
/// button is released; current button state is never used to reconstruct it.
struct CaptureGestureBuffer: Sendable {
    private(set) var resolution: CaptureGestureResolution

    init(initialPointer: CGPoint,
         timestamp: TimeInterval,
         leftButtonDown: Bool) {
        let initial = CaptureGestureSample(point: initialPointer, timestamp: timestamp)
        resolution = leftButtonDown
            ? .dragging(start: initial, current: initial)
            : .idle(pointer: initial)
    }

    mutating func recordMouseDown(at point: CGPoint, timestamp: TimeInterval) {
        guard !isTerminal else { return }
        let sample = CaptureGestureSample(point: point, timestamp: timestamp)
        resolution = .dragging(start: sample, current: sample)
    }

    mutating func recordMouseDragged(to point: CGPoint, timestamp: TimeInterval) {
        guard !isTerminal else { return }
        let sample = CaptureGestureSample(point: point, timestamp: timestamp)
        switch resolution {
        case .dragging(let start, _):
            resolution = .dragging(start: start, current: sample)
        case .idle:
            // A global monitor can attach between mouse-down and the first drag.
            // Starting at the first observed drag is safer than discarding input.
            resolution = .dragging(start: sample, current: sample)
        case .completed, .cancelled:
            break
        }
    }

    mutating func recordMouseUp(at point: CGPoint, timestamp: TimeInterval) {
        guard !isTerminal else { return }
        let sample = CaptureGestureSample(point: point, timestamp: timestamp)
        guard case .dragging(let start, _) = resolution else {
            resolution = .idle(pointer: sample)
            return
        }
        resolution = .completed(start: start, end: sample)
    }

    mutating func updateIdlePointer(to point: CGPoint, timestamp: TimeInterval) {
        guard case .idle = resolution else { return }
        resolution = .idle(pointer: CaptureGestureSample(point: point, timestamp: timestamp))
    }

    mutating func cancel() {
        resolution = .cancelled
    }

    private var isTerminal: Bool {
        switch resolution {
        case .completed, .cancelled:
            return true
        case .idle, .dragging:
            return false
        }
    }
}
