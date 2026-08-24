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

/// Безрамочное окно под холст: тесты рисования и истории заводили его
/// дословно одинаково.
@MainActor
func hostWindow(for canvas: AnnotationCanvasView) -> NSWindow {
    let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    let root = NSView(frame: canvas.frame)
    window.contentView = root
    root.addSubview(canvas)
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.orderFrontRegardless()
    root.layoutSubtreeIfNeeded()
    return window
}

/// Событие мыши в координатах окна.
@MainActor
func mouse(_ type: NSEvent.EventType,
                                     at point: CGPoint,
                                     in window: NSWindow) -> NSEvent {
    NSEvent.mouseEvent(with: type,
                       location: point,
                       modifierFlags: [],
                       timestamp: ProcessInfo.processInfo.systemUptime,
                       windowNumber: window.windowNumber,
                       context: nil,
                       eventNumber: 0,
                       clickCount: 1,
                       pressure: 1)!
}
