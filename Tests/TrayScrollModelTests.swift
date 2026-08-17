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
        restingStackHasConstantSlots()
        mixedHeightsKeepTheSilhouetteClean()
        cardsNeverOutrunTheStrip()
        edgesStandStillBetweenArrivals()
        edgesNeverLeaveTheReserves()
        farStackMirrorsInsideTheReserve()
        dissolveGeometryLeadsOpacity()
        scrubbingIsContinuous()
        deeperLayersGoBehind()
        print("TrayScrollModelTests: passed")
    }

    // MARK: модель смещения

    /// Одна карточка: собирать нечего, ход нулевой. Но уже две карточки можно
    /// сложить в стопку у кнопки (`TR-4a`), даже если лента помещается целиком.
    private static func singleCardHasNowhereToScroll() {
        let one = TrayScrollModel(contentLength: 150, viewportLength: 600,
                                  offset: 0, lastCardLength: 150)
        expect(one.maximumOffset == 0, "единственной карточке некуда ехать")

        let two = TrayScrollModel(contentLength: 312, viewportLength: 600,
                                  offset: 0, lastCardLength: 150)
        expect(two.isScrollable, "две карточки складываются в стопку")
        expect(two.maximumOffset == 162,
               "ход — до начала новейшей карточки; получили \(two.maximumOffset)")
    }

    /// `TR-4a`: максимальный ход оставляет новейшую карточку целиком видимой
    /// верхним элементом стопки.
    private static func fullTravelCollectsEverythingButTheNewest() {
        let model = TrayScrollModel(contentLength: 1608, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        expect(model.maximumOffset == 1458,
               "ход до новейшей карточки; получили \(model.maximumOffset)")
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
        expect(pushed.overshoot > 0 && pushed.overshoot < 100,
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

    /// `TR-5`: докрутка до нового снимка учитывает резервы обеих стопок —
    /// новейшая карточка видна целиком в полезной зоне.
    private static func revealOffsetShowsTheNewestCard() {
        let model = TrayScrollModel(contentLength: 1608, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        let reveal = model.revealNewestOffset()
        let usable = 600 - TrayStripLayout.nearReserve - TrayStripLayout.farReserve
        expect(abs(reveal - (1608 - usable)) < 0.001,
               "докрутка до видимости новейшей; получили \(reveal)")

        let short = TrayScrollModel(contentLength: 300, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        expect(short.revealNewestOffset() == 0, "короткой ленте докрутка не нужна")
    }

    // MARK: силуэт стопки

    private static let gap: CGFloat = 12

    private static func uniform(_ count: Int) -> [CGFloat] {
        Array(repeating: CGFloat(150), count: count)
    }

    private static func content(_ lengths: [CGFloat]) -> CGFloat {
        lengths.reduce(0, +) + gap * CGFloat(lengths.count - 1)
    }

    /// `TR-24`, `TR-25`: при полном сборе новейшая карточка стоит на границе
    /// резерва, под ней две кромки по 7pt ровно в постоянных слотах.
    private static func restingStackHasConstantSlots() {
        let lengths = uniform(10)
        let offset = content(lengths) - 150
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: offset, viewportLength: 600)
        let e = TrayStripLayout.edgeLength
        let base = TrayStripLayout.nearReserve
        let newest = bands[9]
        expect(newest.isFullCard && abs(newest.position - base) < 0.001,
               "новейшая карточка целиком на границе резерва: \(newest.position)")
        expect(abs(bands[8].position - e) < 0.001 && abs(bands[8].length - e) < 0.001,
               "первая кромка в своём слоте: \(bands[8].position), \(bands[8].length)")
        expect(abs(bands[7].position) < 0.001 && abs(bands[7].length - e) < 0.001,
               "вторая кромка прижата к базе: \(bands[7].position), \(bands[7].length)")
        expect(bands[8].insetSteps < bands[7].insetSteps,
               "глубокая кромка уже мелкой")
        for index in 0...6 {
            expect(bands[index].hidden, "слой \(index) глубже стопки обязан скрыться")
        }
    }

    /// Слоты кромок — константы: карточки разной высоты дают ровно тот же
    /// силуэт стопки, что и одинаковые.
    private static func mixedHeightsKeepTheSilhouetteClean() {
        let lengths: [CGFloat] = [200, 90, 260, 120, 180, 90]
        let offset = content(lengths) - lengths[5]
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: offset, viewportLength: 600)
        let e = TrayStripLayout.edgeLength
        let base = TrayStripLayout.nearReserve
        expect(bands[5].isFullCard && abs(bands[5].position - base) < 0.001,
               "новейшая карточка целиком на границе резерва")
        expect(abs(bands[4].position - e) < 0.001 && abs(bands[4].length - e) < 0.001,
               "первая кромка в слоте независимо от высот")
        expect(abs(bands[3].position) < 0.001 && abs(bands[3].length - e) < 0.001,
               "вторая кромка в слоте независимо от высот")
        for index in 0...2 {
            expect(bands[index].hidden, "слой \(index) глубже стопки обязан скрыться")
        }
    }

    /// Карточка всегда движется со скоростью ленты, а не быстрее: ни один
    /// слой не обгоняет ход прокрутки ни позицией, ни высотой. Первая ревизия
    /// нарушала это (кромки ездили в 1.7 раза быстрее ленты) — трей «болтался».
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
                expect(abs(now.position - was.position) <= step + 0.001,
                       "слой \(index) обогнал ленту позицией на смещении \(offset): "
                       + "\(was.position) → \(now.position)")
                expect(abs(now.length - was.length) <= step + 0.001,
                       "слой \(index) обогнал ленту высотой на смещении \(offset): "
                       + "\(was.length) → \(now.length)")
            }
            previous = bands
            offset += step
        }
    }

    /// Пока никакая карточка не конденсируется в кромку, кромки стоят ровно в
    /// своих слотах — стопка неподвижна между прибытиями.
    private static func edgesStandStillBetweenArrivals() {
        let lengths = uniform(10)
        let e = TrayStripLayout.edgeLength
        let base = TrayStripLayout.nearReserve
        // Прибывающая карточка ровно посередине мёртвой зоны: до конденсации
        // ей ещё далеко.
        let offset = 5 * (150 + gap) + 75
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: offset, viewportLength: 600)
        let nearEdges = bands.filter { !$0.hidden && $0.insetSteps >= 0.999 && $0.sliceFromFarSide }
        expect(!nearEdges.isEmpty, "в середине ленты у кнопки обязана быть стопка")
        for edge in nearEdges {
            let inSlotOne = abs(edge.position - e) < 0.001
            let inSlotTwo = abs(edge.position) < 0.001
            expect(inSlotOne || inSlotTwo,
                   "кромка вне слота в мёртвой зоне: \(edge.position)")
            expect(abs(edge.length - e) < 0.001 || edge.length < 0.05,
                   "кромка меняет высоту в мёртвой зоне: \(edge.length)")
        }
        _ = base
    }

    /// Кромки не покидают резервы: сужение по глубине живёт только между
    /// кнопкой и лентой или в дальнем резерве, не поверх полезной зоны.
    private static func edgesNeverLeaveTheReserves() {
        let lengths: [CGFloat] = [200, 90, 260, 120, 180, 90, 210, 150, 100, 170]
        let maximum = content(lengths) - lengths[9]
        let viewport: CGFloat = 600
        let nearLimit = TrayStripLayout.nearReserve
        let farStartLimit = viewport - TrayStripLayout.farReserve
        var offset: CGFloat = 0
        while offset <= maximum {
            let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                              offset: offset, viewportLength: viewport)
            for (index, band) in bands.enumerated() where !band.hidden && band.insetSteps >= 0.999 {
                let inNear = band.sliceFromFarSide
                    && band.position >= -0.001
                    && band.position + band.length <= nearLimit + 0.001
                let inFar = !band.sliceFromFarSide
                    && band.position >= farStartLimit - 0.001
                    && band.position + band.length <= viewport + 0.001
                expect(inNear || inFar,
                       "кромка \(index) вне резерва на смещении \(offset): "
                       + "[\(band.position), \(band.position + band.length)]")
            }
            offset += 7
        }
    }

    /// Дальняя стопка живёт в резерве за границей полезной зоны и никогда не
    /// вылезает за окно просмотра (`TR-4b`).
    private static func farStackMirrorsInsideTheReserve() {
        let lengths = uniform(10)
        let viewport: CGFloat = 600
        let farBase = viewport - TrayStripLayout.farReserve
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: 0, viewportLength: viewport)
        let farBands = bands.enumerated().filter {
            !$0.element.hidden && !$0.element.sliceFromFarSide && $0.element.insetSteps > 0.001
        }
        expect(!farBands.isEmpty, "при нулевом смещении дальняя стопка обязана появиться")
        for (index, band) in farBands {
            expect(band.position >= farBase - TrayStripLayout.edgeLength - 0.001,
                   "слой \(index) дальней стопки ниже резерва: \(band.position)")
            expect(band.position + band.length <= viewport + 0.001,
                   "слой \(index) вылез за окно просмотра: \(band.position + band.length)")
        }
        expect(bands[9].hidden, "самая дальняя карточка глубже стопки")
    }

    /// `TR-26`: у растворяющейся кромки геометрия ведёт, прозрачность падает
    /// только в последней трети, тень привязана к оставшейся высоте.
    private static func dissolveGeometryLeadsOpacity() {
        let lengths = uniform(10)
        let e = TrayStripLayout.edgeLength

        // Смещение, при котором прибывающая карточка k конденсируется с фазой
        // `phase`: её верх на nearReserve + e(1-phase).
        func dissolving(atPhase phase: CGFloat) -> TrayCardBand {
            let k = 7
            let cursor = CGFloat(k) * (150 + gap)
            let offset = cursor + 150 - e * (1 - phase)
            let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                              offset: offset, viewportLength: 600)
            return bands[k - 2]     // ранг 2 — растворяющаяся
        }

        let early = dissolving(atPhase: 0.35)
        expect(early.length < e && early.length > 0,
               "геометрия уже уходит: \(early.length)")
        expect(early.opacity > 0.999,
               "прозрачность в первой части не трогается: \(early.opacity)")
        expect(abs(early.shadowFraction - early.length / e) < 0.001,
               "тень равна доле оставшейся высоты")

        let late = dissolving(atPhase: 0.93)
        expect(late.opacity < 1, "в хвосте прозрачность гаснет: \(late.opacity)")
        expect(late.length < early.length, "геометрия продолжает уходить")
    }

    /// Растворение и все переходы — чистая функция смещения: на шаге в 1pt ни
    /// один слой не прыгает ни геометрией, ни прозрачностью, ни тенью.
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
                    expect(abs(now.length - was.length) < 1.1,
                           "слой \(index) прыгнул высотой на смещении \(offset): \(was.length) → \(now.length)")
                    expect(abs(now.opacity - was.opacity) < 0.6,
                           "слой \(index) мигнул на смещении \(offset): \(was.opacity) → \(now.opacity)")
                    expect(abs(now.shadowFraction - was.shadowFraction) < 0.2,
                           "тень слоя \(index) мигнула на смещении \(offset)")
                }
            }
            previous = bands
            offset += 1
        }
    }

    /// Слои стопки лежат ЗА развёрнутыми карточками, глубже ранг — дальше.
    private static func deeperLayersGoBehind() {
        let lengths = uniform(10)
        // Прибывающая на середине конденсации: в стопке есть и кромки, и
        // конденсирующаяся полоса.
        let k = 6
        let offset = CGFloat(k) * (150 + gap) + 150 - TrayStripLayout.edgeLength / 2
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: offset, viewportLength: 600)
        for band in bands where !band.hidden && band.insetSteps > 0.001 {
            expect(band.zOrder < 0, "слой стопки не уведён за ленту: \(band.zOrder)")
        }
        let nearLayers = bands.enumerated()
            .filter { !$0.element.hidden && $0.element.sliceFromFarSide && $0.element.insetSteps > 0.001 }
            .sorted { $0.offset < $1.offset }
        for (older, newer) in zip(nearLayers, nearLayers.dropFirst()) {
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
