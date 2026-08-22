import AppKit
import Foundation

/// Эталон механики жеста трея.
///
/// Прогоняет `TrayGestureCore` тысячами шагов на подставном мире и сравнивает
/// каждый шаг с записанным эталоном. Смысл — рефакторинг: перенос кода обязан
/// оставить движение ленты тем же до последнего числа, и это должно быть
/// видно, а не заявлено.
///
/// Эталон НЕ пересматривается. Разошлось число — виноват перенос, а не эталон.
/// Перезапись возможна только явным `--record` и только при первом снятии.

// MARK: - Детерминированный источник чисел

/// Свой генератор: эталон обязан воспроизводиться побайтово на любой машине.
struct Deterministic {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func unit() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 11) & 0xFFFFF) / CGFloat(0xFFFFF)
    }
    mutating func range(_ low: CGFloat, _ high: CGFloat) -> CGFloat {
        low + unit() * (high - low)
    }
    mutating func int(_ low: Int, _ high: Int) -> Int {
        low + Int(unit() * CGFloat(high - low + 1)) % max(1, high - low + 1)
    }
}

// MARK: - Прогон

@MainActor
final class BaselineRun {
    private var lines: [String] = []
    private var step = 0
    private var rng = Deterministic(seed: 0x5EED_1234_ABCD_0001)

    var recorded: [String] { lines }
    var stepCount: Int { step }

    /// Один состав ленты, одна пара осей, одна форма жеста.
    func scenario(name: String,
                  cards: Int,
                  cardLength: CGFloat,
                  base: ThumbnailLayoutEdge,
                  alternate: ThumbnailLayoutEdge?,
                  startGathered: Bool,
                  events: [TrayGestureInput]) {
        let gap: CGFloat = 12
        let content = CGFloat(cards) * cardLength + CGFloat(max(0, cards - 1)) * gap
        var model = TrayScrollModel(contentLength: content,
                                    viewportLength: 420,
                                    offset: 0,
                                    lastCardLength: cardLength)
        model.offset = startGathered ? model.maximumOffset : 0
        let probe = TrayGestureProbe(model: model, base: base, alternate: alternate)
        let core = TrayGestureCore()
        probe.core = core
        lines.append("# \(name) cards=\(cards) base=\(base.rawValue) alt=\(alternate?.rawValue ?? "-") gathered=\(startGathered)")
        for input in events {
            probe.effects.removeAll(keepingCapacity: true)
            core.handle(input, out: probe)
            step += 1
            let s = core.state
            lines.append([
                "\(step)",
                fmt(probe.model.offset),
                fmt(probe.model.rawOffset),
                probe.detent.engaged ? "1" : "0",
                fmt(probe.detent.strain),
                fmt(s.velocity.value),
                fmt(CGFloat(s.velocity.lastTimestamp)),
                s.boundary.handedToSpring ? "1" : "0",
                s.scrollGestureActive ? "1" : "0",
                s.wasGathered ? "1" : "0",
                fmt(s.axis.accumulatedX),
                fmt(s.axis.accumulatedY),
                probe.edge.rawValue,
                probe.effects.joined(separator: ",")
            ].joined(separator: "|"))
        }
    }

    /// Формы жеста: палец, инерция, отмена, колесо, бросок, смена оси.
    func buildAll() {
        let layouts: [(Int, CGFloat)] = [(1, 180), (2, 180), (3, 220), (8, 160)]
        let axes: [(ThumbnailLayoutEdge, ThumbnailLayoutEdge?)] = [
            (.right, .bottom), (.bottom, .right), (.right, nil)
        ]
        var shapeIndex = 0
        // Два прохода: тот же набор форм с другими числами хода — эталон
        // должен покрывать не единственную траекторию, а их семейство.
        for _ in 0..<2 {
        for (cards, length) in layouts {
            for (base, alternate) in axes {
                for gathered in [false, true] {
                    for shape in 0..<7 {
                        shapeIndex += 1
                        let name = "shape\(shape)-\(shapeIndex)"
                        scenario(name: name,
                                 cards: cards,
                                 cardLength: length,
                                 base: base,
                                 alternate: alternate,
                                 startGathered: gathered,
                                 events: events(shape: shape, vertical: base.isVertical))
                    }
                }
            }
        }
        }
    }

