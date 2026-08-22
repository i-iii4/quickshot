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

    /// Длина СТУПЕНИ УБИРАНИЯ (`TR-41`) — участка хода ЗА упором, на котором
    /// колода уходит вглубь и гаснет.
    ///
    /// Жест ведёт ленту по этому участку НЕ напрямую: он копит напряжение, а
    /// координата отражает лишь его видимую часть — 8 pt из всей длины. Это
    /// и есть «колода чуть пружинит, почти незаметно». Прыжок к концу
    /// участка делает щелчок, после срабатывания.
    ///
    /// Убирание не отдельное состояние, а продолжение той же координаты. Две
    /// независимые величины — положение ленты и прогресс убирания — некому
    /// согласовывать: лента двигалась при ненулевом прогрессе, и геометрия
    /// рассыпалась, карточки уходили за экран (откат 21.08.2026, три
    /// попытки). Одна координата снимает вопрос: согласовывать нечего.
    static let stowSpan: CGFloat = 120

    /// Предел хода вместе со ступенью.
    var stowedMaximumOffset: CGFloat { maximumOffset + Self.stowSpan }

    /// ФАЗА ленты (`TR-41`) — дискретная величина: колода собрана или
    /// убрана. Промежуточного значения нет; то, что видно во время
    /// движения, — это положение ВНУТРИ фазы, а не третье состояние.
    ///
    /// Меняется ТОЛЬКО щелчком: ни движение пальца, ни отпускание, ни новый
    /// снимок, ни прокрутка её не трогают. Щелчок же двигает координату к
    /// новому пределу, поэтому фаза и координата меняются одним действием и
    /// разойтись не могут — инвариант, которого не хватало трём прежним
    /// реализациям.
    var stowed = false

    /// Докуда ленте позволено СТОЯТЬ в текущей фазе. Резинка работает за
    /// этим пределом, как и раньше.
    var phaseLimit: CGFloat { stowed ? stowedMaximumOffset : maximumOffset }

    /// Насколько убрана колода: 0 — на месте, 1 — убрана.
    ///
    /// Считается от координаты, ЗАЖАТОЙ пределом фазы: растяжение резинки в
    /// неё не попадает по построению. Иначе обычная подтяжка за собранную
    /// колоду читалась бы как частичное убирание — «состояние 2,5»
    /// (приёмка 21.08.2026).
    var stowProgress: CGFloat {
        let settled = min(max(0, offset), phaseLimit)
        return min(1, max(0, (settled - maximumOffset) / Self.stowSpan))
    }

    /// Колода полностью убрана.
    var isStowed: Bool { stowed }

    /// Прокрутка осмысленна, как только есть хотя бы одна карточка: даже две
    /// карточки можно собрать в стопку у кнопки.
    var isScrollable: Bool { contentLength > 0.5 }

    /// Смещение после жеста с резиновым сопротивлением за краями (`TR-13`).
    /// `limit` — докуда жесту позволено вести ленту. По умолчанию упор
    /// сбора; жест, которому открыта ступень (`TR-41`), ведёт до
    /// `stowedMaximumOffset`. Разделение фаз выражено ИМЕННО так: не вторым
    /// состоянием, а пределом хода для конкретного жеста.
    func scrolled(by delta: CGFloat, rubberBand: Bool = true, limit: CGFloat? = nil) -> TrayScrollModel {
        var next = self
        let ceiling = limit ?? maximumOffset
        let raw = rawOffset + delta
        let clamped = min(max(0, raw), ceiling)
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
    /// Характерный размер для формулы сопротивления. Треть карточки: полная
    /// длина давала уход за край на всю её высоту — для ленты чрезмерно
    /// (анализ 20.08.2026).
    var stretchDimension: CGFloat { max(48, lastCardLength / 3) }

    /// Сопротивление за краем по формуле Apple: `(x·d·c)/(d + c·x)`.
    /// Монотонно по ходу пальца, асимптотически ограничено размером `d`.
    static func resisted(_ overshoot: CGFloat, dimension: CGFloat) -> CGFloat {
        guard overshoot != 0, dimension > 0 else { return 0 }
        let magnitude = abs(overshoot)
        let value = (magnitude * dimension * resistanceConstant)
            / (dimension + resistanceConstant * magnitude)
        return overshoot < 0 ? -value : value
    }

    /// Возврат в границы после отпускания — к пределу ТЕКУЩЕЙ ФАЗЫ, а не к
    /// ближайшему из положений. Фазу уже решил щелчок; посадке остаётся
    /// исполнить её решение.
    ///
    /// Прежде посадка считала всё за упором растяжением и тянула обратно —
    /// поэтому убирание отменялось сразу после щелчка, и лента выпрыгивала
    /// во вторую фазу (приёмка 21.08.2026).
    func settled() -> TrayScrollModel {
        var next = self
        next.offset = min(max(0, offset), phaseLimit)
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
    /// Зазор под кнопку хаба. Хаб упразднён (`TR-30`), поэтому ноль: иначе
    /// он добавлялся к отступу карточки от края экрана.
    static let hubClearance: CGFloat = 0

    static func depthScale(_ depth: CGFloat) -> CGFloat {
        max(0.65, 1 - depthScaleStep * depth)
    }

    /// `deckProgress` — доля пройденного пути по зоне схлопывания (`TR-34`),
    /// СЫРАЯ: кривые применяются здесь, потому что их две. 0 — ярусы
    /// разложены как обычно, 1 — вся стопка сошлась к базе и видна одна
    /// верхняя карточка. Схлопывание живёт ЗДЕСЬ, в раскладке, поэтому
    /// работает во всех местах одинаково; отдельного сдвига крышки, который
    /// стирался при полной перекладке, больше нет.
    static func bands(cardLengths: [CGFloat],
                      gap: CGFloat,
                      offset: CGFloat,
                      viewportLength: CGFloat,
                      deckProgress: CGFloat = 0,
                      stow: CGFloat = 0) -> [TrayCardBand] {
        guard !cardLengths.isEmpty else { return [] }
        let count = cardLengths.count
        let e = edgeLength
        let farPark = max(parkLevel + 1, viewportLength - parkLevel)

        // Лента размечена от яруса парковки: при нулевом смещении первая
        // карточка стоит ровно на ярусе, зазоры не съедены упором.
        //
        // При схлопывании колоды (`TR-34`) поток едет ВМЕСТЕ со стопкой:
        // основание ленты опускается на ту же величину, на какую сходятся
        // ярусы. Без этого карточка в момент парковки прыгала с позиции
        // потока на схлопнутую — разрыв в 14 pt у каждой, и он читался как
        // грязь у щелчка (приёмка 20.08.2026).
        // Две кривые: поток гаснет к посадке гладко (иначе верхняя карточка
        // ускоряется и бьётся об упор), промежутки стопки сокращаются
        // пропорционально остатку пути (иначе слои пропадают по одному).
        let progress = min(1, max(0, deckProgress))
        let collapse = 1 - TrayDeckClosure.flowCurve(progress)
        let tierCollapse = 1 - TrayDeckClosure.tierCurve(progress)
        // Резерв под ярусы стопки БЕЗУСЛОВЕН и от числа карточек не зависит.
        // Ступенчатый резерв (ноль при одной карточке, `parkLevel` при
        // остальных) не убирал скачок, а переносил его из точки удаления в
        // точку добавления: второй снимок поднимал всю ленту на 14 pt
        // (приёмка 21.08.2026). Разницу между «одна карточка» и «стопка»
        // задаёт СХЛОПЫВАНИЕ, а не резерв.
        let park = parkLevel
        var cursor: CGFloat = park * collapse
        var raws: [CGFloat] = []
        for length in cardLengths {
            raws.append(cursor - offset)
            cursor += length + gap
        }
        func top(_ index: Int) -> CGFloat { raws[index] + cardLengths[index] }

        var bands = [TrayCardBand](repeating: .hiddenBand, count: count)

        // Запаркованные у кнопки — префикс (низ доехал до яруса), у дальнего
        // края — суффикс (верх доехал до дальнего яруса).
        // Порог парковки схлопывается ВМЕСТЕ с ярусами: иначе карточка
        // считалась запаркованной по старому порогу, а ставилась уже по
        // схлопнутому — прыжок ровно на высоту яруса в момент парковки
        // (приёмка 20.08.2026).
        let nearPark = park * collapse
        let nearCount = (0..<count).lastIndex(where: { raws[$0] <= nearPark }).map { $0 + 1 } ?? 0
        let farStart = (0..<count).firstIndex(where: {
            top($0) >= farPark && $0 >= nearCount
        }) ?? count

        // Фаза наезда: от касания запаркованной до собственной парковки
        // прибывающей. За эту фазу стопка оседает на один ярус.
        var nearPhase: CGFloat = 0
        if nearCount > 0, nearCount < count {
            let travel = max(1, cardLengths[nearCount - 1])
            nearPhase = min(1, max(0, (nearPark + travel - raws[nearCount]) / travel))
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
            // Схлопывание: расстояния между слоями сходятся к нулю, вся
            // стопка едет вниз вместе — на ту же величину, что и основание
            // ленты выше.
            let bottom = max(0, (park - e * CGFloat(depth) - e * nearPhase) * tierCollapse)
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

        return stowed(bands, progress: stow)
    }

    /// Убирание колоды (`TR-41`) как ЧАСТЬ РАСКЛАДКИ.
    ///
    /// Колода уходит вглубь целиком и стягивается к ОСНОВАНИЮ ленты — к тому
    /// краю, где стоит низ шкатулки. Основание в координатах ленты равно
    /// нулю, поэтому стягивание — простое умножение позиций: ошибиться
    /// системой координат негде.
    ///
    /// Якорь именно снизу. Стягивание к верхнему краю уводило колоду вверх и
    /// за экран, а шкатулку заставляло схлопываться не в ту сторону (откат
    /// 21.08.2026). Низ шкатулки обязан стоять неподвижно, а панель —
    /// опускаться вместе с верхней границей.
    ///
    /// Почему здесь, а не поверх раскладки: в трее один источник истины —
    /// постановка карточек, контур шкатулки, попадание мыши и анимации
    /// читают её результат. Наложение поверх невидимо всем троим.
    static func stowed(_ bands: [TrayCardBand], progress: CGFloat) -> [TrayCardBand] {
        let p = min(1, max(0, progress))
        guard p > 0.0001 else { return bands }
        let scale = 1 - (1 - TrayStow.stowedScale) * p
        let fade = 1 - p
        return bands.map { band in
            guard !band.hidden else { return band }
            var next = band
            next.position = band.position * scale
            next.length = band.length * scale
            next.scale = band.scale * scale
            next.opacity = band.opacity * fade
            next.shadowFraction = band.shadowFraction * fade
            next.hidden = next.opacity <= 0.004
            return next
        }
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
    /// Натяжение в зоне: ход пальца в зоне длиннее хода ленты во столько раз.
    /// Было 4 — вход стоил 224 pt хода пальца против 120 pt на выход, вдвое
    /// тяжелее. У механической защёлки закрыть не труднее, чем открыть
    /// (анализ 20.08.2026).
    static let tension: CGFloat = 2
    /// Сырой ход пальца, вырывающий ленту из защёлки. Сопоставим с ходом
    /// входа (зона 56 при натяжении 2 = 112 pt): вход и выход соразмерны.
    static let escape: CGFloat = 112
    /// Знаменатель страгивания при удержании: собранная лента подаётся на
    /// strain/holdTension — непрерывно, без потолка: насыщение создавало
    /// мёртвую зону, где глаз не видел прогресса, и срыв читался взрывом
    /// (аудит анимации 19.08.2026).
    ///
    /// Значение согласовано настройкой 19.08.2026: страгивание 8 pt, около
    /// одного яруса стопки. Прежние 6 давали 20 pt и читались упругой
    /// резиной, а не механическим зацепом.
    ///
    /// 20.08.2026 значение временно опускали до 3 (люфт 37 pt), чтобы
    /// подтягивание вообще что-то показывало: у посадки лежало ПЛАТО, где
    /// схлопывание уже завершено, и короткий люфт целиком тонул в нём.
    /// Плато убрано (`TrayDeckClosure.completionPoint`), кривая раскрывает
    /// колоду пропорционально остатку пути — на люфте в 8 pt колода
    /// приоткрыта на 27%, ярус выглядывает на 1.9 pt. Смягчать защёлку
    /// больше незачем.
    static let holdTension: CGFloat = 14

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
    /// `limit` — предел хода для этого жеста (`TR-41`): без разрешения лента
    /// упирается в сбор, с разрешением идёт дальше, на ступень убирания.
    mutating func apply(delta: CGFloat,
                        to model: TrayScrollModel,
                        stretch: Bool = true,
                        limit: CGFloat? = nil) -> (model: TrayScrollModel, click: Click?) {
        guard Self.fits(model) else {
            let next = model.scrolled(by: delta, rubberBand: stretch, limit: limit)
            sync(with: next)
            return (next, nil)
        }
        return engaged ? applyEngaged(delta: delta, to: model, stretch: stretch, limit: limit)
                       : applyFree(delta: delta, to: model, stretch: stretch, limit: limit)
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
                                    stretch: Bool,
                                    limit: CGFloat? = nil) -> (model: TrayScrollModel, click: Click?) {
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
                                       stretch: Bool,
                                       limit: CGFloat? = nil) -> (model: TrayScrollModel, click: Click?) {
        var next = model
        let maxOffset = next.maximumOffset
        if delta >= 0 {
            // Глубже в упор: без разрешения — обычная резинка за краем
            // (`TR-13`), с разрешением — ход по ступени убирания (`TR-41`).
            strain = 0
            next = next.scrolled(by: delta, rubberBand: stretch, limit: limit)
            return (next, nil)
        }
        if next.offset > maxOffset {
            // Сначала вернуться из перетяга; излишек дельты идёт в побег.
            let back = max(delta, maxOffset - next.offset)
            next.offset += back
            let rest = delta - back
            if rest < -0.001 { return applyEngaged(delta: rest, to: next, stretch: stretch, limit: limit) }
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

/// Проекция броска (`TR-36`).
///
/// Где лента остановилась бы сама, если её отпустить с заданной скоростью.
/// Формула Apple из доклада «Designing Fluid Interfaces» (WWDC 2018) — та же,
/// по которой система считает докрутку инерции. Не подбирается.
///
/// Нужна защёлке: уверенный бросок к сбору должен защёлкивать ПО НАМЕРЕНИЮ
/// жеста, а не по факту доезда до порога. Иначе бросок, не дотянувший
/// чуть-чуть, читается как «не сработало» и требует второго движения.
enum TrayFlickProjection {
    /// Коэффициент замедления системной прокрутки.
    static let decelerationRate: CGFloat = 0.998

    /// Насколько лента проедет по инерции при скорости `velocity` (pt/с).
    static func distance(velocity: CGFloat) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    /// Точка, где лента остановится сама.
    static func endpoint(from offset: CGFloat, velocity: CGFloat) -> CGFloat {
        offset + distance(velocity: velocity)
    }

    /// Защёлкивать ли по броску: спроецированная точка обязана лежать В зоне
    /// защёлки, а не за ней. Пролёт СКВОЗЬ зону на скорости защёлкивать
    /// нельзя — пользователь прокручивает ленту мимо, а не собирает стопку.
    /// Насколько близко к концу хода должен быть бросок, чтобы читаться как
    /// сбор стопки, а не как обычная прокрутка. В долях зоны защёлки.
    static let intentRange: CGFloat = 3

    static func shouldSnap(model: TrayScrollModel, velocity: CGFloat) -> Bool {
        guard TrayDetentModel.fits(model) else { return false }
        // Бросок к сбору — положительная скорость; в другую сторону защёлка
        // не срабатывает.
        guard velocity > 0 else { return false }
        let zone = TrayDetentModel.effectiveZone(for: model)
        let zoneStart = model.maximumOffset - zone
        // Намерение прочитано, если бросок ДОНОСИТ ленту до зоны. Требовать
        // попадания внутрь зоны нельзя: она достигается уже на 112 pt/с, а
        // настоящий бросок даёт полторы тысячи — условие не выполнялось
        // никогда, и функция работала только на вялых движениях (анализ
        // 20.08.2026).
        guard endpoint(from: model.offset, velocity: velocity) >= zoneStart else { return false }
        // Отсекаем не силу броска, а позицию: с дальнего конца ленты бросок
        // предназначен для прокрутки, а не для сбора.
        return model.maximumOffset - model.offset <= zone * intentRange
    }
}

/// Закрытие колоды наезжанием (`TR-34`).
///
/// Верхняя карточка съезжает к краю на высоту ярусов и накрывает их собой.
/// Ярусы не двигаются и не гаснут — они заслонены. Спецификация и
/// обоснование выбора против втягивания — `SPEC_DECK_CLOSURE.md`.
///
/// ЧИСТАЯ ФУНКЦИЯ видимой позиции ленты: своего состояния, аниматоров и
/// таймеров у закрытия нет. Отсюда по построению следуют непрерывность
/// движения, работа до щелчка, возврат при отмене и смена направления без
/// рестарта. Динамика наследуется от ленты, потому что видимая позиция уже
/// проходит через пружину подачи.
enum TrayDeckClosure {
    /// Доля зоны натяжения, на которой схлопывание уже завершено. Остаток
    /// принадлежит щелчку: сначала колода сошлась, потом щёлкнул замок.
    /// Совпадение финала с посадкой смазывает оба события.
    ///
    /// Схлопывание идёт до САМОЙ посадки: доля хода зоны, на которой оно
    /// завершено, — вся зона целиком.
    ///
    /// Разведение схлопывания с щелчком отменено 20.08.2026. Оно оставляло
    /// у посадки ПЛАТО, где промежутки стопки уже нулевые, а зазор между
    /// стопкой и доезжающей карточкой ещё нет: часть расстояний схлопнулась,
    /// часть нет, и число видимых слоёв падало с трёх до одного. Сжимаемый
    /// предмет так себя не ведёт — у него сокращаются ВСЕ расстояния разом,
    /// и ни один слой не пропадает раньше других.
    ///
    /// Довод в пользу разведения («иначе схлопывание смажет щелчок») был
    /// ошибочным: щелчок — событие СКОРОСТИ, а не геометрии. Он проходит
    /// тот же остаток пути, только быстро. Схлопывание, доведённое до
    /// посадки, попадает в этот рывок и делает щелчок заметнее.
    static let completionPoint: CGFloat = 1.0

    /// Кривая для ПРОМЕЖУТКОВ СТОПКИ: квадрат доли пройденного пути.
    ///
    /// Форма выведена из условия равномерности. Зазор между стопкой и
    /// доезжающей карточкой равен остатку пути `d` — это геометрия ленты,
    /// кривой он не подчиняется. Чтобы промежутки стопки сокращались в той
    /// же пропорции и ни один слой не пропадал раньше других, раскрытие
    /// обязано быть ЛИНЕЙНЫМ по `d`. У квадрата это так: раскрытие
    /// `1 - c²` при `c = 1 - d/zone` даёт `≈ 2d/zone`.
    static func tierCurve(_ c: CGFloat) -> CGFloat {
        let x = min(1, max(0, c))
        return x * x
    }

    /// Кривая для ПОТОКА карточек: сглаженный шаг `3c² - 2c³`.
    ///
    /// Поток обязан сжиматься иначе, чем промежутки стопки. Сжатие даёт
    /// верхней карточке ход СВЕРХ движения ленты, и с квадратом этот
    /// добавок максимален у самой посадки: карточка шла в полтора раза
    /// быстрее пальца и упиралась в упор с этой скоростью — рывок, который
    /// заказчик увидел 20.08.2026 («в определённый момент при закрытии
    /// резкий скачок»). У сглаженного шага скорость в конце нулевая:
    /// добавок гаснет к посадке, и карточка приходит к упору со скоростью
    /// ленты.
    ///
    /// Разные кривые для потока и стопки безопасны, потому что в момент
    /// ПАРКОВКИ карточка переходит из потока в стопку, а парковки
    /// приходятся на концы зоны, где обе кривые совпадают (0 и 1).
    /// Все миниатюры одной длины (`TR-37`), поэтому фаза парковки
    /// детерминирована и в середину зоны не попадает.
    static func flowCurve(_ c: CGFloat) -> CGFloat {
        let x = min(1, max(0, c))
        return x * x * (3 - 2 * x)
    }

    /// Степень закрытия по видимой позиции ленты: ноль на краю зоны
    /// натяжения, единица — за долю `completionPoint` до посадки.
    static func value(presented: CGFloat, model: TrayScrollModel) -> CGFloat {
        let maxOffset = model.maximumOffset
        // Лента, которой некуда двигаться, ВСЕГДА собрана. Один снимок — это
        // собранная колода из одного элемента, а не раскрытая: разложить её
        // нельзя. Прежде такая лента считалась раскрытой, ей отводился резерв
        // под ярусы, и она стояла на 14 pt выше собранной стопки — второй
        // снимок ронял всю ленту на эту величину (приёмка 21.08.2026).
        guard maxOffset > 0.5 else { return 1 }
        // Короткая лента: ход есть, а защёлки нет. Схлопывание идёт
        // пропорционально ходу — непрерывно и без порогов.
        guard TrayDetentModel.fits(model) else {
            return min(1, max(0, presented / maxOffset))
        }
        let zone = TrayDetentModel.effectiveZone(for: model)
        let span = max(1, zone * completionPoint)
        let travelled = presented - (model.maximumOffset - zone)
        return min(1, max(0, travelled / span))
    }


    /// Степень схлопывания для раскладки: та же величина, проведённая через
    /// кривую.
    /// Степень схождения ПРОМЕЖУТКОВ СТОПКИ.
    static func collapse(presented: CGFloat, model: TrayScrollModel) -> CGFloat {
        tierCurve(value(presented: presented, model: model))
    }

    /// Степень опускания ПОТОКА карточек.
    static func flow(presented: CGFloat, model: TrayScrollModel) -> CGFloat {
        flowCurve(value(presented: presented, model: model))
    }
}

/// Убирание КОЛОДЫ (`TR-41`): вторая ступень за собранным состоянием.
/// Гаснет вся видимая лента как единый предмет. Спецификация — `SPEC_CARD_STOW.md`.
///
/// Механика — НАПРЯЖЕНИЕ, а не прогресс. Карточка не уезжает за пальцем:
/// она чуть пружинит, почти незаметно, напряжение копится, и за порогом
/// срабатывает щелчок, после которого карточка схлопывается уже своей
/// анимацией.
enum TrayStow {
    /// Полный ход натяжения. Столько же, сколько побег из защёлки сбора:
    /// убирание последнего снимка — действие того же веса, что раскрытие
    /// колоды, и не должно случаться от короткого движения.
    static let threshold: CGFloat = TrayDetentModel.escape

    /// Видимый сдвиг карточки при полном натяжении — примерно один ярус
    /// стопки. Ровно столько же даёт страгивание в защёлке сбора: величина
    /// уже принята на ощупь и читается как «почти незаметно, но заметно».
    static let maxShift: CGFloat = 8

    /// Масштаб в конце натяжения. Предвестник отдаления, которое случится
    /// при срабатывании: интерфейс намекает на исход, а не только сообщает
    /// о нажиме.
    static let tensionScale: CGFloat = 0.98

    /// Масштаб убранной карточки: она удаляется от зрителя, а не улетает и
    /// не сжимается в полоску.
    static let stowedScale: CGFloat = 0.85

    /// Какую долю полного ухода занимает фаза НАТЯЖЕНИЯ. Натяжение обязано
    /// быть «почти незаметным»: колода чуть подаётся, а не наполовину
    /// исчезает. Полный ход натяжения даёт лишь эту долю прогресса.
    static let tensionShare: CGFloat = 0.13

    /// Сдвиг карточки по накопленному напряжению.
    ///
    /// Растёт с УБЫВАЮЩЕЙ скоростью: первые точки хода дают больше сдвига,
    /// последние — меньше, отчего связь читается упругой, а не свободной.
    /// Но убывание пологое: к концу хода прогресс обязан оставаться
    /// видимым.
    ///
    /// Формула сопротивления Apple здесь НЕ годится, хотя за краем ленты
    /// работает именно она. Та рассчитана на уход в десятки точек; здесь
    /// весь ход — 8 pt на 112 pt пальца, и она вырождается: первая четверть
    /// хода забирала 72% сдвига, последняя — 4%. Получалась мёртвая зона,
    /// где глаз не видит прогресса, а срыв читается взрывом — дефект,
    /// отвергнутый ещё в защёлке сбора (аудит 19.08.2026).
    ///
    /// Степень 0.7 даёт по четвертям хода примерно 38 / 24 / 20 / 18
    /// процентов: убывание есть, мёртвой зоны нет.
    static func shift(strain: CGFloat) -> CGFloat {
        maxShift * curve(tension(strain: strain))
    }

    /// Кривая натяжения. Производная в нуле велика — первое же движение
    /// пальца даёт видимый отклик, без этого прямое управление рушится.
    static func curve(_ t: CGFloat) -> CGFloat {
        pow(min(1, max(0, t)), 0.7)
    }

    /// Масштаб в фазе натяжения: от единицы к `tensionScale`, по той же
    /// насыщающейся кривой, что и сдвиг, — оба канала идут вместе.
    static func scale(strain: CGFloat) -> CGFloat {
        return 1 - (1 - tensionScale) * curve(tension(strain: strain))
    }

    /// Доля натяжения от порога: ноль — покой, единица — порог достигнут.
    static func tension(strain: CGFloat) -> CGFloat {
        min(1, max(0, strain / threshold))
    }

    /// Сработало ли убирание. Порог берётся ПО НАМЕРЕНИЮ: уверенный бросок
    /// засчитывается, если спроецированная точка остановки лежит за
    /// порогом. Иначе решительное движение, не дотянувшее десяток точек,
    /// читается как «не сработало» (`TR-36`, `SPEC_FLICK_PROJECTION.md`).
    static func fires(strain: CGFloat, velocity: CGFloat) -> Bool {
        if strain >= threshold { return true }
        let projected = strain + abs(TrayFlickProjection.distance(velocity: velocity))
        return projected >= threshold
    }

    /// Геометрия убранной карточки по прогрессу схлопывания: масштаб идёт
    /// от того, где натяжение его оставило, к `stowedScale`, прозрачность —
    /// в ноль синхронно.
    static func stowedScale(progress: CGFloat, fromScale: CGFloat) -> CGFloat {
        let p = min(1, max(0, progress))
        return fromScale + (stowedScale - fromScale) * p
    }

    static func stowedOpacity(progress: CGFloat) -> CGFloat {
        1 - min(1, max(0, progress))
    }
}

/// Темп второй ступени (`TR-41`).
enum TrayStowAnim {
    /// Отклик пружины схлопывания. Медленнее схлопывания колоды: убирание
    /// последнего снимка — отдельное событие, а не продолжение сбора.
    static let response: CFTimeInterval = 0.45
    /// Отклик возврата, когда порог не пройден. Короче: ничего не
    /// произошло, и задерживать на этом внимание незачем.
    static let releaseResponse: CFTimeInterval = 0.3

    /// Глубина отдачи щелчка, доля хода натяжения. Собственная подача
    /// ступени: подача ЛЕНТЫ здесь не работает — ступень ленту не двигает, и
    /// её пружина выходит по нулевой подаче, не показав ничего.
    static let clickOvershoot: CGFloat = 0.5
    /// Длительность отдачи: щелчок — мгновение, а не анимация.
    static let clickResponse: CFTimeInterval = 0.16

    /// Отдача щелчка: быстрый уход и мягкий возврат к нулю.
    static func clickCurve(_ t: CGFloat) -> CGFloat {
        let x = min(1, max(0, t))
        return sin(x * .pi) * (1 - x * 0.4)
    }

    /// Кривая пружины с наследованием скорости жеста.
    ///
    /// Критически задемпфированная пружина без перелёта: `1 - (1 + k·t)·e^-k·t`
    /// при нулевой начальной скорости. Ненулевая скорость добавляет разгон в
    /// начале — сорвал броском, схлопывание стартует быстрым и тормозит.
    static func curve(_ t: CGFloat, initialVelocity: CGFloat) -> CGFloat {
        let x = min(1, max(0, t))
        let k: CGFloat = 5
        // Нормировка обязательна: несглаженная пружина за отведённое время
        // доходит лишь до 0.96, и остаток отыгрывался бы скачком в последнем
        // кадре — прозрачность прыгала бы на 0.04 у самой границы.
        let tail = 1 - (1 + k) * exp(-k)
        let base = (1 - (1 + k * x) * exp(-k * x)) / tail
        guard initialVelocity > 0.0001 else { return min(1, base) }
        // Разгон гаснет к концу хода, поэтому финал остаётся мягким.
        let boost = initialVelocity * x * exp(-k * x)
        return min(1, base + boost)
    }
}
