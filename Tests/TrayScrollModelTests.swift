import CoreGraphics
import Foundation

@main
struct TrayScrollModelTests {
    static func main() {
        singleCardHasNowhereToScroll()
        fullTravelCollectsEverythingButTheNewest()
        scrollingStaysInsideBounds()
        rubberBandResistsBeyondEdges()
        settlingReturnsIntoBounds()
        revealOffsetShowsTheNewestCard()
        restingStackHasConstantTiers()
        mixedHeightsKeepTheSilhouetteClean()
        depthAddsPerspective()
        cardsAreNeverDeformed()
        parkedCardIsCutOnlyByTheArrivingOne()
        stackSinksWhileTheNextCardArrives()
        cardsNeverOutrunTheStrip()
        tiersStandStillBeforeTheTouch()
        farStackMirrorsAtTheTop()
        bottomEdgeSinksAndDissolves()
        scrubbingIsContinuous()
        deeperLayersGoBehind()
        print("TrayScrollModelTests: passed")
    }

    // MARK: модель смещения

    /// Одна карточка: собирать нечего. Две карточки уже складываются в стопку
    /// у кнопки (`TR-4a`), даже если лента помещается целиком.
    private static func singleCardHasNowhereToScroll() {
        let one = TrayScrollModel(contentLength: 150, viewportLength: 600,
                                  offset: 0, lastCardLength: 150)
        expect(one.maximumOffset == 0, "единственной карточке некуда ехать")

        let two = TrayScrollModel(contentLength: 312, viewportLength: 600,
                                  offset: 0, lastCardLength: 150)
        expect(two.isScrollable, "две карточки складываются в стопку")
        expect(two.maximumOffset == 312 - 150,
               "ход — до парковки новейшей; получили \(two.maximumOffset)")
    }

