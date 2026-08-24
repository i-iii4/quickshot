import AppKit

/// Четыре сценария требований целиком: от изображения до результата с
/// проверкой содержимого.
///
/// Сценарий считается пройденным, только если проверено то, что получил бы
/// пользователь: пиксели итогового изображения, а не факт вызова метода.
@main
struct EndToEndScenarioTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try bugReport()            // С-1
                try stepByStepGuide()      // С-2
                try hidingPrivateData()    // С-3
                try quickReply()           // С-4
                print("EndToEndScenarioTests: passed")
                exit(0)
            } catch {
                fputs("EndToEndScenarioTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// С-1: обвести проблему, поставить стрелку, подписать, забрать в буфер.
    /// `A-1`, `A-4`, `D-7`, `D-9`, `D-13`, `D-23`, `D-26`, `J-1`, `J-4`
    @MainActor private static func bugReport() throws {
        let canvas = makeTestCanvas()
        try drag(canvas, tool: .box, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 220, y: 160))
        try drag(canvas, tool: .arrow, from: CGPoint(x: 300, y: 40), to: CGPoint(x: 230, y: 110))
        addText(canvas, "Broken", at: CGPoint(x: 250, y: 200))

        guard canvas.document.objects.count == 3 else {
            throw Failure("ожидались рамка, стрелка и подпись, получено \(canvas.document.objects.count)")
        }
        guard let result = canvas.flattenedImage() else { throw Failure("нет результата") }
        // Аннотации обязаны оказаться в пикселях, а не остаться в модели.
        guard inkPixels(result) > 200 else {
            throw Failure("аннотации не попали в изображение: \(inkPixels(result)) закрашенных точек")
        }

        Clipboard.copy(preparedImage: Clipboard.prepareImage(cgImage: result))
        guard NSPasteboard.general.data(forType: .png) != nil else {
            throw Failure("результат не попал в буфер обмена")
        }
    }

    /// С-2: пронумерованные метки, каждая со своим номером.
    /// `D-34`, `D-35`, `D-36`, `D-37`
    @MainActor private static func stepByStepGuide() throws {
        let canvas = makeTestCanvas()
        for point in [CGPoint(x: 80, y: 80), CGPoint(x: 180, y: 120), CGPoint(x: 280, y: 180)] {
            try click(canvas, tool: .step, at: point)
        }
        let numbers = canvas.document.objects.compactMap(\.number).sorted()
        guard numbers == [1, 2, 3] else {
            throw Failure("нумерация шагов сбилась: \(numbers)")
        }
        guard let result = canvas.flattenedImage(), inkPixels(result) > 100 else {
            throw Failure("метки шагов не отрисовались")
        }
    }

    /// С-3: под плашкой в готовом файле не должно остаться исходных пикселей.
    /// `E-1`, `E-2`, `E-5`, `J-2`, `J-5`
    @MainActor private static func hidingPrivateData() throws {
        let canvas = AnnotationCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        // Секрет — чёрная полоса на белом фоне: если она уцелеет под плашкой,
        // это будет видно по цвету.
        canvas.image = imageWithSecret()
        canvas.zoomToActualSize()

        let before = pixel(canvas.image!, x: 100, y: 150)
        guard before.brightness < 40 else { throw Failure("исходный секрет не подготовлен") }

        try drag(canvas, tool: .hide, from: CGPoint(x: 40, y: 130), to: CGPoint(x: 300, y: 175))
        guard let result = canvas.flattenedImage() else { throw Failure("нет результата") }

        let after = pixel(result, x: 100, y: 150)
        guard after.alpha == 255 else { throw Failure("плашка не непрозрачна: alpha \(after.alpha)") }
        guard abs(after.brightness - before.brightness) > 10 || after.brightness > 15 else {
            throw Failure("под плашкой остались исходные пиксели")
        }
        // Плашка обязана быть однородной: просвет означает, что секрет виден.
        let samples = [90, 100, 110, 150, 200].map { pixel(result, x: $0, y: 150).brightness }
        guard Set(samples).count == 1 else {
            throw Failure("плашка неоднородна, секрет просвечивает: \(samples)")
        }
    }

    /// С-4: кружок и стрелка за три действия.
    /// `D-3`, `D-4`, `D-14`, `D-15`, `D-17`, `D-18`
    @MainActor private static func quickReply() throws {
        let canvas = makeTestCanvas()
        try drag(canvas, tool: .ellipse, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 180, y: 180))
        try drag(canvas, tool: .arrow, from: CGPoint(x: 260, y: 60), to: CGPoint(x: 190, y: 130))

        guard canvas.document.objects.count == 2 else {
            throw Failure("ожидались круг и стрелка, получено \(canvas.document.objects.count)")
        }
        guard let result = canvas.flattenedImage(), inkPixels(result) > 100 else {
            throw Failure("быстрый ответ не отрисовался")
        }
    }

    // MARK: помощники

    @MainActor private static func addText(_ canvas: AnnotationCanvasView,
                                           _ value: String,
                                           at point: CGPoint) {
        canvas.tool = .text
        canvas.document.add(AnnotationObject(kind: .text,
                                             geometry: .rect(CGRect(origin: point,
                                                                    size: CGSize(width: 80, height: 20)),
                                                             cornerRadius: 0),
                                             style: canvas.currentStyle,
                                             text: value))
    }

    @MainActor private static func drag(_ canvas: AnnotationCanvasView,
                                        tool: AnnotationTool,
                                        from start: CGPoint,
                                        to end: CGPoint) throws {
        canvas.tool = tool
        let window = hostWindow(for: canvas)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: start, in: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: end, in: window))
    }

    @MainActor private static func click(_ canvas: AnnotationCanvasView,
                                         tool: AnnotationTool,
                                         at point: CGPoint) throws {
        canvas.tool = tool
        let window = hostWindow(for: canvas)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: point, in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: point, in: window))
    }

    @MainActor private static func hostWindow(for canvas: AnnotationCanvasView) -> NSWindow {
        if let existing = canvas.window { return existing }
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let root = NSView(frame: canvas.frame)
        window.contentView = root
        root.addSubview(canvas)
        return window
    }

    @MainActor private static func mouse(_ type: NSEvent.EventType,
                                         at point: CGPoint,
                                         in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private static func blankImage() -> CGImage {
        let context = makeContext(width: 400, height: 300)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        return context.makeImage()!
    }

    private static func imageWithSecret() -> CGImage {
        let context = makeContext(width: 400, height: 300)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 50, y: 140, width: 240, height: 26))
        return context.makeImage()!
    }

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private struct Pixel {
        let red: Int, green: Int, blue: Int, alpha: Int
        var brightness: Int { (red + green + blue) / 3 }
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> Pixel {
        let data = imageBytes(image)
        let index = (y * image.width + x) * 4
        return Pixel(red: Int(data[index]), green: Int(data[index + 1]),
                     blue: Int(data[index + 2]), alpha: Int(data[index + 3]))
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
