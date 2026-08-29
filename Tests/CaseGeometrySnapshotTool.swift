import AppKit
import Foundation

/// Рендер ШКАТУЛКИ ЦЕЛИКОМ: подложка, карточки ленты и панель внутри неё.
///
/// Отдельный инструмент от `CasePanelSnapshotTool`, и разница принципиальна.
/// Тот рисует панель в изоляции, на пустом фоне – в таком кадре не видно ни
/// того, как шкатулка обнимает карточки, ни того, куда девается место при
/// раскрытом меню. Ровно поэтому дефект «шкатулка раздувается, элементы
/// плавают в пустоте» не был виден ни на одном моём снимке: я смотрел на
/// панель, а жалоба была про шкатулку (приёмка 26.08.2026).
///
/// Карточки рисуются заглушками: предмет проверки – геометрия, а не
/// содержимое снимков.
@MainActor
@main
struct CaseGeometrySnapshotTool {
    /// Размер карточки ленты.
    private static let cardSize = NSSize(width: 168, height: 108)
    /// Зазор между карточками – тот же, что в ленте (`ThumbStyle.gap`).
    private static let cardGap: CGFloat = 12
    /// Поле вокруг шкатулки на кадре, чтобы её край был виден. С открытым
    /// меню оно больше: меню выходит за шкатулку, и без запаса кадр обрежет
    /// ровно то, ради чего меню и вынесли в своё окно.
    private static let margin: CGFloat = 24
    private static let marginWithMenu: CGFloat = 150
    /// Зазор между пилюлей и меню – тот же, что в `CaseMenuWindow`.
    private static let menuGap: CGFloat = 6

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"