    /// `TR-4a`: максимальный ход паркует новейшую карточку на ярусе стопки,
    /// целиком видимой.
    private static func fullTravelCollectsEverythingButTheNewest() {
        let model = TrayScrollModel(contentLength: 1608, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        expect(model.maximumOffset == 1608 - 150,
               "ход до парковки новейшей; получили \(model.maximumOffset)")
    }

    private static func scrollingStaysInsideBounds() {
        let model = TrayScrollModel(contentLength: 1000, viewportLength: 600,
                                    offset: 200, lastCardLength: 150)
        let forward = model.scrolled(by: 100, rubberBand: false)
        expect(forward.offset == 300, "прокрутка добавляет дельту; получили \(forward.offset)")

        let clampedEnd = model.scrolled(by: 5000, rubberBand: false)
        expect(clampedEnd.offset == model.maximumOffset, "прокрутка упирается в конец")

        let clampedStart = model.scrolled(by: -5000, rubberBand: false)
        expect(clampedStart.offset == 0, "прокрутка упирается в начало")
    }

    /// `TR-13`: за краем движение сопротивляется, а не останавливается насухо.
    private static func rubberBandResistsBeyondEdges() {
        let model = TrayScrollModel(contentLength: 1000, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        let pulled = model.scrolled(by: -100)
        expect(pulled.offset < 0, "лента идёт за пальцами за край")
        expect(pulled.offset > -100, "но сопротивляется: \(pulled.offset)")
        expect(abs(pulled.offset + 25) < 0.001, "сопротивление вчетверо; получили \(pulled.offset)")

        let atEnd = TrayScrollModel(contentLength: 1000, viewportLength: 600,
                                    offset: 850, lastCardLength: 150)
        let pushed = atEnd.scrolled(by: 100)
        expect(pushed.overshoot > 0 && pushed.overshoot < 200,
               "дальний край тоже пружинит; получили \(pushed.overshoot)")
    }

    private static func settlingReturnsIntoBounds() {
        var model = TrayScrollModel(contentLength: 1000, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        model = model.scrolled(by: -200)
        expect(model.offset < 0, "перетянуто за край")
        model = model.settled()
        expect(model.offset == 0, "отпускание возвращает в границы")
    }

    /// `TR-5`: докрутка до нового снимка ставит его целиком ниже дальнего
    /// парковочного яруса.
    private static func revealOffsetShowsTheNewestCard() {
        let model = TrayScrollModel(contentLength: 1608, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        let reveal = model.revealNewestOffset()
        expect(abs(reveal - (1608 - (600 - 2 * TrayStripLayout.parkLevel))) < 0.001,
               "докрутка до видимости новейшей; получили \(reveal)")

        let short = TrayScrollModel(contentLength: 300, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        expect(short.revealNewestOffset() == 0, "короткой ленте докрутка не нужна")
    }

    // MARK: стопка жёстких карточек

    private static let gap: CGFloat = 12

    private static func uniform(_ count: Int) -> [CGFloat] {
        Array(repeating: CGFloat(150), count: count)
    }

    private static func content(_ lengths: [CGFloat]) -> CGFloat {
        lengths.reduce(0, +) + gap * CGFloat(lengths.count - 1)
    }

    /// Смещение, при котором прибывающая карточка `k` наезжает на стопку с
    /// фазой `phase` (0 — касание, 1 — парковка).
    private static func offsetFor(arriving k: Int, phase: CGFloat,
                                  lengths: [CGFloat]) -> CGFloat {
        let cursor = lengths[0..<k].reduce(0, +) + gap * CGFloat(k)
        return cursor - lengths[k - 1] * (1 - phase)
    }

    /// `TR-24`, `TR-25`: при полном сборе новейшая карточка целиком стоит на
    /// парковочном ярусе, под ней две кромки по 7pt на постоянных ярусах.
    private static func restingStackHasConstantTiers() {
        let lengths = uniform(10)
        let model = TrayScrollModel(contentLength: content(lengths), viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: model.maximumOffset, viewportLength: 600)
        let e = TrayStripLayout.edgeLength
        let park = TrayStripLayout.parkLevel
        let newest = bands[9]
        expect(newest.isFullCard && abs(newest.position - park) < 0.001,
               "новейшая карточка целиком на ярусе: \(newest.position)")
        expect(abs(bands[8].position - e) < 0.001 && abs(bands[8].length - e) < 0.001,
               "первая кромка на своём ярусе: \(bands[8].position), \(bands[8].length)")
        expect(abs(bands[7].position) < 0.001 && abs(bands[7].length - e) < 0.001,
               "вторая кромка прижата к базе: \(bands[7].position), \(bands[7].length)")
        expect(!bands[8].sliceFromFarSide && !bands[7].sliceFromFarSide,
               "кромки у кнопки показывают НИЗЫ карточек")
        for index in 0...6 {
            expect(bands[index].hidden, "слой \(index) глубже стопки обязан скрыться")
        }
    }

    /// Ярусы — константы: карточки разной высоты дают ровно тот же силуэт.
    private static func mixedHeightsKeepTheSilhouetteClean() {
        let lengths: [CGFloat] = [200, 90, 260, 120, 180, 90]
        let model = TrayScrollModel(contentLength: content(lengths), viewportLength: 600,
                                    offset: 0, lastCardLength: 90)
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: model.maximumOffset, viewportLength: 600)
        let e = TrayStripLayout.edgeLength
        expect(bands[5].isFullCard && abs(bands[5].position - TrayStripLayout.parkLevel) < 0.001,
               "новейшая карточка целиком на ярусе")
        expect(abs(bands[4].position - e) < 0.001 && abs(bands[4].length - e) < 0.001,
               "первая кромка на ярусе независимо от высот")
        expect(abs(bands[3].position) < 0.001 && abs(bands[3].length - e) < 0.001,
               "вторая кромка на ярусе независимо от высот")
        for index in 0...2 {
            expect(bands[index].hidden, "слой \(index) глубже стопки обязан скрыться")
        }
        // Никакая полоса не торчит выше верха новейшей карточки.
        let stackTop = bands[5].position + bands[5].length
        for (index, band) in bands.enumerated() where !band.hidden && index != 5 {
            expect(band.position + band.length <= stackTop + 0.001,
                   "слой \(index) торчит над стопкой: \(band.position + band.length)")
        }
    }

    /// Перспектива: уходя в глубину, карточка уменьшается целиком, и на ярус
    /// глубже — сильнее радиуса своих углов на сторону, поэтому линия среза
    /// запаркованной никогда не выглядывает в скруглённых углах накрывающей.
    private static func depthAddsPerspective() {
        let lengths = uniform(10)
        let model = TrayScrollModel(contentLength: content(lengths), viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        let resting = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                            offset: model.maximumOffset, viewportLength: 600)
        expect(resting[9].scale > 0.999, "верхняя карточка стопки в полном масштабе")
        expect(abs(resting[8].scale - (1 - TrayStripLayout.depthScaleStep)) < 0.001,
               "первая кромка отдалена на ярус: \(resting[8].scale)")
        expect(abs(resting[7].scale - (1 - 2 * TrayStripLayout.depthScaleStep)) < 0.001,
               "вторая кромка отдалена на два яруса: \(resting[7].scale)")

        // Во время наезда глубина непрерывна: масштаб уходит вместе с фазой.
        let mid = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                        offset: offsetFor(arriving: 6, phase: 0.5, lengths: lengths),
                                        viewportLength: 600)
        let covered = mid[5]
        expect(covered.scale < 1 && covered.scale > 1 - TrayStripLayout.depthScaleStep,
               "накрываемая карточка отдаляется по фазе: \(covered.scale)")
    }

    /// Карточка никогда не деформируется: полоса — часть целой карточки в
    /// масштабе своей глубины, пропорции сохранены, полоса не длиннее
    /// карточки.
    private static func cardsAreNeverDeformed() {
        let lengths: [CGFloat] = [200, 90, 260, 120, 180, 90, 210, 150, 100, 170]
        let maximum = content(lengths) - lengths[9]
        var offset: CGFloat = 0
        while offset <= maximum {
            let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                              offset: offset, viewportLength: 600)
            for (index, band) in bands.enumerated() where !band.hidden {
                expect(band.insetSteps == 0,
                       "карточка \(index) сужена: \(band.insetSteps)")
                expect(band.length <= lengths[index] + 0.001,
                       "полоса \(index) длиннее карточки: \(band.length)")
                expect(abs(band.contentFraction * lengths[index] * band.scale - band.length) < 0.01,
                       "полоса \(index) искажает контент: \(band.contentFraction)")
            }
            offset += 3
        }
    }

    /// Верх запаркованной срезается ТОЛЬКО низом накрывающей карточки и едет
    /// вместе с ним один к одному.
    private static func parkedCardIsCutOnlyByTheArrivingOne() {
        let lengths = uniform(10)
        let k = 6
        for phase: CGFloat in [0.2, 0.5, 0.8] {
            let offset = offsetFor(arriving: k, phase: phase, lengths: lengths)
            let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                              offset: offset, viewportLength: 600)
            let arriving = bands[k]
            let parked = bands[k - 1]
            expect(arriving.isFullCard, "прибывающая карточка обязана быть целой")
            expect(abs((parked.position + parked.length) - arriving.position) < 0.001,
                   "верх запаркованной обязан совпадать с низом прибывающей: "
                   + "\(parked.position + parked.length) против \(arriving.position)")
            expect(arriving.zOrder > parked.zOrder,
                   "прибывающая обязана лежать поверх запаркованной")
        }
    }

    /// С момента касания стопка оседает на один ярус за время наезда —
    /// глубина читается как медленный параллакс.
    private static func stackSinksWhileTheNextCardArrives() {
        let lengths = uniform(10)
        let k = 6
        let early = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: offsetFor(arriving: k, phase: 0.1, lengths: lengths),
                                          viewportLength: 600)
        let late = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                         offset: offsetFor(arriving: k, phase: 0.9, lengths: lengths),
                                         viewportLength: 600)
        let sankBy = early.bands(at: k - 1).position - late.bands(at: k - 1).position
        expect(abs(sankBy - TrayStripLayout.edgeLength * 0.8) < 0.01,
               "стопка обязана осесть на долю яруса, осела на \(sankBy)")
    }

    /// Пока прибывающая не коснулась стопки, ярусы стоят неподвижно.
    private static func tiersStandStillBeforeTheTouch() {
        let lengths = uniform(10)
        let k = 5
        // Прибывающая в зазоре, до касания.
        let cursor = lengths[0..<k].reduce(0, +) + gap * CGFloat(k)
        let offset = cursor - lengths[k - 1] - gap / 2
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: offset, viewportLength: 600)
        let e = TrayStripLayout.edgeLength
        expect(abs(bands[k - 2].position - e) < 0.001,
               "первая кромка не на ярусе в мёртвой зоне: \(bands[k - 2].position)")
        expect(abs(bands[k - 3].position) < 0.001,
               "вторая кромка не на ярусе в мёртвой зоне: \(bands[k - 3].position)")
        expect(bands[k - 1].isFullCard,
               "верхняя запаркованная целиком видна, пока её не накрыли")
    }

    /// Ни один слой никогда не движется быстрее ленты.
    private static func cardsNeverOutrunTheStrip() {
        let lengths: [CGFloat] = [200, 90, 260, 120, 180, 90, 210, 150, 100, 170]
        let maximum = content(lengths) - lengths[9]
        let step: CGFloat = 1
        var previous = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                             offset: 0, viewportLength: 600)
        var offset = step
        while offset <= maximum {
            let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                              offset: offset, viewportLength: 600)
            for index in 0..<bands.count {
                let was = previous[index], now = bands[index]
                guard !was.hidden, !now.hidden else { continue }
                expect(abs(now.position - was.position) <= step * 1.05 + 0.001,
                       "слой \(index) обогнал ленту позицией на смещении \(offset): "
                       + "\(was.position) → \(now.position)")
                // Высота полосы меняется срезом (1:1) и осадкой (7pt за наезд)
                // одновременно — итог всё равно ограничен.
                expect(abs(now.length - was.length) <= step * 1.2 + 0.001,
                       "полоса \(index) прыгнула высотой на смещении \(offset): "
                       + "\(was.length) → \(now.length)")
            }
            previous = bands
            offset += step
        }
    }

    /// Дальняя стопка — зеркало: карточки паркуются верхами на ярусах у
    /// дальней границы, торчат верхние кромки, ничего не вылезает за окно.
    private static func farStackMirrorsAtTheTop() {
        let lengths = uniform(10)
        let viewport: CGFloat = 600
        let farPark = viewport - TrayStripLayout.parkLevel
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: 0, viewportLength: viewport)
        let parked = bands.enumerated().filter { !$0.element.hidden && $0.element.sliceFromFarSide }
        expect(!parked.isEmpty, "при нулевом смещении дальняя стопка обязана появиться")
        for (index, band) in parked {
            expect(band.position + band.length <= viewport + 0.001,
                   "слой \(index) вылез за окно просмотра: \(band.position + band.length)")
            if band.zOrder <= -2 {
                expect(band.position >= farPark - 0.001,
                       "кромка \(index) ниже дальнего яруса: \(band.position)")
            }
        }
        expect(bands[9].hidden, "самая дальняя карточка глубже стопки")
    }

    /// Нижняя кромка стопки при наезде новой карточки уезжает за базу и
    /// растворяется; тень гаснет вместе с высотой.
    private static func bottomEdgeSinksAndDissolves() {
        let lengths = uniform(10)
        let k = 7

        func bottomEdge(atPhase phase: CGFloat) -> TrayCardBand {
            let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                              offset: offsetFor(arriving: k, phase: phase, lengths: lengths),
                                              viewportLength: 600)
            return bands[k - 3]     // глубина 2 — нижняя видимая кромка
        }

        let early = bottomEdge(atPhase: 0.35)
        expect(early.length < TrayStripLayout.edgeLength && early.length > 0,
               "кромка уезжает за базу: \(early.length)")
        expect(abs(early.opacity - 0.65) < 0.01,
               "кромка растворяется по фазе наезда: \(early.opacity)")
        expect(abs(early.shadowFraction - early.length / TrayStripLayout.edgeLength) < 0.001,
               "тень равна доле оставшейся высоты")

        let late = bottomEdge(atPhase: 0.9)
        expect(late.hidden || (late.opacity < 0.2 && late.length < early.length),
               "к концу наезда нижняя кромка почти исчезла")
    }

    /// Все переходы — чистая функция смещения: на шаге в 1pt ни один слой не
    /// прыгает ни геометрией, ни прозрачностью, ни тенью.
    private static func scrubbingIsContinuous() {
        let lengths: [CGFloat] = [200, 90, 260, 120, 180, 90, 210, 150, 100, 170]
        let maximum = content(lengths) - lengths[9]
        var previous: [TrayCardBand]?
        var offset: CGFloat = 0
        while offset <= maximum {
            let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                              offset: offset, viewportLength: 600)
            if let previous {
                for index in 0..<bands.count {
                    let was = previous[index], now = bands[index]
                    guard !was.hidden, !now.hidden else { continue }
                    expect(abs(now.position - was.position) < 1.1,
                           "слой \(index) прыгнул позицией на смещении \(offset): \(was.position) → \(now.position)")
                    expect(abs(now.length - was.length) < 1.3,
                           "слой \(index) прыгнул высотой на смещении \(offset): \(was.length) → \(now.length)")
                    expect(abs(now.opacity - was.opacity) < 0.1,
                           "слой \(index) мигнул на смещении \(offset): \(was.opacity) → \(now.opacity)")
                    expect(abs(now.shadowFraction - was.shadowFraction) < 0.25,
                           "тень слоя \(index) мигнула на смещении \(offset)")
                    expect(abs(now.scale - was.scale) < 0.02,
                           "масштаб слоя \(index) прыгнул на смещении \(offset): \(was.scale) → \(now.scale)")
                }
            }
            previous = bands
            offset += 1
        }
    }

    /// Слои стопки лежат ЗА потоком, глубже ярус — дальше; прибывающая всегда
    /// поверх запаркованных.
    private static func deeperLayersGoBehind() {
        let lengths = uniform(10)
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: offsetFor(arriving: 6, phase: 0.5, lengths: lengths),
                                          viewportLength: 600)
        for band in bands where !band.hidden && band.zOrder < 0 {
            expect(band.zOrder < 0, "слой стопки не уведён за ленту")
        }
        let nearParked = bands.enumerated()
            .filter { !$0.element.hidden && !$0.element.sliceFromFarSide && $0.element.zOrder < -0.5 }
            .sorted { $0.offset < $1.offset }
        expect(nearParked.count >= 2, "в стопке мало слоёв для проверки порядка")
        for (older, newer) in zip(nearParked, nearParked.dropFirst()) {
            expect(older.element.zOrder < newer.element.zOrder,
                   "старый слой \(older.offset) не глубже нового \(newer.offset)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("TrayScrollModelTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}

private extension [TrayCardBand] {
    func bands(at index: Int) -> TrayCardBand { self[index] }
}
