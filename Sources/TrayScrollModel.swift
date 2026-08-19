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
    /// Видимое смещение ленты. Любое присваивание извне синхронизирует
    /// «сырое» смещение: жест начинается с того места, где лента стоит.
    var offset: CGFloat {
        didSet { rawOffset = offset }
    }
    /// Смещение без сопротивления — сумма пройденного пальцем. Резинка
    /// считается ОТ НЕГО, а не от уже сжатого значения: пересчёт сжатого
    /// делал позицию функцией скорости события, а не пройденного пути, из-за
    /// чего лента замирала при равномерном движении и ехала назад при
    /// замедлении (приёмка 19.08.2026 — «череда дёрганий»).
    private(set) var rawOffset: CGFloat = 0
    /// Длина новейшей карточки: полный сбор оставляет её целиком видимой,
    /// поэтому максимальный ход — до её парковки, а не до конца ленты.
    var lastCardLength: CGFloat = 0

    /// Наблюдатели свойств не срабатывают в конструкторе, поэтому сырое
    /// смещение синхронизируется здесь явно — иначе первый же жест считался
    /// бы от нуля вместо текущего положения ленты.
    init(contentLength: CGFloat,
         viewportLength: CGFloat,
         offset: CGFloat,
         lastCardLength: CGFloat = 0) {
        self.contentLength = contentLength
        self.viewportLength = viewportLength
        self.offset = offset
        self.lastCardLength = lastCardLength
        self.rawOffset = offset
    }

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
        let raw = rawOffset + delta
        let clamped = min(max(0, raw), maximumOffset)
        // Присваивание offset синхронизирует rawOffset через наблюдатель,
        // поэтому сырое значение выставляется ПОСЛЕ него.
        next.offset = rubberBand
            ? clamped + Self.resisted(raw - clamped, dimension: stretchDimension)
            : clamped
        next.rawOffset = rubberBand ? raw : clamped
        return next
    }

    /// Константа сопротивления Apple из доклада «Designing Fluid Interfaces»
    /// (WWDC 2018). Не подбирается.
    static let resistanceConstant: CGFloat = 0.55

    /// Характерный размер для формулы сопротивления. У Apple это размер
    /// прокручиваемой области; для ленты карточек взята длина карточки — за
    /// край уводится не больше одной карточки. Полное окно давало уход в
    /// сотни точек, и резинка переставала читаться (приёмка 19.08.2026).
    var stretchDimension: CGFloat { max(60, lastCardLength) }

    /// Сопротивление за краем по формуле Apple: `(x·d·c)/(d + c·x)`.
    /// Монотонно по ходу пальца, асимптотически ограничено размером `d`.
    static func resisted(_ overshoot: CGFloat, dimension: CGFloat) -> CGFloat {
        guard overshoot != 0, dimension > 0 else { return 0 }
        let magnitude = abs(overshoot)
        let value = (magnitude * dimension * resistanceConstant)
            / (dimension + resistanceConstant * magnitude)
        return overshoot < 0 ? -value : value
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
    /// Ближний к кнопке край полосы — настоящий край карточки (скруглён).
    /// false — край обрезан границей зоны, линия прямая.
    var roundsStart: Bool = true
    /// Дальний от кнопки край полосы — настоящий край карточки (скруглён).
    /// false — край срезан вышележащим слоем, линия прямая и спрятана за его
    /// прямым участком.
    var roundsEnd: Bool = true
    /// Начало карточки относительно начала полосы вдоль оси, ≤ 0: карточка
    /// может начинаться за краем полосы (уехала за базу) — клип режет её
    /// скруглённый край постепенно, а не выключает скругление скачком.
    var cardStartOffset: CGFloat = 0
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

        // Ближняя стопка: низы на ярусах 14/7/0 минус осадка. Карточка
        // рисуется ЦЕЛОЙ и уходит под вышележащий слой — перекрытие делает
        // видимой полоску-кромку само, включая скруглённые углы соседки.
        // Срез нужен только торчащему НАД верхом вышележащего слоя куску:
        // линия среза прячется за его прямым верхним краем, потому что
        // перспектива делает нижнюю карточку уже сильнее радиуса углов.
        var coverTop: CGFloat = .greatestFiniteMagnitude
        if nearCount < count {
            coverTop = top(nearCount)      // верх прибывающей: над ним не торчать
        }
        for index in stride(from: nearCount - 1, through: 0, by: -1) {
            let depth = nearCount - 1 - index
            let liveDepth = CGFloat(depth) + nearPhase
            let scale = depthScale(liveDepth)
            // Нижний ярус упирается в базу и НЕ уезжает за неё: карточка
            // растворяется на месте. Уход за виртуальную линию срезал её низ
            // прямой кромкой — та самая «квадратная обрезка нижней карточки».
            let bottom = max(0, parkLevel - e * CGFloat(depth) - e * nearPhase)
            let cardTop = bottom + cardLengths[index] * scale
            let visibleFrom = bottom
            let visibleTo = min(cardTop, coverTop)
            bands[index] = parkedBand(cardLength: cardLengths[index],
                                      scale: scale,
                                      visibleFrom: visibleFrom,
                                      visibleTo: visibleTo,
                                      cardStart: bottom,
                                      depth: depth,
                                      fade: depth == 2 ? nearPhase : 0,
                                      sliceFromFarSide: false,
                                      roundsStart: visibleFrom <= bottom + 0.001,
                                      roundsEnd: visibleTo >= cardTop - 0.001)
            coverTop = min(coverTop, visibleTo)
        }

        // Дальняя стопка — зеркало: верхи на ярусах, карточка целая, из-под
        // накрывшей её снизу соседки торчит верхняя кромка; срезается только
        // свисающий НИЖЕ низа соседки кусок, клип краем окна — сверху.
        var coverBottom: CGFloat = -.greatestFiniteMagnitude
        if farStart > 0 {
            coverBottom = raws[farStart - 1]   // низ прибывающей
        }
        for index in farStart..<count {
            let depth = index - farStart
            let liveDepth = CGFloat(depth) + farPhase
            let scale = depthScale(liveDepth)
            // Верхний ярус упирается в край окна и НЕ выезжает за него:
            // кромка тает на месте, её верх — всегда настоящий край.
            let topEdge = min(viewportLength, farPark + e * CGFloat(depth) + e * farPhase)
            let cardBottom = topEdge - cardLengths[index] * scale
            let visibleFrom = max(cardBottom, coverBottom)
            let visibleTo = topEdge
            bands[index] = parkedBand(cardLength: cardLengths[index],
                                      scale: scale,
                                      visibleFrom: visibleFrom,
                                      visibleTo: visibleTo,
                                      cardStart: cardBottom,
                                      depth: depth,
                                      fade: depth == 2 ? farPhase : 0,
                                      sliceFromFarSide: true,
                                      roundsStart: visibleFrom <= cardBottom + 0.001,
                                      roundsEnd: visibleTo >= topEdge - 0.001)
            coverBottom = max(coverBottom, visibleFrom)
        }

        return bands
    }

    /// Полоса запаркованной карточки: целая карточка в масштабе глубины минус
    /// срезы торчащих частей и краёв зоны. Глубже двух ярусов кромок — скрыто.
    private static func parkedBand(cardLength: CGFloat,
                                   scale: CGFloat,
                                   visibleFrom: CGFloat,
                                   visibleTo: CGFloat,
                                   cardStart: CGFloat,
                                   depth: Int,
                                   fade: CGFloat,
                                   sliceFromFarSide: Bool,
                                   roundsStart: Bool,
                                   roundsEnd: Bool) -> TrayCardBand {
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
                            roundsStart: roundsStart,
                            roundsEnd: roundsEnd,
                            cardStartOffset: min(0, cardStart - visibleFrom),
                            opacity: opacity,
                            shadowFraction: 1,
                            zOrder: -CGFloat(depth + 1),
                            hidden: false)
    }
}

