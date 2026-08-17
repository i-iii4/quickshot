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

        // Порядок наложения задаётся слотом, как и в живом трее. Полоса —
        // часть целой карточки в масштабе своей глубины, центрирована поперёк
        // оси; все углы скруглены — со стороны среза это «плечи», видимые в
        // углах накрывающей (`TR-23`…`TR-26`).
        for slot in result.visible.sorted(by: { $0.stackOrder < $1.stackOrder }) {
            // Как в живом рендере: полоса — прямоугольное ОКНО в целую
            // карточку; скругление принадлежит карточке и срезается клипом
            // постепенно.
            let width = cardWidth * slot.scale
            let cardHeight = slot.isFullCard ? heights[slot.index]
                                             : heights[slot.index] * slot.scale
            let x = slot.origin.x + (cardWidth - width) / 2
            let clip = CGRect(x: x - 20, y: slot.origin.y,
                              width: width + 40,
                              height: slot.isFullCard ? cardHeight : slot.length)
            let cardFrame = CGRect(x: x,
                                   y: slot.origin.y + slot.cardStartOffset,
                                   width: width, height: cardHeight)
            context.saveGState()
            context.setAlpha(slot.opacity)
            context.clip(to: clip)
            if slot.shadowFraction > 0.01 {
                context.setShadow(offset: CGSize(width: 0, height: -2),
                                  blur: 6,
                                  color: NSColor.black
                                      .withAlphaComponent(0.6 * slot.shadowFraction).cgColor)
            }
            let radius = min(10 * slot.scale, min(cardFrame.width, cardFrame.height) / 2)
            let path = CGPath(roundedRect: cardFrame, cornerWidth: radius,
                              cornerHeight: radius, transform: nil)
            context.addPath(path)
            context.setFillColor(NSColor(calibratedHue: CGFloat(slot.index) / 14,
                                         saturation: 0.55, brightness: 0.85, alpha: 1).cgColor)
            context.fillPath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
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
