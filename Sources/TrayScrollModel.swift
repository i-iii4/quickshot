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
/// «где сейчас лента», а раскладку стопок считает `TrayStripLayout`.
struct TrayScrollModel: Equatable {
    var contentLength: CGFloat
    var viewportLength: CGFloat
    var offset: CGFloat
    /// Длина новейшей карточки: полный сбор оставляет её целиком видимой,
    /// поэтому максимальный ход — до её парковки, а не до конца ленты.
    var lastCardLength: CGFloat = 0

    /// Максимальный сдвиг: все карточки в стопке, новейшая запаркована низом
    /// на ярусе стопки, целиком видимая. Лента размечена от яруса парковки,
    /// поэтому ход — ровно до начала новейшей карточки.
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

    /// Наименьшее смещение, при котором новейшая карточка целиком видна ниже
    /// дальнего парковочного уровня (`TR-5`: вставка в дальнюю стопку
    /// докручивает ленту ровно до этого положения).
    func revealNewestOffset() -> CGFloat {
        let usable = max(1, viewportLength - 2 * TrayStripLayout.parkLevel)
        return min(maximumOffset, max(0, contentLength - usable))
    }
}

/// Видимая полоса одного снимка в ленте.
///
/// Карточка НИКОГДА не деформируется: полоса — это часть целой карточки,
/// оставшаяся видимой после перекрытия соседками и краями зоны. Содержимое в
/// полосе — настоящие пиксели карточки в её натуральном масштабе.
struct TrayCardBand: Equatable {
    /// Начало видимой полосы вдоль оси ленты, от основания у кнопки.
    var position: CGFloat
    /// Видимая длина вдоль оси. Для развёрнутой карточки — её полная длина.
    var length: CGFloat
    /// Историческое поле сужения. Карточки в стопке не сужаются: жёсткая
    /// карточка не меняет ширину. Всегда 0.
    var insetSteps: CGFloat
    /// Перспектива: карточка в глубине стопки уменьшается ЦЕЛИКОМ,
    /// пропорционально, вокруг своего яруса — как объект, удаляющийся от
    /// зрителя. 1 — передний план.
    var scale: CGFloat = 1
    /// Доля собственного изображения, видимая в полосе, со стороны
    /// выглядывающего края. 1 — карточка целиком.
    var contentFraction: CGFloat
    /// Откуда берётся срез: true — с дальней от кнопки стороны снимка
    /// (дальняя стопка: торчат верхи), false — с ближней (ближняя стопка:
    /// торчат низы).
    var sliceFromFarSide: Bool
    /// Прозрачность: 1 всюду, кроме растворения нижней кромки стопки.
    var opacity: CGFloat
    /// Доля тени: привязана к оставшейся видимой высоте кромки.
    var shadowFraction: CGFloat
    /// Порядок наложения: больше — ближе к зрителю. Прибывающая карточка
    /// накрывает запаркованных.
    var zOrder: CGFloat
    var hidden: Bool

    /// Полоса без среза и перспективы — обычная развёрнутая карточка.
    var isFullCard: Bool {
        !hidden && insetSteps < 0.001 && contentFraction > 0.999 && scale > 0.999
    }

    static let hiddenBand = TrayCardBand(position: 0, length: 0, insetSteps: 0,
                                         contentFraction: 0, sliceFromFarSide: true,
                                         opacity: 0, shadowFraction: 0, zOrder: -100,
                                         hidden: true)
}

/// Раскладка ленты с жёсткими карточками (`TR-23`…`TR-26`, ревизия 17.08.2026).
///
/// Суть стопки — наложение целых карточек, а не полосы-срезы:
///
/// 1. Карточка доезжает до парковочного яруса ЦЕЛИКОМ и останавливается.
///    Никогда не меняет ни высоту, ни ширину, ни масштаб.
/// 2. Следующая карточка наезжает на неё сверху (лежит выше по порядку
///    наложения) и срезает собой её верх: видимым остаётся низ запаркованной
///    от её низа до низа накрывающей. Снизу торчит — сверху не торчит.
/// 3. С момента касания запаркованные медленно уезжают в глубину: за время
///    наезда стопка оседает ровно на один ярус (7 pt), а нижняя видимая
///    кромка растворяется. Скорость осадки — малая доля скорости ленты:
///    глубина читается как параллакс.
/// 4. Ярусы стопки — константы (низы на 14/7/0 pt от базы), от высот карточек
///    не зависят. В покое видны верхняя карточка и две кромки.
///
/// Дальний край — зеркало: карточка паркуется верхом на ярусе, следующая
/// (более старая) наезжает снизу и накрывает её, торчат верхние 7 pt.
/// Состояние — чистая функция смещения: без таймеров и отдельных анимаций,
/// обратная прокрутка проходит тот же путь задом наперёд.
enum TrayStripLayout {
    /// Высота кромки и шаг ярусов стопки.
    static let edgeLength: CGFloat = 7
    /// Историческая константа сужения; карточки больше не сужаются.
    static let insetStep: CGFloat = 8
    /// Парковочный ярус верхней карточки стопки: под ним ровно два яруса
    /// кромок.
    static var parkLevel: CGFloat { 2 * edgeLength }
    /// Перспектива: доля уменьшения карточки за один ярус глубины. На ярус
    /// карточка сужается с каждой стороны сильнее радиуса своих углов, поэтому
    /// линия среза запаркованной прячется за прямым участком низа накрывающей
    /// и не выглядывает в её скруглённых углах.
    static let depthScaleStep: CGFloat = 0.1
    /// Зазор между кнопкой хаба и базой стопки. Ярусы кромок — и есть резерв
    /// между кнопкой и лентой, отдельный большой отступ поверх них не нужен.
    static let hubClearance: CGFloat = 4