/// Защёлка полного сбора (`TR-29`): вход и выход из собранной стопки проходят
/// точку напряжения — как ход клавиши или крышка шкатулки: сопротивление
/// растёт, проскок, щелчок, встала на место.
///
/// Вход: в последних `zone` pt хода лента идёт медленнее пальца в `tension`
/// раз, и когда до упора остаётся меньше `snapRemainder`, проскакивает домой
/// одним кадром. Выход: собранная лента сперва держится — страгивается лишь на
/// `strain / tension` — и, накопив `escape` сырого хода, вырывается прыжком к
/// началу зоны. Модель чистая: дельты жеста входят, наружу выходят новое
/// смещение и факт щелчка; тактильный и визуальный отклик — дело менеджера.
struct TrayDetentModel: Equatable {
    /// Зона напряжения перед упором, pt хода ленты. Значения крупные
    /// намеренно: трекпад отдаёт сотни точек в секунду, и мелкая зона
    /// проскакивается за одно событие — механика ниже порога восприятия
    /// неотличима от её отсутствия.
    static let zone: CGFloat = 56
    /// Порог проскока: осталось меньше — защёлкивает домой.
    static let snapRemainder: CGFloat = 14
    /// Насколько лента медленнее пальца в зоне напряжения.
    static let tension: CGFloat = 4
    /// Сырой ход пальца, вырывающий ленту из защёлки.
    static let escape: CGFloat = 120
    /// Знаменатель страгивания при удержании: собранная лента подаётся на
    /// strain/holdTension — непрерывно, без потолка: насыщение создавало
    /// мёртвую зону, где глаз не видел прогресса, и срыв читался взрывом
    /// (аудит анимации 19.08.2026).
    static let holdTension: CGFloat = 6

