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
        run("case grows exactly by the panel", testGrowsByPanel)
        run("panel stays inside the case", testPanelInside)
        run("panel hugs the far edge of the case", testPanelEdge)
        run("menu bar ceiling moves the case down", testCeiling)
        run("wide panel widens the case", testWidePanel)
        print("TrayCaseLayoutTests: passed")
    }

    private static let contour = NSRect(x: 400, y: 300, width: 168, height: 580)
    private static let side: CGFloat = 8
    private static let gap: CGFloat = 8
    private static let pill = NSSize(width: 140, height: 40)
    private static let withMenu = NSSize(width: 140, height: 147)

    private static func layout(panel: NSSize = pill,
                               panelBelow: Bool = false,
                               ceiling: CGFloat? = nil) -> TrayCaseLayout {
        trayCaseLayout(contour: contour, panelSize: panel, side: side, gap: gap,
                       panelBelow: panelBelow, ceiling: ceiling)
    }

    /// Подложка обнимает карточки полем `side` со всех сторон, кроме той, где
    /// стоит панель.
    private static func testWrapsContour() {
        let bottom = layout()
        expect(bottom.caseRect.minX == contour.minX - side, "левое поле: \(bottom.caseRect.minX)")
        expect(bottom.caseRect.minY == contour.minY - side, "нижнее поле: \(bottom.caseRect.minY)")
        expect(bottom.caseRect.maxY == contour.maxY + gap + pill.height + gap,
               "полоса панели сверху: \(bottom.caseRect.maxY)")

        let top = layout(panelBelow: true)
        expect(top.caseRect.maxY == contour.maxY + side, "верхнее поле: \(top.caseRect.maxY)")
        expect(top.caseRect.minY == contour.minY - (gap + pill.height + gap),
               "полоса панели снизу: \(top.caseRect.minY)")
    }

    /// Раскрытое меню растит шкатулку РОВНО на свою высоту – не больше и не
    /// меньше. Ровно это ломалось: шкатулка раскрывалась на пол-экрана.
    private static func testGrowsByPanel() {
        let collapsed = layout()
        let expanded = layout(panel: withMenu)
        let grown = expanded.caseRect.height - collapsed.caseRect.height
        expect(grown == withMenu.height - pill.height,
               "прирост шкатулки обязан равняться приросту панели: \(grown)")
        expect(expanded.panelRect.height == withMenu.height,
               "панель обязана быть своего измеренного размера: \(expanded.panelRect.height)")
    }

    /// Панель целиком внутри подложки, с зазором `gap` вокруг: раскрытое меню
    /// живёт ВНУТРИ шкатулки, а не поверх неё.
    private static func testPanelInside() {
        for below in [false, true] {
            for panel in [pill, withMenu] {
                let result = layout(panel: panel, panelBelow: below)
                expect(result.caseRect.contains(result.panelRect),
                       "панель обязана быть внутри шкатулки: \(result.panelRect) в \(result.caseRect)")
                expect(result.panelRect.minX - result.caseRect.minX == side,
                       "поле слева: \(result.panelRect.minX - result.caseRect.minX)")
            }
        }
    }

    /// Панель прижата к тому краю шкатулки, который дальше от карточек.
    private static func testPanelEdge() {
        let bottom = layout(panel: withMenu)
        expect(bottom.caseRect.maxY - bottom.panelRect.maxY == gap,
               "у нижнего угла панель сверху: \(bottom.caseRect.maxY - bottom.panelRect.maxY)")

        let top = layout(panel: withMenu, panelBelow: true)
        expect(top.panelRect.minY - top.caseRect.minY == gap,
               "у верхнего угла панель снизу: \(top.panelRect.minY - top.caseRect.minY)")
    }

    /// Строка меню опускает шкатулку целиком, не обрезая её.
    private static func testCeiling() {
        let free = layout(panel: withMenu)
        let ceiling = free.caseRect.maxY - 60
        let capped = layout(panel: withMenu, ceiling: ceiling)
        expect(capped.caseRect.maxY == ceiling, "потолок: \(capped.caseRect.maxY)")
        expect(capped.caseRect.height == free.caseRect.height,
               "потолок двигает, но не сжимает: \(capped.caseRect.height)")
        expect(capped.caseRect.contains(capped.panelRect),
               "панель обязана уехать вместе со шкатулкой: \(capped.panelRect)")
    }

    /// Панель шире карточек расширяет шкатулку, а не вылезает из неё.
    private static func testWidePanel() {
        let wide = NSSize(width: contour.width + 60, height: 147)
        let result = layout(panel: wide)
        expect(result.caseRect.width == wide.width + side * 2,
               "шкатулка обязана расшириться под панель: \(result.caseRect.width)")
        expect(result.caseRect.contains(result.panelRect),
               "широкая панель обязана остаться внутри: \(result.panelRect)")
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
