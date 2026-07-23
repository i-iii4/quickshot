import AppKit

enum ThumbnailLayoutEdge: String, CaseIterable {
    case right, left, bottom, top

    var isVertical: Bool { self == .right || self == .left }
}

struct ThumbnailLayoutSlot: Equatable {
    let index: Int
    let origin: NSPoint
}

struct ThumbnailLayoutResult: Equatable {
    let visible: [ThumbnailLayoutSlot]
    let hidden: [Int]
}

struct ThumbnailViewportResult: Equatable {
    let firstVisibleIndex: Int
    let layout: ThumbnailLayoutResult
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
