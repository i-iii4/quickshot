import AppKit

enum ThumbnailLayoutEdge: String, CaseIterable {
    case right, left, bottom, top

    var isVertical: Bool { self == .right || self == .left }
}

struct ThumbnailLayoutSlot: Equatable {
    let index: Int
    /// Начало видимой полосы карточки в глобальных координатах, при полной
    /// ширине поперёк оси ленты: сужение по глубине карточка применяет сама.
    let origin: NSPoint
    var opacity: CGFloat = 1
    /// Порядок наложения: больше — ближе к зрителю. Слои стопки обязаны лежать
    /// ЗА карточками ленты, иначе самый прозрачный слой рисуется поверх всех.
    var stackOrder: CGFloat = 0
    /// Поля полосы стопки (`TR-23`…`TR-26`); у развёрнутой карточки полоса
    /// совпадает с самой карточкой.
    var length: CGFloat = 0
    var insetSteps: CGFloat = 0
    /// Перспектива глубины: карточка в стопке уменьшена целиком.
    var scale: CGFloat = 1
    var sliceFromFarSide: Bool = true
    /// Какие края полосы — настоящие края карточки (скруглены); обрезанные
    /// края — прямые.
    var roundsStart: Bool = true
    var roundsEnd: Bool = true
    /// Начало карточки относительно начала полосы вдоль оси (≤ 0).
    var cardStartOffset: CGFloat = 0
    var shadowFraction: CGFloat = 1
    var isFullCard: Bool = true
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
/// сдвигаются на `offset` и собираются в стопки-кромки у кнопки и у дальней
/// границы (`TR-23`…`TR-26`). Видимость определяется геометрией, а не номером
/// первой карточки, поэтому остановка между карточками становится возможной.
func thumbnailScrollLayout(screenFrame: NSRect,
                           edge: ThumbnailLayoutEdge,
                           cardWidth: CGFloat,
                           cardHeights: [CGFloat],
                           hubSize: NSSize,
                           margin: CGFloat,
                           gap: CGFloat,
                           offset: CGFloat,
                           menuBarInset: CGFloat = 0,
                           deckProgress: CGFloat = 0,
                           stow: CGFloat = 0) -> ThumbnailLayoutResult {
    guard !cardHeights.isEmpty else { return .init(visible: [], hidden: []) }

    let lengths = edge.isVertical ? cardHeights : Array(repeating: cardWidth, count: cardHeights.count)
    let viewportLength = thumbnailTrayViewportLength(screenFrame: screenFrame,
                                                     edge: edge,
                                                     hubSize: hubSize,
                                                     margin: margin,
                                                     menuBarInset: menuBarInset)
    let bands = TrayStripLayout.bands(cardLengths: lengths,
                                      gap: gap,
                                      offset: offset,
                                      viewportLength: max(1, viewportLength),
                                      deckProgress: deckProgress,
                                      stow: stow)

    var visible: [ThumbnailLayoutSlot] = []
    var hidden: [Int] = []
    let strip = stripOrigin(screenFrame: screenFrame,
                            edge: edge,
                            hubSize: hubSize,
                            margin: margin)

    for (index, band) in bands.enumerated() {
        guard !band.hidden else {
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
                             y: strip.y + band.position)
        case .left:
            origin = NSPoint(x: screenFrame.minX + margin,
                             y: strip.y + band.position)
        case .bottom:
            origin = NSPoint(x: strip.x - band.position - band.length,
                             y: screenFrame.minY + margin)
        case .top:
            origin = NSPoint(x: strip.x - band.position - band.length,
                             y: screenFrame.maxY - menuBarInset - margin - cardHeights[index])
        }
        // Чем глубже слой, тем он дальше: порядок наложения задаётся явно, а не
        // порядком добавления сабвью. Иначе стопка рисуется задом наперёд.
        visible.append(.init(index: index, origin: origin,
                             opacity: band.opacity,
                             stackOrder: band.zOrder,
                             length: band.length,
                             insetSteps: band.insetSteps,
                             scale: band.scale,
                             sliceFromFarSide: band.sliceFromFarSide,
                             roundsStart: band.roundsStart,
                             roundsEnd: band.roundsEnd,
                             cardStartOffset: band.cardStartOffset,
                             shadowFraction: band.shadowFraction,
                             isFullCard: band.isFullCard))
    }
    return .init(visible: visible, hidden: hidden)
}

/// Длина окна просмотра ленты. Снизу лента начинается почти от кнопки
/// (ярусы стопки — и есть резерв, `TrayStripLayout.hubClearance`), сверху
/// ограничена видимой областью экрана: под строку меню не заходит.
func thumbnailTrayViewportLength(screenFrame: NSRect,
                                 edge: ThumbnailLayoutEdge,
                                 hubSize: NSSize,
                                 margin: CGFloat,
                                 menuBarInset: CGFloat) -> CGFloat {
    if edge.isVertical {
        return screenFrame.height - menuBarInset - margin * 2
            - hubSize.height - TrayStripLayout.hubClearance
    }
    return screenFrame.width - margin * 2 - hubSize.width - TrayStripLayout.hubClearance
}

private func stripOrigin(screenFrame: NSRect,
                         edge: ThumbnailLayoutEdge,
                         hubSize: NSSize,
                         margin: CGFloat) -> NSPoint {
    let clearance = TrayStripLayout.hubClearance
    switch edge {
    case .right:
        return NSPoint(x: screenFrame.maxX - margin - hubSize.width,
                       y: screenFrame.minY + margin + hubSize.height + clearance)
    case .left:
        return NSPoint(x: screenFrame.minX + margin,
                       y: screenFrame.minY + margin + hubSize.height + clearance)
    case .bottom:
        return NSPoint(x: screenFrame.maxX - margin - hubSize.width - clearance,
                       y: screenFrame.minY + margin)
    case .top:
        return NSPoint(x: screenFrame.maxX - margin - hubSize.width - clearance,
                       y: screenFrame.maxY - margin)
    }
}

/// Видимая рамка карточки для слота раскладки, в глобальных координатах и без
/// поля под тень. Повторяет геометрию `ThumbnailWindow.layoutSlice`: полоса
/// центрируется поперёк оси ленты на величину, съеденную перспективой.
///
/// Нужна контуру шкатулки: карточка, которая ещё ВЛЕТАЕТ в ленту, стоит сбоку
/// от своего места, и контур по её текущей рамке уводил шкатулку вбок вслед за
/// ней (приёмка 20.08.2026).
func thumbnailVisibleFrame(slot: ThumbnailLayoutSlot,
                           cardSize: NSSize,
                           vertical: Bool) -> NSRect {
    let length = slot.isFullCard
        ? (vertical ? cardSize.height : cardSize.width) * slot.scale
        : max(1, slot.length)
    let crossInset = vertical
        ? cardSize.width * (1 - slot.scale) / 2
        : cardSize.height * (1 - slot.scale) / 2
    let width = vertical ? max(1, cardSize.width * slot.scale) : length
    let height = vertical ? length : max(1, cardSize.height * slot.scale)
    let origin = vertical
        ? NSPoint(x: slot.origin.x + crossInset, y: slot.origin.y)
        : NSPoint(x: slot.origin.x, y: slot.origin.y + crossInset)
    return NSRect(origin: origin, size: NSSize(width: width, height: height))
}
