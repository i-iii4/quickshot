import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Служебный рендер прокрученного трея в PNG: обе стопки видно глазами.
/// Не тест — инструмент. Карточки рисуются в один растр в том же порядке
/// наложения, что и на экране.
@main
struct TrayStackSnapshotTool {
    static func main() {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/tray-stacks.png"
        let offsetArgument = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) : nil

        // Экран и лента близки к настоящим: карточка 240×150, зазор 12.
        let screen = NSRect(x: 0, y: 0, width: 600, height: 900)
        let hub = NSSize(width: 120, height: 40)
        let margin: CGFloat = 16
        let gap: CGFloat = 12
        let cardWidth: CGFloat = 240
        let heights = Array(repeating: CGFloat(150), count: 14)
        let content = heights.reduce(0, +) + gap * CGFloat(heights.count - 1)
        let viewport = screen.height - margin * 2 - hub.height - gap
        let offset = CGFloat(offsetArgument ?? Double(max(0, content - viewport) / 2))

        let result = thumbnailScrollLayout(screenFrame: screen,
                                           edge: .right,
                                           cardWidth: cardWidth,
                                           cardHeights: heights,
                                           hubSize: hub,
                                           margin: margin,
                                           gap: gap,
                                           offset: offset)

        let scale: CGFloat = 2
        let context = CGContext(data: nil,
                                width: Int(screen.width * scale),
                                height: Int(screen.height * scale),
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        context.fill(screen)

        // Порядок наложения задаётся слотом, как и в живом трее.
        for slot in result.visible.sorted(by: { $0.stackOrder < $1.stackOrder }) {
            let height = heights[slot.index]
            let frame = CGRect(x: slot.origin.x, y: slot.origin.y, width: cardWidth, height: height)
            let scaled = frame.insetBy(dx: frame.width * (1 - slot.scale) / 2,
                                       dy: frame.height * (1 - slot.scale) / 2)
            context.saveGState()
            context.setAlpha(slot.opacity)
            let path = CGPath(roundedRect: scaled, cornerWidth: 10, cornerHeight: 10, transform: nil)
            context.addPath(path)
            context.setFillColor(NSColor(calibratedHue: CGFloat(slot.index) / 14,
                                         saturation: 0.55, brightness: 0.85, alpha: 1).cgColor)
            context.fillPath()
            context.addPath(path)
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(1)
            context.strokePath()
            context.restoreGState()
        }

        // Хаб: ближняя стопка прячется за ним.
        context.setFillColor(NSColor(white: 0.2, alpha: 1).cgColor)
        context.fill(CGRect(x: screen.maxX - margin - hub.width,
                            y: screen.minY + margin,
                            width: hub.width, height: hub.height))

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                  URL(fileURLWithPath: path) as CFURL,
                  UTType.png.identifier as CFString, 1, nil) else {
            fputs("cannot write \(path)\n", stderr)
            exit(1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        print("written \(path); visible \(result.visible.count), hidden \(result.hidden.count), offset \(offset)")
    }
}
