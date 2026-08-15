import AppKit

/// Редактируемое состояние снимка, живущее, пока снимок остаётся в трее.
///
/// Модель предметной области различает две вещи. Файл в папке — единственная
/// версия на диске, её перезаписывает сохранение. Редактируемое состояние —
/// объекты аннотаций, позволяющие вернуться и поправить подпись. Закрытие трея
/// уничтожает второе и оставляет первое (`ED-5`, `ED-7`).
@MainActor
final class AnnotationSessionStore {
    struct Session {
        var objects: [AnnotationObject]
        /// Снимок отличается от захваченного (`ED-3`).
        var isEdited: Bool
    }

    private var sessions: [UUID: Session] = [:]

    func session(for id: UUID) -> Session? { sessions[id] }
    func objects(for id: UUID) -> [AnnotationObject] { sessions[id]?.objects ?? [] }
    func isEdited(_ id: UUID) -> Bool { sessions[id]?.isEdited ?? false }

    /// Сохранение из редактора: объекты запоминаются, снимок помечается
    /// изменённым. Признак не накапливается — он означает «отличается от
    /// захваченного», а не число правок (`ED-9`).
    func store(objects: [AnnotationObject], for id: UUID) {
        sessions[id] = Session(objects: objects, isEdited: !objects.isEmpty)
    }

    /// Возврат к исходному снимку (`ED-10`).
    func reset(_ id: UUID) {
        sessions.removeValue(forKey: id)
    }

    /// Карточка убрана из трея: редактируемое состояние уничтожается вместе с
    /// ней. В папке остаётся последняя сохранённая версия.
    func discard(_ id: UUID) {
        sessions.removeValue(forKey: id)
    }

    func discardAll() {
        sessions.removeAll()
    }

    var trackedCount: Int { sessions.count }
}

/// Отредактированная версия снимка для выдачи.
///
/// После сохранения любая выдача — буфер, перетаскивание, экспорт — обязана
/// отдавать изменённую версию (`ED-4`). Хранилище держит запечённые пиксели
/// рядом с исходными, не подменяя сам артефакт: исходник нужен, чтобы
/// вернуться к нему (`ED-10`) и чтобы повторное редактирование начиналось с
/// чистого снимка, а не с уже нарисованных поверх объектов.
@MainActor
final class EditedImageStore {
    private var images: [UUID: CGImage] = [:]
    private var prepared: [UUID: Clipboard.PreparedImage] = [:]

    func store(_ image: CGImage, for id: UUID) {
        images[id] = image
        prepared[id] = Clipboard.prepareImage(cgImage: image)
    }

    func image(for id: UUID) -> CGImage? { images[id] }
    func preparedImage(for id: UUID) -> Clipboard.PreparedImage? { prepared[id] }
    func hasEdited(_ id: UUID) -> Bool { images[id] != nil }

    func discard(_ id: UUID) {
        images.removeValue(forKey: id)
        prepared.removeValue(forKey: id)
    }

    func discardAll() {
        images.removeAll()
        prepared.removeAll()
    }
}
