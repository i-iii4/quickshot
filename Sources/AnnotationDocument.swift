import CoreGraphics
import Foundation

/// Тип аннотации. Инструмент создаёт объект, но после создания объект от
/// инструмента не зависит (`C-1`).
enum AnnotationKind: String, Equatable, CaseIterable {
    case arrow
    case rectangle
    case ellipse
    case line
    case pencil
    case text
    case highlighter
    case counter
    case redaction
}

/// Геометрия объекта. Формы разведены по способу задания, а не по инструменту:
/// стрелка и линия описываются одним отрезком, прямоугольник и скрывающая
/// плашка — одним прямоугольником.
enum AnnotationGeometry: Equatable {
    /// `curve` — смещение средней точки перпендикулярно отрезку (`D-8`).
    case segment(from: CGPoint, to: CGPoint, curve: CGFloat)
    case rect(CGRect, cornerRadius: CGFloat)
    case path([CGPoint])
    case point(CGPoint)

    var boundingBox: CGRect {
        switch self {
        case let .segment(from, to, _):
            return CGRect(x: min(from.x, to.x),
                          y: min(from.y, to.y),
                          width: abs(to.x - from.x),
                          height: abs(to.y - from.y))
        case let .rect(rect, _):
            return rect.standardized
        case let .path(points):
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for point in points.dropFirst() {
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case let .point(point):
            return CGRect(origin: point, size: .zero)
        }
    }

    func translated(by delta: CGVector) -> AnnotationGeometry {
        switch self {
        case let .segment(from, to, curve):
            return .segment(from: from.offset(by: delta), to: to.offset(by: delta), curve: curve)
        case let .rect(rect, radius):
            return .rect(rect.offsetBy(dx: delta.dx, dy: delta.dy), cornerRadius: radius)
        case let .path(points):
            return .path(points.map { $0.offset(by: delta) })
        case let .point(point):
            return .point(point.offset(by: delta))
        }
    }
}

private extension CGPoint {
    func offset(by delta: CGVector) -> CGPoint {
        CGPoint(x: x + delta.dx, y: y + delta.dy)
    }
}

/// Стиль объекта. Цвет задан индексом в палитре токенов дизайн-системы, а не
/// значением: модель не должна знать о цветовом пространстве и о House Dark
/// (`F-3`).
struct AnnotationStyle: Equatable {
    var paletteIndex: Int
    var lineWidth: CGFloat
    var filled: Bool
    var fillOpacity: CGFloat
    var fontSize: CGFloat

    static let `default` = AnnotationStyle(paletteIndex: 0,
                                           lineWidth: 3,
                                           filled: false,
                                           fillOpacity: 0.2,
                                           fontSize: 14)
}

struct AnnotationObject: Equatable, Identifiable {
    let id: UUID
    var kind: AnnotationKind
    var geometry: AnnotationGeometry
    var style: AnnotationStyle
    /// Текст подписи и выноски; `nil` для остальных типов.
    var text: String?
    /// Номер шага для счётчика (`D-34`).
    var number: Int?
    /// Заблокированный объект не выделяется и не меняется (`C-10`).
    var isLocked: Bool
    /// Группа или связка «метка + подпись» (`C-9`, `D-38`, `D-39`): объекты с
    /// одним идентификатором двигаются вместе.
    var groupID: UUID?

    init(id: UUID = UUID(),
         kind: AnnotationKind,
         geometry: AnnotationGeometry,
         style: AnnotationStyle = .default,
         text: String? = nil,
         number: Int? = nil,
         isLocked: Bool = false,
         groupID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.geometry = geometry
        self.style = style
        self.text = text
        self.number = number
        self.isLocked = isLocked
        self.groupID = groupID
    }

    /// Границы того, что объект реально занимает на снимке. Для большинства
    /// типов это рамка геометрии, но метка задана точкой: её круг рисуется
    /// вокруг центра по размеру шрифта, и без этой поправки в метку нельзя
    /// было ни попасть кликом, ни увидеть осмысленную рамку выделения.
    var visualBounds: CGRect {
        switch kind {
        case .counter:
            guard case let .point(centre) = geometry else { return geometry.boundingBox }
            let radius = Self.counterRadius(fontSize: style.fontSize)
            return CGRect(x: centre.x - radius, y: centre.y - radius,
                          width: radius * 2, height: radius * 2)
        default:
            return geometry.boundingBox
        }
    }

