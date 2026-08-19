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
        detentSlowsInsideTheTensionZone()
        detentSnapsHomeWithAClick()
        detentHoldsAgainstSmallEscape()
        detentReleasesWithAJump()
        detentSkipsShortStrips()
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
        expect(model.offset < -20, "за краем лента почти не сдвинулась: \(model.offset)")
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
        // Асимптота формулы равна самой глубине растяжения.
        let limit = TrayScrollModel.stretchDepth(600)
        expect(abs(model.offset) <= limit + 0.001,
               "растяжение не ограничено: \(model.offset) при пределе \(limit)")
        expect(abs(model.offset) > limit * 0.8,
               "при бесконечном жесте резинка должна дойти до предела: \(model.offset)")

        // На реальном жесте (около 200 pt за краем) уход умеренный.
        var short = TrayScrollModel(contentLength: 1000, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        for _ in 0..<10 { short = short.scrolled(by: -20) }
        expect(abs(short.offset) > 20 && abs(short.offset) < 90,
               "уход за край на обычном жесте вне ожидания: \(short.offset)")
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
