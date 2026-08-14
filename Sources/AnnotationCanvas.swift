import AppKit

/// Геометрия холста: перевод между координатами изображения и вью.
///
/// Модель документа живёт в координатах изображения — иначе зум ломал бы уже
/// созданные объекты. Всё, что зависит от масштаба, считается здесь.
struct AnnotationCanvasTransform: Equatable {
    var zoom: CGFloat
    var contentOffset: CGPoint
    var imageSize: CGSize
    var viewSize: CGSize

    static let minimumZoom: CGFloat = 0.1
    static let maximumZoom: CGFloat = 8

    init(imageSize: CGSize, viewSize: CGSize, zoom: CGFloat = 1, contentOffset: CGPoint = .zero) {
        self.imageSize = imageSize
        self.viewSize = viewSize
        self.zoom = zoom
        self.contentOffset = contentOffset
    }

    /// Масштаб «вписать в окно». Изображение мельче окна не увеличивается:
    /// растянутый на весь экран мелкий снимок выглядит как брак, а не как
    /// удобство.
    func fitZoom() -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return 1 }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        return min(1, max(Self.minimumZoom, scale))
    }

    var scaledImageSize: CGSize {
        CGSize(width: imageSize.width * zoom, height: imageSize.height * zoom)
    }

    /// Прямоугольник изображения во вью: пока изображение меньше вью, оно
    /// центрируется, дальше — сдвигается прокруткой.
    var imageFrame: CGRect {
        let size = scaledImageSize
        let x = size.width < viewSize.width
            ? (viewSize.width - size.width) / 2
            : -contentOffset.x
        let y = size.height < viewSize.height
            ? (viewSize.height - size.height) / 2
            : -contentOffset.y
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    func viewPoint(fromImage point: CGPoint) -> CGPoint {
        let frame = imageFrame
        return CGPoint(x: frame.minX + point.x * zoom, y: frame.minY + point.y * zoom)
    }

    func imagePoint(fromView point: CGPoint) -> CGPoint {
        let frame = imageFrame
        guard zoom > 0 else { return .zero }
        return CGPoint(x: (point.x - frame.minX) / zoom, y: (point.y - frame.minY) / zoom)
    }

    func viewRect(fromImage rect: CGRect) -> CGRect {
        let origin = viewPoint(fromImage: rect.origin)
        return CGRect(x: origin.x, y: origin.y, width: rect.width * zoom, height: rect.height * zoom)
    }

    /// Масштабирование с сохранением точки под курсором (`B-2`).
    func zoomed(to newZoom: CGFloat, around viewAnchor: CGPoint) -> AnnotationCanvasTransform {
        let clamped = min(Self.maximumZoom, max(Self.minimumZoom, newZoom))
        guard clamped != zoom else { return self }
        let anchorInImage = imagePoint(fromView: viewAnchor)
        var next = self
        next.zoom = clamped
        let anchorAfter = next.viewPoint(fromImage: anchorInImage)
        next.contentOffset = CGPoint(x: contentOffset.x + (anchorAfter.x - viewAnchor.x),
                                     y: contentOffset.y + (anchorAfter.y - viewAnchor.y))
        return next.clampedOffset()
    }

    func panned(by delta: CGVector) -> AnnotationCanvasTransform {
        var next = self
        next.contentOffset = CGPoint(x: contentOffset.x - delta.dx, y: contentOffset.y - delta.dy)
        return next.clampedOffset()
    }

    /// Прокрутка не уводит изображение за пределы окна: пустое поле вместо
    /// снимка — не состояние, в котором пользователь должен оказываться.
    func clampedOffset() -> AnnotationCanvasTransform {
        var next = self
        let size = scaledImageSize
        let maxX = max(0, size.width - viewSize.width)
        let maxY = max(0, size.height - viewSize.height)
        next.contentOffset = CGPoint(x: min(max(0, contentOffset.x), maxX),
                                     y: min(max(0, contentOffset.y), maxY))
        return next
    }

    /// Толщина линии в координатах вью. Штрих в 3pt остаётся визуально 3pt при
    /// любом зуме (`B-5`), поэтому в изображении он масштабируется обратно.
    func imageLineWidth(forScreenWidth width: CGFloat) -> CGFloat {
        guard zoom > 0 else { return width }
        return width / zoom
    }
}
