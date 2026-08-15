import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Служебный рендер холста в PNG: визуальная проверка ориентации текста и
/// меток. Не тест — инструмент для глаз.
@main
struct CanvasSnapshotTool {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp"

            let canvas = AnnotationCanvasView(frame: NSRect(x: 0, y: 0, width: 120, height: 48))
            canvas.image = white(width: 120, height: 48)
            canvas.zoomToActualSize()

            var style = AnnotationStyle.default
            style.fontSize = 40
            var text = AnnotationObject(kind: .text,
                                        geometry: .rect(CGRect(x: 0, y: 0, width: 120, height: 48),
                                                        cornerRadius: 0),
                                        style: style)
            text.text = "T"
            canvas.document.add(text)


            if let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
                canvas.cacheDisplay(in: canvas.bounds, to: rep)
                if let cg = rep.cgImage {
                    write(cg, to: "\(directory)/canvas-screen.png")
                }
            }
            if let exported = canvas.flattenedImage() {
                write(exported, to: "\(directory)/canvas-export.png")
            }
            print("written \(directory)/canvas-screen.png and canvas-export.png")
            exit(0)
        }
        RunLoop.main.run()
    }

    private static func write(_ image: CGImage, to path: String) {
        guard let destination = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL,
            UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private static func white(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
