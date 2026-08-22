import AppKit

/// Вход жеста: всё, что механика читает из системного события. Разбор
/// события происходит ОДИН раз, на границе с AppKit; дальше механика живёт
/// на этих величинах и об `NSEvent` не знает.
///
/// Отдельный тип нужен ради проверяемости: событие прокрутки с фазой создаётся
/// только через `CGEvent` и требует окон, а механику надо гонять тысячами
/// шагов без окон и сравнивать с эталоном.
struct TrayGestureInput {
    var deltaX: CGFloat
    var deltaY: CGFloat
    var hasPreciseDeltas: Bool
    var phase: NSEvent.Phase
    var momentumPhase: NSEvent.Phase
    var timestamp: TimeInterval
    /// Источник события для тактильного отклика (`TR-29`). Замыкание, а не
    /// значение: поиск устройства не должен выполняться на событиях, которые
    /// до тактильного отклика не доходят.
    var deviceLookup: () -> UInt64? = { nil }
}

/// Оценка скорости ленты по событиям, pt/с. Нужна пружине границы — без
/// передачи скорости движение рвётся в момент отпускания (`TR-13`).
struct TrayVelocityEstimator: Equatable {
    private(set) var value: CGFloat = 0
    private(set) var lastTimestamp: TimeInterval = 0

    /// История начинается заново. Обнулять её на каждом событии нельзя — так
    /// ломается оценка скорости, а с ней проекция броска.
    mutating func restart(at timestamp: TimeInterval) {
        value = 0
        lastTimestamp = timestamp
    }

    /// Сглаживание убирает выброс от одиночного рваного кадра, иначе он задал
    /// бы скорость передачи пружине.
    mutating func track(movement: CGFloat, at timestamp: TimeInterval) {
        defer { lastTimestamp = timestamp }
        let dt = timestamp - lastTimestamp
        guard dt > 0.0005, dt < 0.2 else { return }
        let instant = movement / CGFloat(dt)
        let alpha: CGFloat = 0.3
        value = value * (1 - alpha) + instant * alpha
    }

    /// Скорость текущего кадра: у отскока сглаженная оценка уже испорчена
    /// зажатыми кадрами (`TR-13`), поэтому там нужна именно эта.
    mutating func frameVelocity(delta: CGFloat, at timestamp: TimeInterval) -> CGFloat {
        let dt = max(0.001, timestamp - lastTimestamp)
        lastTimestamp = timestamp
        return delta / CGFloat(dt)
    }
}

/// Выбор оси раскрытия по ходу пальца (`TR-38`).
///
/// Ось меняется ТОЛЬКО из собранного состояния. Раскрытая лента продолжает
/// жить по своей оси до самого возврата — смена системы координат под
/// раскрытой лентой давала прыжки, случайные щелчки и переходы в чужие
/// состояния (приёмка 20.08.2026).
struct TrayAxisPicker: Equatable {
    enum Decision: Equatable {
        /// Ход по своей оси либо ось уже выбрана: лента работает.
        case proceed
        /// Направление ещё не явное: ход копится, лента стоит.
        case wait
        /// Заявка на смену распознана.
        case switchTo(ThumbnailLayoutEdge)
    }

    /// Порог выбора оси. Столько же, сколько система тратит на распознавание
    /// направления свайпа: меньше — ось скачет на дрожании руки.
    static let threshold: CGFloat = 10

    private(set) var accumulatedX: CGFloat = 0
    private(set) var accumulatedY: CGFloat = 0

    /// Счёт направления начинается с этой точки.
    mutating func restart() {
        accumulatedX = 0
        accumulatedY = 0
    }

