import AppKit
import Darwin

@MainActor
@main
struct HubOdometerVisualMatrix {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let outputPath = CommandLine.arguments.dropFirst().first ?? "/tmp/quickshot-odometer-matrix.png"
        let root = matrixView()
        let window = NSWindow(contentRect: root.bounds,
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
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
            fputs("HubOdometerVisualMatrix: \(error)\n", stderr)
            exit(4)
        }
    }

    private static func matrixView() -> NSView {
        let transitions = [(1, 2), (5, 6), (6, 5), (9, 10), (10, 9), (99, 100)]
        let progressValues: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
        let cell = NSSize(width: 240, height: 82)
        let root = NSView(frame: NSRect(x: 0,
                                        y: 0,
                                        width: cell.width * CGFloat(progressValues.count),
                                        height: cell.height * CGFloat(transitions.count)))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.82, alpha: 1).cgColor

        TrayPosition.testCurrent = .right
        for (row, transition) in transitions.enumerated() {
            for (column, progress) in progressValues.enumerated() {
                let hub = HubWindow()
                hub.setState(count: transition.0, collapsed: false)
                root.addSubview(hub.view)
                let y = CGFloat(transitions.count - row - 1) * cell.height + 20
                hub.setOrigin(NSPoint(x: CGFloat(column) * cell.width + 150, y: y))
                hub.show()
                hub.debugTransitionCount(to: transition.1)
                hub.setOrigin(NSPoint(x: CGFloat(column) * cell.width + 150, y: y))
                hub.debugSetCountTransitionProgress(progress)
            }
        }
        return root
    }
}
