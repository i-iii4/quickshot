import AppKit

@main
struct TrayHoverRegionTests {
    // Реальная геометрия трея у правого края: раскрытый хаб высотой
    // controlHeight + shellInset * 2, над ним карточки через `gap` = 12pt.
    // Зазоры между командами внутри хаба лежат внутри его прямоугольника.
    private static let hub = NSRect(x: 100, y: 100, width: 240, height: 40)
    private static let firstCard = NSRect(x: 100, y: 152, width: 240, height: 150)
    private static let secondCard = NSRect(x: 100, y: 314, width: 240, height: 150)

    private static var trayRects: [NSRect] { [hub, firstCard, secondCard] }

    static func main() {
        bridgesCoverEveryTrayGap()
        hubInteriorIsSolid()
        bridgesRequireSharedProjection()
        distantElementsStayDisconnected()
        hysteresisSeparatesEntryFromExit()
        emptyTrayIsNeverInside()
        print("TrayHoverRegionTests: passed")
    }

    /// Путь указателя от хаба вверх к карточкам не должен ни в одной точке
    /// выпадать из острова — иначе grace-таймер схлопывает трей под курсором.
    private static func bridgesCoverEveryTrayGap() {
        let betweenHubAndCard = NSPoint(x: 130, y: 146)
        let betweenCards = NSPoint(x: 130, y: 308)
        for point in [betweenHubAndCard, betweenCards] {
            expect(trayHoverRegionContains(point,
                                           rects: trayRects,
                                           shield: 0,
                                           bridge: TrayHover.bridge),
                   "gap at \(point) dropped the pointer out of the tray island")
        }
    }

    /// Зазор между командами Hide и Close равен 8pt и лежит внутри хаба:
    /// маршрутизация указателя не должна о нём знать вовсе.
    private static func hubInteriorIsSolid() {
        let betweenHideAndClose = NSPoint(x: 174, y: 120)
        expect(trayHoverRegionContains(betweenHideAndClose,
                                       rects: trayRects,
                                       shield: 0,
                                       bridge: 0),
               "the command row interior must belong to the hub rect itself")
        // Та же величина зазора проверяется и как мост — на случай элементов,
        // которые придут в остров отдельными прямоугольниками.
        let left = NSRect(x: 0, y: 0, width: 70, height: 28)
        let right = NSRect(x: 78, y: 0, width: 74, height: 28)
        expect(trayHoverBridgeRect(left, right, bridge: TrayHover.bridge) != nil,
               "an 8pt neighbour gap must be bridged")
    }

    /// Мост соединяет только элементы с общей проекцией: диагональный сосед
    /// не должен создавать проходимую область по воздуху.
    private static func bridgesRequireSharedProjection() {
        let diagonal = NSRect(x: 400, y: 300, width: 60, height: 40)
        expect(trayHoverBridgeRect(hub, diagonal, bridge: TrayHover.bridge) == nil,
               "diagonal neighbours must not be bridged")
        expect(trayHoverBridgeRect(hub, firstCard, bridge: TrayHover.bridge) != nil,
               "the hub and the nearest card must be bridged")
        expect(trayHoverBridgeRect(hub, firstCard, bridge: 4) == nil,
               "a gap wider than the bridge budget must stay open")
        expect(trayHoverBridgeRect(hub, hub, bridge: TrayHover.bridge) == nil,
               "overlapping elements need no bridge")
    }

    private static func distantElementsStayDisconnected() {
        let farBelow = NSPoint(x: 130, y: 60)
        expect(!trayHoverRegionContains(farBelow,
                                        rects: trayRects,
                                        shield: 0,
                                        bridge: TrayHover.bridge),
               "the desktop below the tray must stay clickable")
        // Поле контейнера карточки шириной resizeBand пропускает клики насквозь,
        // поэтому маршрутизация не должна считать его частью острова.
        let insideContainerMargin = NSPoint(x: firstCard.maxX + 6, y: firstCard.midY)
        expect(!trayHoverRegionContains(insideContainerMargin,
                                        rects: trayRects,
                                        shield: 0,
                                        bridge: TrayHover.bridge),
               "the transparent card margin must not join the routing island")
    }

    /// Вход и выход по одному порогу дают дребезг на границе.
    private static func hysteresisSeparatesEntryFromExit() {
        let justOutside = NSPoint(x: 130, y: 88)   // 12pt под нижней гранью хаба
        expect(trayPointerRemainsInside(justOutside, rects: trayRects, wasInside: true),
               "an engaged hover session must survive a 12pt overshoot")
        expect(!trayPointerRemainsInside(justOutside, rects: trayRects, wasInside: false),
               "a 12pt approach must not open the hover session on its own")
    }

    private static func emptyTrayIsNeverInside() {
        expect(!trayHoverRegionContains(NSPoint(x: 130, y: 120),
                                        rects: [],
                                        shield: TrayHover.shield,
                                        bridge: TrayHover.bridge),
               "an empty tray has no island")
        expect(!trayHoverRegionContains(NSPoint(x: 130, y: 120),
                                        rects: [.zero],
                                        shield: TrayHover.shield,
                                        bridge: TrayHover.bridge),
               "a collapsed element must not contribute an island")
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) {
        guard condition() else {
            fputs("TrayHoverRegionTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
