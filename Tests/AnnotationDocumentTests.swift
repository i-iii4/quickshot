import CoreGraphics
import Foundation

@main
struct AnnotationDocumentTests {
    static func main() {
        undoRestoresExactState()
        undoRestoresSelection()
        gestureCollapsesIntoOneStep()
        emptyGestureLeavesNoHistory()
        redoStackClearsOnNewWork()
        zOrderOperations()
        hitTestingWalksDownOverlaps()
        duplicateAndPasteOffsetCopies()
        lockedObjectsResistEverything()
        counterNumbering()
        print("AnnotationDocumentTests: passed")
    }

    /// Приёмка `C-5`: «создать, изменить цвет, переместить, отменить трижды»
    /// возвращает ровно исходное состояние.
    private static func undoRestoresExactState() {
        let document = AnnotationDocument()
        let empty = document.state

        document.add(object(.rectangle))
        let id = document.objects[0].id
        document.update(id: id) { $0.style.paletteIndex = 3 }
        document.move(ids: [id], by: CGVector(dx: 10, dy: 5))

        expect(document.undo(), "move must be undoable")
        expect(document.undo(), "style change must be undoable")
        expect(document.undo(), "creation must be undoable")
        expect(document.state == empty,
               "three undos must return the exact original state")
        expect(!document.canUndo, "history must be exhausted")

        expect(document.redo() && document.redo() && document.redo(), "redo must replay all three")
        expect(document.objects.count == 1 && document.objects[0].style.paletteIndex == 3,
               "redo must restore the edited object")
    }

    /// `C-6`: после отмены удаления объект снова выделен.
    private static func undoRestoresSelection() {
        let document = AnnotationDocument()
        document.add(object(.arrow))
        let id = document.objects[0].id
        expect(document.selection == [id], "new object is selected")

        document.removeSelection()
        expect(document.objects.isEmpty && document.selection.isEmpty, "object removed")

        expect(document.undo(), "removal is undoable")
        expect(document.selection == [id],
               "undoing a removal must restore selection, got \(document.selection)")
    }

    /// Перетаскивание порождает сотни изменений, но история обязана получить
    /// один шаг.
    private static func gestureCollapsesIntoOneStep() {
        let document = AnnotationDocument()
        document.add(object(.rectangle))
        let id = document.objects[0].id
        let beforeDrag = document.state

        document.beginGesture()
        for _ in 0..<50 {
            document.move(ids: [id], by: CGVector(dx: 1, dy: 0))
        }
        document.endGesture()

        expect(document.objects[0].geometry.boundingBox.origin.x == 50,
               "all gesture steps must apply")
        expect(document.undo(), "gesture must be undoable")
        expect(document.state == beforeDrag,
               "one undo must revert the whole gesture")
    }

    private static func emptyGestureLeavesNoHistory() {
        let document = AnnotationDocument()
        document.add(object(.line))
        let depth = historyDepth(of: document)

        document.beginGesture()
        document.endGesture()

        expect(historyDepth(of: document) == depth,
               "a click without movement must not occupy a history step")
    }

    private static func redoStackClearsOnNewWork() {
        let document = AnnotationDocument()
        document.add(object(.rectangle))
        document.add(object(.ellipse))
        expect(document.undo(), "undo the second object")
        expect(document.canRedo, "redo is available")
        document.add(object(.arrow))
        expect(!document.canRedo, "new work must clear the redo stack")
    }

    private static func zOrderOperations() {
        let document = AnnotationDocument()
        document.add(object(.rectangle))
        document.add(object(.ellipse))
        document.add(object(.arrow))
        let ids = document.objects.map(\.id)

        document.bringToFront(ids: [ids[0]])
        expect(document.objects.map(\.id) == [ids[1], ids[2], ids[0]], "bring to front")

        document.sendToBack(ids: [ids[0]])
        expect(document.objects.map(\.id) == [ids[0], ids[1], ids[2]], "send to back")

        document.bringForward(ids: [ids[0]])
        expect(document.objects.map(\.id) == [ids[1], ids[0], ids[2]], "bring forward one step")

        document.sendBackward(ids: [ids[0]])
        expect(document.objects.map(\.id) == [ids[0], ids[1], ids[2]], "send backward one step")

        document.sendBackward(ids: [ids[0]])
        expect(document.objects.map(\.id) == [ids[0], ids[1], ids[2]],
               "the bottom object cannot go lower")
    }

