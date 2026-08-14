import AppKit

/// Холст редактора: изображение, объекты, выделение и прямое манипулирование.
///
/// Вью владеет только вводом и отрисовкой. Всё состояние живёт в
/// `AnnotationDocument`, вся геометрия зума — в `AnnotationCanvasTransform`.
@MainActor
final class AnnotationCanvasView: NSView {
    /// Радиус ручки на экране и её зона захвата (`G-7`): зона больше, чем
    /// видимая ручка, иначе в неё невозможно попасть.
    private static let handleRadius: CGFloat = 4
    private static let handleHitRadius: CGFloat = 10
    private static let snapDistance: CGFloat = 6

    let document = AnnotationDocument()
    var image: CGImage? { didSet { resetZoom(); needsDisplay = true } }
    var tool: AnnotationTool = .select { didSet { updateCursor() } }
    var onDocumentChanged: (() -> Void)?
    var onRequestTextEditing: ((UUID) -> Void)?

    private var transform = AnnotationCanvasTransform(imageSize: .zero, viewSize: .zero)
    private var draft: AnnotationObject?
    private var dragOrigin: CGPoint?
    private var dragMode: DragMode = .none
    private var lastClickedID: UUID?
    private var marqueeRect: CGRect?

    private enum DragMode {
        case none
        case creating
        case moving(ids: Set<UUID>, start: CGPoint)
        case resizing(id: UUID, handle: AnnotationHandle, start: AnnotationGeometry)
        case marquee(start: CGPoint)
        case panning(start: CGPoint)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: геометрия

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        transform.viewSize = newSize
        transform = transform.clampedOffset()
        needsDisplay = true
    }

    private func resetZoom() {
        guard let image else { return }
        transform = AnnotationCanvasTransform(imageSize: CGSize(width: image.width,
                                                                height: image.height),
                                              viewSize: bounds.size)
        transform.zoom = transform.fitZoom()
    }

    func zoomToFit() {
        transform.zoom = transform.fitZoom()
        transform = transform.clampedOffset()
        needsDisplay = true
    }

    func zoomToActualSize() {
        transform = transform.zoomed(to: 1, around: CGPoint(x: bounds.midX, y: bounds.midY))
        needsDisplay = true
    }

