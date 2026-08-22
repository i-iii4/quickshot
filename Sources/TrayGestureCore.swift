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

/// Состояние, принадлежащее жесту. Раньше эти величины лежали отдельными
/// полями менеджера, и любая правка обработчика обязана была помнить их все.
struct TrayGestureState: Equatable {
    /// Накопленный ход выбора оси (`TR-38`).
    var axisPickupX: CGFloat = 0
    var axisPickupY: CGFloat = 0
    /// Сглаженная оценка скорости ленты, pt/с.
    var scrollVelocity: CGFloat = 0
    var lastScrollTimestamp: TimeInterval = 0
    /// Инерция отдана пружине границы: её события механика не читает (`TR-13`).
    var momentumHandedToSpring = false
    var scrollGestureActive = false
    /// Была ли колода собрана на прошлом событии.
    var wasGathered = true
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
    /// Мёртвая зона распознавания направления (`TR-38`).
    static let axisPickThreshold: CGFloat = 10
    /// Щелчок колеса приходит в строках, а не в точках.
    static let wheelLineHeight: CGFloat = 40

    private(set) var state = TrayGestureState()

    /// Колода собрана: лента доехала до упора и стоит там.
    private func deckIsGathered(_ model: TrayScrollModel) -> Bool {
        model.offset >= model.maximumOffset - 0.5
    }

    /// Выбирает ось раскрытия по ходу пальца.
    ///
    /// Ось меняется ТОЛЬКО из собранного состояния. Раскрытая лента
    /// продолжает жить по своей оси до самого возврата — смена системы
    /// координат под раскрытой лентой давала прыжки, случайные щелчки и
    /// переходы в чужие состояния (приёмка 20.08.2026).
    private func pickOpenAxis(_ input: TrayGestureInput, out: TrayGestureOutput) -> Bool {
        if input.phase == .began {
            state.axisPickupX = 0
            state.axisPickupY = 0
        }
        state.axisPickupX += input.deltaX
        state.axisPickupY += input.deltaY

        // Движение ВДОЛЬ текущей оси не ждёт порога: это не заявка на смену
        // направления, а обычная работа с лентой, и задерживать её нельзя —
        // иначе первые точки хода в упор съедались бы и резинка начиналась с
        // опозданием.
        let activeEdge = out.gestureActiveEdge
        let along = activeEdge.isVertical ? abs(state.axisPickupY) : abs(state.axisPickupX)
        let across = activeEdge.isVertical ? abs(state.axisPickupX) : abs(state.axisPickupY)
        guard across > along else { return true }

        // Заявка на смену: ждём порога, пока направление не станет явным.
        guard let vertical = trayAxisPick(accumulatedX: state.axisPickupX,
                                          accumulatedY: state.axisPickupY,
                                          threshold: Self.axisPickThreshold) else { return false }
        let base = out.gestureBaseEdge
        let alternate = out.gestureAlternateEdge
        let chosen = vertical
            ? (base.isVertical ? base : (alternate ?? base))
            : (base.isVertical ? (alternate ?? base) : base)
        guard chosen != activeEdge else { return true }
        out.gestureSwitchAxis(to: chosen)
        return true
    }

    /// История скорости начинается заново: прежние отсчёты сняты с движения по
    /// другой оси. Обнулять её на каждом событии нельзя — так ломается оценка
    /// скорости, а с ней проекция броска.
    func resetVelocity(at timestamp: TimeInterval) {
        state.scrollVelocity = 0
        state.lastScrollTimestamp = timestamp
    }

    /// Оценка скорости ленты по событиям, pt/с. Сглаживание убирает выброс от
    /// одиночного рваного кадра, иначе он задал бы скорость передачи пружине.
    func trackVelocity(movement: CGFloat, at timestamp: TimeInterval) {
        defer { state.lastScrollTimestamp = timestamp }
        let dt = timestamp - state.lastScrollTimestamp
        guard dt > 0.0005, dt < 0.2 else { return }
        let instant = movement / CGFloat(dt)
        let alpha: CGFloat = 0.3
        state.scrollVelocity = state.scrollVelocity * (1 - alpha) + instant * alpha
    }

