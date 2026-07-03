import AppKit
import Darwin

@MainActor
@main
struct HubWindowVisualMatrix {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)

        let outputPath = CommandLine.arguments.dropFirst().first ?? "/tmp/quickshot-hub-matrix-preview.png"
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
            fputs("HubWindowVisualMatrix: failed to write \(outputPath): \(error)\n", stderr)
            exit(4)
        }
    }

    private static func matrixView() -> NSView {
        let positions: [TrayPosition] = [.right, .left, .bottom, .top]
        let counts = [1, 2, 120]
        let progressFrames: [CGFloat] = [0, 0.18, 0.55, 1]
        let cellW: CGFloat = 620
        let cellH: CGFloat = 116
        let rowCount = positions.count * counts.count

        let root = NSView(frame: NSRect(x: 0,
                                        y: 0,
                                        width: cellW * CGFloat(progressFrames.count),
                                        height: cellH * CGFloat(rowCount)))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1).cgColor

        var rowIndex = 0
        for position in positions {
            for count in counts {
                for (col, progress) in progressFrames.enumerated() {
                    TrayPosition.testCurrent = position
                    let row = rowCount - 1 - rowIndex
                    let cellX = CGFloat(col) * cellW
                    let cellY = CGFloat(row) * cellH

                    let hub = HubWindow()
                    hub.setState(count: count, collapsed: false)
                    root.addSubview(hub.view)

                    let anchorX: CGFloat = position == .left ? cellX + 120 : cellX + 510
                    hub.setOrigin(NSPoint(x: anchorX, y: cellY + 38))
                    hub.show()
                    hub.debugSetExpansionProgress(progress)
                }
                rowIndex += 1
            }
        }

        return root
    }
}
