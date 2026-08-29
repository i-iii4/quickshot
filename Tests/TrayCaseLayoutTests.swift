import AppKit
import Darwin

/// Геометрия шкатулки в числах (`TR-42`, `TR-43`).
///
/// Заведено 26.08.2026: расчёт жил приватным методом менеджера, ни один тест
/// его не видел, и единственным наблюдателем геометрии был человек со
/// скриншотом. Из-за этого дефект «шкатулка раздувается, элементы плавают в
/// пустоте» жил до приёмки, а причину я угадывал по фотографии.
@main
struct TrayCaseLayoutTests {
    static func main() {
        run("case wraps the card contour", testWrapsContour)
        run("case ignores the open menu", testCaseIgnoresMenu)
        run("panel stays inside the case", testPanelInside)
        run("panel hugs the far edge of the case", testPanelEdge)
        run("menu bar ceiling is measured, not forced", testCeiling)
        run("wide panel widens the case", testWidePanel)
        run("panel spans the case content width", testPanelSpansWidth)
        run("ceiling never puts cards outside the case", testCeilingKeepsCardsInside)
        run("the button never moves when the menu opens", testButtonStaysPut)
        print("TrayCaseLayoutTests: passed")
    }

    private static let contour = NSRect(x: 400, y: 300, width: 168, height: 580)
    /// Поле подложки вокруг содержимого – оно же расстояние между внешним
    /// и внутренним контуром (`QS.inset`).
    private static let side: CGFloat = 4
    private static let cardGap: CGFloat = 12
    private static let pill = NSSize(width: 140, height: 40)
    /// Панель большего размера: сама пилюля от состояния меню не зависит
    /// (`TR-45`), но шкатулка обязана правильно обнимать любую панель.
    private static let tallPanel = NSSize(width: 140, height: 147)

    private static func layout(panel: NSSize = pill,
                               panelBelow: Bool = false,
                               ceiling: CGFloat? = nil) -> TrayCaseLayout {
        trayCaseLayout(contour: contour, pillSize: pill, panelSize: panel, side: side, cardGap: cardGap,
                       panelBelow: panelBelow, ceiling: ceiling)
    }

    /// Подложка обнимает карточки полем `side` со всех сторон, кроме той, где
    /// стоит панель.
    private static func testWrapsContour() {
        let bottom = layout()
        expect(bottom.caseRect.minX == contour.minX - side, "левое поле: \(bottom.caseRect.minX)")
        expect(bottom.caseRect.minY == contour.minY - side, "нижнее поле: \(bottom.caseRect.minY)")
        expect(bottom.caseRect.maxY == contour.maxY + cardGap + pill.height + side,
               "полоса панели сверху: \(bottom.caseRect.maxY)")

        let top = layout(panelBelow: true)
        expect(top.caseRect.maxY == contour.maxY + side, "верхнее поле: \(top.caseRect.maxY)")
        expect(top.caseRect.minY == contour.minY - (cardGap + pill.height + side),
               "полоса панели снизу: \(top.caseRect.minY)")
    }

    /// Подложка НЕ меняется от того, открыто меню или нет: её строит размер
    /// пилюли. Меню обязано быть вне шкатулки, и шкатулка о нём не знает
    /// (`TR-45`).
    private static func testCaseIgnoresMenu() {
        let collapsed = layout()
        let expanded = layout(panel: tallPanel)
        expect(collapsed.caseRect == expanded.caseRect,
               "подложка обязана остаться прежней: \(collapsed.caseRect) → \(expanded.caseRect)")
        expect(expanded.panelRect.height == tallPanel.height,
               "панель обязана быть своего измеренного размера: \(expanded.panelRect.height)")
        expect(expanded.panelRect.height > expanded.caseRect.height * 0.1,
               "панель с меню обязана выходить за подложку")
    }

    /// СВЁРНУТАЯ панель целиком внутри подложки, полем `side` от края.
    /// Раскрытая выходит за неё – там всплывшее меню.
    private static func testPanelInside() {
        for below in [false, true] {
            let result = layout(panelBelow: below)
            expect(result.caseRect.contains(result.panelRect),
                   "пилюля обязана быть внутри шкатулки: \(result.panelRect) в \(result.caseRect)")
            expect(result.panelRect.minX - result.caseRect.minX == side,
                   "поле слева: \(result.panelRect.minX - result.caseRect.minX)")
        }
    }

