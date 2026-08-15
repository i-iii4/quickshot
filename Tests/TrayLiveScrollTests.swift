import AppKit
import CoreGraphics

/// Живая прокрутка трея: события идут через окно трея, как от настоящего
/// трекпада, и проверяются наблюдаемые следствия — координаты карточек,
/// доступность новейшего снимка и работа его кнопок.
///
/// Модельные тесты прокрутки (`TrayScrollModelTests`, `TrayScrollLayoutTests`)
/// считают арифметику и раскладку. Они не заметили, что смещение никогда не
/// сбрасывается к новым снимкам, что карточки в стопке перестают принимать
/// мышь и что событие прокрутки вообще не доходит до менеджера.
@MainActor
private final class TrayLiveScrollTests: NSObject, NSApplicationDelegate {
    private var failures: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        newestCaptureStaysReachable()
        scrollWheelMovesCards()
        closeButtonWorksOnNewestCard()
        scrollFollowsTheGesture()
        wheelNotchMovesAVisibleDistance()
        hoverStaysOnASingleCard()
        scrollWorksInTheGapBetweenCards()
        momentumKeepsMovingTheStrip()

        if failures.isEmpty {
            print("TrayLiveScrollTests: passed")
        } else {
            failures.forEach { fputs("TrayLiveScrollTests: \($0)\n", stderr) }
            exit(1)
        }
        NSApp.terminate(nil)
    }

    /// `TR-5`: новый снимок возвращает ленту к новым. Переполненный трей обязан
    /// показывать последнюю карточку целиком и живой, а не прятать её в стопку.
    private func newestCaptureStaysReachable() {
        guard let fixture = makeOverflowingTray(label: "newest") else { return }
        defer { fixture.teardown() }

        let newest = fixture.cards[fixture.cards.count - 1]
        if newest.hostView.isHidden {
            failures.append("новейшая карточка скрыта в переполненном трее")
            return
        }
        if newest.debugOpacity < 0.999 {
            failures.append("новейшая карточка притушена: opacity=\(newest.debugOpacity)")
        }
        if !newest.debugIsInteractive {
            failures.append("новейшая карточка не принимает мышь")
        }
    }

    /// Настоящее событие прокрутки с фазами обязано двигать ленту.
    private func scrollWheelMovesCards() {
        guard let fixture = makeOverflowingTray(label: "scroll") else { return }
        defer { fixture.teardown() }

        let probe = fixture.cards[fixture.cards.count - 1]

        // Мерится максимальный ход по всем карточкам, а не по одной: карточка у
        // дальнего края стоит в стопке и сдвигается только на её шаг, тогда как
        // лента при этом едет целиком.
        // Замер делается ДО фазы `ended`: после отпускания лента возвращается
        // из-за края пружиной, и движение внутри резинки исчезло бы из итога.
        // Направление свободного хода зависит от того, где сейчас лента,
        // поэтому проверяются оба.
        func travel(_ direction: CGFloat) -> CGFloat {
            let before = fixture.cards.map(\.layoutFrame.origin)
            let point = NSPoint(x: probe.layoutFrame.midX, y: probe.layoutFrame.midY)
            post(scroll: 40 * direction, phase: .began, at: point, window: fixture.window)
            for _ in 0..<6 {
                post(scroll: 40 * direction, phase: .changed, at: point, window: fixture.window)
            }
            let after = fixture.cards.map(\.layoutFrame.origin)
            post(scroll: 0, phase: .ended, at: point, window: fixture.window)
            spin(0.4)
            return zip(before, after)
                .map { hypot($1.x - $0.x, $1.y - $0.y) }
                .max() ?? 0
        }

        let travelled = max(travel(1), travel(-1))
        if travelled < 50 {
            failures.append("прокрутка не сдвинула карточку: путь \(travelled) pt")
        }
    }

    /// Кнопка закрытия на новейшей карточке обязана удалять её и в переполненном
    /// трее: до исправления стопка делала карточки неинтерактивными.
    private func closeButtonWorksOnNewestCard() {
        guard let fixture = makeOverflowingTray(label: "close") else { return }
        defer { fixture.teardown() }

        let newest = fixture.cards[fixture.cards.count - 1]
        newest.debugShowControls()
        newest.hostView.superview?.layoutSubtreeIfNeeded()
        spin(0.05)

        let point = newest.debugCloseButtonCenterInHost()
        post(mouse: .leftMouseDown, at: point, window: fixture.window)
        spin(0.02)
        post(mouse: .leftMouseUp, at: point, window: fixture.window)
        spinUntil(1.5) {
            fixture.manager.debugFinishMotions()
            return newest.hostView.superview == nil
        }

        if newest.hostView.superview != nil {
            failures.append("кнопка закрытия новейшей карточки не сработала: \(newest.debugCloseButtonState())")
        }
    }

    /// Лента идёт за пальцами. Открытая на новых снимках, она может ехать
    /// только к старым: жест вверх (отрицательная дельта) поднимает карточки,
    /// открывая те, что лежат ближе к хабу.
    private func scrollFollowsTheGesture() {
        guard let fixture = makeOverflowingTray(label: "direction") else { return }
        defer { fixture.teardown() }

        let probe = fixture.cards[fixture.cards.count / 2]
        let point = NSPoint(x: probe.layoutFrame.midX, y: probe.layoutFrame.midY)
        // Смотрим на карточку, прошедшую наибольший путь: стоящая в стопке
        // сдвигается лишь на её шаг и о направлении ничего не говорит.
        let before = fixture.cards.map { $0.layoutFrame.origin.y }

        post(scroll: -40, phase: .began, at: point, window: fixture.window)
        for _ in 0..<4 { post(scroll: -40, phase: .changed, at: point, window: fixture.window) }
        let after = fixture.cards.map { $0.layoutFrame.origin.y }
        post(scroll: 0, phase: .ended, at: point, window: fixture.window)
        spin(0.4)

        let shift = zip(before, after).map { $1 - $0 }.max(by: { abs($0) < abs($1) }) ?? 0
        guard shift > 20 else {
            failures.append("прокрутка развёрнута или стоит: наибольший сдвиг \(shift) pt")
            return
        }
    }

    /// Щелчок колеса мыши приходит в строках, а не в точках: без пересчёта
    /// лента ползла на пиксель за щелчок.
    private func wheelNotchMovesAVisibleDistance() {
        guard let fixture = makeOverflowingTray(label: "wheel") else { return }
        defer { fixture.teardown() }

        let probe = fixture.cards[fixture.cards.count / 2]
        let point = NSPoint(x: probe.layoutFrame.midX, y: probe.layoutFrame.midY)
        let before = fixture.cards.map { $0.layoutFrame.origin }

        postWheelNotch(at: point, window: fixture.window)
        let after = fixture.cards.map { $0.layoutFrame.origin }
        let travelled = zip(before, after)
            .map { hypot($1.x - $0.x, $1.y - $0.y) }
            .max() ?? 0
        guard travelled >= 20 else {
            failures.append("щелчок колеса сдвинул ленту на \(travelled) pt")
            return
        }
    }

    /// Кнопки видны ровно на одной карточке: уехавшая из-под курсора карточка
    /// `mouseExited` не получает, и её кнопки оставались висеть.
    private func hoverStaysOnASingleCard() {
        guard let fixture = makeOverflowingTray(label: "hover") else { return }
        defer { fixture.teardown() }

        for card in fixture.cards { card.debugShowControls() }
        let probe = fixture.cards[fixture.cards.count / 2]
        let point = NSPoint(x: probe.layoutFrame.midX, y: probe.layoutFrame.midY)
        post(scroll: 40, phase: .began, at: point, window: fixture.window)
        for _ in 0..<4 { post(scroll: 40, phase: .changed, at: point, window: fixture.window) }
        post(scroll: 0, phase: .ended, at: point, window: fixture.window)
        spin(0.4)

        let visible = fixture.cards.filter { $0.debugControlsVisible }
        guard visible.count <= 1 else {
            failures.append("кнопки видны сразу на \(visible.count) карточках")
            return
        }
    }

    /// Зазор между карточками — часть трея. Пустота обязана пропускать клики
    /// насквозь, поэтому `hitTest` там возвращает nil, и жест прокрутки на
    /// зазоре обрывался.
    private func scrollWorksInTheGapBetweenCards() {
        guard let fixture = makeOverflowingTray(label: "gap") else { return }
        defer { fixture.teardown() }

        // Точка ровно между двумя соседними видимыми карточками.
        let frames = fixture.cards
            .filter { !$0.hostView.isHidden }
            .map { $0.debugCardFrame }
            .sorted { $0.minY < $1.minY }
        guard frames.count >= 2 else {
            failures.append("в ленте меньше двух видимых карточек")
            return
        }
        var gapPoint: NSPoint?
        for (lower, upper) in zip(frames, frames.dropFirst()) where upper.minY - lower.maxY > 4 {
            gapPoint = NSPoint(x: lower.midX, y: (lower.maxY + upper.minY) / 2)
            break
        }
        guard let point = gapPoint else {
            failures.append("не нашёл зазора между карточками")
            return
        }
        if fixture.cards.contains(where: { $0.debugCardFrame.contains(point) }) {
            failures.append("точка замера попала на карточку, а не в зазор")
            return
        }

        let before = fixture.cards.map { $0.layoutFrame.origin }
        post(scroll: -40, phase: .began, at: point, window: fixture.window)
        for _ in 0..<4 { post(scroll: -40, phase: .changed, at: point, window: fixture.window) }
        let after = fixture.cards.map { $0.layoutFrame.origin }
        post(scroll: 0, phase: .ended, at: point, window: fixture.window)
        spin(0.4)

        let travelled = zip(before, after).map { hypot($1.x - $0.x, $1.y - $0.y) }.max() ?? 0
        guard travelled >= 20 else {
            failures.append("прокрутка в зазоре не сдвинула ленту: \(travelled) pt")
            return
        }
    }

    /// Инерция: система досылает события после отпускания пальцев, и лента
    /// обязана продолжать движение. Карточки при этом уезжают из-под курсора,
    /// поэтому доставка не может зависеть от того, что под ним сейчас.
    private func momentumKeepsMovingTheStrip() {
        guard let fixture = makeOverflowingTray(label: "momentum") else { return }
        defer { fixture.teardown() }

        let probe = fixture.cards[fixture.cards.count / 2]
        let point = NSPoint(x: probe.layoutFrame.midX, y: probe.layoutFrame.midY)
        post(scroll: -40, phase: .began, at: point, window: fixture.window)
        post(scroll: -40, phase: .changed, at: point, window: fixture.window)
        post(scroll: 0, phase: .ended, at: point, window: fixture.window)

        let before = fixture.cards.map { $0.layoutFrame.origin }
        for _ in 0..<5 { postMomentum(scroll: -30, at: point, window: fixture.window) }
        let after = fixture.cards.map { $0.layoutFrame.origin }
        postMomentumEnd(at: point, window: fixture.window)
        spin(0.4)

        let travelled = zip(before, after).map { hypot($1.x - $0.x, $1.y - $0.y) }.max() ?? 0
        guard travelled >= 20 else {
            failures.append("инерция не двигает ленту: \(travelled) pt")
            return
        }
    }

    // MARK: окружение

    private struct Fixture {
        let manager: ThumbnailManager
        let store: CaptureArtifactStore
        let cards: [ThumbnailWindow]
        let window: NSWindow
        let teardown: () -> Void
    }

    /// Трей, в котором карточек заведомо больше, чем помещается на экран.
    private func makeOverflowingTray(label: String) -> Fixture? {
        guard let screen = NSScreen.main else {
            failures.append("\(label): нет экрана")
            return nil
        }
        TrayPosition.set(.right)
        let store = CaptureArtifactStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickShotTrayLive-\(UUID().uuidString)"))
        let manager = ThumbnailManager(artifactStore: store)

        // Высота карточки при ширине 240 — около 150 pt; берём столько снимков,
        // чтобы лента гарантированно переполнила экран любой высоты.
        let count = Int(screen.frame.height / 120) + 4
        var cards: [ThumbnailWindow] = []
        for index in 0..<count {
            let sequence = CaptureSequence(rawValue: UInt64(index + 1))
            store.registerCapture(sequence)
            guard let image = makeImage(width: 360, height: 220),
                  let artifact = try? store.admit(sequence: sequence, image: image) else {
                failures.append("\(label): снимок \(index) не создан")
                manager.shutdown()
                store.shutdown()
                return nil
            }
            manager.add(artifact: artifact, on: screen)
            manager.debugFinishMotions()
            guard let card = manager.debugThumbnail(for: artifact.id) else {
                failures.append("\(label): карточка \(index) не появилась")
                manager.shutdown()
                store.shutdown()
                return nil
            }
            cards.append(card)
        }
        spin(0.1)
        manager.debugFinishMotions()

        guard let window = cards.last?.hostView.window else {
            failures.append("\(label): у трея нет окна")
            manager.shutdown()
            store.shutdown()
            return nil
        }
        guard manager.debugScrollIsActive else {
            failures.append("\(label): лента не переполнилась при \(count) снимках")
            manager.shutdown()
            store.shutdown()
            return nil
        }
        return Fixture(manager: manager, store: store, cards: cards, window: window) {
            manager.shutdown()
            store.shutdown()
        }
    }

    /// Событие прокрутки с фазой: обычный `NSEvent.mouseEvent` его не создаёт,
    /// а без фазы трей считает жест колесом и не включает резинку.
    private func post(scroll delta: CGFloat,
                      phase: CGScrollPhase,
                      at windowPoint: NSPoint,
                      window: NSWindow) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 1,
                               wheel1: Int32(delta),
                               wheel2: 0,
                               wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        // CGEvent живёт в экранных координатах с началом в верхнем левом углу.
        let flipped = CGPoint(x: screenPoint.x,
                              y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y)
        cg.location = flipped
        guard let event = NSEvent(cgEvent: cg) else { return }
        window.sendEvent(event)
    }

    /// Инерционное событие: пальцы уже отпущены, фаза жеста пуста.
    private func postMomentum(scroll delta: CGFloat, at windowPoint: NSPoint, window: NSWindow) {
        postScroll(delta: delta,
                   scrollPhase: 0,
                   momentumPhase: Int64(CGMomentumScrollPhase.continuous.rawValue),
                   at: windowPoint,
                   window: window)
    }

    private func postMomentumEnd(at windowPoint: NSPoint, window: NSWindow) {
        postScroll(delta: 0,
                   scrollPhase: 0,
                   momentumPhase: Int64(CGMomentumScrollPhase.end.rawValue),
                   at: windowPoint,
                   window: window)
    }

    private func postScroll(delta: CGFloat,
                            scrollPhase: Int64,
                            momentumPhase: Int64,
                            at windowPoint: NSPoint,
                            window: NSWindow) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 1,
                               wheel1: Int32(delta),
                               wheel2: 0,
                               wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        cg.location = CGPoint(x: screenPoint.x,
                              y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y)
        guard let event = NSEvent(cgEvent: cg) else { return }
        window.sendEvent(event)
    }

    /// Щелчок колеса мыши: без фаз и без точных дельт, значение в строках.
    private func postWheelNotch(at windowPoint: NSPoint, window: NSWindow) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .line,
                               wheelCount: 1,
                               wheel1: -1,
                               wheel2: 0,
                               wheel3: 0) else { return }
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        cg.location = CGPoint(x: screenPoint.x,
                              y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y)
        guard let event = NSEvent(cgEvent: cg) else { return }
        window.sendEvent(event)
    }

    private func post(mouse type: NSEvent.EventType, at windowPoint: NSPoint, window: NSWindow) {
        guard let event = NSEvent.mouseEvent(with: type,
                                             location: windowPoint,
                                             modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber,
                                             context: nil,
                                             eventNumber: 0,
                                             clickCount: 1,
                                             pressure: type == .leftMouseDown ? 1 : 0) else { return }
        window.sendEvent(event)
    }

    private func makeImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func spinUntil(_ timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

@main
private struct TrayLiveScrollRunner {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = TrayLiveScrollTests()
        app.delegate = delegate
        app.run()
    }
}