    /// Радиус круга метки. Единственный источник для отрисовки и для попадания.
    static func counterRadius(fontSize: CGFloat) -> CGFloat {
        max(8, fontSize)
    }
}

/// Снимок состояния документа. Выделение входит в состояние намеренно: отмена
/// удаления обязана вернуть и объект, и его выделенность (`C-6`).
struct AnnotationDocumentState: Equatable {
    var objects: [AnnotationObject] = []
    var selection: Set<UUID> = []

    /// Порядок массива — порядок наложения: последний рисуется поверх (`C-4`).
    func index(of id: UUID) -> Int? {
        objects.firstIndex { $0.id == id }
    }
}

/// Документ аннотаций с историей отмены.
///
/// История хранит снимки состояния, а не обратные операции. Для документа из
/// десятков лёгких объектов это дешевле по коду и надёжнее: любая новая
/// операция автоматически отменяема, и невозможно забыть написать её обратную
/// пару — а именно так undo обычно и ломается.
///
/// Жест (перетаскивание, изменение размера, рисование карандашом) порождает
/// сотни промежуточных изменений, но в историю обязан попасть одним шагом.
/// Для этого есть `beginGesture()`/`endGesture()`: снимок делается один раз,
/// в начале жеста.
final class AnnotationDocument {
    private(set) var state = AnnotationDocumentState()
    private var undoStack: [AnnotationDocumentState] = []
    private var redoStack: [AnnotationDocumentState] = []
    private var gestureDepth = 0
    /// Redo, отложенный на время жеста: жест, ничего не изменивший, обязан его
    /// вернуть — иначе клик после Undo молча лишает пользователя повтора.
    private var redoStackDuringGesture: [AnnotationDocumentState] = []

    var canUndo: Bool { !undoStack.isEmpty }
#if TESTING
    /// Сколько шагов истории накоплено: один жест пользователя обязан давать
    /// ровно один.
    var debugUndoDepth: Int { undoStack.count }
#endif
    var canRedo: Bool { !redoStack.isEmpty }
    var objects: [AnnotationObject] { state.objects }
    var selection: Set<UUID> { state.selection }
    var isEmpty: Bool { state.objects.isEmpty }

    init(state: AnnotationDocumentState = AnnotationDocumentState()) {
        self.state = state
    }

    // MARK: история

    /// Изменение с записью в историю. Во время жеста снимок уже сделан, и
    /// повторно история не растёт.
    func perform(_ mutation: (inout AnnotationDocumentState) -> Void) {
        let before = state
        if gestureDepth == 0 { undoStack.append(before) }
        var next = state
        mutation(&next)
        guard next != before else {
            if gestureDepth == 0 { undoStack.removeLast() }
            return
        }
        state = next
        if gestureDepth == 0 { redoStack.removeAll() }
    }

    func beginGesture() {
        if gestureDepth == 0 {
            undoStack.append(state)
            redoStackDuringGesture = redoStack
            redoStack.removeAll()
        }
        gestureDepth += 1
    }

    /// Завершение жеста. Если состояние не изменилось за жест, снимок
    /// снимается: клик без перемещения не должен занимать шаг истории.
    func endGesture() {
        guard gestureDepth > 0 else { return }
        gestureDepth -= 1
        guard gestureDepth == 0 else { return }
        defer { redoStackDuringGesture = [] }
        guard let opening = undoStack.last else { return }
        if opening == state {
            undoStack.removeLast()
            redoStack = redoStackDuringGesture
        }
    }

    /// Изменение, которое не является правкой документа: выделение, загрузка
    /// исходного состояния. В историю не пишется и Redo не сбрасывает.
    ///
    /// Выделение хранится в состоянии (отмена удаления обязана вернуть и
    /// объект, и его выделенность), но САМО изменение выделения шагом истории
    /// не является: иначе протяжка рамки набивает десятки пустых шагов, и Undo
    /// перестаёт отменять содержательные действия.
    private func mutateWithoutHistory(_ mutation: (inout AnnotationDocumentState) -> Void) {
        var next = state
        mutation(&next)
        state = next
    }

