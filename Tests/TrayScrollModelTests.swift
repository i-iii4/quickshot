import CoreGraphics
import Foundation

@main
struct TrayScrollModelTests {
    static func main() {
        shortContentDoesNotScroll()
        defaultOffsetOpensOnNewest()
        scrollingStaysInsideBounds()
        rubberBandResistsBeyondEdges()
        settlingReturnsIntoBounds()
        collapseNeedsIntent()
        collapseThresholdIgnoresCardCount()
        collapseDirectionFollowsTheDrag()
        cardsStackAtBothEdges()
        visibleCardsAreUntouched()
        print("TrayScrollModelTests: passed")
    }

    /// `TR-1`: прокрутка появляется только когда карточки не помещаются.
    private static func shortContentDoesNotScroll() {
        let model = TrayScrollModel(contentLength: 200, viewportLength: 600, offset: 0)
        expect(!model.isScrollable, "content shorter than the viewport must not scroll")
        expect(model.maximumOffset == 0, "there is nowhere to scroll")
    }

    /// `TR-4`, `TR-5`: по умолчанию лента открыта на новых снимках.
    private static func defaultOffsetOpensOnNewest() {
        let offset = TrayScrollModel.defaultOffset(contentLength: 1000, viewportLength: 600)
        expect(offset == 400, "the default offset shows the end of the strip; got \(offset)")

        let short = TrayScrollModel.defaultOffset(contentLength: 300, viewportLength: 600)
        expect(short == 0, "a short strip needs no offset")
    }

    private static func scrollingStaysInsideBounds() {
        let model = TrayScrollModel(contentLength: 1000, viewportLength: 600, offset: 200)
        let forward = model.scrolled(by: 100, rubberBand: false)
        expect(forward.offset == 300, "scrolling adds the delta; got \(forward.offset)")

        let clampedEnd = model.scrolled(by: 5000, rubberBand: false)
        expect(clampedEnd.offset == model.maximumOffset, "scrolling stops at the end")

        let clampedStart = model.scrolled(by: -5000, rubberBand: false)
        expect(clampedStart.offset == 0, "scrolling stops at the start")
    }

    /// `TR-13`: за краем движение сопротивляется, а не останавливается насухо.
    private static func rubberBandResistsBeyondEdges() {
        let model = TrayScrollModel(contentLength: 1000, viewportLength: 600, offset: 0)
        let pulled = model.scrolled(by: -100)
        expect(pulled.offset < 0, "the strip follows the finger past the edge")
        expect(pulled.offset > -100, "but it resists: \(pulled.offset)")
        expect(abs(pulled.offset + 25) < 0.001, "resistance is fourfold; got \(pulled.offset)")

        let atEnd = TrayScrollModel(contentLength: 1000, viewportLength: 600, offset: 400)
        let pushed = atEnd.scrolled(by: 100)
        expect(pushed.overshoot > 0 && pushed.overshoot < 100,
               "the trailing edge resists too; got \(pushed.overshoot)")
    }

    private static func settlingReturnsIntoBounds() {
        var model = TrayScrollModel(contentLength: 1000, viewportLength: 600, offset: 0)
        model = model.scrolled(by: -200)
        expect(model.offset < 0, "pulled past the edge")
        model = model.settled()
        expect(model.offset == 0, "releasing snaps back into bounds")
    }

    /// `TR-7`: сворачивание требует намерения, а не касания края.
    private static func collapseNeedsIntent() {
        let model = TrayScrollModel(contentLength: 1000, viewportLength: 600, offset: 0)
        expect(!model.shouldCollapse(afterOvershoot: -10),
               "a small overshoot must not collapse the tray")
        expect(!model.shouldCollapse(afterOvershoot: -47),
               "just under the threshold still holds")
        expect(model.shouldCollapse(afterOvershoot: -48),
               "a deliberate pull collapses it")
        expect(model.shouldCollapse(afterOvershoot: 60),
               "the trailing edge collapses as well")
    }

    /// `TR-8`: порог одинаков при любом числе снимков.
    private static func collapseThresholdIgnoresCardCount() {
        let single = TrayScrollModel(contentLength: 120, viewportLength: 600, offset: 0)
        let many = TrayScrollModel(contentLength: 5000, viewportLength: 600, offset: 0)
        expect(single.shouldCollapse(afterOvershoot: -50) == many.shouldCollapse(afterOvershoot: -50),
               "the gesture must not depend on how many screenshots there are")
    }

    private static func collapseDirectionFollowsTheDrag() {
        let model = TrayScrollModel(contentLength: 1000, viewportLength: 600, offset: 0)
        expect(model.collapseDirection(afterOvershoot: -80) == .towardStart,
               "pulling past the start collapses toward the start")
        expect(model.collapseDirection(afterOvershoot: 80) == .towardEnd,
               "pushing past the end collapses toward the end")
        expect(model.collapseDirection(afterOvershoot: 10) == nil,
               "no collapse without intent")
    }

    /// `TR-3`: за краями карточки собираются в стопку, а не исчезают.
    private static func cardsStackAtBothEdges() {
        let lengths = [Array(repeating: CGFloat(150), count: 8)].flatMap { $0 }
        let placements = TrayStackLayout.placements(cardLengths: lengths,
                                                    gap: 12,
                                                    offset: 300,
                                                    viewportLength: 600)
        let first = placements[0]
        expect(first.position > -TrayStackLayout.stackStep * CGFloat(TrayStackLayout.stackDepth) - 0.001,
               "cards past the start pile up instead of running away; got \(first.position)")
        expect(first.opacity < 1, "stacked cards fade")
        expect(first.scale < 1, "stacked cards shrink")
        expect(first.opacity > 0.2, "but they stay visible: the stack is the hint that there is more")

        let last = placements[placements.count - 1]
        expect(last.position < 600, "cards past the end stay inside the viewport; got \(last.position)")
        expect(last.opacity < 1, "the trailing stack fades too")
    }

    private static func visibleCardsAreUntouched() {
        let placements = TrayStackLayout.placements(cardLengths: [150, 150, 150],
                                                    gap: 12,
                                                    offset: 0,
                                                    viewportLength: 600)
        for placement in placements {
            expect(placement.opacity == 1 && placement.scale == 1,
                   "a fully visible card must not be faded or scaled")
        }
        expect(placements[0].position == 0, "the first card sits at the origin")
        expect(placements[1].position == 162, "gap is respected; got \(placements[1].position)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("TrayScrollModelTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
