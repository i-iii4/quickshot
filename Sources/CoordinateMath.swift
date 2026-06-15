import AppKit
import CoreGraphics

/// Параметры захвата: что отдавать в ScreenCaptureKit.
struct CaptureSpec {
    /// sourceRect — ЛОКАЛЬНЫЙ для дисплея, начало координат СВЕРХУ-СЛЕВА, в ТОЧКАХ.
    let sourceRect: CGRect
    /// Размеры в ПИКСЕЛЯХ (точки × scale) — иначе Retina-снимок выйдет вдвое меньше и размытым.
    let pixelWidth: Int
    let pixelHeight: Int
}

enum CoordinateMath {

    /// Главная и самая опасная часть. Здесь живут ДВА разных y-flip, и их нельзя путать:
    ///
    /// 1. AppKit: начало координат СНИЗУ-СЛЕВА, единицы — точки, глобальная система десктопа.
    /// 2. SCStreamConfiguration.sourceRect: начало координат СВЕРХУ-СЛЕВА, единицы — точки,
    ///    но ЛОКАЛЬНО для захватываемого дисплея (не глобально по десктопу).
    ///
    /// Поэтому: вычитаем frame.origin дисплея (убираем смещение мульти-монитора), затем
    /// делаем flip по высоте ИМЕННО ЭТОГО дисплея. Высоту меню-бар-дисплея (H0) тут НЕ
    /// используем — она нужна только для настоящих глобальных координат CGDisplayBounds.
    ///
    /// - Parameters:
    ///   - sel: выделение в ГЛОБАЛЬНЫХ точках AppKit (начало снизу-слева).
    ///   - df: frame дисплея в координатах AppKit (снизу-слева), на котором сделано выделение.
    ///   - scale: pointPixelScale фильтра (== screen.backingScaleFactor, ~2.0 на Retina).
    static func captureSpec(globalSelection sel: CGRect,
                            displayFrame df: CGRect,
                            scale: CGFloat) -> CaptureSpec {
        let localX = sel.minX - df.minX
        let localY = (df.minY + df.height) - (sel.minY + sel.height)   // flip по высоте дисплея -> сверху-слева
        let src = CGRect(x: localX, y: localY, width: sel.width, height: sel.height)

        let wPx = Int((src.width * scale).rounded())
        let hPx = Int((src.height * scale).rounded())
        return CaptureSpec(sourceRect: src,
                           pixelWidth: max(1, wPx),
                           pixelHeight: max(1, hPx))
    }
}
