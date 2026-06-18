import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error {
    case permissionDenied
    case noDisplay
    case failed(Error)
}

/// Замороженный полный кадр одного дисплея, снятый в первый миг (до показа оверлея). Кадрирование
/// выделения идёт по нему — поэтому ховеры/тултипы/активные состояния не успевают сброситься.
struct FrozenScreen {
    let displayID: CGDirectDisplayID
    let frame: CGRect          // AppKit-точки (глобальные), снизу-слева
    let scale: CGFloat         // pointPixelScale (== backingScaleFactor)
    let image: CGImage         // весь дисплей, нативные пиксели, начало сверху-слева

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

/// Захват экрана через ScreenCaptureKit.
///
/// Модель «заморозка → кадрирование»: по хоткею мгновенно снимаем ПОЛНЫЕ экраны всех дисплеев в
/// память (без оверлея и без активации приложения), затем показываем эти снимки как подложку
/// выделения и кадрируем уже их. Так в кадр попадает истинное состояние экрана на момент нажатия.
///
/// SCScreenshotManager, а не CGDisplayCreateImage/CGWindowListCreateImage: последние обероблены в
/// SDK 15.0+ и не компилируются. SCScreenshotManager отдаёт CGImage в памяти, с типизированными
/// ошибками и точным контролем Retina-пикселей.
final class RegionCapturer {

    /// Полный кадр каждого переданного дисплея. Один fetch SCShareableContent на все.
    func captureFull(displays: [(id: CGDirectDisplayID, frame: CGRect)]) async throws -> [FrozenScreen] {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.failed(error)
        }

        var result: [FrozenScreen] = []
        for d in displays {
            guard let scDisplay = content.displays.first(where: { $0.displayID == d.id }) else { continue }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)

            let config = SCStreamConfiguration()
            config.width  = max(1, Int((d.frame.width * scale).rounded()))
            config.height = max(1, Int((d.frame.height * scale).rounded()))
            config.scalesToFit = false
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.captureResolution = .best

            do {
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                result.append(FrozenScreen(displayID: d.id, frame: d.frame, scale: scale, image: img))
            } catch {
                if (error as NSError).code == -3801 { throw CaptureError.permissionDenied }   // userDeclined
                throw CaptureError.failed(error)
            }
        }
        guard !result.isEmpty else { throw CaptureError.noDisplay }
        return result
    }
}
