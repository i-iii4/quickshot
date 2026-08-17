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

    /// Наименьшее смещение, при котором новейшая карточка целиком видна в
    /// полезной зоне между резервами обеих стопок (`TR-5`: вставка в дальнюю
    /// стопку докручивает ленту ровно до этого положения).
    func revealNewestOffset() -> CGFloat {
        let usable = max(1, viewportLength - TrayStripLayout.nearReserve
                            - TrayStripLayout.farReserve)
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
    /// (ближняя стопка: карточки уходят к кнопке, виден их дальний край),
    /// false — с ближней (дальняя стопка).
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

/// Раскладка ленты со стопками-кромками (`TR-23`…`TR-26`, ревизия 17.08.2026).
///
/// Главные инварианты, добытые кровью первой ревизии:
///
/// 1. Карточка ВСЕГДА движется со скоростью ленты. У границы стопки она не
///    «прилипает» и не сплющивается — её просто срезает граница, а последние
///    7 pt конденсируются в кромку, продолжая ехать один к одному.
/// 2. Слоты кромок — константы у границы стопки и от высот карточек не
///    зависят. Первая ревизия привязывала слоты к дальнему краю входящей
///    карточки: при разной высоте снимков кромки ездили на десятки пунктов
///    за каждый слот прокрутки — «стопка болталась».
/// 3. Кромки лежат со стороны, КУДА уходят карточки: у кнопки — между
///    кнопкой и лентой, у дальнего края — в резерве за лентой. Только такая
///    сторона совместима с постоянными слотами.
/// 4. Между прибытиями карточек (пока никто не конденсируется) кромки
///    неподвижны.
///
/// Состояние — чистая функция смещения: без таймеров и отдельных анимаций,
/// обратная прокрутка проходит тот же путь задом наперёд.
enum TrayStripLayout {
    /// Высота кромки.
    static let edgeLength: CGFloat = 7
    /// Сужение на ступень глубины, в точках на каждую сторону.
    static let insetStep: CGFloat = 8
    /// Резерв ближней стопки: два постоянных слота кромок между кнопкой и
    /// лентой. Полные карточки живут выше этой границы.
    static var nearReserve: CGFloat { 2 * edgeLength }
    /// Резерв дальней стопки за верхней границей полезной зоны.
    static var farReserve: CGFloat { 2 * edgeLength }

    static func bands(cardLengths: [CGFloat],
                      gap: CGFloat,
                      offset: CGFloat,
                      viewportLength: CGFloat) -> [TrayCardBand] {
        guard !cardLengths.isEmpty else { return [] }
        let count = cardLengths.count
        let e = edgeLength
        let nearBase = nearReserve
        let farBase = max(nearBase + 1, viewportLength - farReserve)

        // Позиция карточки вдоль полосы: лента сдвинута на резерв ближней
        // стопки, чтобы слоты кромок жили между базой и карточками.
        var cursor: CGFloat = 0
        var positions: [CGFloat] = []
        for length in cardLengths {
            positions.append(cursor - offset + nearBase)
            cursor += length + gap
        }
        func top(_ index: Int) -> CGFloat { positions[index] + cardLengths[index] }

        var bands = [TrayCardBand](repeating: .hiddenBand, count: count)

        // Утонувшие у кнопки — префикс ленты, за дальней границей — суффикс.
        let nearSunkCount = (0..<count).lastIndex(where: { top($0) <= nearBase }).map { $0 + 1 } ?? 0
        let farStart = (0..<count).firstIndex(where: {
            positions[$0] >= farBase && $0 >= nearSunkCount
        }) ?? count

        // Фаза стопки — прогресс конденсации прибывающей карточки: последние
        // 7 pt её видимой части скользят в первый слот, продолжая движение
        // один к одному, и на те же 7 pt выталкивают прежние кромки глубже.
        // Прибывающей может не быть — тогда кромки стоят ровно в слотах.
        var nearPhase: CGFloat = 0
        if nearSunkCount < count {
            let entrantTop = top(nearSunkCount)
            if entrantTop <= nearBase + e {
                nearPhase = min(1, max(0, (nearBase + e - entrantTop) / e))
            }
        }
        var farPhase: CGFloat = 0
        if farStart > 0 {
            let entrantPosition = positions[farStart - 1]
            if entrantPosition >= farBase - e {
                farPhase = min(1, max(0, (entrantPosition - (farBase - e)) / e))
            }
        }

        // Поток: полные карточки и срезы у границ. Срез — естественный клип
        // движущейся карточки, скорость всегда один к одному с лентой.
        for index in nearSunkCount..<farStart {
            let length = cardLengths[index]
            let cardTop = top(index)
            let cardBottom = positions[index]
            if cardTop <= nearBase + e {
                // Конденсация у кнопки: полоса высотой 7 pt скользит за
                // границу в первый слот.
                let phase = min(1, max(0, (nearBase + e - cardTop) / e))
                bands[index] = TrayCardBand(position: cardTop - e,
                                            length: e,
                                            insetSteps: phase,
                                            contentFraction: e / max(1, length),
                                            sliceFromFarSide: true, opacity: 1,
                                            shadowFraction: 1,
                                            zOrder: -(1 + phase), hidden: false)
            } else if cardBottom >= farBase - e {
                // Конденсация у дальней границы.
                let phase = min(1, max(0, (cardBottom - (farBase - e)) / e))
                bands[index] = TrayCardBand(position: cardBottom,
                                            length: e,
                                            insetSteps: phase,
                                            contentFraction: e / max(1, length),
                                            sliceFromFarSide: false, opacity: 1,
                                            shadowFraction: 1,
                                            zOrder: -(1 + phase), hidden: false)
            } else {
                let visibleBottom = max(cardBottom, nearBase)
                let visibleTop = min(cardTop, farBase)
                let visibleLength = visibleTop - visibleBottom
                bands[index] = TrayCardBand(position: visibleBottom,
                                            length: visibleLength,
                                            insetSteps: 0,
                                            contentFraction: visibleLength / max(1, length),
                                            sliceFromFarSide: cardBottom < nearBase,
                                            opacity: 1, shadowFraction: 1,
                                            zOrder: 0, hidden: false)
            }
        }

        // Ближняя стопка: слоты [база+e, база+2e] и [база, база+e]; ранги от
        // мелкого к глубокому.
        for index in 0..<nearSunkCount {
            let rank = nearSunkCount - index
            bands[index] = sunkBand(rank: rank, phase: nearPhase,
                                    length: cardLengths[index],
                                    slotOneStart: nearBase - e,
                                    direction: -1,
                                    sliceFromFarSide: true)
        }

        // Дальняя стопка: зеркало со слотами [farBase, +e] и [farBase+e, +2e].
        for index in farStart..<count {
            let rank = index - farStart + 1
            bands[index] = sunkBand(rank: rank, phase: farPhase,
                                    length: cardLengths[index],
                                    slotOneStart: farBase,
                                    direction: 1,
                                    sliceFromFarSide: false)
        }

        return bands
    }

    /// Утонувший слой стопки: ранг 1 — первый слот, уходящий во второй с
    /// фазой конденсации прибывающей; ранг 2 — растворение из второго слота
    /// (`TR-26`): высота уходит один к одному с ходом, кромка задвигается под
    /// соседнюю, прозрачность гаснет в последней трети, тень равна доле
    /// оставшейся высоты. Глубже — скрыто. `direction` — куда стопка растёт
    /// от границы: -1 к кнопке, +1 в дальний резерв.
    private static func sunkBand(rank: Int,
                                 phase: CGFloat,
                                 length: CGFloat,
                                 slotOneStart: CGFloat,
                                 direction: CGFloat,
                                 sliceFromFarSide: Bool) -> TrayCardBand {
        let e = edgeLength
        switch rank {
        case 1:
            return TrayCardBand(position: slotOneStart + direction * e * phase,
                                length: e,
                                insetSteps: 1 + phase,
                                contentFraction: e / max(1, length),
                                sliceFromFarSide: sliceFromFarSide, opacity: 1,
                                shadowFraction: 1,
                                zOrder: -(2 + phase), hidden: false)
        case 2:
            let bandLength = e * (1 - phase)
            // Растворяющаяся полоса примыкает к соседней: её дальний от
            // границы край (начало второго слота) неподвижен, ближний уходит
            // вместе с соседкой. Для ближней стопки начало полосы — низ
            // второго слота, для дальней низ едет за соседкой вверх.
            let slotTwoStart = slotOneStart + direction * e
            let position = direction < 0 ? slotTwoStart : slotTwoStart + e * phase
            let opacity = phase < 0.7 ? 1 : max(0, 1 - (phase - 0.7) / 0.3)
            return TrayCardBand(position: position,
                                length: bandLength,
                                insetSteps: 2 + phase,
                                contentFraction: bandLength / max(1, length),
                                sliceFromFarSide: sliceFromFarSide,
                                opacity: opacity,
                                shadowFraction: bandLength / e,
                                zOrder: -(3 + phase),
                                hidden: bandLength < 0.05)
        default:
            return .hiddenBand
        }
    }
}
