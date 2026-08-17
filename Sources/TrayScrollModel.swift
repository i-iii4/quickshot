import CoreGraphics
import Foundation

/// Модель прокрутки трея: асимметричная лента (`TR-4`), прижатая ближним
/// концом к кнопке хаба.
///
/// Одна степень свободы: насколько лента собрана в стопку у кнопки. Смещение 0
/// — лента полностью развёрнута от кнопки; максимум — все карточки собраны в
/// стопку, верхним элементом лежит новейшая, целиком видимая (`TR-4a`).
/// Дальний конец никогда не прилипает к краю экрана (`TR-4b`).
///
/// Модель намеренно не знает ни о вью, ни о таймерах: она отвечает на вопрос
/// «где сейчас лента», а раскладку кромок считает `TrayStripLayout`.
struct TrayScrollModel: Equatable {
    var contentLength: CGFloat
    var viewportLength: CGFloat
    var offset: CGFloat
    /// Длина новейшей карточки: полный сбор оставляет её целиком видимой,
    /// поэтому максимальный ход — до её начала, а не до конца ленты.
    var lastCardLength: CGFloat = 0

    /// Максимальный сдвиг: все карточки в стопке, новейшая — верхний элемент,
    /// целиком видимый.
    var maximumOffset: CGFloat { max(0, contentLength - lastCardLength) }

    /// Прокрутка осмысленна, как только есть хотя бы одна карточка: даже две
    /// карточки можно собрать в стопку у кнопки.
    var isScrollable: Bool { contentLength > 0.5 }

    /// Смещение после жеста с резиновым сопротивлением за краями (`TR-13`).
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

    /// Наименьшее смещение, при котором новейшая карточка целиком видна в окне
    /// просмотра с учётом полосы дальней стопки (`TR-5`: вставка в дальнюю
    /// стопку докручивает ленту ровно до этого положения).
    func revealNewestOffset() -> CGFloat {
        let usable = max(1, viewportLength - TrayStripLayout.farReserve)
        return min(maximumOffset, max(0, contentLength - usable))
    }
}

/// Кромка или карточка ленты: результат раскладки для одного снимка.
struct TrayCardBand: Equatable {
    /// Начало видимой полосы вдоль оси ленты, от основания у кнопки.
    var position: CGFloat
    /// Видимая длина вдоль оси. Для развёрнутой карточки — её полная длина.
    var length: CGFloat
    /// Сужение по глубине, в ступенях (непрерывно). 0 — полная ширина.
    var insetSteps: CGFloat
    /// Доля собственного изображения, видимая в полосе, со стороны
    /// выглядывающего края. 1 — карточка целиком.
    var contentFraction: CGFloat
    /// Откуда берётся срез: true — с дальней от кнопки стороны снимка
    /// (ближняя стопка), false — с ближней (дальняя стопка).
    var sliceFromFarSide: Bool
    /// Прозрачность: 1 всюду, кроме хвоста растворения последней кромки.
    var opacity: CGFloat
    /// Доля тени: привязана к оставшейся высоте кромки (`TR-26`).
    var shadowFraction: CGFloat
    /// Порядок наложения: больше — ближе к зрителю.
    var zOrder: CGFloat
    var hidden: Bool

    /// Полоса без сужения и среза — обычная развёрнутая карточка.
    var isFullCard: Bool { !hidden && insetSteps < 0.001 && contentFraction > 0.999 }

    static let hiddenBand = TrayCardBand(position: 0, length: 0, insetSteps: 0,
                                         contentFraction: 0, sliceFromFarSide: true,
                                         opacity: 0, shadowFraction: 0, zOrder: -100,
                                         hidden: true)
}

/// Раскладка ленты со стопками-кромками (`TR-23`…`TR-26`).
///
/// Состояние — чистая функция смещения: без таймеров и отдельных анимаций,
/// обратная прокрутка проходит тот же путь задом наперёд. Ранг слоя — его
/// порядковый номер в стопке от мелкого к глубокому; фаза перехода ОБЩАЯ для
/// всей стопки и равна глубине самого мелкого утонувшего слоя. Именно общая
/// фаза держит силуэт чистым при разной высоте карточек: собственные глубины
/// глубоких слоёв не кратны единице, и раздельные фазы оставляли кромки
/// вразнобой.
enum TrayStripLayout {
    /// Высота кромки.
    static let edgeLength: CGFloat = 7
    /// Сужение на ступень глубины, в точках на каждую сторону.
    static let insetStep: CGFloat = 8
    /// В покое видны верхняя карточка и две кромки; третья кромка живёт
    /// только в переходе (`TR-25`).
    static let restingEdges = 3
    /// Полоса под дальнюю стопку внутри окна просмотра.
    static var farReserve: CGFloat { CGFloat(restingEdges) * edgeLength }

