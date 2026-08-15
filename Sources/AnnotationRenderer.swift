import AppKit

/// Палитра аннотаций. Цвета взяты из House Dark так, чтобы читаться и на
/// светлом, и на тёмном интерфейсе: белый и чёрный намеренно отсутствуют —
/// они пропадают на снимках соответствующей темы (`F-4`).
enum AnnotationPalette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.92, green: 0.24, blue: 0.28, alpha: 1),   // красный
        NSColor(srgbRed: 0.99, green: 0.72, blue: 0.16, alpha: 1),   // янтарный
        NSColor(srgbRed: 0.20, green: 0.72, blue: 0.42, alpha: 1),   // зелёный
        NSColor(srgbRed: 0.25, green: 0.55, blue: 0.96, alpha: 1),   // синий
        NSColor(srgbRed: 0.60, green: 0.36, blue: 0.92, alpha: 1),   // фиолетовый
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1),   // графитовый
    ]

    static func color(at index: Int) -> NSColor {
        colors[((index % colors.count) + colors.count) % colors.count]
    }

    /// Цвет скрывающей плашки: непрозрачный графит. Не настраивается по
    /// прозрачности — полупрозрачная «плашка» не скрывает ничего (`E-1`).
    static let redaction = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.10, alpha: 1)
}

/// Отрисовка объектов документа в контекст изображения.
///
/// Рендерер работает в координатах изображения и ничего не знает о зуме: вью
/// подставляет масштаб через `strokeScale`, чтобы штрих сохранял экранную
/// толщину (`B-5`), а экспорт рисует с масштабом 1 и получает те же объекты в
/// пикселях снимка.
enum AnnotationRenderer {
    static func draw(_ objects: [AnnotationObject],
                     in context: CGContext,
                     imageSize: CGSize,
                     strokeScale: CGFloat = 1) {
        for object in objects {
            context.saveGState()
            draw(object, in: context, imageSize: imageSize, strokeScale: strokeScale)
            context.restoreGState()
        }
    }

    private static func draw(_ object: AnnotationObject,
                             in context: CGContext,
                             imageSize: CGSize,
                             strokeScale: CGFloat) {
        let color = AnnotationPalette.color(at: object.style.paletteIndex)
        let lineWidth = max(0.5, object.style.lineWidth * strokeScale)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color.cgColor)