    /// Загрузка исходного состояния (повторное открытие редактора). История
    /// начинается заново: первое Undo не должно стирать восстановленное.
    func reset(to newState: AnnotationDocumentState) {
        state = newState
        undoStack.removeAll()
        redoStack.removeAll()
        gestureDepth = 0
    }

    @discardableResult
    func undo() -> Bool {
        guard gestureDepth == 0, let previous = undoStack.popLast() else { return false }
        redoStack.append(state)
        state = previous
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard gestureDepth == 0, let next = redoStack.popLast() else { return false }
        undoStack.append(state)
        state = next
        return true
    }

    // MARK: объекты

    func add(_ object: AnnotationObject, select: Bool = true) {
        perform { state in
            state.objects.append(object)
            if select { state.selection = [object.id] }
        }
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        perform { state in
            state.objects.removeAll { ids.contains($0.id) && !$0.isLocked }
            state.selection.subtract(ids)
        }
    }

    func removeSelection() {
        remove(ids: state.selection)
    }

    func update(id: UUID, _ mutation: (inout AnnotationObject) -> Void) {
        perform { state in
            guard let index = state.index(of: id), !state.objects[index].isLocked else { return }
            mutation(&state.objects[index])
        }
    }

    func move(ids: Set<UUID>, by delta: CGVector) {
        guard !ids.isEmpty, delta != .zero else { return }
        perform { state in
            for index in state.objects.indices where ids.contains(state.objects[index].id) {
                guard !state.objects[index].isLocked else { continue }
                state.objects[index].geometry = state.objects[index].geometry.translated(by: delta)
            }
        }
    }

    // MARK: выделение

    func select(_ ids: Set<UUID>) {
        mutateWithoutHistory { state in
            state.selection = ids.filter { id in
                state.objects.first { $0.id == id }?.isLocked == false
            }
        }
    }

    func selectAll() {
        mutateWithoutHistory { state in
            state.selection = Set(state.objects.filter { !$0.isLocked }.map(\.id))
        }
    }

    func clearSelection() {
        guard !state.selection.isEmpty else { return }
        mutateWithoutHistory { $0.selection = [] }
    }

