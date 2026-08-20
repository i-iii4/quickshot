import CoreGraphics
import Foundation

@main
struct CardSizingTests {
    static func main() {
        allCardsShareTheSameAspect()
        cropIsCentred()
        cropNeverLeavesTheFrame()
        widthIsCappedByScreenHeight()
        print("CardSizingTests: passed")
    }

    /// `TR-37`: соотношение 3:4 у ЛЮБОГО снимка — широкого, узкого,
    /// квадратного. Лента ровная, карточки взаимозаменяемы по месту.
    private static func allCardsShareTheSameAspect() {
        let sources = [(3840, 2160), (1920, 1080), (1024, 1024), (800, 2400), (300, 200)]
        for (w, h) in sources {
            let layout = CardSizing.layout(imageW: w, imageH: h, width: 240, screenHeight: 1200)
            let aspect = layout.height / 240
            expect(abs(aspect - CardSizing.fixedAspect) < 0.001,
                   "снимок \(w)x\(h) дал соотношение \(aspect) вместо \(CardSizing.fixedAspect)")
        }
    }

    /// Обрезка центрирована: отступы слева и справа (сверху и снизу) равны.
    private static func cropIsCentred() {
        let wide = CardSizing.layout(imageW: 3840, imageH: 2160, width: 240, screenHeight: 1200)
        let leftMargin = wide.cropRect.minX
        let rightMargin = 3840 - wide.cropRect.maxX
        expect(abs(leftMargin - rightMargin) <= 1,
               "широкий кадр обрезан несимметрично: \(leftMargin) против \(rightMargin)")
        expect(leftMargin > 0, "широкий кадр не обрезан вовсе")

        let tall = CardSizing.layout(imageW: 800, imageH: 2400, width: 240, screenHeight: 1200)
        let bottomMargin = tall.cropRect.minY
        let topMargin = 2400 - tall.cropRect.maxY
        expect(abs(bottomMargin - topMargin) <= 1,
               "высокий кадр обрезан несимметрично: \(bottomMargin) против \(topMargin)")
        expect(bottomMargin > 0, "высокий кадр не обрезан вовсе")
    }

    /// Прямоугольник обрезки обязан лежать внутри кадра: иначе системный
    /// вызов вернёт nil, и карточка останется без изображения.
    private static func cropNeverLeavesTheFrame() {
        let sources = [(3840, 2160), (1920, 1080), (1024, 1024), (800, 2400), (300, 200), (1, 1)]
        for (w, h) in sources {
            let rect = CardSizing.layout(imageW: w, imageH: h, width: 240, screenHeight: 1200).cropRect
            expect(rect.minX >= 0 && rect.minY >= 0,
                   "обрезка вышла за начало кадра \(w)x\(h): \(rect)")
            expect(rect.maxX <= CGFloat(w) + 0.001 && rect.maxY <= CGFloat(h) + 0.001,
                   "обрезка вышла за край кадра \(w)x\(h): \(rect)")
        }
    }

    /// Соотношение держится строго, поэтому потолок высоты ограничивает
    /// ширину — иначе карточка переросла бы экран.
    private static func widthIsCappedByScreenHeight() {
        let screen: CGFloat = 1200
        let maxWidth = CardSizing.maxWidth(screenHeight: screen)
        let height = CardSizing.layout(imageW: 1920, imageH: 1080,
                                       width: maxWidth, screenHeight: screen).height
        expect(abs(height - CardSizing.maxHeightFraction * screen) < 0.001,
               "предельная ширина не упирается в потолок высоты: \(height)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("CardSizingTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
