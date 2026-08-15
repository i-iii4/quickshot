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
    /// Пустой текст занимает рамку, в которую помещается поле ввода. Раньше
    /// объект создавался нулевым, и поле выходило размером в девять точек.
    static let minimumTextWidth: CGFloat = 120
    static let minimumTextHeight: CGFloat = 28
    static let minimumTextFieldSize = NSSize(width: 120, height: 28)

    let document = AnnotationDocument()
    var image: CGImage? { didSet { resetZoom(); needsDisplay = true } }   // документ не трогаем: A-6
    var tool: AnnotationTool = .select { didSet { updateCursor() } }

    /// Текущий стиль инструмента. Применяется и к следующему созданному
    /// объекту, и к выделенным — панель свойств обслуживает оба случая
    /// (`F-1`), а изменение выделенного объекта отменяется отдельным шагом
    /// истории (`F-2`).
    private(set) var paletteIndex = 0
    private(set) var strokeWeight = AnnotationStrokeWeight.medium
    private(set) var isFilled = false
    var onDocumentChanged: (() -> Void)?
    var onRequestTextEditing: ((UUID) -> Void)?

    private var transform = AnnotationCanvasTransform(imageSize: .zero, viewSize: .zero)
    private var draft: AnnotationObject?
    private var dragOrigin: CGPoint?
    private var dragMode: DragMode = .none
    private var lastClickedID: UUID?
    /// Рамка кадрирования в координатах изображения (`D-40`). Пока она задана,
    /// снимок не обрезан: обрезка происходит при применении, поэтому её можно
    /// отменить, не потеряв отрезанное (`D-42`).
    private(set) var cropRect: CGRect?
    /// Поворот кратно 90 градусам, применяется к итоговому изображению.
    private(set) var rotationQuarterTurns = 0
    /// Снимок документа на момент последнего сохранения (`ED-8`, `ED-11`).
    private var lastSavedState: AnnotationDocumentState?
    /// Последний выданный результат: держится до следующей выдачи, чтобы
    /// перетаскивание и буфер не пересобирали изображение заново.
    private var lastFlattened: CGImage?
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
        // Вью перевёрнута, а CGImage рисуется в нижне-левой системе координат:
        // без обратного переворота вокруг кадра снимок зеркалится по вертикали.
        context.translateBy(x: 0, y: frame.minY + frame.maxY)
        context.scaleBy(x: 1, y: -1)
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
        drawCropOverlay(in: context)
    }

    private func drawSelection(in context: CGContext) {
        let selected = document.objects.filter { document.selection.contains($0.id) }
        guard !selected.isEmpty else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        for object in selected {
            let rect = transform.viewRect(fromImage: object.visualBounds)
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

    /// Затемнение вне рамки кадрирования: пользователь видит, что останется.
    private func drawCropOverlay(in context: CGContext) {
        guard let rect = cropRect, rect.width > 1, rect.height > 1 else { return }
        let viewRect = transform.viewRect(fromImage: rect)
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.addRect(transform.imageFrame)
        context.addRect(viewRect)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(viewRect)
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
            adoptStyleFromSelection()
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
        if tool == .crop {
            cropRect = CGRect(origin: point, size: .zero)
            dragOrigin = point
            dragMode = .creating
            return
        }
        guard let kind = tool.kind else { return }
        var object = AnnotationObject(kind: kind, geometry: .point(point), style: currentStyle)
        switch kind {
        case .arrow, .line, .highlighter:
            object.geometry = .segment(from: point, to: point, curve: 0)
        case .pencil:
            object.geometry = .path([point])
        case .counter:
            object.geometry = .point(point)
            object.number = document.nextCounterNumber()
        case .text:
            // Пустой текст обязан иметь рамку, в которую можно попасть и в
            // которой помещается поле ввода: нулевой прямоугольник давал поле
            // в девять точек.
            object.geometry = .rect(CGRect(origin: point,
                                           size: CGSize(width: Self.minimumTextWidth,
                                                        height: max(Self.minimumTextHeight,
                                                                    currentStyle.fontSize * 1.4))),
                                    cornerRadius: 0)
            object.text = ""
        default:
            object.geometry = .rect(CGRect(origin: point, size: .zero), cornerRadius: 4)
        }
        // Счётчик ставится одним кликом, ему не нужен протяг. Второе нажатие
        // двойного клика приходит отдельным событием и раньше ставило вторую
        // метку поверх первой.
        if kind == .counter {
            guard event.clickCount <= 1 else { return }
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
        if tool == .crop, let origin = dragOrigin {
            cropRect = CGRect(x: min(origin.x, rawPoint.x), y: min(origin.y, rawPoint.y),
                              width: abs(rawPoint.x - origin.x),
                              height: abs(rawPoint.y - origin.y))
            needsDisplay = true
            return
        }
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
        if tool == .crop {
            // Слишком мелкая рамка — промах, а не намерение обрезать всё.
            if let rect = cropRect, rect.width < 8 || rect.height < 8 { cropRect = nil }
            needsDisplay = true
            onDocumentChanged?()
            return
        }
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

    // MARK: свойства (`F-1`, `F-2`)

    var currentStyle: AnnotationStyle {
        AnnotationStyle(paletteIndex: paletteIndex,
                        lineWidth: strokeWeight.lineWidth,
                        filled: isFilled,
                        fillOpacity: 0.25,
                        fontSize: strokeWeight.fontSize)
    }

    func setPaletteIndex(_ index: Int) {
        paletteIndex = index
        applyStyleToSelection { $0.paletteIndex = index }
    }

    func setStrokeWeight(_ weight: AnnotationStrokeWeight) {
        strokeWeight = weight
        applyStyleToSelection {
            $0.lineWidth = weight.lineWidth
            $0.fontSize = weight.fontSize
        }
    }

    func setFilled(_ filled: Bool) {
        isFilled = filled
        applyStyleToSelection { $0.filled = filled }
    }

    private func applyStyleToSelection(_ mutation: (inout AnnotationStyle) -> Void) {
        guard !document.selection.isEmpty else { return }
        for id in document.selection {
            document.update(id: id) { object in mutation(&object.style) }
        }
        notifyChange()
    }

    /// Стиль выделенного объекта поднимается в панель: пользователь видит
    /// свойства того, что выбрал, а не последние настройки инструмента.
    func adoptStyleFromSelection() {
        guard let id = document.selection.first,
              let object = document.objects.first(where: { $0.id == id }) else { return }
        paletteIndex = object.style.paletteIndex
        isFilled = object.style.filled
        strokeWeight = AnnotationStrokeWeight.allCases.min {
            abs($0.lineWidth - object.style.lineWidth) < abs($1.lineWidth - object.style.lineWidth)
        } ?? .medium
    }

    func restoreObjects(_ objects: [AnnotationObject]) {
        guard !objects.isEmpty else { return }
        document.perform { state in
            state.objects = objects
            state.selection = []
        }
    }

    /// Поворот на четверть оборота (`D-44`). Применяется к итоговому
    /// изображению, а не к объектам: объекты остаются в координатах снимка.
    func rotateQuarterTurn() {
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
        needsDisplay = true
        onDocumentChanged?()
    }

    func clearCrop() {
        cropRect = nil
        needsDisplay = true
        onDocumentChanged?()
    }


    // MARK: клавиатурные операции (`H-1`, `H-2`)

    /// Создание объекта в центре кадра: путь без мыши обязан быть полным.
    func createObjectAtCentre(kind: AnnotationKind) {
        let centre = CGPoint(x: transform.imageSize.width / 2, y: transform.imageSize.height / 2)
        let side: CGFloat = 80
        let geometry: AnnotationGeometry
        switch kind {
        case .arrow, .line, .highlighter:
            geometry = .segment(from: CGPoint(x: centre.x - side / 2, y: centre.y),
                                to: CGPoint(x: centre.x + side / 2, y: centre.y),
                                curve: 0)
        case .pencil:
            geometry = .path([centre])
        case .counter:
            geometry = .point(centre)
        default:
            geometry = .rect(CGRect(x: centre.x - side / 2, y: centre.y - side / 2,
                                    width: side, height: side),
                             cornerRadius: kind == .rectangle ? 4 : 0)
        }
        var object = AnnotationObject(kind: kind, geometry: geometry, style: currentStyle)
        if kind == .counter { object.number = document.nextCounterNumber() }
        document.add(object)
        notifyChange()
    }

    func selectNext(backwards: Bool) {
        cycleSelection(backwards: backwards)
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        nudge(dx: dx, dy: dy)
    }

    func deleteSelection() {
        document.removeSelection()
        notifyChange()
    }

    /// `G-3`, `G-4`: выделение рамкой захватывает пересечённые объекты.
    func selectInRect(_ rect: CGRect) {
        let hits = document.objects.filter { $0.geometry.boundingBox.intersects(rect) }
        document.select(Set(hits.map(\.id)))
        notifyChange()
    }

    // MARK: выравнивание и показатели (`G-11`, `G-12`)

    enum Alignment { case left, right, top, bottom, horizontalCentre, verticalCentre }

    func alignSelection(_ alignment: Alignment) {
        let selected = document.objects.filter { document.selection.contains($0.id) }
        guard selected.count > 1 else { return }
        let boxes = selected.map(\.geometry.boundingBox)
        let target: (CGRect) -> CGVector
        switch alignment {
        case .left:
            let edge = boxes.map(\.minX).min() ?? 0
            target = { CGVector(dx: edge - $0.minX, dy: 0) }
        case .right:
            let edge = boxes.map(\.maxX).max() ?? 0
            target = { CGVector(dx: edge - $0.maxX, dy: 0) }
        case .top:
            let edge = boxes.map(\.minY).min() ?? 0
            target = { CGVector(dx: 0, dy: edge - $0.minY) }
        case .bottom:
            let edge = boxes.map(\.maxY).max() ?? 0
            target = { CGVector(dx: 0, dy: edge - $0.maxY) }
        case .horizontalCentre:
            let centre = (boxes.map(\.midX).reduce(0, +)) / CGFloat(boxes.count)
            target = { CGVector(dx: centre - $0.midX, dy: 0) }
        case .verticalCentre:
            let centre = (boxes.map(\.midY).reduce(0, +)) / CGFloat(boxes.count)
            target = { CGVector(dx: 0, dy: centre - $0.midY) }
        }

        document.beginGesture()
        for object in selected {
            document.update(id: object.id) { item in
                item.geometry = item.geometry.translated(by: target(item.geometry.boundingBox))
            }
        }
        document.endGesture()
        notifyChange()
    }

    /// Размер и положение выделения: показываются во время изменения.
    func selectionMetrics() -> CGRect? {
        let boxes = document.objects
            .filter { document.selection.contains($0.id) }
            .map(\.geometry.boundingBox)
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    // MARK: сохранение и откат (`ED-8`, `ED-11`)

    var hasUnsavedChanges: Bool {
        guard let lastSavedState else { return !document.objects.isEmpty }
        return lastSavedState != document.state
    }

    func markSaved() {
        lastSavedState = document.state
    }

    /// Отмена в редакторе возвращает к последнему сохранению, а не к
    /// захваченному снимку: сохранённое пользователь считает своим.
    func revertToLastSave() {
        guard let lastSavedState else {
            document.perform { $0 = AnnotationDocumentState() }
            notifyChange()
            return
        }
        document.perform { $0 = lastSavedState }
        notifyChange()
    }

    /// `Q-5`: объект, уехавший за кадр, возвращается в видимую область.
    func bringSelectionIntoView() {
        guard !document.selection.isEmpty else { return }
        let frame = CGRect(origin: .zero, size: transform.imageSize)
        document.beginGesture()
        for id in document.selection {
            guard let object = document.objects.first(where: { $0.id == id }) else { continue }
            let box = object.geometry.boundingBox
            guard !box.intersects(frame) else { continue }
            let delta = CGVector(dx: frame.midX - box.midX, dy: frame.midY - box.midY)
            document.update(id: id) { $0.geometry = $0.geometry.translated(by: delta) }
        }
        document.endGesture()
        notifyChange()
    }

    /// Координаты изображения в координаты холста. Редактор обязан считать
    /// рамку поля ввода через владельца трансформации, а не конвертировать
    /// координаты изображения как оконные.
    func viewRect(forImageRect rect: CGRect) -> CGRect {
        transform.viewRect(fromImage: rect)
    }

    var zoomFactor: CGFloat { transform.zoom }

    /// Рамка поля ввода текста: не меньше пригодного размера и целиком внутри
    /// холста.
    func textEditingFrame(for object: AnnotationObject) -> NSRect {
        var rect = transform.viewRect(fromImage: object.visualBounds)
        rect.size.width = max(rect.width, Self.minimumTextFieldSize.width)
        rect.size.height = max(rect.height, Self.minimumTextFieldSize.height)
        rect.origin.x = min(max(0, rect.origin.x), max(0, bounds.width - rect.width))
        rect.origin.y = min(max(0, rect.origin.y), max(0, bounds.height - rect.height))
        return rect
    }

    /// `L-4`: сколько несжатых копий изображения удерживает редактор.
    /// Исходник плюс, на время выдачи, результат — больше быть не должно.
    var debugRetainedImageCount: Int {
        (image == nil ? 0 : 1) + (lastFlattened == nil ? 0 : 1)
    }

    /// Принудительная отрисовка для замеров бюджета кадра.
    func renderForTesting() {
        guard let context = CGContext(data: nil,
                                      width: max(1, Int(bounds.width)),
                                      height: max(1, Int(bounds.height)),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        AnnotationRenderer.draw(document.objects,
                                in: context,
                                imageSize: transform.imageSize,
                                strokeScale: 1)
    }

    /// Итоговое изображение с запечёнными объектами: то, что уходит в буфер,
    /// файл и перетаскивание. Кадрирование и поворот применяются здесь же.
    func flattenedImage() -> CGImage? {
        guard let baked = bakedImage() else { return nil }
        let cropped = applyCrop(to: baked)
        let result = applyRotation(to: cropped)
        lastFlattened = result
        return result
    }

    private func applyCrop(to image: CGImage) -> CGImage {
        guard let rect = cropRect, rect.width >= 8, rect.height >= 8 else { return image }
        // Документ живёт в перевёрнутых координатах вью, а `cropping` считает
        // от верхнего левого угла изображения — по вертикали это совпадает.
        let bounded = rect.intersection(CGRect(x: 0, y: 0,
                                               width: CGFloat(image.width),
                                               height: CGFloat(image.height)))
        guard !bounded.isNull, let cropped = image.cropping(to: bounded) else { return image }
        return cropped
    }

    private func applyRotation(to image: CGImage) -> CGImage {
        guard rotationQuarterTurns % 4 != 0 else { return image }
        let turns = rotationQuarterTurns % 4
        let swapped = turns % 2 == 1
        let width = swapped ? image.height : image.width
        let height = swapped ? image.width : image.height
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.translateBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private func bakedImage() -> CGImage? {
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
