import AppKit

/// Кадрирование и поворот (`D-40`…`D-44`).
///
/// Проверяется итоговое изображение, а не наличие инструмента: обрезка,
/// которая не меняет размер результата, — это отсутствующая обрезка.
@main
struct EditorTransformTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try cropChangesResultSize()          // D-40
                try cropIsReversible()               // D-42
                try tinyCropIsIgnored()              // D-5
                try rotationSwapsOrientation()       // D-44
                try rotationReturnsAfterFourTurns()  // D-44
                try cropAndRotationCompose()
                try displayKeepsImageUpright()       // экран ≠ зеркало
                print("EditorTransformTests: passed")
                exit(0)
            } catch {
                fputs("EditorTransformTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// `D-40`, `D-41`, `D-43`
    @MainActor private static func cropChangesResultSize() throws {
        let canvas = makeTestCanvas()
        try drag(canvas, from: CGPoint(x: 40, y: 30), to: CGPoint(x: 200, y: 130), tool: .crop)

        guard let result = canvas.flattenedImage() else { throw Failure("нет результата") }
        guard result.width == 160, result.height == 100 else {
            throw Failure("обрезка не изменила размер: \(result.width)×\(result.height)")
        }
    }

    /// `D-42`: обрезка отменяема до применения — отрезанное не потеряно.
    /// `D-42`, `C-2`
    @MainActor private static func cropIsReversible() throws {
        let canvas = makeTestCanvas()
        try drag(canvas, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 60, y: 60), tool: .crop)
        guard canvas.flattenedImage()?.width == 50 else { throw Failure("обрезка не применилась") }

        canvas.clearCrop()
        guard let restored = canvas.flattenedImage() else { throw Failure("нет результата") }
        guard restored.width == 400, restored.height == 300 else {
            throw Failure("снятие обрезки не вернуло полный кадр: \(restored.width)×\(restored.height)")
        }
    }

    /// Случайный клик инструментом обрезки не должен обрезать снимок в точку.
    /// `D-5`
    @MainActor private static func tinyCropIsIgnored() throws {
        let canvas = makeTestCanvas()
        try drag(canvas, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 102, y: 101), tool: .crop)
        guard let result = canvas.flattenedImage() else { throw Failure("нет результата") }
        guard result.width == 400 else {
            throw Failure("микроскопическая рамка обрезала снимок: \(result.width)")
        }
    }

    /// `D-44`
    @MainActor private static func rotationSwapsOrientation() throws {
        let canvas = makeTestCanvas()
        canvas.rotateQuarterTurn()
        guard let result = canvas.flattenedImage() else { throw Failure("нет результата") }
        guard result.width == 300, result.height == 400 else {
            throw Failure("поворот не поменял стороны: \(result.width)×\(result.height)")
        }
    }

    @MainActor private static func rotationReturnsAfterFourTurns() throws {
        let canvas = makeTestCanvas()
        for _ in 0..<4 { canvas.rotateQuarterTurn() }
        guard let result = canvas.flattenedImage() else { throw Failure("нет результата") }
        guard result.width == 400, result.height == 300 else {
            throw Failure("четыре поворота не вернули исходную ориентацию: \(result.width)×\(result.height)")
        }
    }

    /// Обрезка и поворот применяются вместе и в предсказуемом порядке.
    @MainActor private static func cropAndRotationCompose() throws {
        let canvas = makeTestCanvas()
        try drag(canvas, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 200, y: 100), tool: .crop)
        canvas.rotateQuarterTurn()
        guard let result = canvas.flattenedImage() else { throw Failure("нет результата") }
        guard result.width == 100, result.height == 200 else {
            throw Failure("совмещение обрезки и поворота дало \(result.width)×\(result.height)")
        }
    }

    /// Экранная отрисовка обязана показывать снимок так, как он снят: верх
    /// изображения — вверху вью. Холст перевёрнут (isFlipped), а CGImage
    /// рисуется в нижне-левой системе координат — без компенсации картинка
    /// выходит зеркальной по вертикали, что и наблюдалось в приложении.
    @MainActor private static func displayKeepsImageUpright() throws {
        let canvas = AnnotationCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.image = topRedBottomBlueImage(width: 400, height: 300)
        canvas.zoomToActualSize()
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = NSView(frame: canvas.frame)
        window.contentView?.addSubview(canvas)

        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            throw Failure("нет буфера отображения")
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / canvas.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / canvas.bounds.height

        // Вью перевёрнута: маленький y — верх. В хранилище rep строка 0 — верхняя.
        guard let top = rep.colorAt(x: Int(200 * scaleX), y: Int(20 * scaleY)),
              let bottom = rep.colorAt(x: Int(200 * scaleX), y: Int(280 * scaleY)) else {
            throw Failure("не удалось прочитать пиксели отображения")
        }
        guard top.redComponent > 0.6, top.blueComponent < 0.4 else {
            throw Failure("верх изображения не красный: экран зеркалит снимок (top=\(top))")
        }
        guard bottom.blueComponent > 0.6, bottom.redComponent < 0.4 else {
            throw Failure("низ изображения не синий: экран зеркалит снимок (bottom=\(bottom))")
        }
    }

    private static func topRedBottomBlueImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // В CG-контексте origin внизу: верхняя половина изображения — большие y.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        return context.makeImage()!
    }

    // MARK: помощники

    /// Протяжка мышью в координатах вью: тест идёт тем же путём, что и рука
    /// пользователя, а не вызывает внутренние методы.
    @MainActor private static func drag(_ canvas: AnnotationCanvasView,
                                        from start: CGPoint,
                                        to end: CGPoint,
                                        tool: AnnotationTool) throws {
        canvas.tool = tool
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = NSView(frame: canvas.frame)
        window.contentView?.addSubview(canvas)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start, in: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: end, in: window))
    }

    @MainActor private static func mouse(_ type: NSEvent.EventType,
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

    private static func sampleImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
