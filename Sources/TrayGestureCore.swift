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
        let chosen = Self.edge(vertical: vertical, base: base, alternate: alternate)
        guard chosen != activeEdge else { return .proceed }
        return .switchTo(chosen)
    }

    /// Край для выбранного направления: пара берётся из одного угла, поэтому
    /// вторая ось — всегда `alternate`.
    static func edge(vertical: Bool,
                     base: ThumbnailLayoutEdge,
                     alternate: ThumbnailLayoutEdge?) -> ThumbnailLayoutEdge {
        vertical
            ? (base.isVertical ? base : (alternate ?? base))
            : (base.isVertical ? (alternate ?? base) : base)
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

/// Мир механики жеста, разделённый по получателям. Всё, что требует окон и
/// экрана, живёт за этими интерфейсами, поэтому механику можно прогнать без
/// них.
///
/// Разделение не косметика: раньше единый протокол на 25 членов видели все,
/// включая ось и границу, которым нужно по четыре. Теперь каждый получатель
/// сужает мир до своего в первой же строке, и компилятор не даст залезть в
/// чужое.

/// Предусловие входа: механика молчит, пока карточки схлопнуты.
@MainActor
protocol TrayGestureIntake: AnyObject {
    var gestureCardsAreCollapsed: Bool { get }
    var gestureModel: TrayScrollModel { get }
}

/// Активная ось: ход берётся вдоль неё, поэтому её читают все, кто считает
/// дельту.
@MainActor
protocol TrayAxisReader: AnyObject {
    var gestureActiveEdge: ThumbnailLayoutEdge { get }
}

/// Что нужно выбору оси (`TR-38`).
@MainActor
protocol TrayAxisOutput: TrayAxisReader {
    var gestureAlternateEdge: ThumbnailLayoutEdge? { get }
    /// Ось, заданная положением трея; вторая ось — `gestureAlternateEdge`.
    var gestureBaseEdge: ThumbnailLayoutEdge { get }
    func gestureSwitchAxis(to edge: ThumbnailLayoutEdge)
}

/// Что нужно границе ленты.
@MainActor
protocol TrayBoundaryOutput: TrayAxisReader {
    var gestureModel: TrayScrollModel { get }
    var gestureDipAnimating: Bool { get }
    func gestureRunDetentSpringUnderFinger()
    func gestureRunBoundarySpring(from boundary: CGFloat, velocity: CGFloat)
}

/// Что нужно самой ленте: защёлка, прокрутка, посадка, отклик. Плюс активная
/// ось — ход берётся вдоль неё.
@MainActor
protocol TrayStripOutput: TrayAxisReader {
    var gestureModel: TrayScrollModel { get }
    var gestureDetentEngaged: Bool { get }
    func gestureCancelSettleAnimation(bumpGeneration: Bool)
    func gesturePrepareHaptics()
    func gestureArmHaptics()
    func gestureAdoptDevice(_ device: UInt64?)
    func gestureLog(_ line: String)
    func gestureClearScrollIntent()
    func gestureWriteModel(_ model: TrayScrollModel, absorbJump: Bool)
    func gestureApplyDetent(delta: CGFloat, stretch: Bool) -> (model: TrayScrollModel, click: TrayDetentModel.Click?)
    func gestureSyncDetent()
    func gesturePerformDetentClick(_ click: TrayDetentModel.Click, underFinger: Bool)
    func gestureApplyScrollOffset()
    func gestureSettleScrollAnimated()
    func gestureSnapByFlick()
    func gestureScheduleSettleAfterGesture()
}

/// Полный мир — объединение. Его реализует менеджер; получатели видят только
/// свою часть.
typealias TrayGestureOutput = TrayGestureIntake & TrayAxisOutput & TrayBoundaryOutput & TrayStripOutput

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

/// Разобранное событие. Величины, зависящие от оси, считаются по запросу:
/// выбор оси стоит первым в цепочке и может сменить ось под теми, кто идёт
/// следом.
@MainActor
struct TrayGestureEvent {
    let input: TrayGestureInput
    /// Колода собрана: лента доехала до упора и стоит там.
    let gathered: Bool
    /// Трекпад шлёт фазы жеста и инерции; классическое колесо — нет.
    let hasPhases: Bool
    /// Пальцы на трекпаде: фаза самого жеста. Инерция приходит уже без них.
    let fingersDown: Bool

    var phase: NSEvent.Phase { input.phase }
    var momentumPhase: NSEvent.Phase { input.momentumPhase }
    var timestamp: TimeInterval { input.timestamp }

    /// Ход вдоль текущей оси, в точках. Колесо мыши шлёт дельту в строках, а
    /// не в точках: один щелчок — это единица, и лента ползла на пиксель за
    /// щелчок.
    func delta(_ out: TrayAxisReader) -> CGFloat {
        let raw = out.gestureActiveEdge.isVertical
            ? input.deltaY
            : (abs(input.deltaX) > 0.01 ? input.deltaX : input.deltaY)
        return input.hasPreciseDeltas ? raw : raw * TrayGestureCore.wheelLineHeight
    }
}

/// Стадия прохода цепочки.
///
/// Две стадии, а не одна, потому что между ними лежит общий кадр жеста:
/// отмена отложенного возврата, взвод отклика, фильтр движения. Граница
/// участвует в обеих — сперва съедает инерцию, отданную пружине, потом ловит
/// отскок. Раньше второе участие выражалось прямым вызовом из ленты, и
/// цепочка в этом месте была фиктивной.
enum TrayGestureStage: String, CaseIterable {
    /// До общего кадра: кому событие вообще не принадлежит.
    case intercept
    /// После общего кадра: кто применяет ход.
    case apply
}

/// Участник цепочки. Событие идёт по участникам по порядку; вернувший
/// получателя забирает событие себе и останавливает цепочку.
@MainActor
protocol TrayGestureParty: AnyObject {
    var kind: TrayGestureRecipient { get }
    func receive(_ event: TrayGestureEvent,
                 stage: TrayGestureStage,
                 out: TrayGestureOutput) -> TrayGestureRecipient?
    /// Конец жеста доходит до КАЖДОГО участника, независимо от того, кто взял
    /// событие.
    func gestureEnded(_ event: TrayGestureEvent, out: TrayGestureOutput)
}

// MARK: - Ось

/// Выбор оси раскрытия (`TR-38`): первым в цепочке, потому что от него
/// зависит, вдоль чего вообще считать ход.
@MainActor
final class TrayAxisParty: TrayGestureParty {
    let kind = TrayGestureRecipient.axis
    private(set) var picker = TrayAxisPicker()
    /// Была ли колода собрана на прошлом событии.
    private(set) var wasGathered = true

    func receive(_ event: TrayGestureEvent,
                 stage: TrayGestureStage,
                 out: TrayGestureOutput) -> TrayGestureRecipient? {
        guard stage == .intercept else { return nil }
        let out: TrayAxisOutput = out
        defer { wasGathered = event.gathered }
        if event.gathered, !wasGathered {
            // Колода только что собралась: направление считаем с этой точки,
            // иначе в счётчике остаётся ход, которым её и собирали, и он
            // перевешивает новое направление (приёмка 21.08.2026).
            picker.restart()
        }
        // Ось выбирает ПАЛЕЦ. Инерция оси не выбирает: события догона летят
        // уже после отрыва, и хвост предыдущего жеста уводил ленту в
        // направление, которого пользователь не показывал (приёмка
        // 20.08.2026).
        guard out.gestureAlternateEdge != nil, event.gathered,
              event.momentumPhase == [] else { return nil }
        switch picker.decide(deltaX: event.input.deltaX,
                             deltaY: event.input.deltaY,
                             began: event.phase == .began,
                             activeEdge: out.gestureActiveEdge,
                             base: out.gestureBaseEdge,
                             alternate: out.gestureAlternateEdge) {
        case .proceed:
            return nil
        case .wait:
            // Пока колода собрана и ось не выбрана, лента не двигается —
            // копится ход пальца, и по нему решается, вверх раскрывать или
            // влево.
            return kind
        case .switchTo(let edge):
            out.gestureSwitchAxis(to: edge)
            return nil
        }
    }

    func gestureEnded(_ event: TrayGestureEvent, out: TrayGestureOutput) {
        // Ход выбора оси обнуляется началом следующего жеста, а не концом
        // текущего: инерция после отрыва идёт по уже выбранной оси.
    }
}

// MARK: - Граница

/// Граница ленты: кому принадлежит инерция и кто отвечает за отскок.
@MainActor
final class TrayBoundaryParty: TrayGestureParty {
    let kind = TrayGestureRecipient.boundary
    private(set) var gate = TrayBoundaryGate()
    private unowned let core: TrayGestureCore

    init(core: TrayGestureCore) { self.core = core }

    func receive(_ event: TrayGestureEvent,
                 stage: TrayGestureStage,
                 out: TrayGestureOutput) -> TrayGestureRecipient? {
        let out: TrayBoundaryOutput = out
        guard stage == .intercept else { return takeBounce(event, out: out) }
        if event.phase == .began { beginGesture(event, out: out) }
        // Инерцию, уже переданную пружине границы, не читаем вовсе — и до
        // общего блока, где события отменяют аниматоры: иначе первое же её
        // событие глушило саму пружину (`TR-13`). Так же ведёт себя системный
        // скролл: после передачи границе затухание не применяется.
        return gate.swallows(momentumPhase: event.momentumPhase) ? kind : nil
    }

    private func beginGesture(_ event: TrayGestureEvent, out: TrayBoundaryOutput) {
        // Новый жест — новая история скорости.
        core.velocity.restart(at: event.timestamp)
        gate.reset()
        // Палец коснулся во время догона: длинная инерционная подача
        // пережимается в короткую от текущего значения — перенацеливание
        // вместо среза (скилл, прерываемость).
        if out.gestureDipAnimating { out.gestureRunDetentSpringUnderFinger() }
    }

    /// Отскок: лента на границе и инерция толкает наружу. Решается ДО
    /// применения дельты, прямой проверкой края. Скорость — из текущего кадра,
    /// сглаженная оценка к этому моменту уже испорчена зажатыми кадрами
    /// (`TR-13`).
    private func takeBounce(_ event: TrayGestureEvent,
                            out: TrayBoundaryOutput) -> TrayGestureRecipient? {
        // Отскок бывает только у жеста с фазами: колесо упирается в край
        // жёстко.
        guard event.hasPhases else { return nil }
        let delta = event.delta(out)
        guard TrayBoundaryHandoff.shouldBounce(model: out.gestureModel, delta: delta,
                                               fingersDown: event.fingersDown,
                                               isMomentum: event.momentumPhase != []) else { return nil }
        let outward = core.velocity.frameVelocity(delta: delta, at: event.timestamp)
        gate.handOff()
        out.gestureRunBoundarySpring(from: out.gestureModel.offset, velocity: outward)
        return kind
    }

    func handOff() { gate.handOff() }

    func gestureEnded(_ event: TrayGestureEvent, out: TrayGestureOutput) {
        // Признаком передачи инерции распоряжаются сами ветки конца:
        // отпускание за краем оставляет инерцию пружине.
    }
}

// MARK: - Лента

/// Сама лента: защёлка, прокрутка, посадка. Последняя в цепочке — берёт всё,
/// что не забрали ось и граница.
@MainActor
final class TrayStripParty: TrayGestureParty {
    let kind = TrayGestureRecipient.strip
    private unowned let core: TrayGestureCore

    init(core: TrayGestureCore) { self.core = core }

    func receive(_ event: TrayGestureEvent,
                 stage: TrayGestureStage,
                 out: TrayGestureOutput) -> TrayGestureRecipient? {
        // Лента работает после общего кадра. Полный мир нужен только рассылке
        // конца жеста — она идёт по всем участникам.
        guard stage == .apply else { return nil }
        let strip: TrayStripOutput = out
        apply(event, delta: event.delta(strip), out: strip)
        strip.gestureApplyScrollOffset()
        settle(event, out: out)
        return kind
    }

    /// Общий кадр жеста и фильтр движения: выполняются между стадиями, до
    /// того как кто-либо начнёт применять ход. Возвращает `false`, если ход
    /// слишком мал и применять нечего.
    func openFrame(_ event: TrayGestureEvent, out: TrayGestureOutput) -> Bool {
        let strip: TrayStripOutput = out
        prepareFrame(event, out: strip)
        let delta = event.delta(strip)
        guard strip.gestureModel.isScrollable || abs(delta) > 0.01 else { return false }
        strip.gestureClearScrollIntent()
        return true
    }

    /// Общий кадр жеста: отложенный возврат отменяется, актуатор взводится,
    /// источник отклика запоминается на всё время жеста.
    private func prepareFrame(_ event: TrayGestureEvent, out: TrayStripOutput) {
        guard event.hasPhases else { return }
        // Новое событие отменяет отложенный возврат: жест продолжается.
        out.gestureCancelSettleAnimation(bumpGeneration: true)
        // Открытие актуатора внешнего трекпада стоит сотни миллисекунд
        // (Bluetooth): готовим дескриптор в фоне заранее, чтобы сам щелчок
        // стоил доли миллисекунды.
        out.gesturePrepareHaptics()
        // Устройство берётся из самого события (`TR-29`). В инерции
        // HID-нагрузки может не быть, поэтому источник запоминается на всё
        // время жеста: защёлка часто срабатывает уже на инерции.
        out.gestureAdoptDevice(event.input.deviceLookup())
        if !core.scrollGestureActive {
            let model = out.gestureModel
            out.gestureLog("gesture offset=\(Int(model.offset)) max=\(Int(model.maximumOffset)) fits=\(TrayDetentModel.fits(model)) engaged=\(out.gestureDetentEngaged)")
        }
        core.scrollGestureActive = true
    }

    /// Применение хода. Возвращает получателя, если событие забрала граница.
    private func apply(_ event: TrayGestureEvent, delta: CGFloat, out: TrayStripOutput) {
        // Резинка только у жестов с фазами: колесо упирается в край жёстко.
        // Содержимое идёт за пальцами: положительная дельта двигает карточки к
        // хабу. Жест никогда не прячет и не показывает трей — это делает
        // только клик по кнопке; перетягивание за край лишь пружинит.
        guard event.hasPhases else { return applyWheel(delta: delta, out: out) }
        // `TR-29`: дельты жеста идут через защёлку — у полного сбора лента
        // проходит точку напряжения и защёлкивается со щелчком.
        if TrayDetentModel.isNearDetent(out.gestureModel) { out.gestureArmHaptics() }
        applyDetent(event, delta: delta, out: out)
    }

    private func applyDetent(_ event: TrayGestureEvent, delta: CGFloat, out: TrayStripOutput) {
        let before = out.gestureModel.offset
        let result = out.gestureApplyDetent(delta: delta, stretch: event.fingersDown)
        // Щелчок ПЕРЕНАЦЕЛИВАЕТ движение: прыжок модели поглощается подачей,
        // видимая позиция остаётся непрерывной. Сдвиг больше порога
        // восприятия за один кадр запрещён (`TR-29`).
        out.gestureWriteModel(result.model, absorbJump: result.click != nil)
        core.velocity.track(movement: out.gestureModel.offset - before, at: event.timestamp)
        // Под пальцем догон короткий и без перелёта: палец сохраняет контроль
        // над моделью, затухает только разница. На инерции — длиннее и с
        // лёгкой осадкой.
        if let click = result.click {
            out.gesturePerformDetentClick(click, underFinger: event.fingersDown)
        }
    }

    /// Колесо шагает дискретно: защёлка следует за фактом без щелчка. Пружину
    /// границы колесо гасит — иначе позицию пишут двое сразу.
    private func applyWheel(delta: CGFloat, out: TrayStripOutput) {
        out.gestureCancelSettleAnimation(bumpGeneration: false)
        out.gestureWriteModel(out.gestureModel.scrolled(by: delta, rubberBand: false),
                              absorbJump: false)
        out.gestureSyncDetent()
    }

    /// Посадка после кадра: у колеса — сразу, у жеста — по виду завершения.
    private func settle(_ event: TrayGestureEvent, out: TrayGestureOutput) {
        guard event.hasPhases else {
            out.gestureWriteModel(out.gestureModel.settled(), absorbJump: false)
            out.gestureApplyScrollOffset()
            return
        }
        guard event.momentumPhase != .ended else {
            // Инерция кончилась — жест завершён окончательно.
            core.scrollGestureActive = false
            out.gestureSettleScrollAnimated()
            return core.finishGesture(event, out: out)
        }
        guard event.phase == .ended || event.phase == .cancelled else { return }
        core.scrollGestureActive = false
        finishRelease(event, out: out)
        core.finishGesture(event, out: out)
    }

    /// Отпускание пальцев: за краем, броском или обычным возвратом.
    private func finishRelease(_ event: TrayGestureEvent, out: TrayGestureOutput) {
        // Отпустили за краем: пружина возврата стартует со скоростью жеста, а
        // вся последующая инерция игнорируется — иначе её события отменяли
        // пружину и схлопывали растяжение телепортом (`TR-13`).
        guard abs(out.gestureModel.overshoot) <= 0.5 else {
            core.handOffMomentumToSpring()
            return out.gestureSettleScrollAnimated()
        }
        // `TR-36`: уверенный бросок к сбору защёлкивает ПО НАМЕРЕНИЮ — по
        // точке, где лента остановилась бы сама, а не по факту доезда. Иначе
        // бросок, не дотянувший чуть-чуть, читается как «не сработало».
        guard out.gestureDetentEngaged
                || !TrayFlickProjection.shouldSnap(model: out.gestureModel,
                                                   velocity: core.velocity.value) else {
            return out.gestureSnapByFlick()
        }
        // Пальцы сняты, но следом может пойти инерция. Возврат из-за края
        // откладывается: запущенный сразу, он тут же отменялся первым же
        // событием инерции, которое снова тянуло ленту наружу (приёмка
        // 19.08.2026).
        out.gestureScheduleSettleAfterGesture()
    }

    func gestureEnded(_ event: TrayGestureEvent, out: TrayGestureOutput) {
        // Посадку ленты выполняет ветка, определившая вид завершения.
    }
}

/// Снимок состояния жеста: собирается из участников, чтобы состояние было
/// видно одним куском — и в проверках, и при разборе поведения.
struct TrayGestureState: Equatable {
    var axis = TrayAxisPicker()
    var velocity = TrayVelocityEstimator()
    var boundary = TrayBoundaryGate()
    var scrollGestureActive = false
    var wasGathered = true
    /// Кто взял последнее событие.
    var lastTaker: TrayGestureRecipient?
    /// Кому был разослан конец последнего жеста.
    var endedRecipients: [TrayGestureRecipient] = []
    /// Кого обошла цепочка на последнем событии.
    var visitedRecipients: [TrayGestureRecipient] = []
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

    /// Оценка скорости общая: её ведёт лента, читают граница и бросок.
    var velocity = TrayVelocityEstimator()
    var scrollGestureActive = false
    private(set) var lastTaker: TrayGestureRecipient?
    private(set) var endedRecipients: [TrayGestureRecipient] = []
    /// Кого обошла цепочка на последнем событии. Первый взявший останавливает
    /// перебор, и следующие в этом списке не появляются.
    private(set) var visitedRecipients: [TrayGestureRecipient] = []

    private(set) lazy var axisParty = TrayAxisParty()
    private(set) lazy var boundaryParty = TrayBoundaryParty(core: self)
    private(set) lazy var stripParty = TrayStripParty(core: self)
    /// Порядок фиксирован и повторяет прежний порядок проверок дословно.
    private lazy var parties: [any TrayGestureParty] = [axisParty, boundaryParty, stripParty]

    var state: TrayGestureState {
        TrayGestureState(axis: axisParty.picker,
                         velocity: velocity,
                         boundary: boundaryParty.gate,
                         scrollGestureActive: scrollGestureActive,
                         wasGathered: axisParty.wasGathered,
                         lastTaker: lastTaker,
                         endedRecipients: endedRecipients,
                         visitedRecipients: visitedRecipients)
    }

    /// Непрерывная прокрутка ленты (`TR-1`, `TR-2`). Пошаговое переключение
    /// заменено на смещение, потому что ступенчатая лента не даёт понять, где
    /// ты находишься, и не позволяет остановиться между карточками.
    func handle(_ input: TrayGestureInput, out: TrayGestureOutput) {
        guard let event = intake(input, out: out) else { return }
        lastTaker = nil
        for stage in TrayGestureStage.allCases {
            if deliver(event, stage: stage, out: out) { break }
        }
    }

    /// Один проход цепочки. Перед применением идёт общий кадр жеста: отмена
    /// отложенного возврата, взвод отклика, фильтр движения — он общий и не
    /// принадлежит никому из участников.
    private func deliver(_ event: TrayGestureEvent,
                         stage: TrayGestureStage,
                         out: TrayGestureOutput) -> Bool {
        if stage == .apply, !stripParty.openFrame(event, out: out) { return true }
        visitedRecipients = []
        for party in parties {
            visitedRecipients.append(party.kind)
            guard let taker = party.receive(event, stage: stage, out: out) else { continue }
            lastTaker = taker
            return true
        }
        return false
    }

    /// Разбор события: один раз, на входе в цепочку.
    private func intake(_ input: TrayGestureInput, out: TrayGestureOutput) -> TrayGestureEvent? {
        guard !out.gestureCardsAreCollapsed else { return nil }
        let model = out.gestureModel
        return TrayGestureEvent(input: input,
                                gathered: model.offset >= model.maximumOffset - 0.5,
                                hasPhases: input.phase != [] || input.momentumPhase != [],
                                fingersDown: input.phase != [])
    }

    /// Конец жеста проходит по ВСЕМ участникам, а не съедается первой веткой.
    ///
    /// Сегодня оси и границе на конце жеста делать нечего, и это записано в их
    /// собственных методах, а не подразумевается отсутствием кода. Любое
    /// изменение того, ЧТО они делают, — отдельная задача.
    func finishGesture(_ event: TrayGestureEvent, out: TrayGestureOutput) {
        endedRecipients = []
        for party in parties {
            party.gestureEnded(event, out: out)
            endedRecipients.append(party.kind)
        }
    }

    /// История скорости начинается заново: прежние отсчёты сняты с движения по
    /// другой оси.
    func resetVelocity(at timestamp: TimeInterval) {
        velocity.restart(at: timestamp)
    }

    /// Жест завершён извне (лента спрятана, карточки схлопнуты).
    func endGesture() {
        scrollGestureActive = false
    }

    func handOffMomentumToSpring() {
        boundaryParty.handOff()
    }
}
