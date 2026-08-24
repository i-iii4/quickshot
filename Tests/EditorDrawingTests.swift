import AppKit
import CoreGraphics

/// Отрисовка через РЕАЛЬНЫЙ путь: перевёрнутый холст на экране и запекание при
/// экспорте. Прежние рендер-тесты рисовали в неперевёрнутый контекст — то есть
/// в единственную систему координат, которой в приложении нет, — и поэтому не
/// могли увидеть, что весь текст в продукте зеркален.
@main
struct EditorDrawingTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try textIsUprightOnScreen()
                try textIsUprightInExport()
                try textFieldIsUsableAfterClick()
                try counterDigitIsUpright()
                try doublePressCreatesOneCounter()
                try counterIsSelectableByItsCircle()
                print("EditorDrawingTests: passed")
                exit(0)
            } catch {
                fputs("EditorDrawingTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    // MARK: текст

    /// Буква «T» несёт почти все чернила в верхней части. Если контекст
    /// зеркалит, перекладина оказывается внизу — это и видно в продукте.
    @MainActor private static func textIsUprightOnScreen() throws {
        let canvas = makeTestCanvas()
        let object = textObject(at: CGPoint(x: 40, y: 40))
        canvas.document.add(object)
        // Новый объект остаётся выделенным, а ручки выделения — тоже пиксели:
        // они считались бы чернилами и размывали форму буквы.
        canvas.document.clearSelection()

        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            throw Failure("нет буфера отображения")
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        // Рамка объекта — ориентир, но замер идёт по всему холсту: важно, где
        // реально лежат чернила буквы, а не где по нашим расчётам должна быть
        // её рамка.
        let ratio = try inkRatio(rep: rep, in: canvas.bounds, canvas: canvas)
        guard ratio >= 2 else {
            let first = canvas.document.objects.first
            throw Failure("на экране текст зеркален: сверху/снизу = \(ratio); \(lastProfile); "
                + "объектов \(canvas.document.objects.count), текст \(first?.text ?? "нет"), "
                + "рамка \(first?.geometry.boundingBox ?? .zero), кегль \(first?.style.fontSize ?? 0), "
                + "растр \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
    }

    /// Экспорт обязан совпадать с экраном: то же изображение, та же ориентация.
    @MainActor private static func textIsUprightInExport() throws {
        let canvas = makeTestCanvas()
        let object = textObject(at: CGPoint(x: 40, y: 40))
        canvas.document.add(object)

        guard let image = canvas.flattenedImage() else { throw Failure("нет результата экспорта") }
        let box = object.geometry.boundingBox
        let ratio = try inkRatio(image: image, in: box)
        guard ratio >= 2 else {
            throw Failure("в экспорте текст зеркален: чернил сверху/снизу = \(ratio); \(lastProfile)")
        }
    }

    /// Клик инструментом текста обязан дать пригодное поле ввода: не точку в
    /// девять пикселей и не улетевшее за пределы холста.
    @MainActor private static func textFieldIsUsableAfterClick() throws {
        let canvas = makeTestCanvas()
        let host = hostWindow(for: canvas)
        var editingFrame: NSRect?
        canvas.onRequestTextEditing = { [weak canvas] id in
            guard let canvas, let object = canvas.document.objects.first(where: { $0.id == id }) else { return }
            editingFrame = canvas.textEditingFrame(for: object)
        }
        canvas.tool = .text
        click(canvas, at: CGPoint(x: 120, y: 90), in: host)

        guard let frame = editingFrame else { throw Failure("клик не запросил ввод текста") }
        guard frame.width >= 80, frame.height >= 24 else {
            throw Failure("поле ввода непригодно: \(frame.size)")
        }
        guard canvas.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            throw Failure("поле ввода вне холста: \(frame), холст \(canvas.bounds)")
        }
    }

    // MARK: метки

    @MainActor private static func counterDigitIsUpright() throws {
        let canvas = makeTestCanvas()
        var style = AnnotationStyle.default
        style.fontSize = 40
        var object = AnnotationObject(kind: .counter,
                                      geometry: .point(CGPoint(x: 200, y: 150)),
                                      style: style)
        // Семёрка держит перекладину сверху: перевёрнутая цифра сразу видна по
        // распределению белых пикселей внутри круга.
        object.number = 7
        canvas.document.add(object)

        guard let image = canvas.flattenedImage() else { throw Failure("нет результата экспорта") }
        // Замер идёт по квадрату, вписанному в круг: за кругом лежит белый фон
        // снимка, и он засчитывался бы в те же светлые пиксели, что и цифра.
        let circle = object.visualBounds
        let inscribed = circle.insetBy(dx: circle.width * 0.15, dy: circle.height * 0.15)
        let ratio = try inkRatio(image: image, in: inscribed, colour: .light)
        guard ratio >= 1.5 else {
            throw Failure("цифра метки зеркальна: чернил сверху/снизу = \(ratio)")
        }
    }

    /// Двойной клик — одна метка, а не две наложенные.
    @MainActor private static func doublePressCreatesOneCounter() throws {
        let canvas = makeTestCanvas()
        canvas.tool = .step
        let host = hostWindow(for: canvas)
        let point = CGPoint(x: 120, y: 90)
        click(canvas, at: point, in: host, clickCount: 1)
        click(canvas, at: point, in: host, clickCount: 2)

        guard canvas.document.objects.count == 1 else {
            throw Failure("двойной клик создал \(canvas.document.objects.count) меток")
        }
    }

    /// Метку выделяют кликом по её кругу, а не по центральной точке.
    @MainActor private static func counterIsSelectableByItsCircle() throws {
        let canvas = makeTestCanvas()
        canvas.tool = .step
        let host = hostWindow(for: canvas)
        click(canvas, at: CGPoint(x: 120, y: 90), in: host)
        guard let object = canvas.document.objects.first else { throw Failure("метка не создана") }

        canvas.tool = .select
        let radius = max(8, object.style.fontSize)
        let target = CGPoint(x: 120 + radius * 0.8, y: 90)
        click(canvas, at: target, in: host)

        guard canvas.document.selection == [object.id] else {
            throw Failure("клик по кругу метки не выделил её: \(canvas.document.selection)")
        }
    }

    // MARK: помощники

    @MainActor private static func textObject(at point: CGPoint) -> AnnotationObject {
        var style = AnnotationStyle.default
        style.fontSize = 40
        var object = AnnotationObject(kind: .text,
                                      geometry: .rect(CGRect(x: point.x, y: point.y,
                                                             width: 120, height: 48),
                                                      cornerRadius: 0),
                                      style: style)
        object.text = "T"
        return object
    }

    @MainActor private static func hostWindow(for canvas: AnnotationCanvasView) -> NSWindow {
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

    @MainActor private static func click(_ canvas: AnnotationCanvasView,
                                         at point: CGPoint,
                                         in window: NSWindow,
                                         clickCount: Int = 1) {
        let inWindow = canvas.convert(point, to: nil)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: inWindow, in: window, clickCount: clickCount))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: inWindow, in: window, clickCount: clickCount))
    }

    @MainActor private static func mouse(_ type: NSEvent.EventType,
                                         at point: CGPoint,
                                         in window: NSWindow,
                                         clickCount: Int) -> NSEvent {
        NSEvent.mouseEvent(with: type,
                           location: point,
                           modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber,
                           context: nil,
                           eventNumber: 0,
                           clickCount: clickCount,
                           pressure: 1)!
    }

    private enum Ink { case dark, light }

    /// Экранный замер идёт по тем же байтам, что и экспортный: `colorAt` у
    /// rep-а, полученного через `cacheDisplay`, возвращает значения не в том
    /// формате и даёт ложную картину.
    @MainActor private static func inkRatio(rep: NSBitmapImageRep,
                                            in viewRect: CGRect,
                                            canvas: NSView) throws -> CGFloat {
        guard let cg = rep.cgImage else { throw Failure("нет растра отображения") }
        let scaleX = CGFloat(cg.width) / canvas.bounds.width
        let scaleY = CGFloat(cg.height) / canvas.bounds.height
        let box = CGRect(x: viewRect.minX * scaleX, y: viewRect.minY * scaleY,
                         width: viewRect.width * scaleX, height: viewRect.height * scaleY)
        return try inkRatio(image: cg, in: box, colour: .dark)
    }

    /// Отношение чернил в верхней и нижней половине их собственной рамки.
    private static func ratio(ofRows rows: [Int: Int]) throws -> CGFloat {
        let total = rows.values.reduce(0, +)
        guard total > 20, let first = rows.keys.min(), let last = rows.keys.max(), last > first else {
            lastProfile = "чернил всего \(total)"
            return 0
        }
        let middle = CGFloat(first + last) / 2
        var top = 0, bottom = 0
        for (row, count) in rows {
            if CGFloat(row) < middle { top += count } else { bottom += count }
        }
        lastProfile = "строки \(first)…\(last), чернил \(total), верх \(top), низ \(bottom)"
        return CGFloat(top) / CGFloat(max(1, bottom))
    }

    nonisolated(unsafe) private static var lastProfile = ""

    private static func inkRatio(image: CGImage,
                                 in imageRect: CGRect,
                                 colour: Ink = .dark) throws -> CGFloat {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure("не удалось прочитать экспорт")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rows: [Int: Int] = [:]
        var y = max(0, Int(imageRect.minY))
        while y < min(height, Int(imageRect.maxY)) {
            var x = max(0, Int(imageRect.minX))
            var count = 0
            while x < min(width, Int(imageRect.maxX)) {
                // Байтовый буфер и экрана, и экспорта начинается с верхней
                // строки — той же, что и верх документа.
                let row = y
                let index = (row * width + x) * 4
                let isInk: Bool
                switch colour {
                case .dark:
                    // Порог по насыщенности, а не по «не совсем белому»: ореол
                    // сглаживания вокруг штриха иначе весит больше самого штриха
                    // и размывает форму буквы.
                    isInk = min(bytes[index], min(bytes[index + 1], bytes[index + 2])) < 153
                case .light:
                    // Цифра метки белая на цветном круге.
                    isInk = bytes[index] > 220 && bytes[index + 1] > 220 && bytes[index + 2] > 220
                }
                if isInk { count += 1 }
                x += 1
            }
            if count > 0 { rows[y] = count }
            y += 1
        }
        return try ratio(ofRows: rows)
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
