import AppKit

enum ThumbnailLayoutEdge: String, CaseIterable {
    case right, left, bottom, top

    var isVertical: Bool { self == .right || self == .left }
}

struct ThumbnailLayoutSlot: Equatable {
    let index: Int
    let origin: NSPoint
    /// Глубина стопки у края (`TR-3`): тусклость и уменьшение, 1 — обычная карточка.
    var opacity: CGFloat = 1
    var scale: CGFloat = 1
    /// Порядок наложения: больше — ближе к зрителю. Слои стопки обязаны лежать
    /// ЗА карточками ленты, иначе самый прозрачный слой рисуется поверх всех.
    var stackOrder: CGFloat = 0
}

struct ThumbnailLayoutResult: Equatable {
    let visible: [ThumbnailLayoutSlot]
    let hidden: [Int]
}

struct ThumbnailViewportResult: Equatable {
    let firstVisibleIndex: Int
    let layout: ThumbnailLayoutResult
}

func thumbnailClampedCardWidth(requested: CGFloat,
                               screenFrame: NSRect,
                               edge: ThumbnailLayoutEdge,
                               hubSize: NSSize,
                               margin: CGFloat,
                               gap: CGFloat,
                               resizeBand: CGFloat,
                               minimum: CGFloat,
                               maximum: CGFloat) -> CGFloat {
    let available: CGFloat
    if edge.isVertical {
        available = screenFrame.width - margin * 2
    } else {
        available = screenFrame.width - margin * 2 - hubSize.width - gap - resizeBand
    }
    let finiteAvailable = max(1, available.isFinite ? available : 1)
    let upper = max(1, min(maximum, finiteAvailable))
    let lower = min(minimum, upper)
    return max(lower, min(requested, upper))
}

func thumbnailLayout(screenFrame: NSRect,
                     edge: ThumbnailLayoutEdge,
                     cardWidth: CGFloat,
                     cardHeights: [CGFloat],
                     hubSize: NSSize,
                     margin: CGFloat,
                     gap: CGFloat,
                     firstVisibleIndex: Int = 0) -> ThumbnailLayoutResult {
    guard !cardHeights.isEmpty else { return .init(visible: [], hidden: []) }
    let first = min(max(0, firstVisibleIndex), cardHeights.count - 1)
    var visible: [ThumbnailLayoutSlot] = []
    var hidden: [Int] = Array(0..<first)
    var overflow = false

    if edge.isVertical {
        let x = edge == .right
            ? screenFrame.maxX - margin - cardWidth
            : screenFrame.minX + margin
        var y = screenFrame.minY + margin + hubSize.height + gap

        for index in first..<cardHeights.count {
            let height = cardHeights[index]
            if overflow {
                hidden.append(index)
                continue
            }
            if !visible.isEmpty && y + height > screenFrame.maxY - margin {
                overflow = true
                hidden.append(index)
                continue
            }
            visible.append(.init(index: index, origin: NSPoint(x: x, y: y)))
            y += height + gap
        }
    } else {
        var x = screenFrame.maxX - margin - hubSize.width - gap - cardWidth

        for index in first..<cardHeights.count {
            let height = cardHeights[index]
            if overflow {
                hidden.append(index)
                continue
            }
            if !visible.isEmpty && x < screenFrame.minX + margin {
                overflow = true
                hidden.append(index)
                continue
            }
            let y = edge == .bottom
                ? screenFrame.minY + margin
                : screenFrame.maxY - margin - height
            visible.append(.init(index: index, origin: NSPoint(x: x, y: y)))
            x -= cardWidth + gap
        }
    }

    return .init(visible: visible, hidden: hidden)
}

/// Finds the earliest viewport that still contains the newest screenshot. This
/// preserves the largest possible amount of recent context while guaranteeing
/// that an appended screenshot never disappears into silent overflow.
func thumbnailLayoutShowingNewest(screenFrame: NSRect,
                                  edge: ThumbnailLayoutEdge,
                                  cardWidth: CGFloat,
                                  cardHeights: [CGFloat],
                                  hubSize: NSSize,
                                  margin: CGFloat,
                                  gap: CGFloat) -> ThumbnailViewportResult {
    guard !cardHeights.isEmpty else {
        return .init(firstVisibleIndex: 0, layout: .init(visible: [], hidden: []))
    }
    let newestIndex = cardHeights.count - 1
    for first in 0...newestIndex {
        let layout = thumbnailLayout(screenFrame: screenFrame,
                                     edge: edge,
                                     cardWidth: cardWidth,
                                     cardHeights: cardHeights,
                                     hubSize: hubSize,
                                     margin: margin,
                                     gap: gap,
                                     firstVisibleIndex: first)
        if layout.visible.contains(where: { $0.index == newestIndex }) {
            return .init(firstVisibleIndex: first, layout: layout)
        }
    }
    let fallback = thumbnailLayout(screenFrame: screenFrame,
                                   edge: edge,
                                   cardWidth: cardWidth,
                                   cardHeights: cardHeights,
                                   hubSize: hubSize,
                                   margin: margin,
                                   gap: gap,
                                   firstVisibleIndex: newestIndex)
    return .init(firstVisibleIndex: newestIndex, layout: fallback)
}