    private func events(shape: Int, vertical: Bool) -> [TrayGestureInput] {
        var out: [TrayGestureInput] = []
        var t: TimeInterval = 10
        func push(_ dx: CGFloat, _ dy: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase, dt: TimeInterval = 1.0 / 120) {
            t += dt
            out.append(TrayGestureInput(deltaX: dx, deltaY: dy,
                                        hasPreciseDeltas: shape != 3,
                                        phase: phase, momentumPhase: momentum,
                                        timestamp: t))
        }
        let steps = rng.int(12, 30)
        switch shape {
        case 0: // ровная подтяжка пальцем и отпускание
            push(0, 0, phase: .began, momentum: [])
            for _ in 0..<steps {
                let d = rng.range(2, 9)
                push(vertical ? 0 : d, vertical ? d : 0, phase: .changed, momentum: [])
            }
            push(0, 0, phase: .ended, momentum: [])
        case 1: // жест с инерцией до полной остановки
            push(0, 0, phase: .began, momentum: [])
            for _ in 0..<steps {
                let d = rng.range(4, 14)
                push(vertical ? 0 : d, vertical ? d : 0, phase: .changed, momentum: [])
            }
            push(0, 0, phase: .ended, momentum: [])
            for i in 0..<10 {
                let d = rng.range(1, 8) / CGFloat(i + 1)
                push(vertical ? 0 : d, vertical ? d : 0, phase: [], momentum: .changed)
            }
            push(0, 0, phase: [], momentum: .ended)
        case 2: // отмена жеста системой
            push(0, 0, phase: .began, momentum: [])
            for _ in 0..<steps {
                let d = rng.range(-6, 10)
                push(vertical ? 0 : d, vertical ? d : 0, phase: .changed, momentum: [])
            }
            push(0, 0, phase: .cancelled, momentum: [])
        case 3: // колесо мыши: без фаз, дельта в строках
            for _ in 0..<steps {
                let d: CGFloat = rng.unit() > 0.5 ? 1 : -1
                push(vertical ? 0 : d, vertical ? d : 0, phase: [], momentum: [], dt: 0.05)
            }
        case 4: // бросок: разгон и резкий отрыв
            push(0, 0, phase: .began, momentum: [])
            for i in 0..<steps {
                let d = rng.range(10, 26) + CGFloat(i)
                push(vertical ? 0 : d, vertical ? d : 0, phase: .changed, momentum: [], dt: 1.0 / 240)
            }
            push(0, 0, phase: .ended, momentum: [])
        case 5: // ход поперёк оси: заявка на смену направления
            push(0, 0, phase: .began, momentum: [])
            for _ in 0..<steps {
                let d = rng.range(3, 11)
                push(vertical ? d : 0, vertical ? 0 : d, phase: .changed, momentum: [])
            }
            push(0, 0, phase: .ended, momentum: [])
        default: // рваный ход с паузами и сменой знака
            push(0, 0, phase: .began, momentum: [])
            for i in 0..<steps {
                let d = rng.range(-14, 18)
                let dt: TimeInterval = i % 5 == 0 ? 0.25 : 1.0 / 90
                push(vertical ? 0 : d, vertical ? d : 0, phase: .changed, momentum: [], dt: dt)
            }
            push(0, 0, phase: .ended, momentum: [])
            for _ in 0..<6 {
                push(0, rng.range(1, 5), phase: [], momentum: .changed)
            }
            push(0, 0, phase: [], momentum: .ended)
        }
        return out
    }
}

// MARK: - Точка входа

@MainActor
@main
struct TrayGestureBaselineTests {
    static let path = "Tests/TrayGestureBaseline.txt"

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let run = BaselineRun()
        run.buildAll()
        let produced = run.recorded.joined(separator: "\n") + "\n"

        let recording = CommandLine.arguments.contains("--record")
        let existing = try? String(contentsOfFile: path, encoding: .utf8)

        if recording {
            guard existing == nil else {
                print("baseline: файл уже снят, перезапись запрещена")
                exit(1)
            }
            try? produced.write(toFile: path, atomically: true, encoding: .utf8)
            print("baseline: recorded \(run.stepCount) steps")
            print("TrayGestureBaselineTests: passed")
            return
        }

        guard let expected = existing else {
            print("baseline: эталон не найден — снимите его с --record")
            exit(1)
        }
        guard run.stepCount >= 5000 else {
            print("baseline: шагов \(run.stepCount), требуется не меньше 5000")
            exit(1)
        }
        let a = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let b = produced.split(separator: "\n", omittingEmptySubsequences: false)
        if a.count != b.count {
            print("baseline diverged: строк \(b.count), в эталоне \(a.count)")
            exit(1)
        }
        for (index, pair) in zip(a, b).enumerated() where pair.0 != pair.1 {
            print("baseline diverged at step \(index + 1):")
            print("  эталон: \(pair.0)")
            print("  сейчас: \(pair.1)")
            exit(1)
        }
        print("baseline: \(run.stepCount) steps identical")
        print("TrayGestureBaselineTests: passed")
    }
}
