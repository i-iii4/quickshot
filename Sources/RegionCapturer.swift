import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error {
    case permissionDenied
    case noDisplay
    case exclusionUnavailable(String)
    case failed(Error)
}

/// Замороженный полный кадр одного дисплея. Кадрирование выделения идёт только по нему:
/// live overlay может двигаться и перерисовываться сколько угодно, но в итоговый снимок попадает
/// статичный ScreenCaptureKit-кадр без UI QuickShot.
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
/// Модель «live selection → frozen backdrop → кадрирование»: overlay появляется сразу, а
/// ScreenCaptureKit снимает полные экраны с исключением окон QuickShot. Когда frozen кадр готов,
/// он докладывается под уже видимую рамку и затем используется для crop.
///
/// SCScreenshotManager, а не CGDisplayCreateImage/CGWindowListCreateImage: последние deprecated в
/// SDK 15.0+ и не компилируются. SCScreenshotManager отдаёт CGImage в памяти, с типизированными
/// ошибками и точным контролем Retina-пикселей.
final class RegionCapturer {

    /// Полный кадр каждого переданного дисплея. Один fetch SCShareableContent на все.
    func captureFull(displays: [(id: CGDirectDisplayID, frame: CGRect)],
                     excludingBundleIdentifier: String? = nil) async throws -> [FrozenScreen] {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.failed(error)
        }

        let excludedApps: [SCRunningApplication]
        if let excludingBundleIdentifier {
            excludedApps = content.applications.filter { $0.bundleIdentifier == excludingBundleIdentifier }
            guard !excludedApps.isEmpty else { throw CaptureError.exclusionUnavailable(excludingBundleIdentifier) }
        } else {
            excludedApps = []
        }

        var result: [FrozenScreen] = []
        for d in displays {
            guard let scDisplay = content.displays.first(where: { $0.displayID == d.id }) else { continue }
            let filter = excludedApps.isEmpty
                ? SCContentFilter(display: scDisplay, excludingWindows: [])
                : SCContentFilter(display: scDisplay, excludingApplications: excludedApps, exceptingWindows: [])
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
