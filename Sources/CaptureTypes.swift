import CoreGraphics

struct CaptureDisplay {
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

/// Замороженный полный кадр одного дисплея. Кадрирование выделения идёт только по нему:
/// live overlay может двигаться и перерисовываться сколько угодно, но в итоговый снимок попадает
/// статичный ScreenCaptureKit-кадр без UI QuickShot.
struct FrozenScreen {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
    let image: CGImage

    /// Вырезать выделение (в глобальных точках AppKit) из замороженного кадра.
    func crop(globalSelection sel: CGRect) -> CGImage? {
        let spec = CoordinateMath.captureSpec(globalSelection: sel, displayFrame: frame, scale: scale)
        let px = CGRect(x: spec.sourceRect.minX * scale, y: spec.sourceRect.minY * scale,
                        width: CGFloat(spec.pixelWidth), height: CGFloat(spec.pixelHeight))
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard px.width >= 1, px.height >= 1 else { return nil }
        return image.cropping(to: px)
    }
}