    mutating func decide(deltaX: CGFloat,
                         deltaY: CGFloat,
                         began: Bool,
                         activeEdge: ThumbnailLayoutEdge,
                         base: ThumbnailLayoutEdge,
                         alternate: ThumbnailLayoutEdge?) -> Decision {
        if began { restart() }
        accumulatedX += deltaX
        accumulatedY += deltaY

        // Движение ВДОЛЬ текущей оси не ждёт порога: это не заявка на смену
        // направления, а обычная работа с лентой, и задерживать её нельзя —
        // иначе первые точки хода в упор съедались бы и резинка начиналась с
        // опозданием.
        let along = activeEdge.isVertical ? abs(accumulatedY) : abs(accumulatedX)
        let across = activeEdge.isVertical ? abs(accumulatedX) : abs(accumulatedY)
        guard across > along else { return .proceed }

        // Заявка на смену: ждём порога, пока направление не станет явным.
        guard let vertical = trayAxisPick(accumulatedX: accumulatedX,
                                          accumulatedY: accumulatedY,
                                          threshold: Self.threshold) else { return .wait }
        let chosen = vertical
            ? (base.isVertical ? base : (alternate ?? base))
            : (base.isVertical ? (alternate ?? base) : base)
        guard chosen != activeEdge else { return .proceed }
        return .switchTo(chosen)
    }
}

/// Кому принадлежит инерция у границы ленты.
struct TrayBoundaryGate: Equatable {
    /// Инерция отдана пружине границы: её события механика не читает вовсе
    /// (`TR-13`). Так же ведёт себя системный скролл.
    private(set) var handedToSpring = false

    mutating func handOff() { handedToSpring = true }
    mutating func reset() { handedToSpring = false }

    /// Съедает ли граница это событие. Событие догона после передачи пружине
    /// до ленты не доходит: иначе первое же его событие глушило саму пружину.
    mutating func swallows(momentumPhase: NSEvent.Phase) -> Bool {
        guard handedToSpring, momentumPhase != [] else { return false }
        if momentumPhase == .ended { handedToSpring = false }
        return true
    }
}

/// Получатели события жеста, в порядке прохождения. Первый взявший
/// останавливает цепочку — раньше это выражалось восемью ранними выходами, и
/// каждая новая ветка обязана была помнить все предыдущие.
enum TrayGestureRecipient: String, CaseIterable {
    /// Выбор оси раскрытия: пока направление не явное, лента стоит.
    case axis
    /// Граница ленты: отскок и инерция, отданная пружине.
    case boundary
    /// Сама лента: защёлка и прокрутка.
    case strip
}

/// Состояние, принадлежащее жесту. Раньше эти величины лежали отдельными
/// полями менеджера, и любая правка обработчика обязана была помнить их все.
struct TrayGestureState: Equatable {
    var axis = TrayAxisPicker()
    var velocity = TrayVelocityEstimator()
    var boundary = TrayBoundaryGate()
    var scrollGestureActive = false
    /// Была ли колода собрана на прошлом событии.
    var wasGathered = true
    /// Кто взял последнее событие. Ведётся ради проверяемости маршрута: без
    /// него «кто съел событие» видно только под отладчиком.
    var lastTaker: TrayGestureRecipient?
    /// Кому был разослан конец последнего жеста.
    var endedRecipients: [TrayGestureRecipient] = []
}

/// Мир, с которым работает механика жеста: позиция ленты, защёлка, анимации,
/// тактильный отклик. Всё, что требует окон и экрана, живёт за этим
/// интерфейсом, поэтому механику можно прогнать без них.
@MainActor
protocol TrayGestureOutput: AnyObject {
    var gestureCardsAreCollapsed: Bool { get }
    var gestureModel: TrayScrollModel { get }
    var gestureDetentEngaged: Bool { get }
    var gestureActiveEdge: ThumbnailLayoutEdge { get }
    var gestureAlternateEdge: ThumbnailLayoutEdge? { get }
    /// Ось, заданная положением трея; вторая ось — `gestureAlternateEdge`.
    var gestureBaseEdge: ThumbnailLayoutEdge { get }
    var gestureDipAnimating: Bool { get }

    func gestureSwitchAxis(to edge: ThumbnailLayoutEdge)
    func gestureRunDetentSpringUnderFinger()
    /// `bumpGeneration` — поднять поколение отложенного возврата, отменив
    /// запланированный. Колесо гасит только аниматор: отложенного возврата у
    /// него нет.
    func gestureCancelSettleAnimation(bumpGeneration: Bool)
    /// Взвод актуатора вместе с подпиской на журнал: делается один раз за
    /// событие жеста.
    func gesturePrepareHaptics()
    func gestureArmHaptics()
    func gestureAdoptDevice(_ device: UInt64?)
    func gestureLog(_ line: String)
    func gestureClearScrollIntent()
    func gestureWriteModel(_ model: TrayScrollModel, absorbJump: Bool)
    func gestureApplyDetent(delta: CGFloat, stretch: Bool) -> (model: TrayScrollModel, click: TrayDetentModel.Click?)
    func gestureSyncDetent()
    func gesturePerformDetentClick(_ click: TrayDetentModel.Click, underFinger: Bool)
    func gestureRunBoundarySpring(from boundary: CGFloat, velocity: CGFloat)
    func gestureApplyScrollOffset()
    func gestureSettleScrollAnimated()
    func gestureSnapByFlick()
    func gestureScheduleSettleAfterGesture()
}

