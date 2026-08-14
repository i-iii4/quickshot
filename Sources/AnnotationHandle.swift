import CoreGraphics

/// Ручка объекта: точка, за которую его тянут.
///
/// Набор ручек зависит от геометрии, а не от инструмента: у отрезка это концы и
/// точка изгиба, у прямоугольника — восемь по периметру. Так добавление нового
/// инструмента с уже известной геометрией не требует новых ручек.
enum AnnotationHandle: Equatable {
    case segmentStart
    case segmentEnd
    case segmentCurve
    case rectCorner(x: RectEdge, y: RectEdge)
    case rectEdge(RectEdge, axis: Axis)

    enum RectEdge: Equatable { case minimum, maximum }
    enum Axis: Equatable { case horizontal, vertical }

    static func handles(for geometry: AnnotationGeometry) -> [AnnotationHandle] {
        switch geometry {
        case .segment:
            return [.segmentStart, .segmentEnd, .segmentCurve]
        case .rect:
            return [
                .rectCorner(x: .minimum, y: .minimum),
                .rectCorner(x: .maximum, y: .minimum),
                .rectCorner(x: .minimum, y: .maximum),
                .rectCorner(x: .maximum, y: .maximum),
                .rectEdge(.minimum, axis: .horizontal),
                .rectEdge(.maximum, axis: .horizontal),
                .rectEdge(.minimum, axis: .vertical),
                .rectEdge(.maximum, axis: .vertical),
            ]
        case .path, .point:
            // Свободный штрих и метка шага перемещаются целиком: тянуть
            // отдельную точку кривой бессмысленно.
            return []
        }
    }

    func position(in geometry: AnnotationGeometry) -> CGPoint {
        switch (self, geometry) {
        case let (.segmentStart, .segment(from, _, _)):
            return from
        case let (.segmentEnd, .segment(_, to, _)):
            return to
        case let (.segmentCurve, .segment(from, to, curve)):
            return Self.curveHandlePosition(from: from, to: to, curve: curve)
        case let (.rectCorner(x, y), .rect(rect, _)):
            let standardized = rect.standardized
            return CGPoint(x: x == .minimum ? standardized.minX : standardized.maxX,
                           y: y == .minimum ? standardized.minY : standardized.maxY)
        case let (.rectEdge(edge, axis), .rect(rect, _)):
            let standardized = rect.standardized
            switch axis {
            case .horizontal:
                return CGPoint(x: edge == .minimum ? standardized.minX : standardized.maxX,
                               y: standardized.midY)
            case .vertical:
                return CGPoint(x: standardized.midX,
                               y: edge == .minimum ? standardized.minY : standardized.maxY)
            }
        default:
            return .zero
        }
    }

    static func curveHandlePosition(from: CGPoint, to: CGPoint, curve: CGFloat) -> CGPoint {
        let midpoint = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        return CGPoint(x: midpoint.x + (-dy / length) * curve,
                       y: midpoint.y + (dx / length) * curve)
    }

    /// Новая геометрия после перетаскивания ручки в точку `point`.
    func applying(point: CGPoint,
                  to geometry: AnnotationGeometry,
                  proportional: Bool) -> AnnotationGeometry {
        switch (self, geometry) {
        case let (.segmentStart, .segment(_, to, curve)):
            return .segment(from: point, to: to, curve: curve)
        case let (.segmentEnd, .segment(from, _, curve)):
            return .segment(from: from, to: point, curve: curve)
        case let (.segmentCurve, .segment(from, to, _)):
            // Знак изгиба берётся из стороны, на которую увели ручку.
            let dx = to.x - from.x
            let dy = to.y - from.y
            let length = max(0.001, (dx * dx + dy * dy).squareRoot())
            let midpoint = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            let offset = CGVector(dx: point.x - midpoint.x, dy: point.y - midpoint.y)
            let curve = (offset.dx * (-dy / length)) + (offset.dy * (dx / length))
            return .segment(from: from, to: to, curve: curve)
        case let (.rectCorner(x, y), .rect(rect, radius)):
            let standardized = rect.standardized
            var minX = x == .minimum ? point.x : standardized.minX
            var maxX = x == .maximum ? point.x : standardized.maxX
            var minY = y == .minimum ? point.y : standardized.minY
            var maxY = y == .maximum ? point.y : standardized.maxY
            if proportional {
                let side = max(abs(maxX - minX), abs(maxY - minY))
                if x == .minimum { minX = maxX - side } else { maxX = minX + side }
                if y == .minimum { minY = maxY - side } else { maxY = minY + side }
            }
            return .rect(CGRect(x: min(minX, maxX), y: min(minY, maxY),
                                width: abs(maxX - minX), height: abs(maxY - minY)),
                         cornerRadius: radius)
        case let (.rectEdge(edge, axis), .rect(rect, radius)):
            let standardized = rect.standardized
            var next = standardized
            switch axis {
            case .horizontal:
                if edge == .minimum {
                    next.size.width = standardized.maxX - point.x
                    next.origin.x = point.x
                } else {
                    next.size.width = point.x - standardized.minX
                }
            case .vertical:
                if edge == .minimum {
                    next.size.height = standardized.maxY - point.y
                    next.origin.y = point.y
                } else {
                    next.size.height = point.y - standardized.minY
                }
            }
            return .rect(next.standardized, cornerRadius: radius)
        default:
            return geometry
        }
    }
}

/// Ограничение угла шагом 15 градусов (`D-10`). Чистая геометрия: живёт вне
/// вью, поэтому проверяется без окна и без главного потока.
func constrainedAngle(from: CGPoint, to: CGPoint) -> CGPoint {
    let dx = to.x - from.x
    let dy = to.y - from.y
    let distance = (dx * dx + dy * dy).squareRoot()
    guard distance > 0 else { return to }
    let step = CGFloat.pi / 12
    let snapped = (atan2(dy, dx) / step).rounded() * step
    return CGPoint(x: from.x + cos(snapped) * distance,
                   y: from.y + sin(snapped) * distance)
}