        switch object.kind {
        case .arrow:
            drawArrow(object, in: context, color: color, lineWidth: lineWidth)
        case .line:
            if case let .segment(from, to, curve) = object.geometry {
                context.addPath(curvedPath(from: from, to: to, curve: curve))
                context.strokePath()
            }
        case .rectangle:
            if case let .rect(rect, radius) = object.geometry {
                let path = CGPath(roundedRect: rect.standardized,
                                  cornerWidth: radius,
                                  cornerHeight: radius,
                                  transform: nil)
                fillAndStroke(path, object: object, color: color, in: context)
            }
        case .ellipse:
            if case let .rect(rect, _) = object.geometry {
                fillAndStroke(CGPath(ellipseIn: rect.standardized, transform: nil),
                              object: object, color: color, in: context)
            }
        case .pencil:
            if case let .path(points) = object.geometry, points.count > 1 {
                context.addPath(smoothedPath(points))
                context.strokePath()
            } else if case let .path(points) = object.geometry, let only = points.first {
                // Одиночный клик ставит точку (`D-20`).
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: CGRect(x: only.x - lineWidth / 2,
                                               y: only.y - lineWidth / 2,
                                               width: lineWidth,
                                               height: lineWidth))
            }
        case .highlighter:
            drawHighlighter(object, in: context, color: color, lineWidth: lineWidth)
        case .counter:
            drawCounter(object, in: context, color: color, strokeScale: strokeScale)
        case .text:
            drawText(object, in: context, color: color, strokeScale: strokeScale)
        case .redaction:
            // `E-1`: непрозрачная плашка, а не размытие.
            if case let .rect(rect, _) = object.geometry {
                context.setFillColor(AnnotationPalette.redaction.cgColor)
                context.fill(rect.standardized)
            }
        }
    }

    private static func fillAndStroke(_ path: CGPath,
                                      object: AnnotationObject,
                                      color: NSColor,
                                      in context: CGContext) {
        if object.style.filled {
            context.setFillColor(color.withAlphaComponent(object.style.fillOpacity).cgColor)
            context.addPath(path)
            context.fillPath()
        }
        context.addPath(path)
        context.strokePath()
    }

    // MARK: стрелка

    /// Наконечник пропорционален толщине и уменьшается вместе с короткой
    /// стрелкой: иначе на коротком отрезке он превращается в кляксу (`D-12`).
    static func arrowHeadLength(lineWidth: CGFloat, distance: CGFloat) -> CGFloat {
        let natural = lineWidth * 4
        return min(natural, max(lineWidth, distance / 3))
    }

    private static func drawArrow(_ object: AnnotationObject,
                                  in context: CGContext,
                                  color: NSColor,
                                  lineWidth: CGFloat) {
        guard case let .segment(from, to, curve) = object.geometry else { return }
        let dx = to.x - from.x
        let dy = to.y - from.y
        let distance = max(0.001, (dx * dx + dy * dy).squareRoot())
        let head = arrowHeadLength(lineWidth: lineWidth, distance: distance)
        let angle = atan2(dy, dx)
        let spread = CGFloat.pi / 7

        // Ствол не доводится до острия, иначе он выступает из-под заливки.
        let shaftEnd = CGPoint(x: to.x - cos(angle) * head * 0.6,
                               y: to.y - sin(angle) * head * 0.6)
        context.addPath(curvedPath(from: from, to: shaftEnd, curve: curve))
        context.strokePath()

        context.setFillColor(color.cgColor)
        context.move(to: to)
        context.addLine(to: CGPoint(x: to.x - cos(angle - spread) * head,
                                    y: to.y - sin(angle - spread) * head))
        context.addLine(to: CGPoint(x: to.x - cos(angle + spread) * head,
                                    y: to.y - sin(angle + spread) * head))
        context.closePath()
        context.fillPath()
    }

    /// Дуга задаётся смещением средней точки перпендикулярно отрезку (`D-8`).
    static func curvedPath(from: CGPoint, to: CGPoint, curve: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: from)
        guard abs(curve) > 0.5 else {
            path.addLine(to: to)
            return path
        }
        let midpoint = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = max(0.001, (dx * dx + dy * dy).squareRoot())
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let control = CGPoint(x: midpoint.x + normal.x * curve * 2,
                              y: midpoint.y + normal.y * curve * 2)
        path.addQuadCurve(to: to, control: control)
        return path
    }

    private static func smoothedPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        guard points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }
        // Сглаживание по средним точкам: траектория пера дрожит, а линия не
        // должна (`D-19`).
        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
            path.addQuadCurve(to: mid, control: current)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    private static func drawHighlighter(_ object: AnnotationObject,
                                        in context: CGContext,
                                        color: NSColor,
                                        lineWidth: CGFloat) {
        guard case let .segment(from, to, _) = object.geometry else { return }
        // Умножение сохраняет читаемость текста под заливкой (`D-31`).
        context.setBlendMode(.multiply)
        context.setStrokeColor(color.withAlphaComponent(0.35).cgColor)
        context.setLineWidth(max(lineWidth, object.style.fontSize))
        context.setLineCap(.butt)
        context.move(to: from)
        context.addLine(to: to)
        context.strokePath()
        context.setBlendMode(.normal)
    }

    private static func drawCounter(_ object: AnnotationObject,
                                    in context: CGContext,
                                    color: NSColor,
                                    strokeScale: CGFloat) {
        guard case let .point(centre) = object.geometry else { return }
        let radius = max(8, object.style.fontSize * strokeScale)
        let rect = CGRect(x: centre.x - radius, y: centre.y - radius,
                          width: radius * 2, height: radius * 2)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: rect)

        let number = object.number ?? 1
        let font = NSFont.systemFont(ofSize: radius * 1.1, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: "\(number)", attributes: attributes)
        drawCentred(text, in: rect, context: context)
    }

    private static func drawText(_ object: AnnotationObject,
                                 in context: CGContext,
                                 color: NSColor,
                                 strokeScale: CGFloat) {
        guard case let .rect(rect, _) = object.geometry,
              let string = object.text, !string.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: object.style.fontSize * strokeScale)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let text = NSAttributedString(string: string, attributes: attributes)
        if object.style.filled {
            context.setFillColor(NSColor.white.withAlphaComponent(object.style.fillOpacity).cgColor)
            context.fill(rect.standardized)
        }
        draw(text, at: rect.standardized.origin, context: context)
    }

    private static func drawCentred(_ text: NSAttributedString,
                                    in rect: CGRect,
                                    context: CGContext) {
        let size = text.size()
        draw(text,
             at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
             context: context)
    }

    private static func draw(_ text: NSAttributedString, at point: CGPoint, context: CGContext) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: point)
        NSGraphicsContext.current = previous
    }
}
