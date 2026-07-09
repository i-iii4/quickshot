import AppKit
import Darwin

@MainActor
@main
struct SelectionToolVisualMatrix {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)

        let outputPath = CommandLine.arguments.dropFirst().first ?? "/tmp/quickshot-selection-tool-preview.png"
        let root = matrixView()
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = root

        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()

        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { exit(2) }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(3) }

        do {
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            print(outputPath)
        } catch {
            fputs("SelectionToolVisualMatrix: failed to write \(outputPath): \(error)\n", stderr)
            exit(4)
        }
    }

    private static func matrixView() -> NSView {
        let cellSize = NSSize(width: 360, height: 260)
        let samples: [(title: String, start: NSPoint, current: NSPoint)] = [
            ("drag down-right", NSPoint(x: 128, y: 92), NSPoint(x: 260, y: 180)),
            ("drag down-left", NSPoint(x: 232, y: 92), NSPoint(x: 96, y: 180)),
            ("drag up-right", NSPoint(x: 128, y: 168), NSPoint(x: 260, y: 78)),
            ("drag up-left", NSPoint(x: 232, y: 168), NSPoint(x: 96, y: 78)),
            ("small selection", NSPoint(x: 166, y: 128), NSPoint(x: 183, y: 142)),
            ("wide shallow", NSPoint(x: 68, y: 128), NSPoint(x: 292, y: 146)),
        ]

        let columns = 3
        let rows = Int(ceil(Double(samples.count) / Double(columns)))
        let root = NSView(frame: NSRect(x: 0,
                                        y: 0,
                                        width: cellSize.width * CGFloat(columns),
                                        height: cellSize.height * CGFloat(rows)))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor

        for (index, sample) in samples.enumerated() {
            let col = index % columns
            let row = rows - 1 - index / columns
            let cellFrame = NSRect(x: CGFloat(col) * cellSize.width,
                                   y: CGFloat(row) * cellSize.height,
                                   width: cellSize.width,
                                   height: cellSize.height)
            let cell = makeCell(frame: cellFrame, title: sample.title, start: sample.start, current: sample.current)
            root.addSubview(cell)
        }

        return root
    }

    private static func makeCell(frame: NSRect, title: String, start: NSPoint, current: NSPoint) -> NSView {
        SelectionPreviewCell(frame: frame, title: title, start: start, current: current)
    }
}

private final class SelectionPreviewCell: NSView {
    private let title: String
    private let start: NSPoint
    private let current: NSPoint

    init(frame frameRect: NSRect, title: String, start: NSPoint, current: NSPoint) {
        self.title = title
        self.start = start
        self.current = current
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
        bounds.fill()

        NSColor.white.withAlphaComponent(0.12).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()

        let canvas = bounds.insetBy(dx: 18, dy: 28)
        drawBackdrop(in: canvas)

        let selection = SelectionView(frame: NSRect(origin: .zero, size: canvas.size))
        selection.debugBeginAndDrag(from: start, to: current)
        let snapshot = selection.debugSnapshot()
        let metrics = SelectionView.debugMetrics()
        let offset = canvas.origin
        let selected = snapshot.currentRect.offsetBy(dx: offset.x, dy: offset.y)

        NSColor.white.withAlphaComponent(metrics.innerOverlayAlpha).setFill()
        selected.fill()

        strokeOutline(points: snapshot.outlinePoints.map { NSPoint(x: $0.x + offset.x, y: $0.y + offset.y) },
                      width: metrics.haloWidth,
                      color: NSColor.black.withAlphaComponent(0.60))
        strokeOutline(points: snapshot.outlinePoints.map { NSPoint(x: $0.x + offset.x, y: $0.y + offset.y) },
                      width: metrics.coreWidth,
                      color: .white)
        drawCrosshair(at: NSPoint(x: current.x + offset.x, y: current.y + offset.y), metrics: metrics)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
        ]
        title.draw(in: NSRect(x: 18, y: bounds.height - 24, width: bounds.width - 36, height: 16),
                   withAttributes: attributes)
    }

    private func drawBackdrop(in rect: NSRect) {
        NSColor(calibratedRed: 0.23, green: 0.29, blue: 0.31, alpha: 1).setFill()
        rect.fill()

        let grid = NSBezierPath()
        for x in stride(from: rect.minX, through: rect.maxX, by: 28) {
            grid.move(to: NSPoint(x: x, y: rect.minY))
            grid.line(to: NSPoint(x: x, y: rect.maxY))
        }
        for y in stride(from: rect.minY, through: rect.maxY, by: 28) {
            grid.move(to: NSPoint(x: rect.minX, y: y))
            grid.line(to: NSPoint(x: rect.maxX, y: y))
        }
        NSColor.white.withAlphaComponent(0.075).setStroke()
        grid.lineWidth = 1
        grid.stroke()

        let accent = NSBezierPath()
        accent.move(to: NSPoint(x: rect.minX + 12, y: rect.midY))
        accent.curve(to: NSPoint(x: rect.maxX - 12, y: rect.midY + 24),
                     controlPoint1: NSPoint(x: rect.midX - 70, y: rect.maxY - 20),
                     controlPoint2: NSPoint(x: rect.midX + 80, y: rect.minY + 12))
        NSColor(calibratedRed: 0.70, green: 0.86, blue: 0.82, alpha: 0.28).setStroke()
        accent.lineWidth = 10
        accent.lineCapStyle = .round
        accent.stroke()
    }

    private func strokeOutline(points: [NSPoint], width: CGFloat, color: NSColor) {
        guard let first = points.first else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: first)
        points.dropFirst().forEach { path.line(to: $0) }
        color.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    private func drawCrosshair(at center: NSPoint, metrics: SelectionView.DebugMetrics) {
        let path = NSBezierPath()
        let gap = metrics.crosshairGap
        let arm = metrics.crosshairArm
        path.move(to: NSPoint(x: center.x - gap - arm, y: center.y))
        path.line(to: NSPoint(x: center.x - gap, y: center.y))
        path.move(to: NSPoint(x: center.x + gap, y: center.y))
        path.line(to: NSPoint(x: center.x + gap + arm, y: center.y))
        path.move(to: NSPoint(x: center.x, y: center.y - gap - arm))
        path.line(to: NSPoint(x: center.x, y: center.y - gap))
        path.move(to: NSPoint(x: center.x, y: center.y + gap))
        path.line(to: NSPoint(x: center.x, y: center.y + gap + arm))
        path.lineCapStyle = .round

        NSColor.black.withAlphaComponent(0.60).setStroke()
        path.lineWidth = metrics.haloWidth
        path.stroke()

        NSColor.white.setStroke()
        path.lineWidth = metrics.coreWidth
        path.stroke()
    }
}
