import AppKit
import Foundation

/// Угол экрана, в котором живёт стопка (`TR-42`).
///
/// Прежняя модель задавала СТОРОНУ, и углов получалось три: `right` и
/// `bottom` делили правый нижний, левого верхнего не существовало вовсе.
/// Угол определяет пару доступных осей: вертикальную и горизонтальную,
/// обе выходят из него.
enum TrayPosition: String {
    case bottomRight, bottomLeft, topRight, topLeft

    var isTop: Bool { self == .topRight || self == .topLeft }
    var isLeft: Bool { self == .bottomLeft || self == .topLeft }

    /// Вертикальная ось угла: лента идёт вдоль правого или левого края.
    var verticalEdge: ThumbnailLayoutEdge { isLeft ? .left : .right }
    /// Горизонтальная ось угла: лента идёт вдоль нижнего или верхнего края.
    var horizontalEdge: ThumbnailLayoutEdge { isTop ? .top : .bottom }

    static let defaultsKey = "trayPosition"
    static let changedNotification = Notification.Name("QuickShotTrayPositionChanged")

    static var current: TrayPosition {
        let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        if let corner = TrayPosition(rawValue: raw) { return corner }
        // Настройка от прежней модели сторон читается как ближайший угол:
        // правый и нижний край сходились в правом нижнем, верхний — в правом
        // верхнем.
        switch raw {
        case "left": return .bottomLeft
        case "top": return .topRight
        default: return .bottomRight
        }
    }
    static func set(_ pos: TrayPosition) {
        UserDefaults.standard.set(pos.rawValue, forKey: defaultsKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