/// Раскладка ленты по непрерывному смещению прокрутки (`TR-1`…`TR-3`).
///
/// Отличие от `thumbnailLayout`: карточки не выпадают из ленты по индексу, а
/// сдвигаются на `offset` и собираются в стопку у краёв. Видимость определяется
/// геометрией, а не номером первой карточки, поэтому остановка между карточками
/// становится возможной.
func thumbnailScrollLayout(screenFrame: NSRect,
                           edge: ThumbnailLayoutEdge,
                           cardWidth: CGFloat,
                           cardHeights: [CGFloat],
                           hubSize: NSSize,
                           margin: CGFloat,
                           gap: CGFloat,
                           offset: CGFloat) -> ThumbnailLayoutResult {
    guard !cardHeights.isEmpty else { return .init(visible: [], hidden: []) }

    let lengths = edge.isVertical ? cardHeights : Array(repeating: cardWidth, count: cardHeights.count)
    let viewportLength = edge.isVertical
        ? screenFrame.height - margin * 2 - hubSize.height - gap
        : screenFrame.width - margin * 2 - hubSize.width - gap
    let placements = TrayStackLayout.placements(cardLengths: lengths,
                                                gap: gap,
                                                offset: offset,
                                                viewportLength: max(1, viewportLength))

    var visible: [ThumbnailLayoutSlot] = []
    var hidden: [Int] = []
    let strip = stripOrigin(screenFrame: screenFrame,
                            edge: edge,
                            hubSize: hubSize,
                            margin: margin,
                            gap: gap)

    for (index, placement) in placements.enumerated() {
        // Карточка глубже стопки не рисуется: три слоя достаточно, чтобы
        // показать «дальше есть ещё», остальное — лишние окна.
        guard placement.depth < CGFloat(TrayStackLayout.stackDepth) else {
            hidden.append(index)
            continue
        }
        // Позиция поперёк оси ленты совпадает с обычной раскладкой
        // `thumbnailLayout`: правый край — карточка у правого края, верхний —
        // карточка целиком на экране. Ошибка здесь и ломала трей при
        // переполнении: полоса бралась от ширины хаба, а не карточки.
        let origin: NSPoint
        switch edge {
        case .right:
            origin = NSPoint(x: screenFrame.maxX - margin - cardWidth,
                             y: strip.y + placement.position)
        case .left:
            origin = NSPoint(x: screenFrame.minX + margin,
                             y: strip.y + placement.position)
        case .bottom:
            origin = NSPoint(x: strip.x - cardWidth - placement.position,
                             y: screenFrame.minY + margin)
        case .top:
            origin = NSPoint(x: strip.x - cardWidth - placement.position,
                             y: screenFrame.maxY - margin - cardHeights[index])
        }
        // Чем глубже слой, тем он дальше: порядок наложения задаётся явно, а не
        // порядком добавления сабвью. Иначе дальняя стопка (в ней лежат самые
        // новые снимки, добавленные последними) рисуется задом наперёд.
        visible.append(.init(index: index, origin: origin,
                             opacity: placement.opacity, scale: placement.scale,
                             stackOrder: -placement.depth))
    }
    return .init(visible: visible, hidden: hidden)
}

private func stripOrigin(screenFrame: NSRect,
                         edge: ThumbnailLayoutEdge,
                         hubSize: NSSize,
                         margin: CGFloat,
                         gap: CGFloat) -> NSPoint {
    switch edge {
    case .right:
        return NSPoint(x: screenFrame.maxX - margin - hubSize.width,
                       y: screenFrame.minY + margin + hubSize.height + gap)
    case .left:
        return NSPoint(x: screenFrame.minX + margin,
                       y: screenFrame.minY + margin + hubSize.height + gap)
    case .bottom:
        return NSPoint(x: screenFrame.maxX - margin - hubSize.width - gap,
                       y: screenFrame.minY + margin)
    case .top:
        return NSPoint(x: screenFrame.maxX - margin - hubSize.width - gap,
                       y: screenFrame.maxY - margin)
    }
}
