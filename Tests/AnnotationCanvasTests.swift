import AppKit

@main
struct AnnotationCanvasTests {
    private static let image = CGSize(width: 2000, height: 1000)
    private static let view = CGSize(width: 800, height: 600)

    static func main() {
        fitZoomNeverUpscales()
        roundTripBetweenSpaces()
        zoomKeepsPointUnderCursor()
        zoomIsClampedToRange()
        offsetNeverLeavesTheImage()
        smallImageStaysCentred()
        strokeWidthIsZoomIndependent()
        print("AnnotationCanvasTests: passed")
    }

    private static func fitZoomNeverUpscales() {
        let wide = AnnotationCanvasTransform(imageSize: image, viewSize: view)
        expect(abs(wide.fitZoom() - 0.4) < 0.0001,
               "a 2000pt image in an 800pt view fits at 0.4; got \(wide.fitZoom())")

        let tiny = AnnotationCanvasTransform(imageSize: CGSize(width: 100, height: 80),
                                             viewSize: view)
        expect(tiny.fitZoom() == 1,
               "an image smaller than the view must not be upscaled to fill it")
    }

    private static func roundTripBetweenSpaces() {
        var transform = AnnotationCanvasTransform(imageSize: image, viewSize: view, zoom: 2)
        transform = transform.panned(by: CGVector(dx: -120, dy: -80))
        let source = CGPoint(x: 640, y: 320)
        let round = transform.imagePoint(fromView: transform.viewPoint(fromImage: source))
        expect(abs(round.x - source.x) < 0.001 && abs(round.y - source.y) < 0.001,
               "image → view → image must be lossless; got \(round)")
    }

    /// `B-2`: точка под курсором остаётся на месте при масштабировании.
    private static func zoomKeepsPointUnderCursor() {
        let transform = AnnotationCanvasTransform(imageSize: image, viewSize: view, zoom: 1)
        let anchor = CGPoint(x: 300, y: 200)
        let before = transform.imagePoint(fromView: anchor)
        let zoomed = transform.zoomed(to: 2.5, around: anchor)
        let after = zoomed.imagePoint(fromView: anchor)
        expect(abs(before.x - after.x) < 0.5 && abs(before.y - after.y) < 0.5,
               "the image point under the cursor must not drift: \(before) → \(after)")
    }

    private static func zoomIsClampedToRange() {
        let transform = AnnotationCanvasTransform(imageSize: image, viewSize: view)
        expect(transform.zoomed(to: 99, around: .zero).zoom == AnnotationCanvasTransform.maximumZoom,
               "zoom must clamp at the maximum")
        expect(transform.zoomed(to: 0.001, around: .zero).zoom == AnnotationCanvasTransform.minimumZoom,
               "zoom must clamp at the minimum")
    }

    private static func offsetNeverLeavesTheImage() {
        var transform = AnnotationCanvasTransform(imageSize: image, viewSize: view, zoom: 1)
        transform = transform.panned(by: CGVector(dx: 5000, dy: 5000))
        expect(transform.contentOffset == .zero,
               "panning past the leading edge must stop at it; got \(transform.contentOffset)")

        transform = transform.panned(by: CGVector(dx: -5000, dy: -5000))
        let maxX = transform.scaledImageSize.width - view.width
        let maxY = max(0, transform.scaledImageSize.height - view.height)
        expect(transform.contentOffset.x == maxX && transform.contentOffset.y == maxY,
               "panning past the trailing edge must stop at it; got \(transform.contentOffset)")
    }

    private static func smallImageStaysCentred() {
        let transform = AnnotationCanvasTransform(imageSize: CGSize(width: 200, height: 100),
                                                  viewSize: view,
                                                  zoom: 1)
        let frame = transform.imageFrame
        expect(abs(frame.midX - view.width / 2) < 0.001 && abs(frame.midY - view.height / 2) < 0.001,
               "an image smaller than the view is centred; got \(frame)")
    }

    /// `B-5`: видимая толщина штриха не зависит от масштаба холста.
    private static func strokeWidthIsZoomIndependent() {
        let base = AnnotationCanvasTransform(imageSize: image, viewSize: view, zoom: 1)
        let zoomedIn = AnnotationCanvasTransform(imageSize: image, viewSize: view, zoom: 4)
        let zoomedOut = AnnotationCanvasTransform(imageSize: image, viewSize: view, zoom: 0.25)

        expect(base.imageLineWidth(forScreenWidth: 3) == 3, "no zoom, no correction")
        expect(zoomedIn.imageLineWidth(forScreenWidth: 3) * zoomedIn.zoom == 3,
               "zoomed in, the stroke must still read as 3pt on screen")
        expect(zoomedOut.imageLineWidth(forScreenWidth: 3) * zoomedOut.zoom == 3,
               "zoomed out, the stroke must still read as 3pt on screen")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("AnnotationCanvasTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