    enum Click: Equatable {
        case snapIn
        case release
    }

    /// Лента стоит в защёлке: собрана до упора.
    private(set) var engaged = false
    /// Накопленный сырой ход побега из защёлки.
    private(set) var strain: CGFloat = 0

    /// Совсем короткой ленте защёлка не положена; на просто короткой зона
    /// пропорционально уже (`effectiveZone`), чтобы не съедать весь ход.
    static func fits(_ model: TrayScrollModel) -> Bool {
        model.maximumOffset > 40
    }

    /// Эффективная зона напряжения: не шире 40% всего хода.
    static func effectiveZone(for model: TrayScrollModel) -> CGFloat {
        min(zone, model.maximumOffset * 0.4)
    }

    /// Лента подошла к защёлке: пора будить актуатор трекпада, его открытие
    /// стоит сотни миллисекунд (`TR-29`).
    static func isNearDetent(_ model: TrayScrollModel) -> Bool {
        guard fits(model) else { return false }
        return model.offset > model.maximumOffset - effectiveZone(for: model) * 2.5
    }

    static func effectiveSnapRemainder(for model: TrayScrollModel) -> CGFloat {
        min(snapRemainder, effectiveZone(for: model) * 0.25)
    }

    /// Синхронизация после программной установки смещения: защёлка следует за
    /// фактом, без щелчка.
    mutating func sync(with model: TrayScrollModel) {
        engaged = Self.fits(model) && model.offset >= model.maximumOffset - 0.5
        strain = 0
    }

    /// Прогон одной дельты жеста через защёлку. `stretch` — можно ли уводить
    /// ленту за край: тянет только палец, инерция упирается (приёмка
    /// 19.08.2026 — после отпускания лента продолжала уезжать).
    mutating func apply(delta: CGFloat,
                        to model: TrayScrollModel,
                        stretch: Bool = true) -> (model: TrayScrollModel, click: Click?) {
        guard Self.fits(model) else {
            let next = model.scrolled(by: delta, rubberBand: stretch)
            sync(with: next)
            return (next, nil)
        }
        return engaged ? applyEngaged(delta: delta, to: model, stretch: stretch)
                       : applyFree(delta: delta, to: model, stretch: stretch)
    }

    /// Куда осесть ленте, если жест замер в зоне напряжения: защёлка не
    /// оставляет ленту на скате — либо дожимает домой, либо выпускает к началу
    /// зоны. Вне зоны решает обычный `settled()`.
    func settleTarget(for model: TrayScrollModel) -> CGFloat? {
        guard Self.fits(model) else { return nil }
        if engaged {
            // Недожатый выход: порог не пройден — защёлка дотягивает ленту
            // обратно в посадочное место. Без этого страгивание оставалось
            // (карточка зависала в миллиметре от места), а `sync` по этой
            // позиции сбрасывал зацепление, и щелчок выхода пропадал совсем
            // (приёмка 19.08.2026).
            return model.offset < model.maximumOffset - 0.5 ? model.maximumOffset : nil
        }
        let zone = Self.effectiveZone(for: model)
        let zoneStart = model.maximumOffset - zone
        guard model.offset > zoneStart + 0.5, model.offset < model.maximumOffset else { return nil }
        return model.offset >= zoneStart + zone / 3 ? model.maximumOffset : zoneStart
    }

    private mutating func applyFree(delta: CGFloat,
                                    to model: TrayScrollModel,
                                    stretch: Bool) -> (model: TrayScrollModel, click: Click?) {
        var next = model
        let zoneStart = next.maximumOffset - Self.effectiveZone(for: next)
        guard delta > 0, next.offset + delta > zoneStart else {
            // Вне зоны или движение от упора: до щелчка выход свободен, жест
            // легко отменяется — сопротивление только в сторону сбора.
            next = next.scrolled(by: delta, rubberBand: stretch)
            return (next, nil)
        }
        // Часть дельты до зоны — один к одному, остаток — через натяжение.
        let before = max(0, zoneStart - next.offset)
        let tensioned = (delta - before) / Self.tension
        let candidate = max(next.offset, zoneStart) + tensioned
        if candidate >= next.maximumOffset - Self.effectiveSnapRemainder(for: next) {
            next.offset = next.maximumOffset
            engaged = true
            strain = 0
            return (next, .snapIn)
        }
        next.offset = candidate
        return (next, nil)
    }