    // MARK: отрисовка

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.07, alpha: 1).setFill()
        context.fill(bounds)

        guard let image else { return }
        let frame = transform.imageFrame

        context.saveGState()
        // При увеличении границы пикселей остаются чёткими (`B-4`).
        context.interpolationQuality = transform.zoom > 1 ? .none : .high
        context.draw(image, in: frame)
        context.restoreGState()

        context.saveGState()
        context.clip(to: frame)
        context.translateBy(x: frame.minX, y: frame.minY)
        context.scaleBy(x: transform.zoom, y: transform.zoom)
        var objects = document.objects
        if let draft { objects.append(draft) }
        AnnotationRenderer.draw(objects,
                                in: context,
                                imageSize: transform.imageSize,
                                strokeScale: 1)
        context.restoreGState()

        drawSelection(in: context)
        drawMarquee(in: context)
    }

    private func drawSelection(in context: CGContext) {
        let selected = document.objects.filter { document.selection.contains($0.id) }
        guard !selected.isEmpty else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        for object in selected {
            let rect = transform.viewRect(fromImage: object.geometry.boundingBox)
                .insetBy(dx: -3, dy: -3)
            context.stroke(rect)
        }
        context.setLineDash(phase: 0, lengths: [])
        // Ручки рисуются только для одиночного выделения: на группе они
        // означали бы масштабирование группы, которого пока нет.
        if selected.count == 1, let object = selected.first {
            for handle in AnnotationHandle.handles(for: object.geometry) {
                let point = transform.viewPoint(fromImage: handle.position(in: object.geometry))
                let rect = CGRect(x: point.x - Self.handleRadius,
                                  y: point.y - Self.handleRadius,
                                  width: Self.handleRadius * 2,
                                  height: Self.handleRadius * 2)
                context.setFillColor(NSColor.white.cgColor)
                context.fillEllipse(in: rect)
                context.setStrokeColor(NSColor(white: 0.15, alpha: 1).cgColor)
                context.strokeEllipse(in: rect)
            }
        }
        context.restoreGState()
    }

    private func drawMarquee(in context: CGContext) {
        guard let marqueeRect else { return }
        context.saveGState()
        context.setFillColor(NSColor.white.withAlphaComponent(0.12).cgColor)
        context.fill(marqueeRect)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(1)
        context.stroke(marqueeRect)
        context.restoreGState()
    }

    // MARK: мышь

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = transform.imagePoint(fromView: viewPoint)

        if event.modifierFlags.contains(.command) {
            dragMode = .panning(start: viewPoint)
            return
        }

        if tool == .select {
            beginSelectionInteraction(at: point, viewPoint: viewPoint, event: event)
        } else {
            beginCreation(at: point, event: event)
        }
    }

    private func beginSelectionInteraction(at point: CGPoint,
                                           viewPoint: CGPoint,
                                           event: NSEvent) {
        // Ручка имеет приоритет над телом объекта: иначе за неё невозможно
        // ухватиться, когда она лежит поверх заливки.
        if document.selection.count == 1,
           let id = document.selection.first,
           let object = document.objects.first(where: { $0.id == id }),
           let handle = handle(at: viewPoint, of: object) {
            document.beginGesture()
            dragMode = .resizing(id: id, handle: handle, start: object.geometry)
            dragOrigin = point
            return
        }

        let below = event.clickCount > 1 ? lastClickedID : nil
        if let hit = document.topmostObject(at: point, below: below) {
            lastClickedID = hit.id
            if event.modifierFlags.contains(.shift) {
                var selection = document.selection
                if selection.contains(hit.id) { selection.remove(hit.id) } else { selection.insert(hit.id) }
                document.select(selection)
            } else if !document.selection.contains(hit.id) {
                document.select([hit.id])
            }
            if hit.kind == .text, event.clickCount > 1 {
                onRequestTextEditing?(hit.id)
                return
            }
            document.beginGesture()
            dragMode = .moving(ids: document.selection, start: point)
            dragOrigin = point
        } else {
            lastClickedID = nil
            document.clearSelection()
            dragMode = .marquee(start: point)
            dragOrigin = point
        }
        notifyChange()
    }

    private func beginCreation(at point: CGPoint, event: NSEvent) {
        guard let kind = tool.kind else { return }
        var object = AnnotationObject(kind: kind, geometry: .point(point))
        switch kind {
        case .arrow, .line, .highlighter:
            object.geometry = .segment(from: point, to: point, curve: 0)
        case .pencil:
            object.geometry = .path([point])
        case .counter:
            object.geometry = .point(point)
            object.number = document.nextCounterNumber()
        case .text:
            object.geometry = .rect(CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                                    cornerRadius: 0)
            object.text = ""
        default:
            object.geometry = .rect(CGRect(origin: point, size: .zero), cornerRadius: 4)
        }
        // Счётчик ставится одним кликом, ему не нужен протяг.
        if kind == .counter {
            document.add(object)
            notifyChange()
            return
        }
        draft = object
        dragOrigin = point
        dragMode = .creating
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = transform.imagePoint(fromView: viewPoint)

        switch dragMode {
        case .panning(let start):
            transform = transform.panned(by: CGVector(dx: viewPoint.x - start.x,
                                                      dy: viewPoint.y - start.y))
            dragMode = .panning(start: viewPoint)
            needsDisplay = true
        case .creating:
            updateDraft(to: point, event: event)
        case let .moving(ids, start):
            var delta = CGVector(dx: point.x - start.x, dy: point.y - start.y)
            if event.modifierFlags.contains(.shift) {
                // Ограничение по доминирующей оси.
                if abs(delta.dx) > abs(delta.dy) { delta.dy = 0 } else { delta.dx = 0 }
            }
            document.move(ids: ids, by: delta)
            dragMode = .moving(ids: ids, start: point)
            notifyChange()
        case let .resizing(id, handle, start):
            document.update(id: id) { object in
                object.geometry = handle.applying(point: point,
                                                  to: start,
                                                  proportional: event.modifierFlags.contains(.shift))
            }
            notifyChange()
        case let .marquee(start):
            let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            marqueeRect = transform.viewRect(fromImage: rect)
            let hits = document.objects.filter { $0.geometry.boundingBox.intersects(rect) }
            document.select(Set(hits.map(\.id)))
            needsDisplay = true
        case .none:
            break
        }
    }

    private func updateDraft(to rawPoint: CGPoint, event: NSEvent) {
        guard var object = draft, let origin = dragOrigin else { return }
        var point = rawPoint
        let proportional = event.modifierFlags.contains(.shift)

        switch object.kind {
        case .arrow, .line, .highlighter:
            if proportional { point = constrainedAngle(from: origin, to: point) }
            object.geometry = .segment(from: origin, to: point, curve: 0)
        case .pencil:
            if case var .path(points) = object.geometry {
                points.append(point)
                object.geometry = .path(points)
            }
        default:
            var rect = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                              width: abs(point.x - origin.x), height: abs(point.y - origin.y))
            if proportional {
                let side = max(rect.width, rect.height)
                rect.size = CGSize(width: side, height: side)
            }
            if event.modifierFlags.contains(.option) {
                rect = CGRect(x: origin.x - rect.width, y: origin.y - rect.height,
                              width: rect.width * 2, height: rect.height * 2)
            }
            object.geometry = .rect(rect, cornerRadius: object.kind == .rectangle ? 4 : 0)
        }
        draft = object
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .creating:
            commitDraft()
        case .moving, .resizing:
            document.endGesture()
            notifyChange()
        case .marquee:
            marqueeRect = nil
            needsDisplay = true
        case .panning, .none:
            break
        }
        dragMode = .none
        dragOrigin = nil
    }

    /// `D-5`: объект пренебрежимо малого размера не создаётся — случайный клик
    /// не должен оставлять мусор.
    private func commitDraft() {
        defer { draft = nil }
        guard let object = draft else { return }
        let box = object.geometry.boundingBox
        let isDegenerate = box.width < 3 && box.height < 3
        if isDegenerate, object.kind != .pencil, object.kind != .text {
            needsDisplay = true
            return
        }
        document.add(object)
        if object.kind == .text { onRequestTextEditing?(object.id) }
        notifyChange()
    }

    // MARK: колесо и зум

    override func scrollWheel(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            let factor = 1 + event.scrollingDeltaY / 200
            transform = transform.zoomed(to: transform.zoom * factor, around: viewPoint)
        } else {
            transform = transform.panned(by: CGVector(dx: event.scrollingDeltaX,
                                                      dy: event.scrollingDeltaY))
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        transform = transform.zoomed(to: transform.zoom * (1 + event.magnification),
                                     around: viewPoint)
        needsDisplay = true
    }

    // MARK: клавиатура (`H-1`, `H-2`)

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: nudge(dx: -step, dy: 0)
        case 124: nudge(dx: step, dy: 0)
        case 125: nudge(dx: 0, dy: step)
        case 126: nudge(dx: 0, dy: -step)
        case 51, 117:
            document.removeSelection()
            notifyChange()
        case 48:
            cycleSelection(backwards: event.modifierFlags.contains(.shift))
        case 53:
            if !document.selection.isEmpty {
                document.clearSelection()
                notifyChange()
            } else {
                super.keyDown(with: event)
            }
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  !event.modifierFlags.contains(.command),
                  let selected = AnnotationTool.tool(forShortcut: characters) else {
                super.keyDown(with: event)
                return
            }
            tool = selected
            onDocumentChanged?()
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard !document.selection.isEmpty else { return }
        document.move(ids: document.selection, by: CGVector(dx: dx, dy: dy))
        notifyChange()
    }

    /// Табуляция обходит объекты в порядке создания (`H-2`).
    private func cycleSelection(backwards: Bool) {
        let ids = document.objects.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = document.selection.first,
              let index = ids.firstIndex(of: current) else {
            document.select([backwards ? ids[ids.count - 1] : ids[0]])
            notifyChange()
            return
        }
        let next = backwards
            ? (index == 0 ? ids.count - 1 : index - 1)
            : (index + 1) % ids.count
        document.select([ids[next]])
        notifyChange()
    }

    // MARK: курсор (`G-10`)

    private func updateCursor() {
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        let cursor: NSCursor = tool == .select ? .arrow : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: вспомогательное

    private func handle(at viewPoint: CGPoint, of object: AnnotationObject) -> AnnotationHandle? {
        AnnotationHandle.handles(for: object.geometry).first { handle in
            let point = transform.viewPoint(fromImage: handle.position(in: object.geometry))
            return hypot(point.x - viewPoint.x, point.y - viewPoint.y) <= Self.handleHitRadius
        }
    }

    private func notifyChange() {
        needsDisplay = true
        onDocumentChanged?()
    }

    /// Итоговое изображение с запечёнными объектами: то, что уходит в буфер,
    /// файл и перетаскивание.
    func flattenedImage() -> CGImage? {
        guard let image else { return nil }
        let width = image.width
        let height = image.height
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Изображение рисуется в неперевёрнутом контексте, а документ живёт в
        // перевёрнутых координатах вью, поэтому объекты зеркалим по вертикали.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.draw(document.objects,
                                in: context,
                                imageSize: CGSize(width: width, height: height),
                                strokeScale: 1)
        return context.makeImage()
    }
}
