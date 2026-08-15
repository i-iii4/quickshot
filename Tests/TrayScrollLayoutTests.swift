import AppKit

/// Раскладка ленты по смещению прокрутки (`TR-1`, `TR-3`, `TR-5`).
///
/// Модельные тесты `TrayScrollModelTests` проверяют арифметику смещения. Здесь
/// проверяется, что смещение доходит до координат карточек: именно этого звена
/// не хватало — модель считала, а раскладка её игнорировала.
@main
struct TrayScrollLayoutTests {
    private static let screen = NSRect(x: 0, y: 0, width: 1600, height: 900)
    private static let hub = NSSize(width: 120, height: 40)
    private static let margin: CGFloat = 16
    private static let gap: CGFloat = 12

    static func main() {
        offsetMovesCards()
        stacksAppearAtEdges()
        deepCardsLeaveTheStrip()
        horizontalTrayScrollsAlongItsAxis()
        shortStripIsUnaffected()
        edgesKeepCardsOnScreen()
        stackDepthReachesSlots()
        print("TrayScrollLayoutTests: passed")
    }

    /// Смещение обязано двигать координаты, иначе прокрутка существует только
    /// в модели.
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

    /// `TR-3`: у краёв карточки собираются в стопку, а не улетают.
    private static func stacksAppearAtEdges() {
        let heights = Array(repeating: CGFloat(200), count: 12)
        let result = layout(heights: heights, offset: 600)
        let positions = result.visible.map(\.origin.y).sorted()

        guard let lowest = positions.first, let second = positions.dropFirst().first else {
            fail("в ленте меньше двух видимых карточек")
            return
        }
        expect(second - lowest < 200,
               "у края карточки должны наезжать друг на друга, шаг \(second - lowest)")
        expect(lowest >= margin + hub.height,
               "стопка не должна уезжать под хаб: \(lowest)")
    }

    /// Глубже стопки карточки скрываются: три слоя достаточно, чтобы показать
    /// «дальше есть ещё».
    private static func deepCardsLeaveTheStrip() {
        let heights = Array(repeating: CGFloat(200), count: 20)
        let result = layout(heights: heights, offset: 1500)
        expect(!result.hidden.isEmpty, "глубокие карточки обязаны уходить из ленты")
        expect(result.visible.count < 20, "все двадцать карточек не могут быть видимы")
        expect(result.visible.count >= 3, "видимых слишком мало: \(result.visible.count)")
    }

    /// `TR-6`: горизонтальный трей двигается по своей оси.
    /// `TR-6`, `TR-15`, `TR-16`
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

    /// Пока лента помещается целиком, прокрутка ничего не меняет.
    private static func shortStripIsUnaffected() {
        let heights = Array(repeating: CGFloat(200), count: 3)
        let result = layout(heights: heights, offset: 0)
        expect(result.hidden.isEmpty, "короткая лента не прячет карточки")
        expect(result.visible.count == 3, "видимы все три карточки")
    }

    /// Абсолютная геометрия каждого края: полоса обязана совпадать с обычной
    /// раскладкой `thumbnailLayout`. Именно тут трей ломался при переполнении:
    /// правый край считался от ширины хаба, верхний ставил карточку за экран.
    private static func edgesKeepCardsOnScreen() {
        let heights = Array(repeating: CGFloat(200), count: 12)
        // Стопка у начала ленты законно выглядывает к хабу на глубину стопки:
        // карточки лежат под хабом по z-порядку.
        let stackAllowance = TrayStackLayout.stackStep * CGFloat(TrayStackLayout.stackDepth)
        for edge in ThumbnailLayoutEdge.allCases {
            let result = thumbnailScrollLayout(screenFrame: screen, edge: edge,
                                               cardWidth: 240, cardHeights: heights,
                                               hubSize: hub, margin: margin, gap: gap,
                                               offset: 600)
            for slot in result.visible {
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
                    expect(slot.origin.x + 240 <= screen.maxX - margin - hub.width - gap + stackAllowance + 0.5,
                           "нижний край: карточка налезает на хаб: \(slot.origin.x)")
                case .top:
                    expect(abs(slot.origin.y - (screen.maxY - margin - 200)) < 0.5,
                           "верхний край: карточка за экраном: \(slot.origin.y)")
                    expect(slot.origin.x + 240 <= screen.maxX - margin - hub.width - gap + stackAllowance + 0.5,
                           "верхний край: карточка налезает на хаб: \(slot.origin.x)")
                }
            }
        }
    }

    /// Глубина стопки обязана доходить до слотов раскладки, а не оставаться
    /// в модели: карточка у края тусклее и меньше обычной.
    private static func stackDepthReachesSlots() {
        let heights = Array(repeating: CGFloat(200), count: 12)
        let result = layout(heights: heights, offset: 600)
        let dimmed = result.visible.filter { $0.opacity < 0.999 }
        expect(!dimmed.isEmpty, "у краёв нет ни одной притушенной карточки стопки")
        expect(dimmed.allSatisfy { $0.scale < 0.999 },
               "притушенные карточки стопки обязаны уменьшаться")
        let ordinary = result.visible.filter { $0.opacity >= 0.999 }
        expect(ordinary.allSatisfy { $0.scale >= 0.999 },
               "обычные карточки не должны масштабироваться")
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