    /// Верхний объект под точкой. Повторный клик в ту же точку спускается на
    /// уровень ниже (`G-2`): `below` задаёт текущий выбор, ниже которого искать.
    func topmostObject(at point: CGPoint,
                       tolerance: CGFloat = 6,
                       below currentID: UUID? = nil) -> AnnotationObject? {
        let hits = state.objects.filter {
            !$0.isLocked && $0.visualBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
        guard !hits.isEmpty else { return nil }
        guard let currentID, let position = hits.firstIndex(where: { $0.id == currentID }) else {
            return hits.last
        }
        return position == hits.startIndex ? hits.last : hits[hits.index(before: position)]
    }

    // MARK: порядок наложения (`C-3`)

    func bringToFront(ids: Set<UUID>) {
        reorder(ids: ids) { objects, moving in objects + moving }
    }

    func sendToBack(ids: Set<UUID>) {
        reorder(ids: ids) { objects, moving in moving + objects }
    }

    func bringForward(ids: Set<UUID>) {
        shift(ids: ids, by: 1)
    }

    func sendBackward(ids: Set<UUID>) {
        shift(ids: ids, by: -1)
    }

    private func reorder(ids: Set<UUID>,
                         _ combine: ([AnnotationObject], [AnnotationObject]) -> [AnnotationObject]) {
        guard !ids.isEmpty else { return }
        perform { state in
            let moving = state.objects.filter { ids.contains($0.id) }
            guard !moving.isEmpty else { return }
            let rest = state.objects.filter { !ids.contains($0.id) }
            state.objects = combine(rest, moving)
        }
    }

    private func shift(ids: Set<UUID>, by step: Int) {
        guard !ids.isEmpty, step != 0 else { return }
        perform { state in
            let indices = state.objects.indices.filter { ids.contains(state.objects[$0].id) }
            let ordered = step > 0 ? indices.reversed().map { $0 } : indices
            for index in ordered {
                let target = index + step
                guard state.objects.indices.contains(target) else { continue }
                guard !ids.contains(state.objects[target].id) else { continue }
                state.objects.swapAt(index, target)
            }
        }
    }

    // MARK: дублирование и буфер (`C-7`, `C-8`)

    /// Дубликат смещён, иначе он полностью закрывает оригинал и выглядит как
    /// отсутствие результата.
    func duplicate(ids: Set<UUID>, offset: CGVector = CGVector(dx: 12, dy: 12)) {
        guard !ids.isEmpty else { return }
        perform { state in
            let copies = state.objects
                .filter { ids.contains($0.id) }
                .map { source -> AnnotationObject in
                    var copy = source
                    copy = AnnotationObject(kind: source.kind,
                                            geometry: source.geometry.translated(by: offset),
                                            style: source.style,
                                            text: source.text,
                                            number: source.number,
                                            isLocked: false)
                    return copy
                }
            guard !copies.isEmpty else { return }
            state.objects.append(contentsOf: copies)
            state.selection = Set(copies.map(\.id))
        }
    }

    func copySelection() -> [AnnotationObject] {
        state.objects.filter { state.selection.contains($0.id) }
    }

    func paste(_ objects: [AnnotationObject], offset: CGVector = CGVector(dx: 12, dy: 12)) {
        guard !objects.isEmpty else { return }
        perform { state in
            let copies = objects.map { source in
                AnnotationObject(kind: source.kind,
                                 geometry: source.geometry.translated(by: offset),
                                 style: source.style,
                                 text: source.text,
                                 number: source.number,
                                 isLocked: false)
            }
            state.objects.append(contentsOf: copies)
            state.selection = Set(copies.map(\.id))
        }
    }

    // MARK: группы и связки (`C-9`, `D-38`, `D-39`)

    func groupSelection() {
        guard state.selection.count > 1 else { return }
        let group = UUID()
        perform { state in
            for index in state.objects.indices where state.selection.contains(state.objects[index].id) {
                state.objects[index].groupID = group
            }
        }
    }

    func ungroupSelection() {
        perform { state in
            for index in state.objects.indices where state.selection.contains(state.objects[index].id) {
                state.objects[index].groupID = nil
            }
        }
    }

    /// Связка метки шага с подписью: та же механика, что и группа, но создаётся
    /// парой, а не выделением.
    func pair(_ first: UUID, with second: UUID) {
        let group = UUID()
        perform { state in
            for index in state.objects.indices
            where state.objects[index].id == first || state.objects[index].id == second {
                state.objects[index].groupID = group
            }
        }
    }

    /// Выделение расширяется до целых групп: половина группы под курсором
    /// означает всю группу.
    func expandSelectionToGroups() {
        let groups = Set(state.objects
            .filter { state.selection.contains($0.id) }
            .compactMap(\.groupID))
        guard !groups.isEmpty else { return }
        mutateWithoutHistory { state in
            let extra = state.objects.filter { object in
                guard let group = object.groupID else { return false }
                return groups.contains(group)
            }
            state.selection.formUnion(extra.map(\.id))
        }
    }

    /// Перенос стиля на выделение (`F-6`).
    func applyStyle(_ style: AnnotationStyle, to ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        perform { state in
            for index in state.objects.indices where ids.contains(state.objects[index].id) {
                state.objects[index].style = style
            }
        }
    }

    // MARK: счётчик шагов (`D-36`)

    /// Следующий номер шага: продолжает максимум, а не количество, иначе после
    /// удаления средней метки номера начали бы повторяться.
    func nextCounterNumber(startingAt start: Int = 1) -> Int {
        let used = state.objects.compactMap(\.number)
        return (used.max().map { $0 + 1 }) ?? start
    }

    /// Перенумерация после удаления промежуточной метки. Отключаемо настройкой
    /// (`D-36`), поэтому вынесено отдельным действием, а не побочным эффектом
    /// удаления.
    func renumberCounters(startingAt start: Int = 1) {
        perform { state in
            var next = start
            for index in state.objects.indices where state.objects[index].kind == .counter {
                state.objects[index].number = next
                next += 1
            }
        }
    }
}
