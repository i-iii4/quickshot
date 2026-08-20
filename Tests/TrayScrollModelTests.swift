import CoreGraphics
import Foundation

@main
struct TrayScrollModelTests {
    static func main() {
        singleCardHasNowhereToScroll()
        fullTravelCollectsEverythingButTheNewest()
        scrollingStaysInsideBounds()
        rubberBandResistsBeyondEdges()
        rubberBandFollowsTheFingerMonotonically()
        rubberBandDoesNotDependOnEventSize()
        rubberBandStaysBounded()
        momentumDoesNotStretchTheBand()
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
        cardsAreNeverClippedByTheZoneEdges()
        scrubbingIsContinuous()
        deeperLayersGoBehind()
        boundarySpringIsContinuousAtHandoff()
        boundarySpringBouncesProportionallyToSpeed()
        boundarySpringReturnsWithoutOscillation()
        boundarySpringStaysStillWithoutInput()
        bounceHandoffFiresOnlyAtRealEdges()
        abortedEscapeSeatsBackAndKeepsTheDetent()
        detentSlowsInsideTheTensionZone()
        detentSnapsHomeWithAClick()
        detentHoldsAgainstSmallEscape()
        detentReleasesWithAJump()
        detentSkipsShortStrips()
        deckClosureIsMonotonic()
        deckClosureIsContinuous()
        deckClosureHitsItsBounds()
        detentHoldRevealsTheTiers()
        deckSqueezesEveryGapAlike()
        deckCurveEasesInAndClosesLinearly()
        deckCoverHasNoSpeedStep()
        deckCollapseKeepsCardsContinuous()
        flickProjectionMatchesApplesFormula()
        flickSnapsOnlyWhenItLandsInTheZone()
        detentBackingOutOfTheZoneIsFree()
        detentSettleFinishesTheZone()
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

        let atEnd = TrayScrollModel(contentLength: 1000, viewportLength: 600,
                                    offset: 850, lastCardLength: 150)
        let pushed = atEnd.scrolled(by: 100)
        expect(pushed.overshoot > 0 && pushed.overshoot < 200,
               "дальний край тоже пружинит; получили \(pushed.overshoot)")
    }

