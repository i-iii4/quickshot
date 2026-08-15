import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Служебный рендер панели редактора в PNG: визуальная проверка дизайна
/// без запуска приложения. Не тест — инструмент.
@main
struct ToolbarSnapshotTool {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            let arguments = CommandLine.arguments
            let width = arguments.count > 1 ? CGFloat(Double(arguments[1]) ?? 1200) : 1200
            let path = arguments.count > 2 ? arguments[2] : "/tmp/toolbar.png"

            let mode = arguments.count > 3 ? arguments[3] : "idle"
            let toolbar = AnnotationToolbarView(frame: .zero)
            toolbar.setSelectionPresence(mode == "selected")
            if mode == "crop" { toolbar.setSelectedTool(.crop) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
            window.contentView = root
            root.addSubview(toolbar)
            toolbar.frame = NSRect(x: 0, y: 0, width: width, height: 60)
            root.layoutSubtreeIfNeeded()
            toolbar.layoutSubtreeIfNeeded()
            let height = toolbar.fittingSize.height
            toolbar.frame = NSRect(x: 0, y: 400 - height, width: width, height: height)
            root.layoutSubtreeIfNeeded()
            toolbar.layoutSubtreeIfNeeded()

            guard let rep = toolbar.bitmapImageRepForCachingDisplay(in: toolbar.bounds) else {
                fputs("no bitmap rep\n", stderr)
                exit(1)
            }
            toolbar.cacheDisplay(in: toolbar.bounds, to: rep)
            guard let cg = rep.cgImage,
                  let destination = CGImageDestinationCreateWithURL(
                      URL(fileURLWithPath: path) as CFURL,
                      UTType.png.identifier as CFString, 1, nil) else {
                fputs("no png destination\n", stderr)
                exit(1)
            }
            CGImageDestinationAddImage(destination, cg, nil)
            CGImageDestinationFinalize(destination)
            print("written \(path) \(rep.pixelsWide)x\(rep.pixelsHigh), toolbar height \(height)")
            exit(0)
        }
        RunLoop.main.run()
    }
}
