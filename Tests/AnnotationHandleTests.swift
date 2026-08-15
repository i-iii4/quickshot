import CoreGraphics
import Foundation

@main
struct AnnotationHandleTests {
    static func main() {
        segmentHasEndsAndCurve()
        rectHasEightHandles()
        freeFormsHaveNoHandles()
        draggingEndMovesOnlyThatEnd()
        curveHandleSignFollowsTheSide()
        cornerResizeKeepsOppositeCornerFixed()
        proportionalResizeMakesSquares()
        edgeResizeMovesOneSide()
        constrainedAngleSnapsToFifteenDegrees()
        print("AnnotationHandleTests: passed")
    }

    /// `D-8`, `D-11`, `G-5`
    private static func segmentHasEndsAndCurve() {
        let geometry = AnnotationGeometry.segment(from: .zero, to: CGPoint(x: 100, y: 0), curve: 0)
        let handles = AnnotationHandle.handles(for: geometry)
        expect(handles == [.segmentStart, .segmentEnd, .segmentCurve],
               "a segment exposes both ends and the curve handle")
        expect(AnnotationHandle.segmentStart.position(in: geometry) == .zero, "start handle sits at the start")
        expect(AnnotationHandle.segmentEnd.position(in: geometry) == CGPoint(x: 100, y: 0),
               "end handle sits at the end")
        expect(AnnotationHandle.segmentCurve.position(in: geometry) == CGPoint(x: 50, y: 0),
               "an unbent segment keeps its curve handle on the line")
    }

    /// `D-16`, `G-5`, `G-7`
    private static func rectHasEightHandles() {
        let geometry = AnnotationGeometry.rect(CGRect(x: 10, y: 20, width: 100, height: 60),
                                               cornerRadius: 0)
        expect(AnnotationHandle.handles(for: geometry).count == 8,
               "a rect exposes four corners and four edges")
        let corner = AnnotationHandle.rectCorner(x: .maximum, y: .maximum)
        expect(corner.position(in: geometry) == CGPoint(x: 110, y: 80), "corner handle position")
        let edge = AnnotationHandle.rectEdge(.minimum, axis: .horizontal)
        expect(edge.position(in: geometry) == CGPoint(x: 10, y: 50), "left edge handle is centred")
    }

    /// Свободный штрих и метка шага перемещаются целиком: тянуть точку кривой
    /// бессмысленно.
    private static func freeFormsHaveNoHandles() {
        expect(AnnotationHandle.handles(for: .path([.zero])).isEmpty, "a pencil stroke has no handles")
        expect(AnnotationHandle.handles(for: .point(.zero)).isEmpty, "a step marker has no handles")
    }

    private static func draggingEndMovesOnlyThatEnd() {
        let geometry = AnnotationGeometry.segment(from: .zero, to: CGPoint(x: 100, y: 0), curve: 5)
        let result = AnnotationHandle.segmentEnd.applying(point: CGPoint(x: 40, y: 40),
                                                          to: geometry,
                                                          proportional: false)
        guard case let .segment(from, to, curve) = result else {
            fail("segment must stay a segment"); return
        }
        expect(from == .zero, "the untouched end must not move")
        expect(to == CGPoint(x: 40, y: 40), "the dragged end follows the pointer")
        expect(curve == 5, "resizing must not silently drop the curve")
    }

    /// Знак изгиба берётся из стороны, на которую увели ручку (`D-8`).
    private static func curveHandleSignFollowsTheSide() {
        let geometry = AnnotationGeometry.segment(from: .zero, to: CGPoint(x: 100, y: 0), curve: 0)
        let up = AnnotationHandle.segmentCurve.applying(point: CGPoint(x: 50, y: 30),
                                                         to: geometry,
                                                         proportional: false)
        let down = AnnotationHandle.segmentCurve.applying(point: CGPoint(x: 50, y: -30),
                                                          to: geometry,
                                                          proportional: false)
        guard case let .segment(_, _, upCurve) = up, case let .segment(_, _, downCurve) = down else {
            fail("curve handle must return a segment"); return
        }
        expect(upCurve > 0 && downCurve < 0,
               "opposite sides must give opposite curve signs; got \(upCurve) and \(downCurve)")
        expect(abs(abs(upCurve) - abs(downCurve)) < 0.001, "symmetric drags give symmetric curves")
    }

    private static func cornerResizeKeepsOppositeCornerFixed() {
        let geometry = AnnotationGeometry.rect(CGRect(x: 0, y: 0, width: 100, height: 100),
                                               cornerRadius: 4)
        let result = AnnotationHandle.rectCorner(x: .minimum, y: .minimum)
            .applying(point: CGPoint(x: 40, y: 30), to: geometry, proportional: false)
        guard case let .rect(rect, radius) = result else { fail("rect must stay a rect"); return }
        expect(rect == CGRect(x: 40, y: 30, width: 60, height: 70),
               "dragging a corner keeps the opposite one fixed; got \(rect)")
        expect(radius == 4, "corner radius survives a resize")
    }

    /// `G-6`, `H-3`
    private static func proportionalResizeMakesSquares() {
        let geometry = AnnotationGeometry.rect(CGRect(x: 0, y: 0, width: 100, height: 100),
                                               cornerRadius: 0)
        let result = AnnotationHandle.rectCorner(x: .maximum, y: .maximum)
            .applying(point: CGPoint(x: 160, y: 120), to: geometry, proportional: true)
        guard case let .rect(rect, _) = result else { fail("rect must stay a rect"); return }
        expect(rect.width == rect.height, "the proportional modifier must give a square; got \(rect)")
        expect(rect.origin == .zero, "the anchor corner must not move")
    }

    private static func edgeResizeMovesOneSide() {
        let geometry = AnnotationGeometry.rect(CGRect(x: 0, y: 0, width: 100, height: 100),
                                               cornerRadius: 0)
        let result = AnnotationHandle.rectEdge(.maximum, axis: .vertical)
            .applying(point: CGPoint(x: 999, y: 40), to: geometry, proportional: false)
        guard case let .rect(rect, _) = result else { fail("rect must stay a rect"); return }
        expect(rect.width == 100, "an edge handle must not change the other axis")
        expect(rect.height == 40, "the dragged edge follows the pointer; got \(rect)")
    }

    /// `D-10`: модификатор ограничивает угол шагом 15 градусов.
    /// `D-10`, `G-8`, `G-9`
    private static func constrainedAngleSnapsToFifteenDegrees() {
        let origin = CGPoint.zero
        let almostFlat = constrainedAngle(from: origin,
                                                             to: CGPoint(x: 100, y: 4))
        expect(abs(almostFlat.y) < 0.001,
               "a nearly horizontal drag snaps to horizontal; got \(almostFlat)")

        let diagonal = constrainedAngle(from: origin,
                                                           to: CGPoint(x: 100, y: 96))
        expect(abs(diagonal.x - diagonal.y) < 0.001,
               "a nearly diagonal drag snaps to 45 degrees; got \(diagonal)")

        let length = (diagonal.x * diagonal.x + diagonal.y * diagonal.y).squareRoot()
        let original = (CGFloat(100 * 100 + 96 * 96)).squareRoot()
        expect(abs(length - original) < 0.001, "snapping must preserve length")
    }

    private static func fail(_ message: String) {
        fputs("AnnotationHandleTests failed: \(message)\n", stderr)
        exit(1)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message); return }
    }
}