    /// Панель прижата к тому краю шкатулки, который дальше от карточек.
    private static func testPanelEdge() {
        let bottom = layout()
        expect(bottom.caseRect.maxY - bottom.panelRect.maxY == side,
               "у нижнего угла панель сверху: \(bottom.caseRect.maxY - bottom.panelRect.maxY)")

        let top = layout(panelBelow: true)
        expect(top.panelRect.minY - top.caseRect.minY == side,
               "у верхнего угла панель снизу: \(top.panelRect.minY - top.caseRect.minY)")
    }

    /// Упор в строку меню измеряется, но подложку не калечит: шкатулка
    /// обнимает содержимое вплотную, и сдвиг выставил бы карточки наружу.
    private static func testCeiling() {
        let free = layout()
        expect(free.overflow == 0, "без потолка переполнения нет: \(free.overflow)")

        let capped = layout(ceiling: free.caseRect.maxY - 60)
        expect(capped.overflow == 60, "переполнение обязано измеряться: \(capped.overflow)")
        expect(capped.caseRect == free.caseRect,
               "потолок не двигает подложку: \(capped.caseRect)")
        expect(capped.caseRect.contains(capped.panelRect),
               "свёрнутая панель обязана остаться внутри: \(capped.panelRect)")
    }

    /// Панель шире карточек расширяет шкатулку, а не вылезает из неё.
    private static func testWidePanel() {
        let wide = NSSize(width: contour.width + 60, height: 40)
        let result = trayCaseLayout(contour: contour, pillSize: wide, panelSize: wide,
                                    side: side, cardGap: cardGap, panelBelow: false, ceiling: nil)
        expect(result.caseRect.width == wide.width + side * 2,
               "шкатулка обязана расшириться под панель: \(result.caseRect.width)")
        expect(result.caseRect.contains(result.panelRect),
               "широкая панель обязана остаться внутри: \(result.panelRect)")
    }

    /// Панель тянется на всю ширину содержимого шкатулки: измеренная по
    /// своему тексту, она прижималась влево и оставляла дыру справа.
    private static func testPanelSpansWidth() {
        for panel in [pill, tallPanel] {
            let result = layout(panel: panel)
            expect(result.panelRect.width == result.caseRect.width - side * 2,
                   "панель обязана занять ширину содержимого: \(result.panelRect.width)")
            expect(result.caseRect.maxX - result.panelRect.maxX == side,
                   "поле справа: \(result.caseRect.maxX - result.panelRect.maxX)")
        }
    }

    /// Карточки внутри подложки при любом упоре: подложка от потолка не
    /// двигается, и выставить их наружу больше нечем.
    private static func testCeilingKeepsCardsInside() {
        let free = layout()
        for drop in [CGFloat(20), 80, 400] {
            let capped = layout(ceiling: free.caseRect.maxY - drop)
            expect(capped.caseRect.contains(contour),
                   "карточки обязаны остаться внутри при упоре \(drop): \(capped.caseRect)")
            expect(capped.overflow == drop, "переполнение при упоре \(drop): \(capped.overflow)")
        }
    }

    /// Место КНОПКИ не меняется при открытии меню: она прижата к верху панели,
    /// панель крепится верхом к её месту и растёт вниз. Прижатая иначе, панель
    /// уносила кнопку вместе с собой – жалоба, с которой всё началось.
    private static func testButtonStaysPut() {
        for below in [false, true] {
            let collapsed = layout(panelBelow: below)
            let expanded = layout(panel: tallPanel, panelBelow: below)
            expect(collapsed.panelRect.maxY == expanded.panelRect.maxY,
                   "верх панели обязан стоять: \(collapsed.panelRect.maxY) → \(expanded.panelRect.maxY)")
        }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write(Data("  \(message)\n".utf8))
            exit(1)
        }
    }

    private static func run(_ name: String, _ body: () -> Void) {
        body()
        print("  \(name): passed")
    }
}
