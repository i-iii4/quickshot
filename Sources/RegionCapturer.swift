import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error {
    case permissionDenied
    case noDisplay
    case failed(Error)
}

/// Захват прямоугольного региона через ScreenCaptureKit.
///
/// Почему SCScreenshotManager, а не CGDisplayCreateImage/CGWindowListCreateImage:
/// последние обероблены в SDK 15.0+ и просто не компилируются под актуальный SDK.
/// SCScreenshotManager отдаёт CGImage прямо в памяти, с типизированными ошибками и
/// точным контролем Retina-пикселей.
final class RegionCapturer {

    /// Тихая проверка статуса доступа «Запись экрана» (без диалога).
    func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// Показать системный запрос доступа и зарегистрировать приложение в списке.
    @discardableResult
    func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Захват `globalRect` (в глобальных точках AppKit) с дисплея `displayID`.
    /// Принимает Sendable-данные (CGRect/идентификатор), чтобы не передавать NSScreen
    /// через границу Task.
    func capture(globalRect: CGRect,
                 displayID: CGDirectDisplayID,
                 displayFrame: CGRect) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.failed(error)
        }

        // Берём именно тот SCDisplay, на котором сделано выделение: sourceRect-кроп
        // надёжно работает только в рамках одного дисплея.
        let scDisplay: SCDisplay
        if displayID != 0, let match = content.displays.first(where: { $0.displayID == displayID }) {
            scDisplay = match
        } else if let first = content.displays.first {
            scDisplay = first
        } else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)            // == screen.backingScaleFactor
        let spec = CoordinateMath.captureSpec(globalSelection: globalRect,
                                              displayFrame: displayFrame, scale: scale)

        let config = SCStreamConfiguration()
        config.sourceRect = spec.sourceRect                   // точки, локально для дисплея, сверху-слева
        config.width  = spec.pixelWidth                       // пиксели
        config.height = spec.pixelHeight                      // пиксели
        config.scalesToFit = false
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB             // тег цвета — без него возможны сдвиги
        config.captureResolution = .best

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            // -3801 == userDeclined (доступ «Запись экрана» отозван/не выдан).
            if (error as NSError).code == -3801 { throw CaptureError.permissionDenied }
            throw CaptureError.failed(error)
        }
    }
}
