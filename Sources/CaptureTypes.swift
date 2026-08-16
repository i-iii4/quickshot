import CoreGraphics
import Foundation

struct CaptureDisplay: Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let quartzBounds: CGRect
}

struct FrozenSnapshotBatch: @unchecked Sendable {
    let sessionID: UUID
    let screens: [FrozenScreen]
    let captureStartedAt: CFAbsoluteTime
    let captureCompletedAt: CFAbsoluteTime
    let maximumDisplaySkew: TimeInterval
}

/// Момент, из которого собран снимок.
///
/// Итог всегда вырезается из ОДНОГО дисплея, поэтому разброс времени между
/// кадрами разных экранов не может испортить выданные пиксели. Значение он
/// имеет в одном случае: пользователь протянул выделение через границу
/// экранов. Тогда часть выделения, оставшаяся на соседнем дисплее, была снята
/// в заметно другой момент и в результат не попала — об этом честно сообщается,
/// но снимок выдаётся.
struct CaptureMomentQuality: Equatable, Sendable {
    /// Выделение задело больше одного дисплея.
    let crossedDisplays: Bool
    /// Разброс времени между задетыми дисплеями.
    let displaySkew: TimeInterval
    /// Бюджет, выше которого разброс считается заметным.
    let budget: TimeInterval

    var isDegraded: Bool { crossedDisplays && displaySkew > budget }

    static let intact = CaptureMomentQuality(crossedDisplays: false, displaySkew: 0, budget: .infinity)
}

/// Качество момента для выделения по набору замороженных экранов.
///
/// Судится по СЫРОМУ прямоугольнику выделения, до обрезки по дисплею доставки:
/// именно он показывает, куда пользователь тянул рамку.
func captureMomentQuality(rawSelection: CGRect,
                          screens: [FrozenScreen],
                          budget: TimeInterval) -> CaptureMomentQuality {
    let touched = screens.filter { !$0.frame.intersection(rawSelection).isNull
        && $0.frame.intersection(rawSelection).width >= 1
        && $0.frame.intersection(rawSelection).height >= 1 }
    guard touched.count > 1 else {
        return CaptureMomentQuality(crossedDisplays: false, displaySkew: 0, budget: budget)
    }
    let timestamps = touched.map(\.capturedAt)
    let skew = (timestamps.max() ?? 0) - (timestamps.min() ?? 0)
    return CaptureMomentQuality(crossedDisplays: true, displaySkew: skew, budget: budget)
}

struct FrozenScreen: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let image: CGImage
    let capturedAt: CFAbsoluteTime
    let captureDuration: TimeInterval

    init(displayID: CGDirectDisplayID,
         frame: CGRect,
         image: CGImage,
         capturedAt: CFAbsoluteTime = CFAbsoluteTimeGetCurrent(),
         captureDuration: TimeInterval = 0) {
        self.displayID = displayID
        self.frame = frame
        self.image = image
        self.capturedAt = capturedAt
        self.captureDuration = captureDuration
    }

    func crop(globalSelection selection: CGRect) -> CGImage? {
        let pixelRect = CoordinateMath.pixelCropRect(globalSelection: selection,
                                                     displayFrame: frame,
                                                     imageSize: CGSize(width: image.width,
                                                                       height: image.height))
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }
}

enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case noDisplay
    case snapshotUnavailable(String)
    case captureStackUnavailable(String)

    var description: String {
        switch self {
        case .permissionDenied:
            return "permissionDenied"
        case .noDisplay:
            return "noDisplay"
        case .snapshotUnavailable(let reason):
            return "snapshotUnavailable(\(reason))"
        case .captureStackUnavailable(let reason):
            return "captureStackUnavailable(\(reason))"
        }
    }
}
