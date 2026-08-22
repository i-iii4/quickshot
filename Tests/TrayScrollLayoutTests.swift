import AppKit

/// Раскладка ленты по смещению прокрутки (`TR-1`, `TR-3`, `TR-5`).
///
/// Модельные тесты `TrayScrollModelTests` проверяют арифметику полос. Здесь
/// проверяется, что полосы доходят до координат карточек на каждом из четырёх
/// краёв экрана: именно этого звена не хватало — модель считала, а раскладка
/// её игнорировала.
@main
struct TrayScrollLayoutTests {
    private static let screen = NSRect(x: 0, y: 0, width: 1600, height: 900)
    private static let hub = NSSize(width: 120, height: 40)
    private static let margin: CGFloat = 16
    private static let gap: CGFloat = 12

    static func main() {
        offsetMovesCards()
        stacksAppearAtTheHub()
        deepCardsLeaveTheStrip()
        horizontalTrayScrollsAlongItsAxis()
        shortStripIsUnaffected()
        edgesKeepCardsOnScreen()
        bandFieldsReachSlots()
        trailingStackStaysOnScreen()
        deeperLayersGoBehind()
        stowSweepKeepsTheBaseStill()
        stowSweepSurvivesCollectionChanges()
        visibleFrameFollowsTheSlot()
        loneCardStandsWhereTheStackTopStands()
        print("TrayScrollLayoutTests: passed")
    }

    /// Смещение обязано двигать координаты, иначе прокрутка существует только
    /// в модели.
    /// Единственная карточка стоит РОВНО ТАМ ЖЕ, где верхняя карточка
    /// стопки. Резерв под ярусы поднимал её на `parkLevel` выше, и удаление
    /// предпоследнего снимка давало прыжок на 14 pt: одиночный снимок и
    /// снимок в стопке жили по разным правилам (приёмка 21.08.2026).
    private static func loneCardStandsWhereTheStackTopStands() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let cardW: CGFloat = 200, cardH: CGFloat = 150, gap: CGFloat = 8, margin: CGFloat = 16

        func topOfGatheredStrip(count: Int) -> CGFloat {
            let heights = Array(repeating: cardH, count: count)
            let content = heights.reduce(0, +) + gap * CGFloat(max(0, count - 1))
            var model = TrayScrollModel(
                contentLength: content,
                viewportLength: thumbnailTrayViewportLength(screenFrame: screen, edge: .right,
                                                            hubSize: .zero, margin: margin,
                                                            menuBarInset: 24),
                offset: 0, lastCardLength: cardH)
            model.offset = model.maximumOffset
            let layout = thumbnailScrollLayout(
                screenFrame: screen, edge: .right, cardWidth: cardW, cardHeights: heights,
                hubSize: .zero, margin: margin, gap: gap, offset: model.offset,
                menuBarInset: 24,
                deckProgress: TrayDeckClosure.value(presented: model.offset, model: model))
            let top = layout.visible.max(by: { $0.index < $1.index })!
            return thumbnailVisibleFrame(slot: top,
                                         cardSize: NSSize(width: cardW, height: cardH),
                                         vertical: true).minY
        }

