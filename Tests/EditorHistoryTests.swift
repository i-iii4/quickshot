import AppKit

/// История отмены с точки зрения пользователя: один жест — один шаг.
///
/// Модельные тесты дёргают документ напрямую и поэтому не видели, что
/// выделение проходит через ту же запись истории, что и правка: протяжка рамки
/// выделения набивала десятки пустых шагов, а Undo после неё «ничего не делал».
@main
struct EditorHistoryTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try dragIsOneStep()
                try marqueeIsNotHistory()
                try restoredEditorHasNothingToUndo()
                try clickAfterUndoKeepsRedo()
                print("EditorHistoryTests: passed")
                exit(0)
            } catch {
                fputs("EditorHistoryTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// Перетаскивание объекта — ровно один шаг истории.
    @MainActor private static func dragIsOneStep() throws {
        let canvas = makeTestCanvas()
        let host = hostWindow(for: canvas)
        let object = box(at: CGPoint(x: 100, y: 100))
        canvas.document.add(object)
        canvas.document.clearSelection()
        let before = canvas.document.debugUndoDepth

        canvas.tool = .select
        drag(canvas, from: CGPoint(x: 120, y: 120), to: CGPoint(x: 200, y: 160), in: host, steps: 10)

        let added = canvas.document.debugUndoDepth - before
        guard added == 1 else {
            throw Failure("перетаскивание дало \(added) шагов истории вместо одного")
        }
    }

    /// Протяжка рамки выделения меняет только выделение: истории она не пишет.
    @MainActor private static func marqueeIsNotHistory() throws {
        let canvas = makeTestCanvas()
        let host = hostWindow(for: canvas)
        canvas.document.add(box(at: CGPoint(x: 100, y: 100)))
        canvas.document.clearSelection()
        let before = canvas.document.debugUndoDepth

        canvas.tool = .select
        drag(canvas, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 260, y: 220), in: host, steps: 10)

        let added = canvas.document.debugUndoDepth - before
        guard added <= 1 else {
            throw Failure("рамка выделения дала \(added) шагов истории")
        }
    }

    /// Повторно открытый редактор восстанавливает объекты как исходное
    /// состояние: первое же Undo не должно их стирать.
    @MainActor private static func restoredEditorHasNothingToUndo() throws {
        let canvas = makeTestCanvas()
        canvas.restoreObjects([box(at: CGPoint(x: 50, y: 50)), box(at: CGPoint(x: 150, y: 90))])
        guard !canvas.document.canUndo else {
            throw Failure("восстановление объектов попало в историю")
        }
    }

    /// Клик по объекту после Undo не должен убивать Redo.
    @MainActor private static func clickAfterUndoKeepsRedo() throws {
        let canvas = makeTestCanvas()
        let host = hostWindow(for: canvas)
        canvas.document.add(box(at: CGPoint(x: 100, y: 100)))
        _ = canvas.document.undo()
        guard canvas.document.canRedo else { throw Failure("после Undo нечего повторять") }

        canvas.tool = .select
        click(canvas, at: CGPoint(x: 20, y: 20), in: host)

        guard canvas.document.canRedo else {
            throw Failure("клик после Undo потерял Redo")
        }
    }

    // MARK: помощники

    private static func box(at point: CGPoint) -> AnnotationObject {
        AnnotationObject(kind: .rectangle,
                         geometry: .rect(CGRect(x: point.x, y: point.y, width: 60, height: 40),
                                         cornerRadius: 0))
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

    @MainActor private static func drag(_ canvas: AnnotationCanvasView,
                                        from start: CGPoint,
                                        to end: CGPoint,
                                        in window: NSWindow,
                                        steps: Int) {
        canvas.mouseDown(with: mouse(.leftMouseDown, at: canvas.convert(start, to: nil), in: window))
        for index in 1...steps {
            let t = CGFloat(index) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t,
                                y: start.y + (end.y - start.y) * t)
            canvas.mouseDragged(with: mouse(.leftMouseDragged, at: canvas.convert(point, to: nil), in: window))
        }
        canvas.mouseUp(with: mouse(.leftMouseUp, at: canvas.convert(end, to: nil), in: window))
    }

    @MainActor private static func click(_ canvas: AnnotationCanvasView,
                                         at point: CGPoint,
                                         in window: NSWindow) {
        let inWindow = canvas.convert(point, to: nil)
        canvas.mouseDown(with: mouse(.leftMouseDown, at: inWindow, in: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: inWindow, in: window))
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

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
