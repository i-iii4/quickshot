import AppKit
import CoreGraphics

/// Общая оснастка тестов редактора.
///
/// Белый холст и его вью заводились дословно одинаково в семи наборах —
/// от снимков полотна до сквозного сценария.

/// Белое изображение заданного размера: основа для всех проверок рисования.
func whiteTestImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// Холст аннотаций поверх белого изображения, в масштабе один к одному.
@MainActor
func makeTestCanvas(width: CGFloat = 400, height: CGFloat = 300) -> AnnotationCanvasView {
    let canvas = AnnotationCanvasView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    canvas.image = whiteTestImage(width: Int(width), height: Int(height))
    canvas.zoomToActualSize()
    return canvas
}