        let three = topOfGatheredStrip(count: 3)
        let two = topOfGatheredStrip(count: 2)
        let one = topOfGatheredStrip(count: 1)
        expect(abs(three - two) < 0.001, "верх стопки зависит от её глубины: \(three) против \(two)")
        expect(abs(two - one) < 0.001,
               "одиночная карточка встала не там, где верх стопки: \(one) против \(two)")
    }

    /// Целевая рамка карточки по слоту — та же геометрия, что кладёт сама
    /// карточка. По ней контур шкатулки берёт МЕСТО влетающей карточки:
    /// по живой рамке шкатулку уводило вбок вслед за влётом.
    private static func visibleFrameFollowsTheSlot() {
        let card = NSSize(width: 200, height: 150)

        // Полная карточка: рамка совпадает со слотом, без полей.
        let full = ThumbnailLayoutSlot(index: 0, origin: NSPoint(x: 300, y: 40))
        let frame = thumbnailVisibleFrame(slot: full, cardSize: card, vertical: false)
        expect(frame == NSRect(x: 300, y: 40, width: 200, height: 150),
               "полная карточка встала не по слоту: \(frame)")

        // Слой стопки: полоса короче карточки и центрирована поперёк оси на
        // то, что съела перспектива.
        var band = ThumbnailLayoutSlot(index: 1, origin: NSPoint(x: 300, y: 40))
        band.isFullCard = false
        band.length = 12
        band.scale = 0.8
        let bandFrame = thumbnailVisibleFrame(slot: band, cardSize: card, vertical: false)
        expect(abs(bandFrame.width - 12) < 0.001, "полоса взяла не свою длину: \(bandFrame.width)")
        expect(abs(bandFrame.height - 120) < 0.001, "перспектива не применилась: \(bandFrame.height)")
        expect(abs(bandFrame.minY - (40 + 15)) < 0.001,
               "полоса не центрирована поперёк оси: \(bandFrame.minY)")

        // Вертикальная лента: оси меняются местами.
        let vertical = thumbnailVisibleFrame(slot: band, cardSize: card, vertical: true)
        expect(abs(vertical.height - 12) < 0.001, "вертикальная полоса взяла не свою длину")
        expect(abs(vertical.minX - (300 + 20)) < 0.001, "вертикальная полоса не центрирована")
    }

    /// `TR-41`: раскладка ведётся по ВСЕМУ ходу — от нуля до конца ступени
    /// убирания — и на каждом шаге проверяется целиком.
    ///
    /// Замеров отдельных положений недостаточно: три реализации подряд
    /// давали верные числа на статических срезах и разваливались в движении.
    /// Дефект живёт в сочетании — лента едет, ступень не в нуле, — поэтому
    /// проверка идёт непрерывным проходом.
    private static func stowSweepKeepsTheBaseStill() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let cardW: CGFloat = 200, cardH: CGFloat = 150, gap: CGFloat = 8, margin: CGFloat = 16
        let heights = Array(repeating: cardH, count: 5)
        let content = heights.reduce(0, +) + gap * CGFloat(heights.count - 1)
        var model = TrayScrollModel(contentLength: content, viewportLength: 844,
                                    offset: 0, lastCardLength: cardH)
        // Проход ведётся по ленте, которой ступень УЖЕ разрешена: фаза
        // дискретна и меняется щелчком, а тест проверяет геометрию внутри
        // неё.
        model.stowed = true
        let base = screen.minY + margin

        // Сопоставление идёт по НАСТОЯЩЕМУ индексу карточки, а не по месту в
        // списке видимых: когда одна выпадает, места сдвигаются, и сравнение
        // пошло бы между разными карточками.
        func frames(at offset: CGFloat) -> [Int: NSRect] {
            model.offset = offset
            let layout = thumbnailScrollLayout(
                screenFrame: screen, edge: .right, cardWidth: cardW, cardHeights: heights,
                hubSize: .zero, margin: margin, gap: gap, offset: offset, menuBarInset: 24,
                deckProgress: TrayDeckClosure.value(presented: offset, model: model),
                stow: model.stowProgress)
            var result: [Int: NSRect] = [:]
            for slot in layout.visible {
                result[slot.index] = thumbnailVisibleFrame(
                    slot: slot, cardSize: NSSize(width: cardW, height: cardH), vertical: true)
            }
            return result
        }

        // Низ в точке упора — эталон для ступени.
        let baseAtStop = frames(at: model.maximumOffset).values
            .reduce(CGRect.null) { $0.union($1) }.minY

        var previous: [Int: NSRect] = [:]
        var sawStowed = false
        var topAtStow: CGFloat = .greatestFiniteMagnitude
        var offset: CGFloat = 0
        while offset <= model.stowedMaximumOffset + 0.001 {
            model.offset = offset
            let current = frames(at: offset)
            let list = Array(current.values)
            let union = list.reduce(CGRect.null) { $0.union($1) }

            if !list.isEmpty {
                // Низ шкатулки НЕПОДВИЖЕН: колода стягивается к основанию.
                // Низ не уходит НИЖЕ основания нигде.
                expect(union.minY >= base - 0.5,
                       "низ колоды ушёл ниже основания при ходе \(offset): \(union.minY)")
                // А НА СТУПЕНИ он неподвижен — это равенство, а не «не ниже».
                // Односторонним неравенством проходила и колода, уехавшая
                // вверх от основания (аудит 22.08.2026). До упора низ
                // меняется законно: схлопывается резерв под ярусы.
                if offset > model.maximumOffset + 0.5 {
                    expect(abs(union.minY - baseAtStop) < 0.5,
                           "низ шкатулки сместился на ступени при ходе \(offset): \(union.minY) вместо \(baseAtStop)")
                }
                // Ни одна карточка не выходит за экран.
                for frame in list {
                    expect(frame.minY >= screen.minY - 0.5 && frame.maxY <= screen.maxY + 0.5,
                           "карточка вышла за экран по вертикали при ходе \(offset)")
                    expect(frame.minX >= screen.minX - 0.5 && frame.maxX <= screen.maxX + 0.5,
                           "карточка вышла за экран по горизонтали при ходе \(offset)")
                }
            }

            // За упором верх монотонно убывает.
            if offset > model.maximumOffset, !union.isNull {
                expect(union.maxY <= topAtStow + 0.5,
                       "верх колоды растёт на ступени при ходе \(offset)")
                topAtStow = union.maxY
            } else if !union.isNull {
                topAtStow = union.maxY
            }

            // Разрывов нет НИГДЕ, включая границу упора.
            for (index, frame) in current {
                if let was = previous[index] {
                    let shift = max(abs(frame.minY - was.minY), abs(frame.minX - was.minX))
                    expect(shift <= 1,
                           "разрыв \(shift) pt у карточки \(index) при ходе \(offset)")
                }
            }
            previous = current
            if offset >= model.stowedMaximumOffset - 0.001 {
                sawStowed = true
                expect(list.isEmpty, "в конце ступени карточки всё ещё видны: \(list.count)")
            }
            offset += 0.5
        }
        expect(sawStowed, "проход не дошёл до конца ступени")

        // Прозрачность и масштаб монотонны и приходят в свои точки.
        var previousOpacity: CGFloat = 2
        var previousScale: CGFloat = 2
        var step: CGFloat = 0
        while step <= 1.0001 {
            let bands = TrayStripLayout.stowed(
                [TrayCardBand(position: 0, length: cardH, insetSteps: 0, contentFraction: 1,
                              sliceFromFarSide: false, opacity: 1, shadowFraction: 1,
                              zOrder: 0, hidden: false)], progress: step)
            let band = bands[0]
            expect(band.opacity <= previousOpacity + 0.0001, "прозрачность не монотонна")
            expect(band.scale <= previousScale + 0.0001, "масштаб не монотонен")
            previousOpacity = band.opacity
            previousScale = band.scale
            step += 0.05
        }
        expect(previousOpacity <= 0.0001, "прозрачность не пришла в ноль: \(previousOpacity)")
        expect(abs(previousScale - TrayStow.stowedScale) < 0.001,
               "масштаб не пришёл в свою точку: \(previousScale)")
    }

    /// Ступень переживает смену состава: снимок прилетел или ушёл, пока
    /// колода убрана.
    private static func stowSweepSurvivesCollectionChanges() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let cardW: CGFloat = 200, cardH: CGFloat = 150, gap: CGFloat = 8, margin: CGFloat = 16

        func sweep(count: Int) -> [NSRect] {
            let heights = Array(repeating: cardH, count: count)
            let content = heights.reduce(0, +) + gap * CGFloat(max(0, count - 1))
            var model = TrayScrollModel(contentLength: content, viewportLength: 844,
                                        offset: 0, lastCardLength: cardH)
            model.stowed = true
            model.offset = model.stowedMaximumOffset
            let layout = thumbnailScrollLayout(
                screenFrame: screen, edge: .right, cardWidth: cardW, cardHeights: heights,
                hubSize: .zero, margin: margin, gap: gap, offset: model.offset, menuBarInset: 24,
                deckProgress: TrayDeckClosure.value(presented: model.offset, model: model),
                stow: model.stowProgress)
            return layout.visible.map {
                thumbnailVisibleFrame(slot: $0, cardSize: NSSize(width: cardW, height: cardH),
                                      vertical: true)
            }
        }

        for count in [1, 2, 3, 5, 8] {
            expect(sweep(count: count).isEmpty,
                   "при \(count) снимках убранная колода всё ещё видна")
        }

        // `TR-41`: вставка снимка при убранной колоде оставляет смещение в
        // конце ступени — третья фаза не прерывается, меняется только
        // счётчик. Проверяется тем, что после удлинения ленты конец ступени
        // по-прежнему держит колоду убранной.
        let heights = Array(repeating: cardH, count: 3)
        let content = heights.reduce(0, +) + gap * CGFloat(heights.count - 1)
        var before = TrayScrollModel(contentLength: content, viewportLength: 844,
                                     offset: 0, lastCardLength: cardH)
        before.stowed = true
        before.offset = before.stowedMaximumOffset
        expect(before.isStowed, "исходная лента не убрана")

        var after = before
        after.contentLength = content + cardH + gap
        after.offset = after.stowedMaximumOffset
        expect(after.isStowed, "после вставки колода перестала быть убранной")
        expect(after.stowProgress > 0.9999,
               "после вставки степень убранности упала: \(after.stowProgress)")
    }

    private static func offsetMovesCards() {
        let heights = Array(repeating: CGFloat(200), count: 10)
        let atStart = layout(heights: heights, offset: 0)
        let scrolled = layout(heights: heights, offset: 300)

        guard let firstAtStart = atStart.visible.first(where: { $0.index == 2 }),
              let firstScrolled = scrolled.visible.first(where: { $0.index == 2 }) else {
            fail("карточка 2 пропала из ленты")
            return
        }
        expect(abs(firstAtStart.origin.y - firstScrolled.origin.y - 300) < 1,
               "смещение 300 не сдвинуло карточку: \(firstAtStart.origin.y) → \(firstScrolled.origin.y)")
    }

    /// `TR-3`, `TR-23`: у кнопки карточки собираются в стопку-кромки, а не
    /// улетают за экран.
    private static func stacksAppearAtTheHub() {
        let heights = Array(repeating: CGFloat(200), count: 12)
        let result = layout(heights: heights, offset: 600)
        let bands = result.visible.filter { !$0.isFullCard }
        expect(!bands.isEmpty, "при смещении 600 стопка обязана появиться")
        let stripBase = screen.minY + margin + hub.height + TrayStripLayout.hubClearance
        for slot in bands {
            expect(slot.origin.y >= stripBase - 0.5,
                   "кромка уезжает под хаб: \(slot.origin.y)")
            expect(slot.length < 200, "кромка обязана быть полосой, не карточкой")
        }
    }

    /// Глубже стопки карточки скрываются: две кромки в покое и третья в
    /// переходе достаточно, чтобы показать «дальше есть ещё».
    private static func deepCardsLeaveTheStrip() {
        let heights = Array(repeating: CGFloat(200), count: 20)
        let result = layout(heights: heights, offset: 1500)
        expect(!result.hidden.isEmpty, "глубокие карточки обязаны уходить из ленты")
        expect(result.visible.count < 20, "все двадцать карточек не могут быть видимы")
        expect(result.visible.count >= 3, "видимых слишком мало: \(result.visible.count)")
    }

    /// `TR-6`, `TR-15`, `TR-16`: горизонтальный трей двигается по своей оси.
    private static func horizontalTrayScrollsAlongItsAxis() {
        let heights = Array(repeating: CGFloat(200), count: 12)
        let atStart = thumbnailScrollLayout(screenFrame: screen, edge: .bottom,
                                            cardWidth: 240, cardHeights: heights,
                                            hubSize: hub, margin: margin, gap: gap, offset: 0)
        let scrolled = thumbnailScrollLayout(screenFrame: screen, edge: .bottom,
                                             cardWidth: 240, cardHeights: heights,
                                             hubSize: hub, margin: margin, gap: gap, offset: 250)

        guard let before = atStart.visible.first(where: { $0.index == 1 }),
              let after = scrolled.visible.first(where: { $0.index == 1 }) else {
            fail("карточка 1 пропала из горизонтальной ленты")
            return
        }
        expect(abs(before.origin.y - after.origin.y) < 1,
               "горизонтальная лента не должна двигаться по вертикали")
        expect(abs(before.origin.x - after.origin.x) > 100,
               "горизонтальная лента обязана двигаться по горизонтали: \(before.origin.x) → \(after.origin.x)")
    }

    /// Пока лента помещается в полезную часть окна, прокрутка ничего не
    /// прячет и не сужает.
    private static func shortStripIsUnaffected() {
        let heights = Array(repeating: CGFloat(200), count: 3)
        let result = layout(heights: heights, offset: 0)
        expect(result.hidden.isEmpty, "короткая лента не прячет карточки")
        expect(result.visible.count == 3, "видимы все три карточки")
        expect(result.visible.allSatisfy(\.isFullCard), "все три карточки целиком")
    }

    /// Абсолютная геометрия каждого края: полоса обязана совпадать с обычной
    /// раскладкой `thumbnailLayout`. Именно тут трей ломался при переполнении:
    /// правый край считался от ширины хаба, верхний ставил карточку за экран.
    private static func edgesKeepCardsOnScreen() {
        let heights = Array(repeating: CGFloat(200), count: 12)
        for edge in ThumbnailLayoutEdge.allCases {
            let result = thumbnailScrollLayout(screenFrame: screen, edge: edge,
                                               cardWidth: 240, cardHeights: heights,
                                               hubSize: hub, margin: margin, gap: gap,
                                               offset: 600)
            for slot in result.visible {
                let along = slot.isFullCard
                    ? (edge.isVertical ? heights[slot.index] : 240)
                    : slot.length
                switch edge {
                case .right:
                    expect(abs(slot.origin.x - (screen.maxX - margin - 240)) < 0.5,
                           "правый край: x карточки \(slot.origin.x)")
                case .left:
                    expect(abs(slot.origin.x - (screen.minX + margin)) < 0.5,
                           "левый край: x карточки \(slot.origin.x)")
                case .bottom:
                    expect(abs(slot.origin.y - (screen.minY + margin)) < 0.5,
                           "нижний край: y карточки \(slot.origin.y)")
                    expect(slot.origin.x + along <= screen.maxX - margin - hub.width - TrayStripLayout.hubClearance + 0.5,
                           "нижний край: карточка налезает на хаб: \(slot.origin.x + along)")
                case .top:
                    expect(abs(slot.origin.y - (screen.maxY - margin - 200)) < 0.5,
                           "верхний край: карточка за экраном: \(slot.origin.y)")
                    expect(slot.origin.x + along <= screen.maxX - margin - hub.width - TrayStripLayout.hubClearance + 0.5,
                           "верхний край: карточка налезает на хаб: \(slot.origin.x + along)")
                }
            }
        }
    }

    /// Поля полосы обязаны доходить до слотов раскладки, а не оставаться в
    /// модели: кромка режет содержимое перекрытием и несёт свою тень.
    /// Карточки жёсткие: никаких сужений ни у кого.
    private static func bandFieldsReachSlots() {
        let heights = Array(repeating: CGFloat(200), count: 12)
        let result = layout(heights: heights, offset: 600)
        let bands = result.visible.filter { !$0.isFullCard }
        expect(!bands.isEmpty, "у кнопки нет ни одной кромки стопки")
        expect(result.visible.allSatisfy { $0.insetSteps == 0 },
               "жёсткие карточки не сужаются")
        expect(bands.allSatisfy { $0.length > 0 && $0.length < 200 },
               "кромка — полоса, а не карточка целиком")
        let full = result.visible.filter(\.isFullCard)
        expect(full.allSatisfy { $0.opacity > 0.999 },
               "развёрнутые карточки не тускнеют")
    }

    /// Дальняя стопка живёт в резерве окна просмотра и не касается края
    /// экрана (`TR-4b`).
    private static func trailingStackStaysOnScreen() {
        let heights = Array(repeating: CGFloat(200), count: 14)
        let result = layout(heights: heights, offset: 0)
        for slot in result.visible {
            let top = slot.origin.y + (slot.isFullCard ? heights[slot.index] : slot.length)
            expect(top <= screen.maxY - margin + 0.5,
                   "карточка \(slot.index) уходит за верхний край: \(top) при пределе \(screen.maxY - margin)")
        }

        // Со строкой меню граница опускается: лента не заходит под меню.
        let menuBar: CGFloat = 30
        let insetResult = thumbnailScrollLayout(screenFrame: screen, edge: .right,
                                                cardWidth: 240, cardHeights: heights,
                                                hubSize: hub, margin: margin, gap: gap,
                                                offset: 0, menuBarInset: menuBar)
        for slot in insetResult.visible {
            let top = slot.origin.y + (slot.isFullCard ? heights[slot.index] : slot.length)
            expect(top <= screen.maxY - menuBar - margin + 0.5,
                   "карточка \(slot.index) заходит под строку меню: \(top)")
        }
    }

    /// Слой стопки лежит ЗА карточками ленты: иначе кромка рисуется поверх
    /// развёрнутых карточек и стопка превращается в мешанину.
    private static func deeperLayersGoBehind() {
        let heights = Array(repeating: CGFloat(200), count: 14)
        let result = layout(heights: heights, offset: 0)
        let stacked = result.visible.filter { $0.stackOrder < -0.5 && !$0.isFullCard }
        expect(!stacked.isEmpty, "в ленте нет ни одного слоя стопки")
        for slot in stacked {
            expect(slot.stackOrder < 0,
                   "слой стопки \(slot.index) не уведён за ленту: \(slot.stackOrder)")
        }
        // Сравнение с потоком: запаркованная, но ещё не накрытая карточка
        // сама несёт отрицательный уровень своей стопки и в потоке не живёт.
        for front in result.visible where front.isFullCard && front.stackOrder >= 0 {
            for behind in stacked {
                expect(behind.stackOrder < front.stackOrder,
                       "слой \(behind.index) не за карточкой \(front.index)")
            }
        }
        // Внутри дальней стопки порядок монотонен: новее — глубже.
        let sorted = stacked.sorted { $0.index < $1.index }
        for (older, newer) in zip(sorted, sorted.dropFirst()) {
            expect(newer.stackOrder < older.stackOrder,
                   "порядок в дальней стопке нарушен: \(newer.index) поверх \(older.index)")
        }
    }

    private static func layout(heights: [CGFloat], offset: CGFloat) -> ThumbnailLayoutResult {
        thumbnailScrollLayout(screenFrame: screen,
                              edge: .right,
                              cardWidth: 240,
                              cardHeights: heights,
                              hubSize: hub,
                              margin: margin,
                              gap: gap,
                              offset: offset)
    }

    private static func fail(_ message: String) {
        fputs("TrayScrollLayoutTests failed: \(message)\n", stderr)
        exit(1)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message); return }
    }
}
