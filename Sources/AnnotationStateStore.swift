import CoreGraphics
import Foundation
import OSLog

/// Служебное состояние аннотаций на диске (`ED-16`…`ED-18`).
///
/// Это не формат проекта: файлы лежат в скрытом каталоге рядом со снимками,
/// пользователю не показываются, не открываются двойным кликом и не
/// пересылаются. Отсюда и правило совместимости — её нет: при любом
/// несовпадении структуры состояние отбрасывается целиком, снимок остаётся
/// изображением без редактируемых объектов (`ED-17`).
@MainActor
final class AnnotationStateStore {
    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot",
                                                category: "state")
    /// Версия структуры. При несовпадении файл выбрасывается, а не мигрируется.
    private static let version = 1

    let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func save(objects: [AnnotationObject], for id: UUID) {
        guard !objects.isEmpty else { discard(for: id); return }
        let payload = StatePayload(version: Self.version,
                                   objects: objects.map(ObjectPayload.init))
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: url(for: id), options: .atomic)
        } catch {
            Self.log.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func load(for id: UUID) -> [AnnotationObject] {
        guard let data = try? Data(contentsOf: url(for: id)) else { return [] }
        guard let payload = try? JSONDecoder().decode(StatePayload.self, from: data) else {
            // Повреждённое или чужое состояние: выбрасываем молча, снимок от
            // этого не страдает.
            discard(for: id)
            return []
        }
        guard payload.version == Self.version else {
            discard(for: id)
            return []
        }
        return payload.objects.map(\.object)
    }

    func discard(for id: UUID) {
        try? fileManager.removeItem(at: url(for: id))
    }

    func discardAll() {
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: сериализация

    private struct StatePayload: Codable {
        let version: Int
        let objects: [ObjectPayload]
    }

    private struct ObjectPayload: Codable {
        let kind: String
        let geometry: GeometryPayload
        let paletteIndex: Int
        let lineWidth: CGFloat
        let filled: Bool
        let fillOpacity: CGFloat
        let fontSize: CGFloat
        let text: String?
        let number: Int?
        let isLocked: Bool

        init(_ object: AnnotationObject) {
            kind = object.kind.rawValue
            geometry = GeometryPayload(object.geometry)
            paletteIndex = object.style.paletteIndex
            lineWidth = object.style.lineWidth
            filled = object.style.filled
            fillOpacity = object.style.fillOpacity
            fontSize = object.style.fontSize
            text = object.text
            number = object.number
            isLocked = object.isLocked
        }

        var object: AnnotationObject {
            AnnotationObject(kind: AnnotationKind(rawValue: kind) ?? .rectangle,
                             geometry: geometry.geometry,
                             style: AnnotationStyle(paletteIndex: paletteIndex,
                                                    lineWidth: lineWidth,
                                                    filled: filled,
                                                    fillOpacity: fillOpacity,
                                                    fontSize: fontSize),
                             text: text,
                             number: number,
                             isLocked: isLocked)
        }
    }

    private struct GeometryPayload: Codable {
        let kind: String
        let points: [CGPoint]
        let rect: CGRect?
        let curve: CGFloat
        let cornerRadius: CGFloat

        init(_ geometry: AnnotationGeometry) {
            switch geometry {
            case let .segment(from, to, curveValue):
                kind = "segment"; points = [from, to]; rect = nil
                curve = curveValue; cornerRadius = 0
            case let .rect(value, radius):
                kind = "rect"; points = []; rect = value
                curve = 0; cornerRadius = radius
            case let .path(values):
                kind = "path"; points = values; rect = nil
                curve = 0; cornerRadius = 0
            case let .point(value):
                kind = "point"; points = [value]; rect = nil
                curve = 0; cornerRadius = 0
            }
        }

        var geometry: AnnotationGeometry {
            switch kind {
            case "segment":
                return .segment(from: points.first ?? .zero,
                                to: points.count > 1 ? points[1] : .zero,
                                curve: curve)
            case "path":
                return .path(points)
            case "point":
                return .point(points.first ?? .zero)
            default:
                return .rect(rect ?? .zero, cornerRadius: cornerRadius)
            }
        }
    }
}