/// Механика жеста прокрутки трея.
///
/// Класс, а не структура: владелец передаёт себя как `out`, и механика по ходу
/// работы дёргает владельца обратно. У структуры это был бы одновременный
/// доступ к одной переменной.
@MainActor
final class TrayGestureCore {
    /// Щелчок колеса приходит в строках, а не в точках.
    static let wheelLineHeight: CGFloat = 40

    private(set) var state = TrayGestureState()

    /// Колода собрана: лента доехала до упора и стоит там.
    private func deckIsGathered(_ model: TrayScrollModel) -> Bool {
        model.offset >= model.maximumOffset - 0.5
    }

    /// Прогоняет событие через выбор оси. `false` — лента стоит, ход копится.
    private func pickOpenAxis(_ input: TrayGestureInput, out: TrayGestureOutput) -> Bool {
        switch state.axis.decide(deltaX: input.deltaX,
                                 deltaY: input.deltaY,
                                 began: input.phase == .began,
                                 activeEdge: out.gestureActiveEdge,
                                 base: out.gestureBaseEdge,
                                 alternate: out.gestureAlternateEdge) {
        case .proceed:
            return true
        case .wait:
            return false
        case .switchTo(let edge):
            out.gestureSwitchAxis(to: edge)
            return true
        }
    }

    /// История скорости начинается заново: прежние отсчёты сняты с движения по
    /// другой оси. Обнулять её на каждом событии нельзя — так ломается оценка
    /// скорости, а с ней проекция броска.
    func resetVelocity(at timestamp: TimeInterval) {
        state.velocity.restart(at: timestamp)
    }

    /// Жест завершён извне (лента спрятана, карточки схлопнуты).
    func endGesture() {
        state.scrollGestureActive = false
    }

    func handOffMomentumToSpring() {
        state.boundary.handOff()
    }

