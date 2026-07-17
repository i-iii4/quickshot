import AppKit
import Darwin

private final class ThumbnailMotionMatrixView: NSView {
    private let progressValues: [CGFloat] = [0, 0.2, 0.5, 0.8, 1]
    private let cellSize = NSSize(width: 320, height: 430)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.95, alpha: 1).setFill()
        bounds.fill()
        for (index, progress) in progressValues.enumerated() {
            drawCell(index: index, progress: progress)
        }
    }

    private func drawCell(index: Int, progress: CGFloat) {
        let cellX = CGFloat(index) * cellSize.width
        let hubFrame = NSRect(x: cellX + 236, y: 374, width: 62, height: 34)
        let state = thumbnailTrayVisualState(progress: progress, reduceMotion: false)
        let travelOffset = thumbnailTrayTravelOffset(vertical: true)

        NSColor(calibratedWhite: 0.45, alpha: 1).setFill()
        NSString(string: String(format: "%.0f%%", progress * 100)).draw(
            at: NSPoint(x: cellX + 18, y: 16),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                             .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1)]
        )

        for cardIndex in 0..<3 {
            let frame = NSRect(x: cellX + 38,
                               y: 62 + CGFloat(cardIndex) * 96,
                               width: 236,
                               height: 78)
            drawCard(frame: frame,
                     index: cardIndex,
                     travelOffset: travelOffset,
                     state: state)
        }

        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: hubFrame, xRadius: 12, yRadius: 12).fill()
        NSString(string: "3").draw(
            at: NSPoint(x: hubFrame.midX - 4, y: hubFrame.midY - 9),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                             .foregroundColor: NSColor.white]
        )
    }

    private func drawCard(frame: NSRect,
                          index: Int,
                          travelOffset: NSPoint,
                          state: ThumbnailTrayVisualState) {
        let offsetX = travelOffset.x * state.travelProgress
        let offsetY = travelOffset.y * state.travelProgress

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: frame.midX + offsetX, yBy: frame.midY + offsetY)
        transform.translateX(by: -frame.midX, yBy: -frame.midY)
        transform.concat()

        let shadow = NSShadow()
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: 4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(state.shadowOpacity)
        shadow.set()

        NSColor(calibratedWhite: 0.16 + CGFloat(index) * 0.025, alpha: state.alpha).setFill()
        NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8).fill()

        NSShadow().set()
        NSColor(calibratedWhite: 0.35, alpha: state.alpha).setFill()
        NSBezierPath(roundedRect: frame.insetBy(dx: 12, dy: 12), xRadius: 4, yRadius: 4).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
@main
struct ThumbnailMotionVisualMatrix {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let output = CommandLine.arguments.dropFirst().first ?? "/tmp/quickshot-thumbnail-motion.png"
        let root = ThumbnailMotionMatrixView(frame: NSRect(x: 0, y: 0, width: 1600, height: 430))
        let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = root
        root.displayIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { exit(2) }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(3) }
        do {
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            print(output)
        } catch {
            fputs("ThumbnailMotionVisualMatrix: \(error)\n", stderr)
            exit(4)
        }
    }
}