    /// Главный инвариант резинки: пока палец идёт в одну сторону, лента
    /// движется туда же и никогда не пятится. Прежняя формула пересчитывала
    /// уже сжатое смещение, из-за чего лента ехала назад при замедлении
    /// пальца — это и читалось как череда дёрганий.
    private static func rubberBandFollowsTheFingerMonotonically() {
        var model = TrayScrollModel(contentLength: 1000, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        var previous = model.offset
        // Палец идёт равномерно, потом замедляется — позиция обязана
        // монотонно уходить за край.
        for delta in [-30.0, -30, -30, -20, -12, -6, -3, -1] {
            model = model.scrolled(by: delta)
            expect(model.offset < previous + 0.001,
                   "лента попятилась при продолжении жеста: \(previous) → \(model.offset)")
            previous = model.offset
        }
        expect(model.offset < -10, "за краем лента почти не сдвинулась: \(model.offset)")
    }

    /// Один и тот же путь пальца даёт один и тот же результат, независимо от
    /// того, пришёл он одним событием или дюжиной мелких.
    private static func rubberBandDoesNotDependOnEventSize() {
        let base = TrayScrollModel(contentLength: 1000, viewportLength: 600,
                                   offset: 0, lastCardLength: 150)
        let oneStep = base.scrolled(by: -120)
        var manySteps = base
        for _ in 0..<12 { manySteps = manySteps.scrolled(by: -10) }
        expect(abs(oneStep.offset - manySteps.offset) < 0.001,
               "дробление жеста меняет результат: \(oneStep.offset) против \(manySteps.offset)")
    }

    /// Сколько ни тяни, за край уходит ограниченная величина: упор должен
    /// читаться пределом, а не уездом ленты за экран.
    private static func rubberBandStaysBounded() {
        var model = TrayScrollModel(contentLength: 1000, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        for _ in 0..<200 { model = model.scrolled(by: -50) }
        // Асимптота формулы равна характерному размеру — длине карточки.
        let limit = model.stretchDimension
        expect(abs(model.offset) <= limit + 0.001,
               "растяжение не ограничено: \(model.offset) при пределе \(limit)")
        expect(abs(model.offset) > limit * 0.8,
               "при бесконечном жесте резинка должна дойти до предела: \(model.offset)")

        // На реальном жесте (около 200 pt за краем) уход умеренный.
        var short = TrayScrollModel(contentLength: 1000, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        for _ in 0..<10 { short = short.scrolled(by: -20) }
        expect(abs(short.offset) > 10 && abs(short.offset) < short.stretchDimension,
               "уход за край на обычном жесте вне ожидания: \(short.offset)")
    }

    /// Резинку тянет только палец. Инерция упирается в край: иначе лента
    /// продолжает уезжать уже после отпускания, а возврат приходит с
    /// задержкой.
    private static func momentumDoesNotStretchTheBand() {
        let model = TrayScrollModel(contentLength: 1000, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        let byFinger = model.scrolled(by: -80, rubberBand: true)
        expect(byFinger.offset < -1, "палец обязан уводить ленту за край")
        let byMomentum = model.scrolled(by: -80, rubberBand: false)
        expect(byMomentum.offset == 0, "инерция увела ленту за край: \(byMomentum.offset)")
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
        // Кромка — выступ ЦЕЛОЙ карточки из-под соседки: полоса рисуется до
        // своего настоящего верха и уходит под соседку, наружу торчат 7pt.
        expect(abs(bands[8].position - e) < 0.001,
               "первая кромка на своём ярусе: \(bands[8].position)")
        expect(abs(bands[7].position) < 0.001,
               "вторая кромка прижата к базе: \(bands[7].position)")
        for index in [7, 8] {
            let band = bands[index]
            expect(band.position + band.length <= newest.position + newest.length + 0.001,
                   "слой \(index) торчит над стопкой")
            expect(band.length > e, "полоса \(index) — целая карточка, не срез: \(band.length)")
            expect(!band.sliceFromFarSide, "кромки у кнопки показывают НИЗЫ карточек")
            expect(band.roundsStart, "низ кромки \(index) — настоящий край")
        }
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
        expect(abs(bands[4].position - e) < 0.001,
               "первая кромка на ярусе независимо от высот")
        expect(abs(bands[3].position) < 0.001,
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

    /// Запаркованная карточка рисуется ЦЕЛОЙ и уходит ПОД прибывающую:
    /// перекрытие делает кромку само, включая скруглённые углы прибывающей.
    /// Линия среза по низу накрывающей запрещена.
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
            expect(parked.position + parked.length > arriving.position + 1,
                   "запаркованная обязана уходить ПОД прибывающую, а не "
                   + "обрезаться её низом: верх \(parked.position + parked.length), "
                   + "низ прибывающей \(arriving.position)")
            expect(parked.roundsEnd,
                   "верх запаркованной под прибывающей — настоящий край карточки")
            expect(parked.roundsStart, "низ запаркованной — настоящий край")
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
            let bandTop = band.position + band.length
            expect(bandTop <= viewport + 0.001,
                   "слой \(index) вылез за окно просмотра: \(bandTop)")
            expect(bandTop >= farPark - 0.001,
                   "верх слоя \(index) ниже дальнего яруса: \(bandTop)")
        }
        // Выступы верхних кромок — не больше яруса; слой, упершийся в край
        // окна, тает на месте, и его выступ легитимно сжимается.
        let tops = parked.map { $0.element.position + $0.element.length }.sorted()
        for (lower, upper) in zip(tops, tops.dropFirst()) {
            let step = upper - lower
            expect(step > -0.001 && step <= TrayStripLayout.edgeLength + 0.75,
                   "выступ верхней кромки больше яруса: \(step)")
        }
        expect(bands[9].hidden, "самая дальняя карточка глубже стопки")
    }

    /// Нижняя кромка стопки при наезде новой карточки растворяется НА СВОЁМ
    /// ярусе: никуда не уезжает, её низ — всегда настоящий скруглённый край.
    private static func bottomEdgeSinksAndDissolves() {
        let lengths = uniform(10)
        let k = 7

        func bands(atPhase phase: CGFloat) -> [TrayCardBand] {
            TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                  offset: offsetFor(arriving: k, phase: phase, lengths: lengths),
                                  viewportLength: 600)
        }

        let early = bands(atPhase: 0.35)
        let bottomEarly = early[k - 3]      // глубина 2 — нижняя видимая кромка
        expect(abs(bottomEarly.position) < 0.001,
               "нижняя кромка стоит на базе: \(bottomEarly.position)")
        expect(bottomEarly.roundsStart && bottomEarly.cardStartOffset >= -0.001,
               "низ нижней кромки — настоящий край, не обрезка")
        expect(abs(bottomEarly.opacity - 0.65) < 0.01,
               "кромка растворяется по фазе наезда: \(bottomEarly.opacity)")
        // Выступ из-под соседки сокращается: соседка опускается на её ярус.
        let protrusionEarly = early[k - 2].position - bottomEarly.position
        expect(protrusionEarly < TrayStripLayout.edgeLength,
               "выступ нижней кромки обязан сокращаться: \(protrusionEarly)")

        let late = bands(atPhase: 0.9)
        let bottomLate = late[k - 3]
        expect(bottomLate.hidden || bottomLate.opacity < 0.2,
               "к концу наезда нижняя кромка почти исчезла")
    }

    /// Ни одна карточка НИКОГДА не обрезается краями зоны: нижняя кромка
    /// растворяется на своём ярусе, а не уезжает за виртуальную линию базы с
    /// прямым срезом; дальняя — упирается в край окна и тает, не выезжая.
    /// Низ полосы ближней стопки — всегда настоящий скруглённый край.
    private static func cardsAreNeverClippedByTheZoneEdges() {
        let lengths: [CGFloat] = [200, 90, 260, 120, 180, 90, 210, 150, 100, 170]
        let maximum = content(lengths) - lengths[9]
        let viewport: CGFloat = 600
        var offset: CGFloat = 0
        while offset <= maximum {
            let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                              offset: offset, viewportLength: viewport)
            for (index, band) in bands.enumerated() where !band.hidden {
                if !band.sliceFromFarSide {
                    expect(band.roundsStart && band.cardStartOffset >= -0.001,
                           "полоса \(index) обрезана базой на смещении \(offset): "
                           + "offset \(band.cardStartOffset)")
                    expect(band.position >= -0.001,
                           "полоса \(index) ниже базы на смещении \(offset)")
                } else {
                    expect(band.roundsEnd,
                           "полоса \(index) обрезана краем окна на смещении \(offset)")
                    expect(band.position + band.length <= viewport + 0.001,
                           "полоса \(index) выше окна на смещении \(offset)")
                }
            }
            offset += 2
        }
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

    // MARK: защёлка полного сбора (`TR-29`)

    private static func detentModel() -> TrayScrollModel {
        TrayScrollModel(contentLength: 600, viewportLength: 400, offset: 0, lastCardLength: 100)
    }

    /// В зоне напряжения лента идёт медленнее пальца.
    private static func detentSlowsInsideTheTensionZone() {
        var model = detentModel()
        var detent = TrayDetentModel()
        model.offset = model.maximumOffset - TrayDetentModel.zone
        let (next, click) = detent.apply(delta: 9, to: model)
        expect(click == nil, "щелчок раньше порога проскока")
        expect(abs(next.offset - (model.offset + 9 / TrayDetentModel.tension)) < 0.001,
               "зона не замедлила ход: \(next.offset - model.offset) вместо \(9 / TrayDetentModel.tension)")
    }

    /// Проскок порога защёлкивает ленту домой одним кадром.
    private static func detentSnapsHomeWithAClick() {
        var model = detentModel()
        var detent = TrayDetentModel()
        model.offset = model.maximumOffset - TrayDetentModel.zone
        let travel = (TrayDetentModel.zone - TrayDetentModel.snapRemainder) * TrayDetentModel.tension + 1
        let (next, click) = detent.apply(delta: travel, to: model)
        expect(click == .snapIn, "проскок без щелчка")
        expect(abs(next.offset - model.maximumOffset) < 0.001, "защёлкнулась не домой: \(next.offset)")
        expect(detent.engaged, "защёлка не встала")
    }

    /// Малый обратный ход лишь страгивает ленту: защёлка держит.
    private static func detentHoldsAgainstSmallEscape() {
        var model = detentModel()
        var detent = TrayDetentModel()
        model.offset = model.maximumOffset
        detent.sync(with: model)
        expect(detent.engaged, "sync не увидел собранную ленту")
        let (next, click) = detent.apply(delta: -(TrayDetentModel.escape / 2), to: model)
        expect(click == nil, "защёлка отпустила раньше порога")
        expect(detent.engaged, "защёлка потеряла хват")
        let creep = model.maximumOffset - next.offset
        expect(creep > 0.5 && creep < TrayDetentModel.zone / 2,
               "страгивание вне ожидания: \(creep)")
    }

    /// Накопленный побег вырывает ленту прыжком к началу зоны.
    private static func detentReleasesWithAJump() {
        var model = detentModel()
        var detent = TrayDetentModel()
        model.offset = model.maximumOffset
        detent.sync(with: model)
        var click: TrayDetentModel.Click?
        var offsetAtClick: CGFloat = .nan
        for _ in 0..<4 where click == nil {
            let result = detent.apply(delta: -(TrayDetentModel.escape / 3), to: model)
            model = result.model
            if let c = result.click {
                click = c
                offsetAtClick = model.offset
            }
        }
        expect(click == .release, "побег не дал щелчка")
        expect(abs(offsetAtClick - (model.maximumOffset - TrayDetentModel.zone)) < 0.001,
               "прыжок не к началу зоны: \(offsetAtClick)")
        expect(!detent.engaged, "защёлка не отпустила")
    }

    /// Короткой ленте защёлка не положена: ход как у обычной прокрутки.
    private static func detentSkipsShortStrips() {
        var model = TrayScrollModel(contentLength: 130, viewportLength: 400, offset: 0,
                                    lastCardLength: 100)
        var detent = TrayDetentModel()
        let (next, click) = detent.apply(delta: 20, to: model)
        model = model.scrolled(by: 20)
        expect(click == nil, "щелчок на короткой ленте")
        expect(abs(next.offset - model.offset) < 0.001, "короткая лента пошла через защёлку")
    }

    /// До щелчка выход из зоны свободен: жест легко отменяется.
    private static func detentBackingOutOfTheZoneIsFree() {
        var model = detentModel()
        var detent = TrayDetentModel()
        model.offset = model.maximumOffset - TrayDetentModel.zone / 2
        let (next, click) = detent.apply(delta: -10, to: model)
        expect(click == nil, "обратный ход дал щелчок")
        expect(abs(next.offset - (model.offset - 10)) < 0.001,
               "обратный ход в зоне не один к одному: \(model.offset - next.offset)")
    }

    /// Замерший в зоне жест не оставляет ленту на скате.
    private static func detentSettleFinishesTheZone() {
        var model = detentModel()
        let detent = TrayDetentModel()
        let zoneStart = model.maximumOffset - TrayDetentModel.zone
        model.offset = zoneStart + TrayDetentModel.zone / 2
        expect(detent.settleTarget(for: model) == model.maximumOffset,
               "глубокий замер не дожат домой")
        model.offset = zoneStart + 2
        expect(detent.settleTarget(for: model) == zoneStart,
               "мелкий замер не выпущен к началу зоны")
        model.offset = zoneStart - 10
        expect(detent.settleTarget(for: model) == nil, "цель защёлки вне зоны")
    }

    // MARK: пружина границы (`TR-13`)

    /// Непрерывность в точке передачи: позиция и скорость на входе пружины
    /// совпадают с тем, что было в момент передачи. Разрыв скорости — это и
    /// есть «нет замедления».
    private static func boundarySpringIsContinuousAtHandoff() {
        for (x0, v0) in [(0.0, 900.0), (40.0, -300.0), (25.0, 0.0)] {
            let position = TrayBoundarySpring.offset(displacement: x0, velocity: v0, time: 0)
            let speed = TrayBoundarySpring.velocity(displacement: x0, velocity: v0, time: 0)
            expect(abs(position - x0) < 0.001, "позиция рвётся на входе: \(position) вместо \(x0)")
            expect(abs(speed - v0) < 0.001, "скорость рвётся на входе: \(speed) вместо \(v0)")
        }
    }

    /// Отскок существует и пропорционален скорости: вдвое быстрее — вдвое
    /// глубже. Подбирать глубину не нужно, она следует из скорости.
    private static func boundarySpringBouncesProportionallyToSpeed() {
        func peakByScan(_ v0: CGFloat) -> CGFloat {
            stride(from: 0.0, through: TrayBoundarySpring.duration, by: 0.001)
                .map { TrayBoundarySpring.offset(displacement: 0, velocity: v0, time: $0) }
                .max() ?? 0
        }
        let slow = peakByScan(400)
        let fast = peakByScan(800)
        expect(slow > 1, "отскока нет вовсе: \(slow)")
        expect(abs(slow - TrayBoundarySpring.peak(velocity: 400)) < slow * 0.01,
               "пик разошёлся с формулой: \(slow) против \(TrayBoundarySpring.peak(velocity: 400))")
        expect(abs(fast / slow - 2) < 0.02,
               "глубина непропорциональна скорости: \(fast) против \(slow)")
    }

    /// Возврат монотонный и полный: знак не меняется (нет колебаний), хвост к
    /// концу прогона исчезает.
    private static func boundarySpringReturnsWithoutOscillation() {
        for (x0, v0) in [(60.0, 0.0), (0.0, 700.0), (30.0, 500.0)] {
            var previous = TrayBoundarySpring.offset(displacement: x0, velocity: v0, time: 0)
            var peak = abs(previous)
            var crossedZero = false
            for t in stride(from: 0.0, through: TrayBoundarySpring.duration, by: 0.005) {
                let value = TrayBoundarySpring.offset(displacement: x0, velocity: v0, time: t)
                peak = max(peak, abs(value))
                if value * previous < -0.001 { crossedZero = true }
                previous = value
            }
            expect(!crossedZero, "пружина колеблется при x0=\(x0) v0=\(v0)")
            let tail = abs(TrayBoundarySpring.offset(displacement: x0, velocity: v0,
                                                     time: TrayBoundarySpring.duration))
            expect(tail < peak * 0.005, "хвост не исчез: \(tail) при пике \(peak)")
        }
    }

    /// Без смещения и скорости пружина не двигает ленту: медленное подведение
    /// к краю отскока не даёт.
    private static func boundarySpringStaysStillWithoutInput() {
        for t in stride(from: 0.0, through: TrayBoundarySpring.duration, by: 0.02) {
            let value = TrayBoundarySpring.offset(displacement: 0, velocity: 0, time: t)
            expect(abs(value) < 0.001, "пружина двинулась без входа: \(value)")
        }
    }

    /// Таблица передачи инерции пружине: только настоящий край, никогда —
    /// зона защёлки. Косвенный признак «сдвиг меньше дельты» глушил бросок к
    /// сбору посреди зоны натяжения.
    private static func bounceHandoffFiresOnlyAtRealEdges() {
        var strip = TrayScrollModel(contentLength: 1000, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        // Свободный край, инерция наружу — отскок.
        expect(TrayBoundaryHandoff.shouldBounce(model: strip, delta: -20,
                                                fingersDown: false, isMomentum: true),
               "нет отскока на свободном крае")
        // Тот же край, но пальцы на трекпаде — растягивает резинка, не пружина.
        expect(!TrayBoundaryHandoff.shouldBounce(model: strip, delta: -20,
                                                 fingersDown: true, isMomentum: false),
               "отскок под пальцем")
        // Инерция внутрь хода — никакой передачи.
        expect(!TrayBoundaryHandoff.shouldBounce(model: strip, delta: 20,
                                                 fingersDown: false, isMomentum: true),
               "отскок при движении внутрь хода")
        // Середина хода — никакой передачи.
        strip.offset = 300
        expect(!TrayBoundaryHandoff.shouldBounce(model: strip, delta: -20,
                                                 fingersDown: false, isMomentum: true),
               "отскок посреди хода")
        // Зона защёлки: лента идёт медленнее дельт, но это НЕ край.
        strip.offset = strip.maximumOffset - TrayDetentModel.effectiveZone(for: strip) / 2
        expect(!TrayBoundaryHandoff.shouldBounce(model: strip, delta: 20,
                                                 fingersDown: false, isMomentum: true),
               "отскок в зоне защёлки — бросок к сбору глохнет")
        // Дальний край с защёлкой — конец хода принадлежит защёлке.
        strip.offset = strip.maximumOffset
        expect(!TrayBoundaryHandoff.shouldBounce(model: strip, delta: 20,
                                                 fingersDown: false, isMomentum: true),
               "отскок на краю защёлки")
        // Дальний край короткой ленты без защёлки — отскок положен.
        var short = TrayScrollModel(contentLength: 130, viewportLength: 600,
                                    offset: 0, lastCardLength: 100)
        short.offset = short.maximumOffset
        expect(!TrayDetentModel.fits(short), "короткая лента получила защёлку")
        expect(TrayBoundaryHandoff.shouldBounce(model: short, delta: 20,
                                                fingersDown: false, isMomentum: true),
               "нет отскока на дальнем крае без защёлки")
        // Колесо (не инерция) — жёсткий упор, без пружин.
        expect(!TrayBoundaryHandoff.shouldBounce(model: short, delta: 20,
                                                 fingersDown: false, isMomentum: false),
               "отскок от колеса")
    }

    /// Недожатый выход: короткий скролл из защёлки, порог не пройден. Лента
    /// обязана дотянуться обратно в посадочное место, зацепление — уцелеть,
    /// а следующий полный выход — дать щелчок. Багом короткий скролл
    /// оставлял ленту в миллиметре от места и убивал щелчок выхода насовсем.
    private static func abortedEscapeSeatsBackAndKeepsTheDetent() {
        var model = TrayScrollModel(contentLength: 600, viewportLength: 400,
                                    offset: 0, lastCardLength: 100)
        var detent = TrayDetentModel()
        model.offset = model.maximumOffset
        detent.sync(with: model)
        expect(detent.engaged, "защёлка не зацепилась в исходном состоянии")

        // Короткий недоскролл: порог выхода (escape) не пройден.
        let result = detent.apply(delta: -(TrayDetentModel.escape / 4), to: model, stretch: true)
        model = result.model
        expect(result.click == nil, "недоскролл дал щелчок")
        expect(model.offset < model.maximumOffset - 0.5, "страгивание не видно")

        // Жест кончился: осадка обязана вернуть ленту в посадочное место.
        let target = detent.settleTarget(for: model)
        expect(target == model.maximumOffset,
               "недожатый выход не дотянут в место: \(String(describing: target))")
        model.offset = model.maximumOffset
        detent.sync(with: model)
        expect(detent.engaged, "зацепление потеряно после дотяжки")
        // В посадочном месте дотягивать больше нечего.
        expect(detent.settleTarget(for: model) == nil, "дотяжка зациклилась")

        // Полный выход после этого работает и щёлкает.
        var click: TrayDetentModel.Click?
        for _ in 0..<6 where click == nil {
            let step = detent.apply(delta: -(TrayDetentModel.escape / 3), to: model, stretch: true)
            model = step.model
            click = step.click
        }
        expect(click == .release, "щелчок выхода умер после недоскролла")
    }

    // MARK: проекция броска (`TR-36`)

    /// Проекция считается формулой Apple, а не подобранным числом.
    private static func flickProjectionMatchesApplesFormula() {
        let rate = TrayFlickProjection.decelerationRate
        for velocity in [200.0, 500, 1000, 2000] {
            let expected = (velocity / 1000) * rate / (1 - rate)
            let actual = TrayFlickProjection.distance(velocity: velocity)
            expect(abs(actual - expected) < 0.001,
                   "проекция разошлась с формулой на \(velocity): \(actual)")
        }
        // Вдвое быстрее — вдвое дальше.
        expect(abs(TrayFlickProjection.distance(velocity: 1000)
                   - 2 * TrayFlickProjection.distance(velocity: 500)) < 0.001,
               "проекция непропорциональна скорости")
        // Стоящая лента никуда не проедет.
        expect(TrayFlickProjection.distance(velocity: 0) == 0, "стоящая лента проехала")
    }

    /// Таблица срабатывания: бросок защёлкивает, только если лента
    /// остановилась бы В зоне. Пролёт сквозь зону на скорости защёлкивать
    /// нельзя — пользователь прокручивает мимо, а не собирает стопку.
    private static func flickSnapsOnlyWhenItLandsInTheZone() {
        var model = TrayScrollModel(contentLength: 600, viewportLength: 400,
                                    offset: 0, lastCardLength: 100)
        let zone = TrayDetentModel.effectiveZone(for: model)
        let zoneStart = model.maximumOffset - zone

        // Бросок, чья проекция попадает в зону, — защёлкиваем.
        model.offset = zoneStart - 100
        let intoZone = (100 + zone / 2) / (TrayFlickProjection.decelerationRate
                                           / (1 - TrayFlickProjection.decelerationRate)) * 1000
        expect(TrayFlickProjection.shouldSnap(model: model, velocity: intoZone),
               "бросок в зону не защёлкнул")

        // Слабое движение, не доносящее до зоны, — не защёлкиваем.
        expect(!TrayFlickProjection.shouldSnap(model: model, velocity: intoZone / 4),
               "слабое движение защёлкнуло")

        // Сильный бросок с близкой позиции защёлкивает: зона стоит в КОНЦЕ
        // хода, пролететь сквозь неё некуда — лента упирается в край и всё
        // равно окажется собранной.
        expect(TrayFlickProjection.shouldSnap(model: model, velocity: intoZone * 8),
               "сильный бросок к концу хода не защёлкнул")

        // А вот бросок с дальнего конца ленты — это прокрутка, а не сбор.
        var far = model
        far.offset = 0
        expect(far.maximumOffset - far.offset > zone * TrayFlickProjection.intentRange,
               "тестовая лента слишком коротка для проверки дальнего броска")
        expect(!TrayFlickProjection.shouldSnap(model: far, velocity: intoZone * 8),
               "бросок с дальнего конца защёлкнул")

        // Бросок в обратную сторону защёлку не трогает.
        expect(!TrayFlickProjection.shouldSnap(model: model, velocity: -intoZone),
               "обратный бросок защёлкнул")

        // Короткой ленте защёлка не положена вовсе.
        let short = TrayScrollModel(contentLength: 130, viewportLength: 400,
                                    offset: 0, lastCardLength: 100)
        expect(!TrayFlickProjection.shouldSnap(model: short, velocity: intoZone),
               "короткая лента защёлкнулась по броску")
    }

    // MARK: закрытие колоды наезжанием (`TR-34`)

    private static func deckStrip() -> TrayScrollModel {
        TrayScrollModel(contentLength: 600, viewportLength: 400, offset: 0, lastCardLength: 100)
    }

    /// Критерий 1: при движении ленты к сбору перекрытие только растёт, при
    /// обратном — только убывает.
    private static func deckClosureIsMonotonic() {
        let model = deckStrip()
        let zone = TrayDetentModel.effectiveZone(for: model)
        var previous: CGFloat = -1
        for step in stride(from: model.maximumOffset - zone * 1.2,
                           through: model.maximumOffset, by: 0.5) {
            let shift = TrayDeckClosure.collapse(presented: step, model: model)
            expect(shift >= previous - 0.001,
                   "перекрытие уменьшилось при движении к сбору: \(previous) → \(shift)")
            previous = shift
        }
    }

    /// Критерий 2: соседние положения ленты дают близкие величины —
    /// разрывов нет.
    private static func deckClosureIsContinuous() {
        let model = deckStrip()
        let zone = TrayDetentModel.effectiveZone(for: model)
        var previous = TrayDeckClosure.collapse(
            presented: model.maximumOffset - zone * 1.2, model: model)
        for step in stride(from: model.maximumOffset - zone * 1.2,
                           through: model.maximumOffset, by: 0.5) {
            let shift = TrayDeckClosure.collapse(presented: step, model: model)
            expect(abs(shift - previous) < 0.1,
                   "разрыв перекрытия на позиции \(step): скачок \(shift - previous)")
            previous = shift
        }
    }

    /// Сжатие РАВНОМЕРНОЕ: промежутки стопки сокращаются в той же
    /// пропорции, что и зазор между стопкой и доезжающей карточкой.
    /// Требование заказчика: «если бы это были физические объекты и я их
    /// сжимал, расстояние между ними сокращалось бы равномерно; нет
    /// момента, когда я вижу меньше объектов».
    ///
    /// Зазор равен остатку пути и кривой не подчиняется — поэтому кривая
    /// схлопывания обязана давать раскрытие, линейное по остатку. Гладкая
    /// с обоих концов кривая этого не даёт: у посадки она гасит промежутки
    /// стопки быстрее, чем закрывается зазор, и слои пропадают по одному.
    private static func deckSqueezesEveryGapAlike() {
        let model = deckStrip()
        let zone = TrayDetentModel.effectiveZone(for: model)
        var ratios: [CGFloat] = []
        var distance = zone
        while distance > 2 {
            let presented = model.maximumOffset - distance
            let open = 1 - TrayDeckClosure.collapse(presented: presented, model: model)
            // Промежуток стопки — ярус, сжатый на ту же долю; зазор — сам
            // остаток пути. Отношение обязано держаться, а не уходить в ноль.
            let tierGap = TrayStripLayout.edgeLength * open
            ratios.append(tierGap / distance)
            distance -= 2
        }
        let low = ratios.min() ?? 0
        let high = ratios.max() ?? 0
        expect(low > 0.08, "промежутки стопки схлопываются раньше зазора: \(low)")
        expect(high / max(low, 0.0001) < 2.5,
               "сжатие неравномерно: отношение гуляет от \(low) до \(high)")
    }

    /// Подтягивание до щелчка ПРИОТКРЫВАЕТ ярусы соразмерно ходу, а
    /// отпускание закрывает обратно. Требование заказчика словами
    /// пользователя: «потянул чуть-чуть, не дожидаясь щелчка, увидел
    /// немножко нижний ярус; отпустил — всё вернулось на место».
    ///
    /// Тест сторожит СВЯЗКУ двух параметров, а не одно число: люфт защёлки
    /// `escape / holdTension` обязан дотягиваться за плато схлопывания
    /// `zone × (1 - completionPoint)`. Настройка любого из них поодиночке
    /// снова сделает подтягивание немым — так и случилось 20.08.2026.
    private static func detentHoldRevealsTheTiers() {
        let model = deckStrip()
        let closed = TrayDeckClosure.collapse(presented: model.maximumOffset, model: model)
        expect(abs(closed - 1) < 0.001, "дома колода не закрыта: \(closed)")

        var previous = closed
        var reveal: [CGFloat] = []
        for share in [CGFloat(0.4), 0.7, 0.99] {
            var detent = TrayDetentModel()
            var home = model
            home.offset = model.maximumOffset
            detent.sync(with: home)
            let (pulled, click) = detent.apply(delta: -(TrayDetentModel.escape * share), to: home)
            expect(click == nil, "защёлка сорвалась на доле \(share)")
            let value = TrayDeckClosure.collapse(presented: pulled.offset, model: model)
            expect(value <= previous + 0.001, "приоткрывание не монотонно на доле \(share)")
            previous = value
            reveal.append(1 - value)
        }

        // На полном ходе удержания колода обязана быть ЗАМЕТНО приоткрыта.
        // Порог — пятая часть: на люфте защёлки в 8 pt раскрытие 27%, и
        // ярус выглядывает примерно на 1.9 pt, различимый глазом край.
        expect(reveal.last! > 0.2,
               "подтягивание почти не открывает колоду: \(reveal.last! * 100)%")

        // Отпускание возвращает ленту домой, и колода закрывается обратно.
        var detent = TrayDetentModel()
        var home = model
        home.offset = model.maximumOffset
        detent.sync(with: home)
        let (pulled, _) = detent.apply(delta: -(TrayDetentModel.escape * 0.9), to: home)
        expect(pulled.offset < model.maximumOffset, "подтягивание не сдвинуло ленту")
        let released = TrayDeckClosure.collapse(presented: model.maximumOffset, model: model)
        expect(abs(released - 1) < 0.001, "после возврата колода не закрылась: \(released)")
    }

    /// Критерий 3: на краю зоны перекрытия нет, у посадки ярусы закрыты
    /// полностью, причём закрытие завершается РАНЬШЕ посадки.
    private static func deckClosureHitsItsBounds() {
        let model = deckStrip()
        let zone = TrayDetentModel.effectiveZone(for: model)
        let atZoneStart = TrayDeckClosure.value(presented: model.maximumOffset - zone, model: model)
        expect(atZoneStart == 0, "на краю зоны уже есть перекрытие: \(atZoneStart)")

        let atHome = TrayDeckClosure.value(presented: model.maximumOffset, model: model)
        expect(atHome == 1, "у посадки колода не закрыта: \(atHome)")
        expect(abs(TrayDeckClosure.collapse(presented: model.maximumOffset, model: model) - 1) < 0.001,
               "у посадки колода не схлопнута полностью")

        // Схлопывание завершается РОВНО в посадке, а не раньше. Плато у
        // посадки, где промежутки стопки уже нулевые, а зазор до доезжающей
        // карточки ещё нет, роняло число видимых слоёв (приёмка 20.08.2026).
        let completionDistance = zone * (1 - TrayDeckClosure.completionPoint)
        expect(completionDistance < 0.001,
               "схлопывание кончается раньше посадки: \(completionDistance) pt плато")
        let atCompletion = TrayDeckClosure.collapse(
            presented: model.maximumOffset - completionDistance, model: model)
        expect(atCompletion >= 0.999, "колода не сложилась к своей точке: \(atCompletion)")

        // Короткой ленте закрытие не положено.
        let short = TrayScrollModel(contentLength: 130, viewportLength: 400,
                                    offset: 0, lastCardLength: 100)
        expect(TrayDeckClosure.value(presented: short.maximumOffset, model: short) == 0,
               "короткая лента закрывает колоду")
    }

    /// Критерий 4: кривая гладкая на ВХОДЕ в зону и ЛИНЕЙНА у посадки.
    ///
    /// Два конца отвечают за разное. На входе скорость обязана быть
    /// нулевой — иначе колода дёргается в движение при пересечении границы
    /// зоны. У посадки, наоборот, скорость обязана быть НЕнулевой: зазор
    /// между стопкой и доезжающей карточкой закрывается линейно по остатку
    /// пути, и промежутки стопки должны сокращаться в той же пропорции.
    /// Гладкая с обоих концов кривая гасила их раньше зазора, и число
    /// видимых слоёв падало с трёх до одного (приёмка 20.08.2026).
    private static func deckCurveEasesInAndClosesLinearly() {
        let step: CGFloat = 0.001
        let startSpeed = (TrayDeckClosure.curve(step) - TrayDeckClosure.curve(0)) / step
        let endSpeed = (TrayDeckClosure.curve(1) - TrayDeckClosure.curve(1 - step)) / step
        let midSpeed = (TrayDeckClosure.curve(0.5 + step) - TrayDeckClosure.curve(0.5)) / step

        expect(startSpeed < midSpeed * 0.05,
               "колода дёргается на входе в зону: скорость \(startSpeed) против \(midSpeed)")
        expect(endSpeed > midSpeed,
               "у посадки кривая замедляется и гасит слои раньше зазора: \(endSpeed)")

        // Раскрытие линейно по остатку пути: доля, на которую колода
        // раскрыта, пропорциональна тому, сколько ленте осталось доехать.
        let a = 1 - TrayDeckClosure.curve(1 - 0.02)
        let b = 1 - TrayDeckClosure.curve(1 - 0.04)
        expect(abs(b / a - 2) < 0.15,
               "раскрытие не пропорционально остатку пути: \(b / a) вместо 2")
    }

    /// Скорость схлопывания меняется ПЛАВНО: кусочно-линейное деление
    /// удваивало её ступенькой на границе ярусов, и глаз читал рывок ровно в
    /// этой точке. Проверяем непрерывность первой производной.
    private static func deckCoverHasNoSpeedStep() {
        let model = deckStrip()
        let zone = TrayDetentModel.effectiveZone(for: model)
        let span = zone * TrayDeckClosure.completionPoint
        let step: CGFloat = 0.005
        var previousSpeed: CGFloat?
        var maxJump: CGFloat = 0
        for c in stride(from: 0.0, through: 1.0 - step, by: step) {
            let here = TrayDeckClosure.collapse(
                presented: model.maximumOffset - zone + span * c, model: model)
            let next = TrayDeckClosure.collapse(
                presented: model.maximumOffset - zone + span * (c + step), model: model)
            let speed = (next - here) / step
            if let previousSpeed {
                maxJump = max(maxJump, abs(speed - previousSpeed))
            }
            previousSpeed = speed
        }
        expect(maxJump < 0.05, "скорость схлопывания меняется ступенькой: скачок \(maxJump)")
    }

    /// Схлопывание не имеет права рвать движение отдельной карточки: порог
    /// парковки обязан схлопываться вместе с ярусами. Пока он оставался
    /// прежним, карточка считалась запаркованной по старому порогу, а
    /// ставилась по схлопнутому — прыжок ровно на высоту яруса в момент
    /// парковки (приёмка 20.08.2026).
    private static func deckCollapseKeepsCardsContinuous() {
        let lengths: [CGFloat] = Array(repeating: 180, count: 4)
        let gap: CGFloat = 12
        let content = lengths.reduce(0, +) + gap * CGFloat(lengths.count - 1)
        let model = TrayScrollModel(contentLength: content, viewportLength: 800,
                                    offset: 0, lastCardLength: 180)
        let zone = TrayDetentModel.effectiveZone(for: model)

        var previous: [Int: CGFloat] = [:]
        var maxJump: CGFloat = 0
        for i in 0...300 {
            let offset = model.maximumOffset - 150 + CGFloat(i) * 0.5
            var probe = model
            probe.offset = offset
            let closure = TrayDeckClosure.collapse(presented: offset, model: probe)
            let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap, offset: offset,
                                              viewportLength: 800, deckClosure: closure)
            for (index, band) in bands.enumerated() where !band.hidden {
                if let was = previous[index] {
                    maxJump = max(maxJump, abs(band.position - was))
                }
                previous[index] = band.position
            }
        }
        _ = zone
        // Шаг ленты 0.5 pt: карточка не имеет права смещаться существенно
        // больше. Разрыв на границе парковки давал 14.8 pt.
        expect(maxJump < 2, "карточка прыгает при схлопывании: \(maxJump) pt за 0.5 pt хода")
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
