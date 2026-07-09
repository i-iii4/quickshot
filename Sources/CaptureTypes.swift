import CoreGraphics

struct CaptureDisplay: Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
}

enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case noDisplay
    case captureStackUnavailable(String)

    var description: String {
        switch self {
        case .permissionDenied:
            return "permissionDenied"
        case .noDisplay:
            return "noDisplay"
        case .captureStackUnavailable(let reason):
            return "captureStackUnavailable(\(reason))"
        }
    }
}
