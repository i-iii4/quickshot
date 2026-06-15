import CoreGraphics

enum CropEdge { case none, bottom, right }

/// Результат расчёта геометрии карточки по варианту D.
struct CardLayout {
    let height: CGFloat        // итоговая высота карточки в точках
    let cropped: Bool          // показывается ли только часть кадра
    let cropEdge: CropEdge     // у какого края обрезано (для фейда)
    let cropRect: CGRect       // прямоугольник исходника (в пикселях, начало сверху-слева)
}

/// Вариант D: ширина — пользовательская (анкер), высота производная, но клампится
/// потолком по экрану и окном допустимых пропорций. В пределах окна — кадр целиком;
/// за окном — cover-crop с якорем сверху-слева (контент скриншота обычно начинается там).
enum CardSizing {
    static let minHeight: CGFloat = 96
    static let maxHeightFraction: CGFloat = 0.42   // потолок высоты = 42% высоты экрана
    static let tallAspect: CGFloat = 2.0           // максимум height/width (1:2)
    static let wideAspect: CGFloat = 0.42          // минимум height/width (≈2.4:1)

    static func layout(imageW: Int, imageH: Int, width W: CGFloat, screenHeight: CGFloat) -> CardLayout {
        let iw = CGFloat(max(1, imageW)), ih = CGFloat(max(1, imageH))
        let nativeAspect = ih / iw
        let targetAspect = min(tallAspect, max(wideAspect, nativeAspect))
        let maxH = maxHeightFraction * screenHeight
        let cardH = min(maxH, max(minHeight, W * targetAspect))
        let cardAspect = cardH / W

        var cropW = iw, cropH = ih
        var edge: CropEdge = .none
        if nativeAspect > cardAspect + 0.005 {            // кадр выше карточки — режем низ
            cropW = iw
            cropH = min(ih, (iw * cardAspect).rounded())  // clamp: cropping(to:) вернёт nil, если выйти за кадр
            edge = .bottom
        } else if nativeAspect < cardAspect - 0.005 {     // кадр шире карточки — режем правый край
            cropH = ih
            cropW = min(iw, (ih / cardAspect).rounded())
            edge = .right
        }
        return CardLayout(height: cardH,
                          cropped: edge != .none,
                          cropEdge: edge,
                          cropRect: CGRect(x: 0, y: 0, width: max(1, cropW), height: max(1, cropH)))
    }
}