    /// Непрерывная прокрутка ленты (`TR-1`, `TR-2`). Пошаговое переключение
    /// заменено на смещение, потому что ступенчатая лента не даёт понять, где
    /// ты находишься, и не позволяет остановиться между карточками.
    func handle(_ input: TrayGestureInput, out: TrayGestureOutput) {
        guard !out.gestureCardsAreCollapsed else { return }
        // `TR-38`: ось раскрытия выбирает ЖЕСТ. Пока колода собрана и ось не
        // выбрана, лента не двигается — копится ход пальца, и по нему
        // решается, вверх раскрывать или влево.
        // Ось выбирает ПАЛЕЦ. Инерция оси не выбирает: события догона летят
        // уже после отрыва, и хвост предыдущего жеста уводил ленту в
        // направление, которого пользователь не показывал (приёмка
        // 20.08.2026).
        let gathered = deckIsGathered(out.gestureModel)
        defer { state.wasGathered = gathered }
        if gathered, !state.wasGathered {
            // Колода только что собралась: направление считаем с этой точки,
            // иначе в счётчике остаётся ход, которым её и собирали, и он
            // перевешивает новое направление (приёмка 21.08.2026).
            state.axis.restart()
        }
        if out.gestureAlternateEdge != nil, gathered, input.momentumPhase == [],
           !pickOpenAxis(input, out: out) { return hand(to: .axis) }
        let vertical = out.gestureActiveEdge.isVertical
        // Ход, накопленный до выбора оси, лента НЕ наверстывает. Порог —
        // мёртвая зона распознавания направления, как у системных жестов:
        // после него движение идёт с текущей точки. Наверстывание давало
        // скачок на старте и завышало оценку скорости, отчего ломались
        // проекция броска и подача (приёмка 20.08.2026).
        let raw = vertical
            ? input.deltaY
            : (abs(input.deltaX) > 0.01 ? input.deltaX : input.deltaY)
        // Колесо мыши шлёт дельту в строках, а не в точках: один щелчок — это
        // единица, и лента ползла на пиксель за щелчок.
        let delta = input.hasPreciseDeltas ? raw : raw * Self.wheelLineHeight
        // Трекпад шлёт фазы жеста и инерции; классическое колесо — нет.
        let hasPhases = input.phase != [] || input.momentumPhase != []
        // Пальцы на трекпаде: фаза самого жеста. Инерция приходит уже без них
        // (`momentumPhase`) — и это разные режимы для анимации щелчка.
        let fingersDown = input.phase != []

        if input.phase == .began {
            // Новый жест — новая история скорости.
            state.velocity.restart(at: input.timestamp)
            state.boundary.reset()
            // Палец коснулся во время догона: длинная инерционная подача
            // пережимается в короткую от текущего значения — перенацеливание
            // вместо среза (скилл, прерываемость).
            if out.gestureDipAnimating { out.gestureRunDetentSpringUnderFinger() }
        }
        // Инерцию, уже переданную пружине границы, не читаем вовсе — и до
        // общего блока, где события отменяют аниматоры: иначе первое же её
        // событие глушило саму пружину (`TR-13`). Так же ведёт себя системный
        // скролл: после передачи границе затухание не применяется.
        if state.boundary.swallows(momentumPhase: input.momentumPhase) { return hand(to: .boundary) }
        if hasPhases {
            // Новое событие отменяет отложенный возврат: жест продолжается.
            out.gestureCancelSettleAnimation(bumpGeneration: true)
            // Открытие актуатора внешнего трекпада стоит сотни миллисекунд
            // (Bluetooth): готовим дескриптор в фоне заранее, чтобы сам
            // щелчок стоил доли миллисекунды.
            out.gesturePrepareHaptics()
            // Устройство берётся из самого события (`TR-29`). В инерции
            // HID-нагрузки может не быть, поэтому источник запоминается на
            // всё время жеста: защёлка часто срабатывает уже на инерции.
            out.gestureAdoptDevice(input.deviceLookup())
            if !state.scrollGestureActive {
                let model = out.gestureModel
                out.gestureLog("gesture offset=\(Int(model.offset)) max=\(Int(model.maximumOffset)) fits=\(TrayDetentModel.fits(model)) engaged=\(out.gestureDetentEngaged)")
            }
            state.scrollGestureActive = true
        }

        guard out.gestureModel.isScrollable || abs(delta) > 0.01 else { return }
        out.gestureClearScrollIntent()
        // Резинка только у жестов с фазами: колесо упирается в край жёстко.
        // Содержимое идёт за пальцами: положительная дельта двигает карточки к
        // хабу. Обратный знак разворачивал ленту против жеста. Жест никогда не
        // прячет и не показывает трей — это делает только клик по кнопке;
        // перетягивание за край лишь пружинит и возвращается.
        if hasPhases {
            // `TR-29`: дельты жеста идут через защёлку — у полного сбора лента
            // проходит точку напряжения и защёлкивается со щелчком.
            if TrayDetentModel.isNearDetent(out.gestureModel) { out.gestureArmHaptics() }
            // Растягивает резинку только палец: инерция упирается в край,
            // иначе после отпускания лента продолжает уезжать, а возврат
            // приходит с задержкой (приёмка 19.08.2026).
            // Отскок решается ДО применения дельты, прямой проверкой края:
            // лента на границе и инерция толкает наружу. Скорость — из
            // текущего кадра (дельта/время), сглаженная оценка к этому
            // моменту уже испорчена зажатыми кадрами (`TR-13`).
            if TrayBoundaryHandoff.shouldBounce(model: out.gestureModel, delta: delta,
                                                fingersDown: fingersDown,
                                                isMomentum: input.momentumPhase != []) {
                let outward = state.velocity.frameVelocity(delta: delta, at: input.timestamp)
                state.boundary.handOff()
                out.gestureRunBoundarySpring(from: out.gestureModel.offset, velocity: outward)
                return hand(to: .boundary)
            }
            let before = out.gestureModel.offset
            let result = out.gestureApplyDetent(delta: delta, stretch: fingersDown)
            // Щелчок ПЕРЕНАЦЕЛИВАЕТ движение: прыжок модели поглощается
            // подачей, видимая позиция остаётся непрерывной. Сдвиг больше
            // порога восприятия за один кадр запрещён (`TR-29`).
            out.gestureWriteModel(result.model, absorbJump: result.click != nil)
            state.velocity.track(movement: out.gestureModel.offset - before, at: input.timestamp)
            if let click = result.click {
                // Под пальцем догон короткий и без перелёта: палец сохраняет
                // контроль над моделью, затухает только разница. На инерции —
                // длиннее и с лёгкой осадкой.
                out.gesturePerformDetentClick(click, underFinger: fingersDown)
            }
        } else {
            // Колесо шагает дискретно: защёлка следует за фактом без щелчка.
            // Пружину границы колесо гасит — иначе позицию пишут двое сразу.
            out.gestureCancelSettleAnimation(bumpGeneration: false)
            out.gestureWriteModel(out.gestureModel.scrolled(by: delta, rubberBand: false),
                                  absorbJump: false)
            out.gestureSyncDetent()
        }

        hand(to: .strip)
        out.gestureApplyScrollOffset()

        if !hasPhases {
            out.gestureWriteModel(out.gestureModel.settled(), absorbJump: false)
            out.gestureApplyScrollOffset()
            return
        }
        if input.momentumPhase == .ended {
            // Инерция кончилась — жест завершён окончательно.
            state.scrollGestureActive = false
            out.gestureSettleScrollAnimated()
            finishGesture(out: out)
        } else if (input.phase == .ended || input.phase == .cancelled),
                  abs(out.gestureModel.overshoot) > 0.5 {
            // Отпустили за краем: пружина возврата стартует со скоростью
            // жеста, а вся последующая инерция игнорируется — иначе её
            // события отменяли пружину и схлопывали растяжение телепортом.
            // Системный скролл после отпускания за краем инерцию тоже не
            // читает (`TR-13`).
            state.scrollGestureActive = false
            state.boundary.handOff()
            out.gestureSettleScrollAnimated()
            finishGesture(out: out)
        } else if input.phase == .ended || input.phase == .cancelled {
            state.scrollGestureActive = false
            // `TR-36`: уверенный бросок к сбору защёлкивает ПО НАМЕРЕНИЮ —
            // по точке, где лента остановилась бы сама, а не по факту
            // доезда. Иначе бросок, не дотянувший чуть-чуть, читается как
            // «не сработало».
            if !out.gestureDetentEngaged,
               TrayFlickProjection.shouldSnap(model: out.gestureModel, velocity: state.velocity.value) {
                out.gestureSnapByFlick()
                finishGesture(out: out)
                return
            }
            // Пальцы сняты, но следом может пойти инерция. Возврат из-за края
            // откладывается: запущенный сразу, он тут же отменялся первым же
            // событием инерции, которое снова тянуло ленту наружу — старт,
            // отмена, старт, и это читалось как дёрганье (приёмка 19.08.2026).
            out.gestureScheduleSettleAfterGesture()
            finishGesture(out: out)
        }
    }

    /// Отмечает получателя, взявшего событие.
    private func hand(to recipient: TrayGestureRecipient) {
        state.lastTaker = recipient
    }

    /// Конец жеста проходит по ВСЕМ получателям, а не съедается первой веткой.
    ///
    /// Сегодня оси и границе на конце жеста делать нечего, и это записано
    /// здесь явно, а не подразумевается отсутствием кода. Любое изменение
    /// того, ЧТО они делают, — отдельная задача: этот перенос поведение не
    /// меняет.
    private func finishGesture(out: TrayGestureOutput) {
        state.endedRecipients = []
        for recipient in TrayGestureRecipient.allCases {
            switch recipient {
            case .axis:
                // Ход выбора оси обнуляется началом следующего жеста, а не
                // концом текущего: инерция после отрыва идёт по уже выбранной
                // оси.
                break
            case .boundary:
                // Признаком передачи инерции распоряжаются сами ветки конца:
                // отпускание за краем оставляет инерцию пружине.
                break
            case .strip:
                // Посадку ленты выполняет ветка, определившая вид завершения.
                break
            }
            state.endedRecipients.append(recipient)
        }
    }
}