    /// Жест завершён извне (лента спрятана, карточки схлопнуты).
    func endGesture() {
        state.scrollGestureActive = false
    }

    func handOffMomentumToSpring() {
        state.momentumHandedToSpring = true
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
            state.axisPickupX = 0
            state.axisPickupY = 0
        }
        if out.gestureAlternateEdge != nil, gathered, input.momentumPhase == [],
           !pickOpenAxis(input, out: out) { return }
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
            state.scrollVelocity = 0
            state.lastScrollTimestamp = input.timestamp
            state.momentumHandedToSpring = false
            // Палец коснулся во время догона: длинная инерционная подача
            // пережимается в короткую от текущего значения — перенацеливание
            // вместо среза (скилл, прерываемость).
            if out.gestureDipAnimating { out.gestureRunDetentSpringUnderFinger() }
        }
        // Инерцию, уже переданную пружине границы, не читаем вовсе — и до
        // общего блока, где события отменяют аниматоры: иначе первое же её
        // событие глушило саму пружину (`TR-13`). Так же ведёт себя системный
        // скролл: после передачи границе затухание не применяется.
        if state.momentumHandedToSpring, input.momentumPhase != [] {
            if input.momentumPhase == .ended { state.momentumHandedToSpring = false }
            return
        }
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
                let dt = max(0.001, input.timestamp - state.lastScrollTimestamp)
                let outward = delta / CGFloat(dt)
                state.lastScrollTimestamp = input.timestamp
                state.momentumHandedToSpring = true
                out.gestureRunBoundarySpring(from: out.gestureModel.offset, velocity: outward)
                return
            }
            let before = out.gestureModel.offset
            let result = out.gestureApplyDetent(delta: delta, stretch: fingersDown)
            // Щелчок ПЕРЕНАЦЕЛИВАЕТ движение: прыжок модели поглощается
            // подачей, видимая позиция остаётся непрерывной. Сдвиг больше
            // порога восприятия за один кадр запрещён (`TR-29`).
            out.gestureWriteModel(result.model, absorbJump: result.click != nil)
            trackVelocity(movement: out.gestureModel.offset - before, at: input.timestamp)
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
        } else if (input.phase == .ended || input.phase == .cancelled),
                  abs(out.gestureModel.overshoot) > 0.5 {
            // Отпустили за краем: пружина возврата стартует со скоростью
            // жеста, а вся последующая инерция игнорируется — иначе её
            // события отменяли пружину и схлопывали растяжение телепортом.
            // Системный скролл после отпускания за краем инерцию тоже не
            // читает (`TR-13`).
            state.scrollGestureActive = false
            state.momentumHandedToSpring = true
            out.gestureSettleScrollAnimated()
        } else if input.phase == .ended || input.phase == .cancelled {
            state.scrollGestureActive = false
            // `TR-36`: уверенный бросок к сбору защёлкивает ПО НАМЕРЕНИЮ —
            // по точке, где лента остановилась бы сама, а не по факту
            // доезда. Иначе бросок, не дотянувший чуть-чуть, читается как
            // «не сработало».
            if !out.gestureDetentEngaged,
               TrayFlickProjection.shouldSnap(model: out.gestureModel, velocity: state.scrollVelocity) {
                out.gestureSnapByFlick()
                return
            }
            // Пальцы сняты, но следом может пойти инерция. Возврат из-за края
            // откладывается: запущенный сразу, он тут же отменялся первым же
            // событием инерции, которое снова тянуло ленту наружу — старт,
            // отмена, старт, и это читалось как дёрганье (приёмка 19.08.2026).
            out.gestureScheduleSettleAfterGesture()
        }
    }
}
