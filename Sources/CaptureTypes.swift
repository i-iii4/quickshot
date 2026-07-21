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
}

struct FrozenScreen: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let image: CGImage

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