    /// `G-2`: повторный клик в ту же точку спускается на уровень ниже.
    private static func hitTestingWalksDownOverlaps() {
        let document = AnnotationDocument()
        document.add(object(.rectangle, rect: CGRect(x: 0, y: 0, width: 100, height: 100)))
        document.add(object(.ellipse, rect: CGRect(x: 10, y: 10, width: 50, height: 50)))
        let bottom = document.objects[0].id
        let top = document.objects[1].id
        let point = CGPoint(x: 30, y: 30)

        let first = document.topmostObject(at: point)
        expect(first?.id == top, "first click selects the topmost object")

        let second = document.topmostObject(at: point, below: top)
        expect(second?.id == bottom, "second click descends one level")

        let third = document.topmostObject(at: point, below: bottom)
        expect(third?.id == top, "descending past the bottom wraps to the top")
    }

    private static func duplicateAndPasteOffsetCopies() {
        let document = AnnotationDocument()
        document.add(object(.rectangle, rect: CGRect(x: 0, y: 0, width: 20, height: 20)))
        let original = document.objects[0].id

        document.duplicate(ids: [original])
        expect(document.objects.count == 2, "duplicate adds an object")
        expect(document.objects[1].id != original, "duplicate has its own identity")
        expect(document.objects[1].geometry.boundingBox.origin.x == 12,
               "duplicate is offset so it does not hide the original")
        expect(document.selection == [document.objects[1].id], "duplicate becomes the selection")

        let copied = document.copySelection()
        document.paste(copied)
        expect(document.objects.count == 3, "paste adds another object")
        expect(Set(document.objects.map(\.id)).count == 3, "pasted object has a fresh identity")
    }

    /// `C-10`: заблокированный объект не двигается, не меняется, не удаляется
    /// и не выделяется.
    private static func lockedObjectsResistEverything() {
        let document = AnnotationDocument()
        document.add(object(.rectangle))
        let id = document.objects[0].id
        document.update(id: id) { $0.isLocked = true }
        let locked = document.state

        document.move(ids: [id], by: CGVector(dx: 10, dy: 10))
        document.update(id: id) { $0.style.lineWidth = 99 }
        document.remove(ids: [id])
        document.select([id])

        expect(document.objects.count == 1, "locked object survives removal")
        expect(document.objects[0] == locked.objects[0], "locked object is unchanged")
        expect(document.selection.isEmpty, "locked object is not selectable")
    }

    private static func counterNumbering() {
        let document = AnnotationDocument()
        for _ in 0..<3 {
            var counter = object(.counter)
            counter.number = document.nextCounterNumber()
            document.add(counter)
        }
        expect(document.objects.compactMap(\.number) == [1, 2, 3], "counters auto-increment")

        let middle = document.objects[1].id
        document.remove(ids: [middle])
        expect(document.nextCounterNumber() == 4,
               "next number continues past the maximum, so numbers never repeat")

        document.renumberCounters()
        expect(document.objects.compactMap(\.number) == [1, 2],
               "explicit renumbering closes the gap")
    }

    // MARK: помощники

    private static func object(_ kind: AnnotationKind,
                               rect: CGRect = CGRect(x: 0, y: 0, width: 10, height: 10))
        -> AnnotationObject {
        switch kind {
        case .arrow, .line, .highlighter:
            return AnnotationObject(kind: kind,
                                    geometry: .segment(from: rect.origin,
                                                       to: CGPoint(x: rect.maxX, y: rect.maxY),
                                                       curve: 0))
        case .counter:
            return AnnotationObject(kind: kind, geometry: .point(rect.origin))
        case .pencil:
            return AnnotationObject(kind: kind, geometry: .path([rect.origin]))
        default:
            return AnnotationObject(kind: kind, geometry: .rect(rect, cornerRadius: 0))
        }
    }

    private static func historyDepth(of document: AnnotationDocument) -> Int {
        var depth = 0
        let snapshot = document.state
        while document.undo() { depth += 1 }
        for _ in 0..<depth { _ = document.redo() }
        expect(document.state == snapshot, "probing history must not change state")
        return depth
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("AnnotationDocumentTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
