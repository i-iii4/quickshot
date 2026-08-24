import AppKit

/// Оснастка тестов редактора: холст поверх белого изображения.
///
/// Отдельно от `ImageTestSupport`, потому что тянет за собой сам редактор, а
/// изображения нужны и наборам, которые его не собирают.

/// Холст аннотаций поверх белого изображения, в масштабе один к одному.
@MainActor
func makeTestCanvas(width: CGFloat = 400, height: CGFloat = 300) -> AnnotationCanvasView {
    let canvas = AnnotationCanvasView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    canvas.image = whiteTestImage(width: Int(width), height: Int(height))
    canvas.zoomToActualSize()
    return canvas
}
