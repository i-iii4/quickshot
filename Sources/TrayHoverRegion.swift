import AppKit

/// Защитная геометрия наведения. Указатель ведут между соседними контролами
/// через зазоры, и каждый такой зазор — не «пустота вне трея», а часть одного
/// интерактивного острова.
enum TrayHover {
    /// Наибольший зазор, который замыкается в остров: 8pt между командами хаба,
    /// 12pt между карточками и 18pt между хабом и ближайшей карточкой.
    static let bridge: CGFloat = 20
    /// Запас вокруг видимой геометрии для решения об удержании hover-сессии.
    static let shield: CGFloat = 8
    /// Выход считается по большему порогу, чем вход: одинаковый порог даёт
    /// дребезг на границе при движении вдоль края.
    static let exitHysteresis: CGFloat = 8
    /// Отложенное снятие подсветки контрола. Проход через зазор к соседней
    /// команде не должен проходить через состояние «ничего не выбрано».
    static let controlGrace: Double = 0.1
}

/// Прямоугольник, замыкающий зазор между двумя элементами острова.
/// `nil`, если элементы дальше `bridge`, пересекаются или не имеют общей
/// проекции на поперечную ось.
func trayHoverBridgeRect(_ a: NSRect, _ b: NSRect, bridge: CGFloat) -> NSRect? {
    guard bridge > 0, a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return nil }
    guard !a.intersects(b) else { return nil }

    let verticalOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
    if verticalOverlap > 0 {
        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        if gap > 0, gap <= bridge {
            return NSRect(x: min(a.maxX, b.maxX),
                          y: max(a.minY, b.minY),
                          width: gap,
                          height: verticalOverlap)
        }
    }

    let horizontalOverlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
    if horizontalOverlap > 0 {
        let gap = max(a.minY, b.minY) - min(a.maxY, b.maxY)
        if gap > 0, gap <= bridge {
            return NSRect(x: max(a.minX, b.minX),
                          y: min(a.maxY, b.maxY),
                          width: horizontalOverlap,
                          height: gap)
        }
    }

    return nil
}

/// Указатель внутри острова, собранного из видимых элементов трея?
/// `shield` расширяет каждый элемент, `bridge` замыкает зазоры между ними.
func trayHoverRegionContains(_ point: NSPoint,
                             rects: [NSRect],
                             shield: CGFloat,
                             bridge: CGFloat) -> Bool {
    let shielded = rects
        .filter { $0.width > 0 && $0.height > 0 }
        .map { $0.insetBy(dx: -shield, dy: -shield) }
    guard !shielded.isEmpty else { return false }
    if shielded.contains(where: { $0.contains(point) }) { return true }
    for index in shielded.indices {
        for other in shielded.indices where other > index {
            if let gap = trayHoverBridgeRect(shielded[index], shielded[other], bridge: bridge),
               gap.contains(point) {
                return true
            }
        }
    }
    return false
}

/// Решение об удержании hover-сессии с гистерезисом: вход по `shield`,
/// выход — только за `shield + exitHysteresis`.
func trayPointerRemainsInside(_ point: NSPoint,
                              rects: [NSRect],
                              wasInside: Bool,
                              shield: CGFloat = TrayHover.shield,
                              exitHysteresis: CGFloat = TrayHover.exitHysteresis,
                              bridge: CGFloat = TrayHover.bridge) -> Bool {
    trayHoverRegionContains(point,
                            rects: rects,
                            shield: wasInside ? shield + exitHysteresis : shield,
                            bridge: bridge)
}
