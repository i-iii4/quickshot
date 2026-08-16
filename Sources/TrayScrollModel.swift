import CoreGraphics
import Foundation

/// Модель прокрутки трея: непрерывное смещение, стопки на краях и порог
/// сворачивания жестом.
///
/// Модель намеренно не знает ни о вью, ни о таймерах: она отвечает на вопрос
/// «где сейчас лента и как выглядят карточки», а инерцию крутит аниматор.
struct TrayScrollModel: Equatable {
    /// Зазор между карточками равен `ThumbStyle.gap`; здесь он приходит
    /// параметром, чтобы модель проверялась без глобальных констант.
    var contentLength: CGFloat
    var viewportLength: CGFloat
    var offset: CGFloat

    /// Максимальный сдвиг: дальше лента упирается в конец.
    var maximumOffset: CGFloat { max(0, contentLength - viewportLength) }

    /// Прокрутка нужна только если содержимое не помещается (`TR-1`).
    var isScrollable: Bool { contentLength > viewportLength + 0.5 }

    /// Состояние по умолчанию: лента открыта на новых снимках, старые собраны
    /// в стопку у дальнего края (`TR-4`, `TR-5`).
    static func defaultOffset(contentLength: CGFloat, viewportLength: CGFloat) -> CGFloat {
        max(0, contentLength - viewportLength)
    }

    /// Смещение после жеста с резиновым сопротивлением за краями (`TR-13`).
    /// За границей движение идёт вчетверо медленнее — это не украшение, а
    /// сигнал: лента сообщает, что дальше ничего нет.
    func scrolled(by delta: CGFloat, rubberBand: Bool = true) -> TrayScrollModel {
        var next = self
        let raw = offset + delta
        if raw < 0 {
            next.offset = rubberBand ? raw / 4 : 0
        } else if raw > maximumOffset {
            let overshoot = raw - maximumOffset
            next.offset = rubberBand ? maximumOffset + overshoot / 4 : maximumOffset
        } else {
            next.offset = raw
        }
        return next
    }

    /// Возврат в границы после отпускания.
    func settled() -> TrayScrollModel {
        var next = self
        next.offset = min(max(0, offset), maximumOffset)
        return next
    }

    var overshoot: CGFloat {
        if offset < 0 { return offset }
        if offset > maximumOffset { return offset - maximumOffset }
        return 0
    }

    /// Продолженное движение за краем сворачивает трей (`TR-7`). Порог именно
    /// в перетянутом расстоянии, а не в самом факте касания края: иначе трей
    /// схлопывался бы при обычной прокрутке до конца (`TR-8` — порог не
    /// зависит от числа карточек).
    static let collapseThreshold: CGFloat = 48

    func shouldCollapse(afterOvershoot value: CGFloat) -> Bool {
        abs(value) >= Self.collapseThreshold
    }

    /// Направление сворачивания: к началу ленты или к её концу. Нужно, чтобы
    /// карточки уходили в ту сторону, куда их тянули.
    func collapseDirection(afterOvershoot value: CGFloat) -> TrayCollapseDirection? {
        guard shouldCollapse(afterOvershoot: value) else { return nil }
        return value < 0 ? .towardStart : .towardEnd
    }
}

enum TrayCollapseDirection: Equatable {
    case towardStart
    case towardEnd
}

/// Раскладка карточки в ленте с учётом стопок на краях.
struct TrayCardPlacement: Equatable {
    /// Смещение вдоль оси ленты.
    var position: CGFloat
    /// Прозрачность: карточки в глубине стопки тускнеют.
    var opacity: CGFloat
    /// Масштаб: та же глубина отражается размером.
    var scale: CGFloat
    /// Глубина в стопке: 0 — карточка в ленте, дальше — слои стопки. Задаёт и
    /// порядок наложения: чем глубже, тем дальше от зрителя.
    var depth: CGFloat = 0
}

/// Раскладка ленты: карточки за краем не исчезают, а собираются в стопку с
/// уменьшающимся шагом (`TR-3`).
///
/// Стопка нужна не для красоты: без неё лента обрывается, и по картинке нельзя
/// понять, есть ли что-то дальше.
enum TrayStackLayout {
    /// Шаг между карточками в стопке и предел глубины.
    static let stackStep: CGFloat = 6
    static let stackDepth = 3

    static func placements(cardLengths: [CGFloat],
                           gap: CGFloat,
                           offset: CGFloat,
                           viewportLength: CGFloat) -> [TrayCardPlacement] {
        var placements: [TrayCardPlacement] = []
        var cursor: CGFloat = 0
        for length in cardLengths {
            let rawPosition = cursor - offset
            placements.append(placement(rawPosition: rawPosition,
                                        length: length,
                                        viewportLength: viewportLength))
            cursor += length + gap
        }
        return placements
    }

    /// Полоса, зарезервированная под дальнюю стопку внутри окна просмотра.
    /// Ближняя стопка растёт наружу и прячется за хабом; у дальнего края
    /// прятаться не за что — там край экрана, и стопка, растущая наружу,
    /// срезалась им, оставляя обрубки полупрозрачных слоёв.
    static var trailingReserve: CGFloat { CGFloat(stackDepth) * stackStep }

    private static func placement(rawPosition: CGFloat,
                                  length: CGFloat,
                                  viewportLength: CGFloat) -> TrayCardPlacement {
        if rawPosition < 0 {
            // Карточка ушла за начало: собираем в стопку у края.
            let depth = min(CGFloat(stackDepth), -rawPosition / max(1, length))
            let position = -depth * stackStep
            return TrayCardPlacement(position: position,
                                     opacity: fadedOpacity(depth: depth),
                                     scale: fadedScale(depth: depth),
                                     depth: depth)
        }
        let usable = max(1, viewportLength - trailingReserve)
        let trailing = rawPosition + length - usable
        if trailing > 0 {
            let depth = min(CGFloat(stackDepth), trailing / max(1, length))
            // Шаг растёт наружу, но стартует внутри зарезервированной полосы:
            // самый глубокий слой ложится ровно на край окна просмотра.
            let position = usable - length + depth * stackStep
            return TrayCardPlacement(position: position,
                                     opacity: fadedOpacity(depth: depth),
                                     scale: fadedScale(depth: depth),
                                     depth: depth)
        }
        return TrayCardPlacement(position: rawPosition, opacity: 1, scale: 1, depth: 0)
    }

    /// Слои стопки обязаны различаться: три ступени прозрачности вместо
    /// плавного ухода в ноль, где несколько карточек выглядят одинаково.
    private static func fadedOpacity(depth: CGFloat) -> CGFloat {
        let fade = min(1, depth / CGFloat(stackDepth))
        return max(0.3, 1 - fade * 0.7)
    }

    private static func fadedScale(depth: CGFloat) -> CGFloat {
        let fade = min(1, depth / CGFloat(stackDepth))
        return max(0.88, 1 - fade * 0.12)
    }
}
