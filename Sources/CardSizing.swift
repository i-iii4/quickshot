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
    /// Все миниатюры одного соотношения 3:4 (ширина к высоте) — лента
    /// становится ровной, карточки взаимозаменяемы по месту (`TR-37`).
    /// Раньше карточка повторяла пропорции снимка, и лента выглядела рваной.
    static let fixedAspect: CGFloat = 4.0 / 3.0    // height / width

    /// Максимальная ширина, при которой высота ещё умещается в потолок:
    /// соотношение держится строго, поэтому ограничивать надо ширину.
    static func maxWidth(screenHeight: CGFloat) -> CGFloat {
        maxHeightFraction * screenHeight / fixedAspect
    }

    static func layout(imageW: Int, imageH: Int, width W: CGFloat, screenHeight: CGFloat) -> CardLayout {
        let iw = CGFloat(max(1, imageW)), ih = CGFloat(max(1, imageH))
        let cardH = max(minHeight, W * fixedAspect)
        let nativeAspect = ih / iw

        // Обрезка ЦЕНТРИРОВАННАЯ: лишнее снимается симметрично с обеих
        // сторон, в кадре остаётся середина. Прежний якорь сверху-слева
        // отбрасывал правый край и низ целиком.
        var cropW = iw, cropH = ih
        var edge: CropEdge = .none
        if nativeAspect > fixedAspect + 0.005 {           // кадр выше — режем верх и низ
            cropH = min(ih, (iw * fixedAspect).rounded())
            edge = .bottom
        } else if nativeAspect < fixedAspect - 0.005 {    // кадр шире — режем оба края
            cropW = min(iw, (ih / fixedAspect).rounded())
            edge = .right
        }
        return CardLayout(height: cardH,
                          cropped: edge != .none,
                          cropEdge: edge,
                          cropRect: CGRect(x: ((iw - cropW) / 2).rounded(),
                                           y: ((ih - cropH) / 2).rounded(),
                                           width: max(1, cropW), height: max(1, cropH)))
    }
}