    static func bands(cardLengths: [CGFloat],
                      gap: CGFloat,
                      offset: CGFloat,
                      viewportLength: CGFloat) -> [TrayCardBand] {
        guard !cardLengths.isEmpty else { return [] }
        let count = cardLengths.count
        let usable = max(1, viewportLength - farReserve)

        var cursor: CGFloat = 0
        var raws: [CGFloat] = []
        for length in cardLengths {
            raws.append(cursor - offset)
            cursor += length + gap
        }

        func nearDepth(_ index: Int) -> CGFloat {
            max(0, -raws[index] / (cardLengths[index] + gap))
        }
        func farDepth(_ index: Int) -> CGFloat {
            max(0, (raws[index] + cardLengths[index] - usable) / (cardLengths[index] + gap))
        }

        var bands = [TrayCardBand](repeating: .hiddenBand, count: count)

        // Утонувшие у кнопки — префикс ленты (порядок совпадает с порядком
        // добавления), утонувшие за дальней границей — суффикс.
        let nearSunkCount = (0..<count).lastIndex(where: { nearDepth($0) > 0 }).map { $0 + 1 } ?? 0
        let farStart = (0..<count).firstIndex(where: { farDepth($0) > 0 && $0 >= nearSunkCount }) ?? count

        // Развёрнутые карточки: полная геометрия, полное содержимое.
        for index in nearSunkCount..<farStart {
            bands[index] = TrayCardBand(position: raws[index],
                                        length: cardLengths[index],
                                        insetSteps: 0, contentFraction: 1,
                                        sliceFromFarSide: true, opacity: 1,
                                        shadowFraction: 1, zOrder: 0, hidden: false)
        }

        // Ближняя стопка. Фаза перехода общая: глубина самого мелкого
        // утонувшего — это же прогресс спуска следующей развёрнутой карточки.
        // Начала переходов привязаны к длине запаркованного слоя, концы — к
        // длине спускающейся карточки: при разной высоте снимков слоты кромок
        // переезжают плавно, а не прыгают при смене ранга.
        if nearSunkCount > 0 {
            let phase = smoothstep(min(1, nearDepth(nearSunkCount - 1)))
            let parked = cardLengths[nearSunkCount - 1]
            let frontLength = nearSunkCount < count
                ? cardLengths[nearSunkCount]
                : cardLengths[count - 1]
            for index in 0..<nearSunkCount {
                bands[index] = nearBand(rank: nearSunkCount - 1 - index,
                                        phase: phase,
                                        length: cardLengths[index],
                                        parked: parked,
                                        frontLength: frontLength)
            }
        }

        // Дальняя стопка — зеркало у границы окна просмотра; слоты кромок
        // привязаны к самой границе, поэтому от высот не зависят. Срез
        // содержимого — с ближней к кнопке стороны.
        if farStart < count {
            let phase = smoothstep(min(1, farDepth(farStart)))
            for index in farStart..<count {
                bands[index] = farBand(rank: index - farStart,
                                       phase: phase,
                                       length: cardLengths[index],
                                       base: usable)
            }
        }

        return bands
    }

    /// Слой ближней стопки по рангу и общей фазе перехода.
    private static func nearBand(rank: Int,
                                 phase: CGFloat,
                                 length: CGFloat,
                                 parked: CGFloat,
                                 frontLength: CGFloat) -> TrayCardBand {
        let e = edgeLength
        let z = -CGFloat(rank + 1) - phase
        switch rank {
        case 0:
            // Паркуется у кнопки и превращается в первую кромку, пока
            // следующая развёрнутая карточка спускается и накрывает его.
            let bandLength = length + (e - length) * phase
            return TrayCardBand(position: frontLength * phase,
                                length: bandLength,
                                insetSteps: phase,
                                contentFraction: bandLength / max(1, length),
                                sliceFromFarSide: true, opacity: 1,
                                shadowFraction: 1, zOrder: z, hidden: false)
        case 1:
            // Первая кромка уходит на вторую позицию: от слота за
            // запаркованным слоем к слоту за спускающейся карточкой.
            return TrayCardBand(position: parked + phase * (frontLength + e - parked),
                                length: e,
                                insetSteps: 1 + phase,
                                contentFraction: e / max(1, length),
                                sliceFromFarSide: true, opacity: 1,
                                shadowFraction: 1, zOrder: z, hidden: false)
        case 2:
            // Растворение (`TR-26`): геометрия ведёт — кромка задвигается под
            // соседнюю, прозрачность падает только в последней трети, тень
            // равна доле оставшейся высоты.
            let bandLength = e * (1 - phase)
            let opacity = phase < 0.7 ? 1 : max(0, 1 - (phase - 0.7) / 0.3)
            return TrayCardBand(position: parked + e + phase * (frontLength + e - parked),
                                length: bandLength,
                                insetSteps: 2 + phase,
                                contentFraction: bandLength / max(1, length),
                                sliceFromFarSide: true,
                                opacity: opacity,
                                shadowFraction: bandLength / e,
                                zOrder: z,
                                hidden: bandLength < 0.05)
        default:
            return .hiddenBand
        }
    }

    /// Слой дальней стопки: зеркало у границы `base`, кромки растут в резерв.
    private static func farBand(rank: Int,
                                phase: CGFloat,
                                length: CGFloat,
                                base: CGFloat) -> TrayCardBand {
        let e = edgeLength
        let z = -CGFloat(rank + 1) - phase
        switch rank {
        case 0:
            let bandLength = length + (e - length) * phase
            return TrayCardBand(position: (base - length) + length * phase,
                                length: bandLength,
                                insetSteps: phase,
                                contentFraction: bandLength / max(1, length),
                                sliceFromFarSide: false, opacity: 1,
                                shadowFraction: 1, zOrder: z, hidden: false)
        case 1:
            return TrayCardBand(position: base + phase * e,
                                length: e,
                                insetSteps: 1 + phase,
                                contentFraction: e / max(1, length),
                                sliceFromFarSide: false, opacity: 1,
                                shadowFraction: 1, zOrder: z, hidden: false)
        case 2:
            let bandLength = e * (1 - phase)
            let opacity = phase < 0.7 ? 1 : max(0, 1 - (phase - 0.7) / 0.3)
            return TrayCardBand(position: base + e + phase * e,
                                length: bandLength,
                                insetSteps: 2 + phase,
                                contentFraction: bandLength / max(1, length),
                                sliceFromFarSide: false,
                                opacity: opacity,
                                shadowFraction: bandLength / e,
                                zOrder: z,
                                hidden: bandLength < 0.05)
        default:
            return .hiddenBand
        }
    }

    private static func smoothstep(_ t: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, t))
        return clamped * clamped * (3 - 2 * clamped)
    }
}
