import AppKit
import Foundation

/// Маршрут события жеста: то, что эталон покрыть не может.
///
/// Эталон сравнивает числа. Здесь проверяется устройство: событие проходит
/// получателей по порядку и останавливается на первом взявшем, конец жеста
/// доходит до каждого, а обработчик не держит собственного состояния. Именно
/// на этом ломались правки 21-22.08.2026: событие не доходило до получателя,
/// а конец жеста съедался чужой веткой.
@MainActor
@main
struct TrayGestureRoutingTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        run("порядок получателей объявлен: ось, граница, лента", testOrderDeclared)
        run("ход поперёк оси берёт выбор оси", testAxisTakesEvent)
        run("инерцию после передачи пружине берёт граница", testBoundaryTakesMomentum)
        run("обычный ход доходит до ленты", testStripTakesEvent)
        run("отскок за краем берёт граница", testBounceTakenByBoundary)
        run("конец жеста доходит до каждого получателя", testEndReachesEveryone)
        run("отпускание за краем тоже рассылает конец всем", testEndAfterOvershoot)
        run("бросок к сбору тоже рассылает конец всем", testEndAfterFlick)
        run("взявший останавливает перебор: за осью никого", testAxisStopsChain)
        run("взявший останавливает перебор: за границей нет ленты", testBoundaryStopsChain)
        run("не взявшие пропускают событие дальше", testChainReachesStrip)
        run("каждый получатель — свой тип со своими методами", testPartiesAreSeparateTypes)
        run("следующий жест начинает счёт направления с нуля", testNoLeftoverState)
        run("обработчик не хранит полей состояния жеста", testHandlerHoldsNoState)
        run("обработчик остаётся коротким", testHandlerStaysShort)
        print("TrayGestureRoutingTests: passed")
    }

    // MARK: - Маршрут

    private static func testOrderDeclared() throws {
        try require(TrayGestureRecipient.allCases == [.axis, .boundary, .strip],
                    "Порядок получателей задаёт поведение и не может быть произвольным")
    }

    private static func testAxisTakesEvent() throws {
        // Собранная колода, две оси, короткий ход поперёк: направление ещё не
        // явное, лента обязана стоять.
        let (core, probe) = make(gathered: true, alternate: .bottom)
        let before = probe.model.offset
        core.handle(input(dx: 4, dy: 0, phase: .began), out: probe)
        try require(core.state.lastTaker == .axis,
                    "Ход поперёк оси должен останавливаться на выборе оси, взял: \(String(describing: core.state.lastTaker))")
        try require(probe.model.offset == before,
                    "Лента сдвинулась, хотя направление ещё не выбрано")
        try require(!probe.effects.contains(where: { $0.hasPrefix("write") }),
                    "Выбор оси пропустил событие дальше по цепочке")
    }

    private static func testBoundaryTakesMomentum() throws {
        let (core, probe) = make(gathered: false, alternate: nil)
        core.handOffMomentumToSpring()
        probe.effects.removeAll()
        core.handle(input(dx: 0, dy: 12, phase: [], momentum: .changed), out: probe)
        try require(core.state.lastTaker == .boundary,
                    "Инерцию, отданную пружине, обязана съедать граница")
        try require(probe.effects.isEmpty,
                    "Событие, съеденное границей, дошло до ленты: \(probe.effects)")
    }

    private static func testStripTakesEvent() throws {
        let (core, probe) = make(gathered: false, alternate: nil)
        core.handle(input(dx: 0, dy: 6, phase: .began), out: probe)
        core.handle(input(dx: 0, dy: 6, phase: .changed, at: 10.02), out: probe)
        try require(core.state.lastTaker == .strip,
                    "Обычный ход обязан доходить до ленты, взял: \(String(describing: core.state.lastTaker))")
        try require(probe.effects.contains(where: { $0.hasPrefix("detent") }),
                    "Лента не применила ход через защёлку")
    }

    private static func testBounceTakenByBoundary() throws {
        // Лента стоит на нуле, инерция толкает наружу: это отскок.
        let (core, probe) = make(gathered: false, alternate: nil)
        core.handle(input(dx: 0, dy: -30, phase: [], momentum: .changed), out: probe)
        try require(core.state.lastTaker == .boundary,
                    "Отскок обязан оставаться у границы, взял: \(String(describing: core.state.lastTaker))")
        try require(probe.effects.contains(where: { $0.hasPrefix("boundarySpring") }),
                    "Пружина границы не запущена: \(probe.effects)")
    }

    private static func testAxisStopsChain() throws {
        let (core, probe) = make(gathered: true, alternate: .bottom)
        core.handle(input(dx: 4, dy: 0, phase: .began), out: probe)
        try require(core.state.visitedRecipients == [.axis],
                    "Цепочка пошла дальше оси: \(core.state.visitedRecipients)")
    }

    private static func testBoundaryStopsChain() throws {
        let (core, probe) = make(gathered: false, alternate: nil)
        core.handOffMomentumToSpring()
        core.handle(input(dx: 0, dy: 12, phase: [], momentum: .changed), out: probe)
        try require(core.state.visitedRecipients == [.axis, .boundary],
                    "Лента получила событие, съеденное границей: \(core.state.visitedRecipients)")
    }

    private static func testChainReachesStrip() throws {
        let (core, probe) = make(gathered: false, alternate: nil)
        core.handle(input(dx: 0, dy: 6, phase: .began), out: probe)
        try require(core.state.visitedRecipients == [.axis, .boundary, .strip],
                    "Событие не дошло до ленты: \(core.state.visitedRecipients)")
    }

    private static func testPartiesAreSeparateTypes() throws {
        let source = try read("Sources/TrayGestureCore.swift")
        for name in ["TrayAxisParty", "TrayBoundaryParty", "TrayStripParty"] {
            try require(source.contains("final class \(name): TrayGestureParty"),
                        "Получатель \(name) не отдельный тип")
        }
        // У каждого — оба метода: приём события и конец жеста.
        try require(source.components(separatedBy: "func receive(_ event: TrayGestureEvent").count == 5,
                    "Метод приёма есть не у всех трёх получателей")
        try require(source.components(separatedBy: "func gestureEnded(_ event: TrayGestureEvent").count == 5,
                    "Метод конца жеста есть не у всех трёх получателей")
    }

    // MARK: - Конец жеста

    private static func testEndReachesEveryone() throws {
        let (core, probe) = make(gathered: false, alternate: nil)
        core.handle(input(dx: 0, dy: 8, phase: .began), out: probe)
        core.handle(input(dx: 0, dy: 8, phase: .changed, at: 10.02), out: probe)
        core.handle(input(dx: 0, dy: 0, phase: .ended, at: 10.04), out: probe)
        try require(core.state.endedRecipients == TrayGestureRecipient.allCases,
                    "Конец жеста дошёл не до всех: \(core.state.endedRecipients)")
        try require(!core.state.scrollGestureActive,
                    "Жест остался активным после завершения")
    }

    private static func testEndAfterOvershoot() throws {
        // Уводим ленту за край пальцем и отпускаем: ветка возврата из-за края.
        let (core, probe) = make(gathered: false, alternate: nil)
        core.handle(input(dx: 0, dy: 0, phase: .began), out: probe)
        for i in 1...6 {
            core.handle(input(dx: 0, dy: -20, phase: .changed, at: 10 + Double(i) * 0.008), out: probe)
        }
        core.handle(input(dx: 0, dy: 0, phase: .ended, at: 10.1), out: probe)
        try require(core.state.endedRecipients == TrayGestureRecipient.allCases,
                    "После отпускания за краем конец дошёл не до всех: \(core.state.endedRecipients)")
    }

    private static func testEndAfterFlick() throws {
        // Уверенный бросок к сбору: ветка защёлкивания по намерению.
        let (core, probe) = make(gathered: false, alternate: nil)
        core.handle(input(dx: 0, dy: 0, phase: .began), out: probe)
        var t = 10.0
        for _ in 0..<10 {
            t += 1.0 / 240
            core.handle(input(dx: 0, dy: 30, phase: .changed, at: t), out: probe)
        }
        core.handle(input(dx: 0, dy: 0, phase: .ended, at: t + 0.004), out: probe)
        try require(probe.effects.contains("snapByFlick"),
                    "Бросок не защёлкнул ленту, эффекты: \(probe.effects)")
        try require(core.state.endedRecipients == TrayGestureRecipient.allCases,
                    "После броска конец дошёл не до всех: \(core.state.endedRecipients)")
    }

    private static func testNoLeftoverState() throws {
        let (core, probe) = make(gathered: true, alternate: .bottom)
        core.handle(input(dx: 6, dy: 0, phase: .began), out: probe)
        core.handle(input(dx: 6, dy: 0, phase: .changed, at: 10.02), out: probe)
        let carried = core.state.axis.accumulatedX
        try require(carried != 0, "Ход выбора оси не накопился — проверка бессмысленна")
        core.handle(input(dx: 0, dy: 0, phase: .ended, at: 10.04), out: probe)
        // Новый жест: счёт направления обязан начинаться с нуля, иначе ход
        // прошлого жеста перевешивает новое направление.
        core.handle(input(dx: 1, dy: 0, phase: .began, at: 11), out: probe)
        try require(abs(core.state.axis.accumulatedX) <= 1.0001,
                    "Новый жест унаследовал ход прошлого: \(core.state.axis.accumulatedX)")
        try require(core.state.axis.accumulatedY == 0,
                    "Поперечный ход не обнулился на начале жеста")
    }

    // MARK: - Обработчик

    private static func testHandlerHoldsNoState() throws {
        let source = try read("Sources/ThumbnailManager.swift")
        for field in ["axisPickupX", "axisPickupY", "scrollVelocity",
                      "lastScrollTimestamp", "momentumHandedToSpring",
                      "scrollGestureActive", "wasGathered"] {
            try require(!source.contains("private var \(field)"),
                        "Поле жеста \(field) осталось в менеджере")
        }
    }

    private static func testHandlerStaysShort() throws {
        let source = try read("Sources/ThumbnailManager.swift")
        guard let start = source.range(of: "    func scrollTray(with event: NSEvent) {") else {
            throw Failure("Обработчик не найден")
        }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n    }\n") else {
            throw Failure("Конец обработчика не найден")
        }
        let body = rest[..<end.lowerBound]
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
        try require(lines <= 18,
                    "Обработчик снова разросся: \(lines) строк тела")
        try require(!body.contains("if ") && !body.contains("guard "),
                    "В обработчике снова появились решения — они принадлежат механике")
    }

    // MARK: - Оснастка

    private static func make(gathered: Bool,
                             alternate: ThumbnailLayoutEdge?) -> (TrayGestureCore, TrayGestureProbe) {
        var model = TrayScrollModel(contentLength: 3 * 220 + 2 * 12,
                                    viewportLength: 420,
                                    offset: 0,
                                    lastCardLength: 220)
        model.offset = gathered ? model.maximumOffset : 0
        let probe = TrayGestureProbe(model: model, base: .right, alternate: alternate)
        let core = TrayGestureCore()
        probe.core = core
        return (core, probe)
    }

    private static func input(dx: CGFloat,
                              dy: CGFloat,
                              phase: NSEvent.Phase,
                              momentum: NSEvent.Phase = [],
                              at timestamp: TimeInterval = 10) -> TrayGestureInput {
        TrayGestureInput(deltaX: dx, deltaY: dy, hasPreciseDeltas: true,
                         phase: phase, momentumPhase: momentum, timestamp: timestamp)
    }

    private static func read(_ path: String) throws -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw Failure("Не читается \(path)")
        }
        return text
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ text: String) { description = text }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    private static func run(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            print("  \(name): passed")
        } catch {
            print("  \(name): FAILED — \(error)")
            exit(1)
        }
    }
}