        for position in [TrayPosition.bottomRight, .topRight, .bottomLeft, .topLeft] {
            for expanded in [false, true] {
                shoot(position: position, expanded: expanded, cards: 5, in: directory)
            }
        }
        // Одна карточка: шкатулка узкая, и панель может оказаться ШИРЕ её
        // содержимого – проверяем, что тогда делает ширина.
        shoot(position: .bottomRight, expanded: false, cards: 1, in: directory, tag: "single")
        shoot(position: .bottomRight, expanded: true, cards: 1, in: directory, tag: "single")
        // Упор в строку меню: шкатулка сдвигается вниз, а карточки остаются
        // на месте – видно, не наезжает ли панель на верхнюю карточку.
        shoot(position: .topRight, expanded: true, cards: 5, in: directory,
              tag: "ceiling", ceilingDrop: 80)
        print("снимки шкатулки записаны в \(directory)")
    }

    /// Один кадр: шкатулка в заданном углу, с собранным или раскрытым меню.
    private static func shoot(position: TrayPosition, expanded: Bool,
                              cards: Int, in directory: String,
                              tag: String? = nil, ceilingDrop: CGFloat? = nil) {
        let panel = NativeCasePanelView(frame: .zero)
        panel.setCount(cards)
        let panelSize = panel.fittingSize

        let frames = cardFrames(cards: cards, position: position)
        let contour = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        // Потолок задаётся как «опустить шкатулку на N», чтобы кадр не зависел
        // от размера настоящего экрана.
        let free = trayCaseLayout(contour: contour, panelSize: panelSize,
                                  side: TrayCaseView.sidePadding,
                                  cardGap: cardGap,
                                  panelBelow: position.isTop, ceiling: nil)
        // При упоре в строку меню панель уходит на другую сторону шкатулки –
        // как в менеджере.
        var layout = free
        var below = position.isTop
        if let drop = ceilingDrop {
            let ceiling = free.caseRect.maxY - drop
            layout = trayCaseLayout(contour: contour, panelSize: panelSize,
                                    side: TrayCaseView.sidePadding, cardGap: cardGap,
                                    panelBelow: below, ceiling: ceiling)
            if layout.overflow > 0 {
                let flipped = trayCaseLayout(contour: contour, panelSize: panelSize,
                                             side: TrayCaseView.sidePadding, cardGap: cardGap,
                                             panelBelow: !below, ceiling: ceiling)
                if flipped.overflow < layout.overflow { below = !below; layout = flipped }
            }
            panel.layoutSubtreeIfNeeded()
        }

        // Кадр строится вокруг шкатулки: её рамка живёт в координатах экрана,
        // а рисуем мы в своём маленьком окне.
        let pad = expanded ? marginWithMenu : margin
        let canvas = layout.caseRect.union(contour).insetBy(dx: -pad, dy: -pad)
        let shift = NSPoint(x: -canvas.minX, y: -canvas.minY)
        let root = FlatBackdrop(frame: NSRect(origin: .zero, size: canvas.size))
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = root

        // Порядок слоёв как в трее: подложка, поверх неё карточки, поверх
        // всего панель.
        let caseView = TrayCaseView(frame: shifted(layout.caseRect, by: shift))
        root.addSubview(caseView)
        for frame in frames {
            root.addSubview(CardStub(frame: shifted(frame, by: shift)))
        }
        panel.frame = shifted(layout.panelRect, by: shift)
        root.addSubview(panel)

        // `TR-45`: меню живёт в СВОЁМ окне поверх трея. В кадре оно рисуется
        // тем же слоем поверх шкатулки, на своём месте относительно пилюли:
        // геометрию проверяем целиком, а не по частям.
        if expanded {
            let menu = NativeCaseMenuView(frame: .zero)
            let size = menu.fittingSize
            let pill = shifted(layout.panelRect, by: shift)
            let above = !position.isTop
            let y = above ? pill.maxY + menuGap : pill.minY - menuGap - size.height
            menu.frame = NSRect(x: pill.minX, y: y, width: size.width, height: size.height)
            root.addSubview(menu)
            menu.needsLayout = true
            menu.layoutSubtreeIfNeeded()
        }
        root.layoutSubtreeIfNeeded()
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()

        let suffix = tag.map { "-\($0)" } ?? ""
        let name = "case-\(position.rawValue)-\(expanded ? "expanded" : "collapsed")\(suffix)"
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: "\(directory)/\(name).png"))

        // Числа рядом с кадром: глазом не отличить 8 pt от 12, а расхождение
        // полей – это и есть «поехавшая геометрия».
        print(String(format: "%@: шкатулка %.0fx%.0f, панель %.0fx%.0f, поля свеpху/снизу/слева/справа %.0f/%.0f/%.0f/%.0f",
                     name,
                     layout.caseRect.width, layout.caseRect.height,
                     layout.panelRect.width, layout.panelRect.height,
                     layout.caseRect.maxY - layout.panelRect.maxY,
                     layout.panelRect.minY - layout.caseRect.minY,
                     layout.panelRect.minX - layout.caseRect.minX,
                     layout.caseRect.maxX - layout.panelRect.maxX))
    }

    /// Рамки карточек собранной ленты в координатах экрана.
    private static func cardFrames(cards: Int, position: TrayPosition) -> [NSRect] {
        let anchor = NSPoint(x: 400, y: 400)
        return (0..<cards).map { index in
            let offset = CGFloat(index) * (cardSize.height + cardGap)
            let y = position.isTop ? anchor.y - offset : anchor.y + offset
            return NSRect(x: anchor.x, y: y, width: cardSize.width, height: cardSize.height)
        }
    }

    private static func shifted(_ rect: NSRect, by shift: NSPoint) -> NSRect {
        NSRect(x: rect.origin.x + shift.x, y: rect.origin.y + shift.y,
               width: rect.width, height: rect.height)
    }

    /// Подложка кадра: рабочий стол под треем.
    private final class FlatBackdrop: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            // Рабочий стол под треем: нейтральный тон, отличный от палитры
            // интерфейса, чтобы край шкатулки был виден на кадре.
            layer?.backgroundColor = NSColor(calibratedRed: 0.28, green: 0.30,
                                             blue: 0.34, alpha: 1).cgColor
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    /// Заглушка карточки: видно место и границы, содержимое неважно.
    private final class CardStub: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            // Заливка изображает светлый снимок; скругление и обводка – те же
            // токены, что у настоящей карточки, иначе кадр врёт о геометрии.
            layer?.backgroundColor = NSColor(calibratedWhite: 0.62, alpha: 1).cgColor
            layer?.cornerRadius = QS.radiusInner
            layer?.borderWidth = QS.hairline
            layer?.borderColor = QS.Color.border.cgColor
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
}
