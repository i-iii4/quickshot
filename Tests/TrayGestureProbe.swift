import AppKit
import Foundation

// MARK: - Подставной мир

/// Мир без окон: держит ленту и защёлку, честно применяет к ним операции,
/// записывает порядок эффектов. Анимации выполняются мгновенно — эталону
/// нужна воспроизводимость, а не реальное время.
@MainActor
final class TrayGestureProbe: TrayGestureOutput {
    var model: TrayScrollModel
    var detent = TrayDetentModel()
    var collapsed = false
    var edge: ThumbnailLayoutEdge
    var alternate: ThumbnailLayoutEdge?
    var base: ThumbnailLayoutEdge
    var dipAnimating = false
    var device: UInt64?
    var reversed = false
    var scrollIntentCleared = false
    var settleGeneration = 0
    /// След эффектов за шаг: порядок вызовов — такая же часть поведения, как
    /// числа.
    var effects: [String] = []
    weak var core: TrayGestureCore?

    init(model: TrayScrollModel, base: ThumbnailLayoutEdge, alternate: ThumbnailLayoutEdge?) {
        self.model = model
        self.base = base
        self.edge = base
        self.alternate = alternate
        detent.sync(with: model)
    }

    var gestureCardsAreCollapsed: Bool { collapsed }
    var gestureModel: TrayScrollModel { model }
    var gestureDetentEngaged: Bool { detent.engaged }
    var gestureActiveEdge: ThumbnailLayoutEdge { edge }
    /// Направление роста ленты: подставной мир держит углы, растущие от
    /// начала координат, поэтому ход считается как есть.
    var gestureAxisReversed: Bool { reversed }
    var gestureAlternateEdge: ThumbnailLayoutEdge? { alternate }
    var gestureBaseEdge: ThumbnailLayoutEdge { base }
    var gestureDipAnimating: Bool { dipAnimating }

    func gestureSwitchAxis(to edge: ThumbnailLayoutEdge) {
        effects.append("switchAxis(\(edge.rawValue))")
        self.edge = edge
        core?.resetVelocity(at: 0)
        model.offset = model.maximumOffset
        detent.sync(with: model)
    }

    func gestureRunDetentSpringUnderFinger() {
        effects.append("dipSpring")
        dipAnimating = false
    }

    func gestureCancelSettleAnimation(bumpGeneration: Bool) {
        effects.append(bumpGeneration ? "cancelSettle+gen" : "cancelSettle")
        if bumpGeneration { settleGeneration &+= 1 }
    }

    func gesturePrepareHaptics() { effects.append("prepareHaptics") }
    func gestureArmHaptics() { effects.append("armHaptics") }

    func gestureAdoptDevice(_ device: UInt64?) {
        guard let device else { return }
        effects.append("device(\(device))")
        self.device = device
    }

    /// Журнал в след НЕ пишется: он ничего не двигает, а эталон сравнивает
    /// движение. Иначе любая новая диагностическая строка ломала бы сравнение.
    func gestureLog(_ line: String) {}
    func gestureClearScrollIntent() {
        effects.append("clearIntent")
        scrollIntentCleared = true
    }

    func gestureWriteModel(_ model: TrayScrollModel, absorbJump: Bool) {
        effects.append("write(\(fmt(model.offset)),jump=\(absorbJump))")
        self.model = model
    }

    func gestureApplyDetent(delta: CGFloat,
                            stretch: Bool) -> (model: TrayScrollModel, click: TrayDetentModel.Click?) {
        let result = detent.apply(delta: delta, to: model, stretch: stretch)
        effects.append("detent(\(fmt(delta)),stretch=\(stretch))")
        return result
    }

    func gestureSyncDetent() {
        effects.append("syncDetent")
        detent.sync(with: model)
    }

    func gesturePerformDetentClick(_ click: TrayDetentModel.Click, underFinger: Bool) {
        effects.append("click(\(click),finger=\(underFinger))")
        dipAnimating = true
    }

    func gestureRunBoundarySpring(from boundary: CGFloat, velocity: CGFloat) {
        effects.append("boundarySpring(\(fmt(boundary)),v=\(fmt(velocity)))")
        model.offset = boundary
        detent.sync(with: model)
    }

    func gestureApplyScrollOffset() { effects.append("layout") }

    func gestureSettleScrollAnimated() {
        effects.append("settle")
        let target = detent.settleTarget(for: model) ?? model.settled().offset
        model.offset = target
        detent.sync(with: model)
    }

    func gestureSnapByFlick() {
        effects.append("snapByFlick")
        core?.handOffMomentumToSpring()
        model.offset = model.maximumOffset
        detent.sync(with: model)
    }

    func gestureScheduleSettleAfterGesture() {
        effects.append("scheduleSettle")
        settleGeneration &+= 1
    }
}

/// Округление до сотых: эталон не должен ломаться на последнем бите double,
/// но обязан ловить любое различие, заметное движению.
@MainActor
func fmt(_ value: CGFloat) -> String {
    let rounded = (value * 100).rounded() / 100
    return String(format: "%.2f", rounded == 0 ? 0 : rounded)
}
