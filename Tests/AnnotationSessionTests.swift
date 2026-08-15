import AppKit

@main
struct AnnotationSessionTests {
    static func main() {
        Task { @MainActor in
            savingMarksEditedAndKeepsObjects()
            reopeningReturnsEditableObjects()
            emptyDocumentIsNotEdited()
            resetReturnsToTheCapturedState()
            closingTheTrayDestroysEverything()
            editedImageIsUsedForDelivery()
            strokeWeightsAreDistinguishable()
            print("AnnotationSessionTests: passed")
            exit(0)
        }
        RunLoop.main.run()
    }

    /// `ED-3`, `ED-5`: сохранение помечает снимок изменённым и запоминает
    /// объекты редактируемыми.
    @MainActor private static func savingMarksEditedAndKeepsObjects() {
        let store = AnnotationSessionStore()
        let id = UUID()
        expect(!store.isEdited(id), "a fresh screenshot is not edited")

        store.store(objects: [object()], for: id)
        expect(store.isEdited(id), "saving marks the screenshot edited")
        expect(store.objects(for: id).count == 1, "objects survive for a later edit")
    }

    @MainActor private static func reopeningReturnsEditableObjects() {
        let store = AnnotationSessionStore()
        let id = UUID()
        var text = object()
        text.text = "before"
        store.store(objects: [text], for: id)

        var restored = store.objects(for: id)
        expect(restored.first?.text == "before", "the text comes back as text, not as pixels")

        restored[0].text = "after"
        store.store(objects: restored, for: id)
        expect(store.objects(for: id).first?.text == "after",
               "a second edit replaces the stored objects")
        expect(store.isEdited(id), "the badge does not accumulate, it stays set")
    }

    /// `ED-9`: признак означает «отличается от захваченного». Документ без
    /// объектов от захваченного не отличается.
    @MainActor private static func emptyDocumentIsNotEdited() {
        let store = AnnotationSessionStore()
        let id = UUID()
        store.store(objects: [], for: id)
        expect(!store.isEdited(id), "an empty document must not claim to be edited")
    }

    /// `ED-10`: возврат к исходному снимку.
    @MainActor private static func resetReturnsToTheCapturedState() {
        let store = AnnotationSessionStore()
        let id = UUID()
        store.store(objects: [object()], for: id)
        store.reset(id)
        expect(!store.isEdited(id) && store.objects(for: id).isEmpty,
               "reset clears both the badge and the objects")
    }

    /// `ED-7`: закрытие трея уничтожает редактируемое состояние.
    @MainActor private static func closingTheTrayDestroysEverything() {
        let sessions = AnnotationSessionStore()
        let images = EditedImageStore()
        let id = UUID()
        sessions.store(objects: [object()], for: id)
        images.store(sampleImage(), for: id)

        sessions.discardAll()
        images.discardAll()
        expect(sessions.trackedCount == 0, "no editable state survives closing the tray")
        expect(!images.hasEdited(id), "no baked version survives closing the tray")
    }

    /// `ED-4`: после сохранения выдача берёт изменённую версию.
    @MainActor private static func editedImageIsUsedForDelivery() {
        let images = EditedImageStore()
        let id = UUID()
        expect(images.preparedImage(for: id) == nil, "nothing to deliver before an edit")

        images.store(sampleImage(), for: id)
        let prepared = images.preparedImage(for: id)
        expect(prepared != nil, "an edited screenshot must be ready for delivery")
        expect(prepared?.png != nil, "delivery needs encoded pixels")

        images.discard(id)
        expect(images.preparedImage(for: id) == nil, "discarding removes the edited version")
    }

    /// Три ступени толщины обязаны быть различимы: иначе выбор бессмысленен.
    @MainActor private static func strokeWeightsAreDistinguishable() {
        let widths = AnnotationStrokeWeight.allCases.map(\.lineWidth)
        expect(widths == widths.sorted(), "weights must grow monotonically")
        expect(Set(widths).count == widths.count, "weights must differ")
        for index in 1..<widths.count {
            expect(widths[index] - widths[index - 1] >= 2,
                   "neighbouring weights must differ visibly; got \(widths)")
        }
        let fonts = AnnotationStrokeWeight.allCases.map(\.fontSize)
        expect(fonts == fonts.sorted() && Set(fonts).count == fonts.count,
               "label size follows the same ladder; got \(fonts)")
    }

    private static func object() -> AnnotationObject {
        AnnotationObject(kind: .text,
                         geometry: .rect(CGRect(x: 0, y: 0, width: 10, height: 10),
                                         cornerRadius: 0),
                         text: "note")
    }

    private static func sampleImage() -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 4,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("AnnotationSessionTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
