import AppKit
import CoreGraphics

/// Оснастка тестовых изображений.
///
/// Контекст RGBA и белый холст заводились дословно одинаково в семи наборах —
/// от снимков полотна до сквозного сценария.

/// Контекст RGBA для тестовых изображений: отличалась только заливка.
func makeTestContext(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height,
              bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Белое изображение заданного размера: основа для всех проверок рисования.
func whiteTestImage(width: Int, height: Int) -> CGImage {
    let context = makeTestContext(width: width, height: height)
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// Байты изображения — основа попиксельных проверок.
func imageBytes(_ image: CGImage) -> [UInt8] {
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

/// Сколько пикселей не белые: мера «чернил» на холсте.
func inkPixels(_ image: CGImage) -> Int {
    let data = imageBytes(image)
    var count = 0
    for index in stride(from: 0, to: data.count, by: 4) {
        let isWhite = data[index] > 250 && data[index + 1] > 250 && data[index + 2] > 250
        if !isWhite { count += 1 }
    }
    return count
}
