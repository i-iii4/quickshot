import AppKit

@main
struct AnnotationRendererTests {
    private static let size = CGSize(width: 200, height: 120)

    static func main() {
        paletteAvoidsPureBlackAndWhite()
        arrowHeadShrinksWithShortArrows()
        curveOnlyBendsWhenAsked()
        redactionIsOpaqueAndCoversPixels()
        blurIsVisiblyDifferentFromRedaction()
        strokeScaleKeepsScreenWidth()
        everyKindRendersSomething()
        print("AnnotationRendererTests: passed")
    }

    /// `F-4`: цвет по умолчанию обязан читаться и на светлом, и на тёмном
    /// интерфейсе, поэтому в палитре нет ни белого, ни чёрного.
    private static func paletteAvoidsPureBlackAndWhite() {
        for color in AnnotationPalette.colors {
            let srgb = color.usingColorSpace(.sRGB)!
            let brightness = (srgb.redComponent + srgb.greenComponent + srgb.blueComponent) / 3
            expect(brightness > 0.05 && brightness < 0.95,
                   "palette colour is too close to black or white: \(srgb)")
        }
        expect(AnnotationPalette.color(at: -1) == AnnotationPalette.colors.last,
               "negative index must wrap, not crash")
        expect(AnnotationPalette.color(at: 99) == AnnotationPalette.color(at: 99 % AnnotationPalette.colors.count),
               "index must wrap around the palette")
    }

    /// `D-12`: на короткой стрелке наконечник не должен превращаться в кляксу.
    private static func arrowHeadShrinksWithShortArrows() {
        let long = AnnotationRenderer.arrowHeadLength(lineWidth: 3, distance: 200)
        expect(long == 12, "a long arrow uses the natural head size; got \(long)")

        let short = AnnotationRenderer.arrowHeadLength(lineWidth: 3, distance: 15)
        expect(short == 5, "a short arrow shrinks its head; got \(short)")
        expect(short < long, "head must shrink with distance")

        let tiny = AnnotationRenderer.arrowHeadLength(lineWidth: 3, distance: 1)
        expect(tiny >= 3, "the head never collapses below the stroke width; got \(tiny)")
    }

    private static func curveOnlyBendsWhenAsked() {
        let straight = AnnotationRenderer.curvedPath(from: .zero,
                                                     to: CGPoint(x: 100, y: 0),
                                                     curve: 0)
        expect(straight.boundingBox.height < 0.001,
               "a zero curve must stay a straight line; got \(straight.boundingBox)")

        let bent = AnnotationRenderer.curvedPath(from: .zero,
                                                 to: CGPoint(x: 100, y: 0),
                                                 curve: 20)
        expect(bent.boundingBox.height > 5,
               "a curved arrow must leave the straight line; got \(bent.boundingBox)")
    }

    /// `E-1`, `E-2`: плашка непрозрачна и действительно закрывает пиксели.
    private static func redactionIsOpaqueAndCoversPixels() {
        let secret = filledImage(color: .white)
        let object = AnnotationObject(kind: .redaction,
                                      geometry: .rect(CGRect(x: 40, y: 30, width: 80, height: 40),
                                                      cornerRadius: 0))
        let result = render([object], over: secret)

        let inside = pixel(result, at: CGPoint(x: 80, y: 50))
        let outside = pixel(result, at: CGPoint(x: 10, y: 10))
        expect(inside.alpha == 255, "redaction must be fully opaque; got alpha \(inside.alpha)")
        expect(inside.brightness < 60,
               "redaction must be a dark solid bar, not a tint; got \(inside.brightness)")
        expect(outside.brightness > 200,
               "pixels outside the redaction must survive untouched")
    }

    private static func blurIsVisiblyDifferentFromRedaction() {
        let source = filledImage(color: .white)
        let rect = CGRect(x: 40, y: 30, width: 80, height: 40)
        let blurred = render([AnnotationObject(kind: .blur, geometry: .rect(rect, cornerRadius: 0))],
                             over: source)
        let redacted = render([AnnotationObject(kind: .redaction, geometry: .rect(rect, cornerRadius: 0))],
                              over: source)
        let blurPixel = pixel(blurred, at: CGPoint(x: 80, y: 50))
        let redactionPixel = pixel(redacted, at: CGPoint(x: 80, y: 50))
        expect(blurPixel.brightness != redactionPixel.brightness,
               "the unsafe tool must not look like the safe one")
        expect(blurPixel.brightness > redactionPixel.brightness,
               "pixelation stays lighter than a solid redaction bar")
    }