    static func depthScale(_ depth: CGFloat) -> CGFloat {
        max(0.65, 1 - depthScaleStep * depth)
    }

    static func bands(cardLengths: [CGFloat],
                      gap: CGFloat,
                      offset: CGFloat,
                      viewportLength: CGFloat) -> [TrayCardBand] {
        guard !cardLengths.isEmpty else { return [] }
        let count = cardLengths.count
        let e = edgeLength
        let farPark = max(parkLevel + 1, viewportLength - parkLevel)

        // Лента размечена от яруса парковки: при нулевом смещении первая
        // карточка стоит ровно на ярусе, зазоры не съедены упором.
        var cursor: CGFloat = parkLevel
        var raws: [CGFloat] = []
        for length in cardLengths {
            raws.append(cursor - offset)
            cursor += length + gap
        }
        func top(_ index: Int) -> CGFloat { raws[index] + cardLengths[index] }

        var bands = [TrayCardBand](repeating: .hiddenBand, count: count)

        // Запаркованные у кнопки — префикс (низ доехал до яруса), у дальнего
        // края — суффикс (верх доехал до дальнего яруса).
        let nearCount = (0..<count).lastIndex(where: { raws[$0] <= parkLevel }).map { $0 + 1 } ?? 0
        let farStart = (0..<count).firstIndex(where: {
            top($0) >= farPark && $0 >= nearCount
        }) ?? count

        // Фаза наезда: от касания запаркованной до собственной парковки
        // прибывающей. За эту фазу стопка оседает на один ярус.
        var nearPhase: CGFloat = 0
        if nearCount > 0, nearCount < count {
            let travel = max(1, cardLengths[nearCount - 1])
            nearPhase = min(1, max(0, (parkLevel + travel - raws[nearCount]) / travel))
        }
        var farPhase: CGFloat = 0
        if farStart < count, farStart > 0 {
            let travel = max(1, cardLengths[farStart])
            farPhase = min(1, max(0, (top(farStart - 1) - (farPark - travel)) / travel))
        }

        // Поток: целые карточки, движутся один к одному со смещением.
        for index in nearCount..<farStart {
            bands[index] = TrayCardBand(position: raws[index],
                                        length: cardLengths[index],
                                        insetSteps: 0, contentFraction: 1,
                                        sliceFromFarSide: false, opacity: 1,
                                        shadowFraction: 1, zOrder: 0, hidden: false)
        }

        // Ближняя стопка: низы на ярусах 14/7/0 минус осадка; видимая полоса —
        // от собственного низа до низа соседки сверху (или прибывающей).
        // Глубина непрерывна (ярус + фаза осадки) и задаёт перспективу.
        for index in 0..<nearCount {
            let depth = nearCount - 1 - index
            let liveDepth = CGFloat(depth) + nearPhase
            let scale = depthScale(liveDepth)
            let bottom = parkLevel - e * CGFloat(depth) - e * nearPhase
            let cover: CGFloat
            if depth == 0 {
                cover = nearCount < count ? raws[nearCount] : .greatestFiniteMagnitude
            } else {
                cover = parkLevel - e * CGFloat(depth - 1) - e * nearPhase
            }
            bands[index] = parkedBand(cardLength: cardLengths[index],
                                      scale: scale,
                                      visibleFrom: max(bottom, 0),
                                      visibleTo: min(cover, bottom + cardLengths[index] * scale),
                                      depth: depth,
                                      fade: depth == 2 ? nearPhase : 0,
                                      sliceFromFarSide: false)
        }

        // Дальняя стопка — зеркало: верхи на ярусах от дальней границы,
        // прибывающая (более старая) накрывает снизу, торчат верхи.
        for index in farStart..<count {
            let depth = index - farStart
            let liveDepth = CGFloat(depth) + farPhase
            let scale = depthScale(liveDepth)
            let topEdge = farPark + e * CGFloat(depth) + e * farPhase
            let cover: CGFloat
            if depth == 0 {
                cover = farStart > 0 ? top(farStart - 1) : -.greatestFiniteMagnitude
            } else {
                cover = farPark + e * CGFloat(depth - 1) + e * farPhase
            }
            bands[index] = parkedBand(cardLength: cardLengths[index],
                                      scale: scale,
                                      visibleFrom: max(topEdge - cardLengths[index] * scale, cover),
                                      visibleTo: min(topEdge, viewportLength),
                                      depth: depth,
                                      fade: depth == 2 ? farPhase : 0,
                                      sliceFromFarSide: true)
        }

        return bands
    }

    /// Видимая полоса запаркованной карточки. Карточка цела (в масштабе своей
    /// глубины); полосу задаёт перекрытие соседками и краями зоны. Глубже
    /// двух ярусов кромок — скрыто.
    private static func parkedBand(cardLength: CGFloat,
                                   scale: CGFloat,
                                   visibleFrom: CGFloat,
                                   visibleTo: CGFloat,
                                   depth: Int,
                                   fade: CGFloat,
                                   sliceFromFarSide: Bool) -> TrayCardBand {
        guard depth <= 2 else { return .hiddenBand }
        let length = visibleTo - visibleFrom
        guard length > 0.05 else { return .hiddenBand }
        let opacity = max(0, 1 - fade)
        guard opacity > 0.01 else { return .hiddenBand }
        return TrayCardBand(position: visibleFrom,
                            length: length,
                            insetSteps: 0,
                            scale: scale,
                            contentFraction: length / max(1, cardLength * scale),
                            sliceFromFarSide: sliceFromFarSide,
                            opacity: opacity,
                            shadowFraction: min(1, length / edgeLength),
                            zOrder: -CGFloat(depth + 1),
                            hidden: false)
    }
}
