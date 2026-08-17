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
        restingStackIsFrontPlusTwoEdges()
        mixedHeightsKeepTheSilhouetteClean()
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

    /// `TR-5`: докрутка до нового снимка учитывает полосу дальней стопки —
    /// новейшая карточка видна целиком, а не срезана резервом.
    private static func revealOffsetShowsTheNewestCard() {
        let model = TrayScrollModel(contentLength: 1608, viewportLength: 600,
                                    offset: 0, lastCardLength: 150)
        let reveal = model.revealNewestOffset()
        let usable = 600 - TrayStripLayout.farReserve
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

    /// `TR-24`, `TR-25`: в покое силуэт — верхняя карточка и ровно две кромки
    /// по 7pt, каждая уже предыдущей; глубже — ничего.
    private static func restingStackIsFrontPlusTwoEdges() {
        let lengths = uniform(10)
        let content = lengths.reduce(0, +) + gap * 9
        let offset = content - 150     // полный сбор: ход до новейшей карточки
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: offset, viewportLength: 600)
        let newest = bands[9]
        expect(newest.isFullCard && abs(newest.position) < 0.001,
               "новейшая карточка лежит целиком у кнопки")

        let e = TrayStripLayout.edgeLength
        expect(abs(bands[8].position - 150) < 0.001 && abs(bands[8].length - e) < 0.001,
               "первая кромка сразу за карточкой: \(bands[8].position), \(bands[8].length)")
        expect(abs(bands[7].position - 150 - e) < 0.001 && abs(bands[7].length - e) < 0.001,
               "вторая кромка за первой: \(bands[7].position), \(bands[7].length)")
        expect(bands[8].insetSteps < bands[7].insetSteps,
               "глубокая кромка уже мелкой")
        for index in 0...6 {
            expect(bands[index].hidden, "слой \(index) глубже стопки обязан скрыться")
        }
    }

    /// Карточки разной высоты не торчат из стопки: в покое кромки стоят по
    /// своим слотам независимо от высот, силуэт заканчивается на второй кромке.
    private static func mixedHeightsKeepTheSilhouetteClean() {
        let lengths: [CGFloat] = [200, 90, 260, 120, 180, 90]
        let content = lengths.reduce(0, +) + gap * 5
        let offset = content - lengths[5]
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: offset, viewportLength: 600)
        let e = TrayStripLayout.edgeLength
        let front = lengths[5]
        expect(bands[5].isFullCard, "новейшая карточка целиком")
        for (index, band) in bands.enumerated() where index != 5 && !band.hidden {
            expect(band.length <= e + 0.001,
                   "слой \(index) высотой \(band.length) торчит из стопки")
            expect(band.position >= front - 0.001
                   && band.position + band.length <= front + 2 * e + 0.001,
                   "слой \(index) вне силуэта: [\(band.position), \(band.position + band.length)]")
        }
    }

    /// Дальняя стопка живёт в резерве за границей `usable` и никогда не
    /// вылезает за окно просмотра (`TR-4b`).
    private static func farStackMirrorsInsideTheReserve() {
        let lengths = uniform(10)
        let viewport: CGFloat = 600
        let usable = viewport - TrayStripLayout.farReserve
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: 0, viewportLength: viewport)
        let farBands = bands.enumerated().filter { !$0.element.hidden && $0.element.position + $0.element.length > usable + 0.5 }
        expect(!farBands.isEmpty, "при нулевом смещении дальняя стопка обязана появиться")
        for (index, band) in farBands {
            expect(band.position + band.length <= viewport + 0.001,
                   "слой \(index) вылез за окно просмотра: \(band.position + band.length)")
            expect(!band.sliceFromFarSide,
                   "дальняя стопка режет содержимое с ближней стороны")
        }
        // Глубже стопки — скрыто, и скрытые начинаются с самых новых карточек.
        expect(bands[9].hidden, "самая дальняя карточка глубже стопки")
    }

    /// `TR-26`: у растворяющейся кромки геометрия ведёт, прозрачность падает
    /// только в последней трети, тень привязана к оставшейся высоте.
    private static func dissolveGeometryLeadsOpacity() {
        let lengths = uniform(10)
        let e = TrayStripLayout.edgeLength

        func dissolving(atPhase phase: CGFloat) -> TrayCardBand {
            // Смещение, при котором самый мелкий утонувший слой имеет глубину
            // `phase`: третий с конца ранг тогда растворяется.
            let content = lengths.reduce(0, +) + gap * 9
            let offset = content - 150 - (150 + gap) + (150 + gap) * phase
            let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                              offset: offset, viewportLength: 600)
            // Ранг 2 в этот момент — карточка на три позиции глубже входящей.
            let sunkCount = bands.filter { !$0.isFullCard || $0.insetSteps > 0 }.count
            _ = sunkCount
            return bands[6]
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
        let content = lengths.reduce(0, +) + gap * 9
        let maximum = content - lengths[9]
        var previous: [TrayCardBand]?
        var offset: CGFloat = 0
        while offset <= maximum {
            let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                              offset: offset, viewportLength: 600)
            if let previous {
                for index in 0..<bands.count {
                    let was = previous[index], now = bands[index]
                    guard !was.hidden, !now.hidden else { continue }
                    expect(abs(now.position - was.position) < 6,
                           "слой \(index) прыгнул позицией на смещении \(offset): \(was.position) → \(now.position)")
                    expect(abs(now.length - was.length) < 6,
                           "слой \(index) прыгнул высотой на смещении \(offset): \(was.length) → \(now.length)")
                    expect(abs(now.opacity - was.opacity) < 0.12,
                           "слой \(index) мигнул на смещении \(offset): \(was.opacity) → \(now.opacity)")
                    expect(abs(now.shadowFraction - was.shadowFraction) < 0.3,
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
        let content = lengths.reduce(0, +) + gap * 9
        let bands = TrayStripLayout.bands(cardLengths: lengths, gap: gap,
                                          offset: content - 150 - 81,
                                          viewportLength: 600)
        for band in bands where !band.hidden && !band.isFullCard {
            expect(band.zOrder < 0, "слой стопки не уведён за ленту: \(band.zOrder)")
        }
        let nearLayers = bands.enumerated()
            .filter { !$0.element.hidden && !$0.element.isFullCard }
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