    /// `B-5`: при увеличенном холсте штрих в изображении тоньше, чтобы на
    /// экране остаться прежним.
    private static func strokeScaleKeepsScreenWidth() {
        let object = AnnotationObject(kind: .line,
                                      geometry: .segment(from: CGPoint(x: 10, y: 60),
                                                         to: CGPoint(x: 190, y: 60),
                                                         curve: 0),
                                      style: AnnotationStyle(paletteIndex: 0,
                                                             lineWidth: 8,
                                                             filled: false,
                                                             fillOpacity: 0,
                                                             fontSize: 14))
        let thick = render([object], over: filledImage(color: .white), strokeScale: 1)
        let thin = render([object], over: filledImage(color: .white), strokeScale: 0.25)
        expect(inkRows(thick, column: 100) > inkRows(thin, column: 100),
               "a smaller stroke scale must paint fewer rows")
    }

    private static func everyKindRendersSomething() {
        for kind in AnnotationKind.allCases {
            let object = sample(kind)
            let result = render([object], over: filledImage(color: .white))
            expect(inkPixels(result) > 0, "\(kind) rendered nothing")
        }
    }

    // MARK: помощники

    private static func sample(_ kind: AnnotationKind) -> AnnotationObject {
        let rect = CGRect(x: 40, y: 30, width: 90, height: 50)
        switch kind {
        case .arrow, .line, .highlighter:
            return AnnotationObject(kind: kind,
                                    geometry: .segment(from: CGPoint(x: 20, y: 20),
                                                       to: CGPoint(x: 160, y: 90),
                                                       curve: kind == .arrow ? 12 : 0))
        case .pencil:
            return AnnotationObject(kind: kind,
                                    geometry: .path([CGPoint(x: 20, y: 20),
                                                     CGPoint(x: 60, y: 70),
                                                     CGPoint(x: 120, y: 40),
                                                     CGPoint(x: 170, y: 90)]))
        case .counter:
            return AnnotationObject(kind: kind,
                                    geometry: .point(CGPoint(x: 100, y: 60)),
                                    number: 3)
        case .text:
            return AnnotationObject(kind: kind,
                                    geometry: .rect(rect, cornerRadius: 0),
                                    text: "Bug here")
        default:
            return AnnotationObject(kind: kind, geometry: .rect(rect, cornerRadius: 4))
        }
    }

    private static func filledImage(color: NSColor) -> CGImage {
        let context = makeContext()
        context.setFillColor(color.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()!
    }

    private static func makeContext() -> CGContext {
        CGContext(data: nil,
                  width: Int(size.width),
                  height: Int(size.height),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func render(_ objects: [AnnotationObject],
                               over image: CGImage,
                               strokeScale: CGFloat = 1) -> CGImage {
        let context = makeContext()
        context.draw(image, in: CGRect(origin: .zero, size: size))
        AnnotationRenderer.draw(objects, in: context, imageSize: size, strokeScale: strokeScale)
        return context.makeImage()!
    }

    private struct Pixel {
        let red: Int, green: Int, blue: Int, alpha: Int
        var brightness: Int { (red + green + blue) / 3 }
    }

    private static func bytes(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress,
                                    width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return buffer
    }

    private static func pixel(_ image: CGImage, at point: CGPoint) -> Pixel {
        let data = bytes(image)
        let index = (Int(point.y) * image.width + Int(point.x)) * 4
        return Pixel(red: Int(data[index]),
                     green: Int(data[index + 1]),
                     blue: Int(data[index + 2]),
                     alpha: Int(data[index + 3]))
    }

    private static func inkPixels(_ image: CGImage) -> Int {
        let data = bytes(image)
        var count = 0
        for index in stride(from: 0, to: data.count, by: 4) {
            let isWhite = data[index] > 250 && data[index + 1] > 250 && data[index + 2] > 250
            if !isWhite { count += 1 }
        }
        return count
    }

    private static func inkRows(_ image: CGImage, column: Int) -> Int {
        let data = bytes(image)
        var rows = 0
        for y in 0..<image.height {
            let index = (y * image.width + column) * 4
            let isWhite = data[index] > 250 && data[index + 1] > 250 && data[index + 2] > 250
            if !isWhite { rows += 1 }
        }
        return rows
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("AnnotationRendererTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
