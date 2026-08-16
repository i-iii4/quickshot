import CoreGraphics
import Foundation

/// Разброс времени между дисплеями судится по кадрированию, а не по захвату.
///
/// Результат всегда вырезается из одного экрана, поэтому разброс не может
/// испортить выданные пиксели. Значение он имеет ровно в одном случае:
/// выделение задело соседний дисплей, снятый в заметно другой момент, и эта
/// часть в результат не попала.
@main
struct CaptureMomentQualityTests {
    static func main() {
        singleDisplayIsNeverDegraded()
        crossingDisplaysWithHighSkewIsDegraded()
        crossingDisplaysWithinBudgetIsIntact()
        touchingBySliverDoesNotCount()
        print("CaptureMomentQualityTests: passed")
    }

    private static let budget: TimeInterval = 0.120

    /// Выделение внутри одного дисплея не помечается ни при каком разбросе.
    private static func singleDisplayIsNeverDegraded() {
        let screens = [screen(id: 1, x: 0, capturedAt: 100),
                       screen(id: 2, x: 1000, capturedAt: 100.9)]
        let quality = captureMomentQuality(rawSelection: CGRect(x: 40, y: 40, width: 200, height: 200),
                                           screens: screens,
                                           budget: budget)
        expect(!quality.crossedDisplays, "выделение внутри экрана сочтено межэкранным")
        expect(!quality.isDegraded,
               "разброс соседнего дисплея испортил оценку выделения внутри одного экрана")
    }

    /// Выделение через границу при разбросе выше бюджета — ухудшенное.
    private static func crossingDisplaysWithHighSkewIsDegraded() {
        let screens = [screen(id: 1, x: 0, capturedAt: 100),
                       screen(id: 2, x: 1000, capturedAt: 100.5)]
        let quality = captureMomentQuality(rawSelection: CGRect(x: 900, y: 40, width: 300, height: 200),
                                           screens: screens,
                                           budget: budget)
        expect(quality.crossedDisplays, "пересечение границы не распознано")
        expect(quality.isDegraded, "разброс 500 мс не помечен как ухудшение")
        expect(abs(quality.displaySkew - 0.5) < 0.001,
               "разброс посчитан неверно: \(quality.displaySkew)")
    }

    /// Пересечение границы само по себе ухудшением не является.
    private static func crossingDisplaysWithinBudgetIsIntact() {
        let screens = [screen(id: 1, x: 0, capturedAt: 100),
                       screen(id: 2, x: 1000, capturedAt: 100.03)]
        let quality = captureMomentQuality(rawSelection: CGRect(x: 900, y: 40, width: 300, height: 200),
                                           screens: screens,
                                           budget: budget)
        expect(quality.crossedDisplays, "пересечение границы не распознано")
        expect(!quality.isDegraded, "разброс 30 мс не должен считаться ухудшением")
    }

    /// Касание соседнего экрана в один пиксель — это промах курсора, а не
    /// межэкранное выделение.
    private static func touchingBySliverDoesNotCount() {
        let screens = [screen(id: 1, x: 0, capturedAt: 100),
                       screen(id: 2, x: 1000, capturedAt: 100.9)]
        let quality = captureMomentQuality(rawSelection: CGRect(x: 999.5, y: 40, width: 0.9, height: 200),
                                           screens: screens,
                                           budget: budget)
        expect(!quality.isDegraded, "касание в доли пикселя сочтено межэкранным выделением")
    }

    private static func screen(id: CGDirectDisplayID,
                               x: CGFloat,
                               capturedAt: CFAbsoluteTime) -> FrozenScreen {
        FrozenScreen(displayID: id,
                     frame: CGRect(x: x, y: 0, width: 1000, height: 800),
                     image: blankImage(),
                     capturedAt: capturedAt,
                     captureDuration: 0.01)
    }

    private static func blankImage() -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 4,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("CaptureMomentQualityTests failed: \(message)\n".utf8))
            exit(1)
        }
    }
}
