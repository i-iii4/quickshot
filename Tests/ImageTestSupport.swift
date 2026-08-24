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