    private mutating func applyEngaged(delta: CGFloat,
                                       to model: TrayScrollModel,
                                       stretch: Bool) -> (model: TrayScrollModel, click: Click?) {
        var next = model
        let maxOffset = next.maximumOffset
        if delta >= 0 {
            // Глубже в упор — обычная резинка за краем (`TR-13`).
            strain = 0
            next = next.scrolled(by: delta, rubberBand: stretch)
            return (next, nil)
        }
        if next.offset > maxOffset {
            // Сначала вернуться из перетяга; излишек дельты идёт в побег.
            let back = max(delta, maxOffset - next.offset)
            next.offset += back
            let rest = delta - back
            if rest < -0.001 { return applyEngaged(delta: rest, to: next, stretch: stretch) }
            return (next, nil)
        }
        strain += -delta
        if strain >= Self.escape {
            // Вырвалась: накопленное напряжение выпускается одним прыжком.
            engaged = false
            strain = 0
            next.offset = maxOffset - Self.effectiveZone(for: next)
            return (next, .release)
        }
        next.offset = maxOffset - strain / Self.holdTension
        return (next, nil)
    }
}

/// Решение о передаче инерции пружине границы (`TR-13`).
///
/// Отскок положен ТОЛЬКО на настоящем крае: свободный конец ленты (ноль
/// хода) при движении наружу, либо дальний конец у лент без защёлки. Там,
/// где работает защёлка, отскока нет — конец хода обслуживает она. Косвенный
/// признак «сдвиг меньше дельты» запрещён: так же ведёт себя зона натяжения
/// защёлки, и бросок к сбору глох на полпути (приёмка 19.08.2026).
enum TrayBoundaryHandoff {
    /// Передавать ли остаток инерции пружине отскока.
    static func shouldBounce(model: TrayScrollModel,
                             delta: CGFloat,
                             fingersDown: Bool,
                             isMomentum: Bool) -> Bool {
        guard !fingersDown, isMomentum else { return false }
        // Свободный край: лента у нуля, инерция толкает наружу.
        if model.offset <= 0.001, delta < 0 { return true }
        // Дальний край: только у лент без защёлки — иначе конец хода
        // принадлежит защёлке.
        if !TrayDetentModel.fits(model),
           model.offset >= model.maximumOffset - 0.001, delta > 0 { return true }
        return false
    }
}

/// Пружина границы ленты (`TR-13`).
///
/// Критически задемпфированная пружина с начальным смещением и НАЧАЛЬНОЙ
/// СКОРОСТЬЮ — один механизм на оба случая границы:
/// - возврат растянутой ленты после отпускания (`displacement` > 0);
/// - отскок от края, когда инерция довезла ленту до упора (`displacement` = 0,
///   скорость наружу).
///
/// Параметры не подбираются: демпфирование 1.0 и отклик 0.4 с — значения Apple
/// для перемещения объектов («Designing Fluid Interfaces», WWDC 2018).
/// Колебаний нет по построению, глубина отскока пропорциональна скорости.
enum TrayBoundarySpring {
    /// Отклик пружины, с.
    static let response: CGFloat = 0.4
    /// Сколько прогонять кадры: к этому времени хвост меньше половины
    /// процента пути.
    static let duration: CGFloat = 0.7
    static var omega: CGFloat { 2 * .pi / response }

    /// Уход за край в момент `time`: `(x0 + (v0 + ω·x0)·t)·e^(−ω·t)`.
    static func offset(displacement x0: CGFloat, velocity v0: CGFloat, time: CGFloat) -> CGFloat {
        (x0 + (v0 + omega * x0) * time) * exp(-omega * time)
    }

    /// Пик отскока при чистой передаче скорости: `v0/(ω·e)`.
    static func peak(velocity v0: CGFloat) -> CGFloat {
        v0 / (omega * CGFloat(M_E))
    }

    /// Скорость ленты в момент `time` — производная `offset`. Нужна для
    /// проверки непрерывности в точке передачи.
    static func velocity(displacement x0: CGFloat, velocity v0: CGFloat, time: CGFloat) -> CGFloat {
        let w = omega
        return (v0 - w * (v0 + w * x0) * time) * exp(-w * time)
    }
}
