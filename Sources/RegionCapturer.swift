import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error {
    case permissionDenied
    case noDisplay
    case cacheUnavailable
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

    /// Прогревает ScreenCaptureKit после запуска приложения, если доступ уже выдан.
    /// Пиксели не снимаем: только убираем холодную инициализацию shareable-content из первого hotkey.
    func prewarm() {
        guard CGPreflightScreenCaptureAccess() else { return }
        Task.detached(priority: .utility) {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// Полный кадр каждого переданного дисплея. Один лёгкий fetch SCShareableContent на все,
    /// дальше дисплеи снимаются параллельно: hotkey-путь не должен ждать мониторы очередью.
    /// `onShotCaptured` вызывается по мере готовности каждого дисплея, чтобы overlay мог замерзать
    /// частями и не ждать самый медленный экран.
    func captureFull(displays: [(id: CGDirectDisplayID, frame: CGRect)],
                     excludingBundleIdentifier: String? = nil,
                     onShotCaptured: ((FrozenScreen) async -> Void)? = nil) async throws -> [FrozenScreen] {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.failed(error)
        }

        let excludedWindows: [SCWindow]
        if let excludingBundleIdentifier {
            excludedWindows = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == excludingBundleIdentifier
            }
            guard !excludedWindows.isEmpty else { throw CaptureError.exclusionUnavailable(excludingBundleIdentifier) }
        } else {
            excludedWindows = []
        }

        let scDisplays = Dictionary(uniqueKeysWithValues: content.displays.map { ($0.displayID, $0) })
        let requestedDisplays = displays.compactMap { d -> (id: CGDirectDisplayID, frame: CGRect, scDisplay: SCDisplay)? in
            guard let scDisplay = scDisplays[d.id] else { return nil }
            return (d.id, d.frame, scDisplay)
        }
        guard !requestedDisplays.isEmpty else { throw CaptureError.noDisplay }

        return try await withThrowingTaskGroup(of: FrozenScreen.self) { group in
            for display in requestedDisplays {
                group.addTask {
                    let filter = SCContentFilter(display: display.scDisplay, excludingWindows: excludedWindows)
                    let scale = CGFloat(filter.pointPixelScale)

                    let config = SCStreamConfiguration()
                    config.width  = max(1, Int((display.frame.width * scale).rounded()))
                    config.height = max(1, Int((display.frame.height * scale).rounded()))
                    config.scalesToFit = false
                    config.showsCursor = false
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    config.colorSpaceName = CGColorSpace.sRGB
                    config.captureResolution = .best

                    do {
                        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        return FrozenScreen(displayID: display.id, frame: display.frame, scale: scale, image: img)
                    } catch {
                        if (error as NSError).code == -3801 { throw CaptureError.permissionDenied }   // userDeclined
                        throw CaptureError.failed(error)
                    }
                }
            }

            var result: [FrozenScreen] = []
            for try await shot in group {
                result.append(shot)
                if let onShotCaptured {
                    await onShotCaptured(shot)
                }
            }
            guard !result.isEmpty else { throw CaptureError.noDisplay }
            return result
        }
    }
}
