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
/// Обходит область с заданным шагом и считает, сколько её пикселей закрашено
/// синим фикстуры. Оба живых прогона трея сканировали её одинаково, а
/// вложенные циклы с проверкой границ давали пять уровней вложенности.
@MainActor
private func sampleFixtureBlue(rep: NSBitmapImageRep,
                               host: NSView,
                               rect: NSRect,
                               step: CGFloat) -> (sampled: Int, painted: Int) {
    let scaleX = CGFloat(rep.pixelsWide) / host.bounds.width
    let scaleY = CGFloat(rep.pixelsHigh) / host.bounds.height
    var sampled = 0
    var painted = 0
    var y = rect.minY
    while y < rect.maxY {
        var x = rect.minX
        while x < rect.maxX {
            let px = Int(x * scaleX)
            // rep хранит строки сверху вниз, host не перевёрнут.
            let py = Int((host.bounds.height - y) * scaleY)
            if let colour = pixel(rep, x: px, y: py) {
                sampled += 1
                if isFixtureBlue(colour) { painted += 1 }
            }
            x += step
        }
        y += step
    }
    return (sampled, painted)
}

/// Цвет пикселя, если он внутри буфера.
@MainActor
private func pixel(_ rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
    guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
    return rep.colorAt(x: x, y: y)
}

/// Снимок в фикстуре — синяя заливка: пиксель карточки обязан быть заметно
/// синим и непрозрачным. Проверка повторялась в двух прогонах дословно.
private func isFixtureBlue(_ colour: NSColor) -> Bool {
    colour.alphaComponent > 0.5
        && colour.blueComponent > 0.4
        && colour.blueComponent > colour.redComponent + 0.1
}

@MainActor
private final class TrayLiveScrollTests: NSObject, NSApplicationDelegate {
    private var failures: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.environment["QUICKSHOT_DUMP_TRAY"] == "1" {
            dumpTrayStates()
            NSApp.terminate(nil)
            return
        }
        cardSurvivesADisplayPass()
        newestCaptureStaysReachable()
        scrollWheelMovesCards()
        closeButtonWorksOnNewestCard()
        scrollFollowsTheGesture()
        wheelNotchMovesAVisibleDistance()
        hoverStaysOnASingleCard()
        scrollWorksInTheGapBetweenCards()
        momentumKeepsMovingTheStrip()
        overscrollCollectsAllCards()
        gestureNeverHidesTheTray()
        captureWhileCompressedStaysCompressed()
        captureWhileUnrolledRevealsTheNewest()
        stackEdgesShowContentAfterADisplayPass()
        stackEdgeCornersStayRoundedAfterADisplayPass()

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
        // Кадры стопки законно перекрываются с опускающейся карточкой, поэтому
        // сосед по сортировке — ещё не зазор: кандидат обязан быть не накрыт
        // ни одной карточкой.
        var gapPoint: NSPoint?
        for (lower, upper) in zip(frames, frames.dropFirst()) where upper.minY - lower.maxY > 4 {
            let candidate = NSPoint(x: lower.midX, y: (lower.maxY + upper.minY) / 2)
            if !frames.contains(where: { $0.contains(candidate) }) {
                gapPoint = candidate
                break
            }
        }
        guard let point = gapPoint else {
            failures.append("не нашёл зазора между карточками")
            return
        }
        // Скрытые карточки сохраняют последний кадр где попало — точку зазора
        // проверяем только против видимых.
        if fixture.cards.contains(where: { !$0.hostView.isHidden && $0.debugCardFrame.contains(point) }) {
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

    /// Карточка обязана показывать пиксели снимка ПОСЛЕ прохода отрисовки.
    /// Проход идёт в конце оборота run loop, и именно он затирал картинку,
    /// положенную руками в layer.contents: проверки, читающие состояние сразу
    /// после размещения, оставались зелёными, а экран показывал одну тень.
    private func cardSurvivesADisplayPass() {
        guard let screen = NSScreen.main else {
            failures.append("display-pass: нет экрана")
            return
        }
        TrayPosition.set(.right)
        let store = CaptureArtifactStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickShotDisplayPass-\(UUID().uuidString)"))
        let manager = ThumbnailManager(artifactStore: store)
        defer {
            manager.shutdown()
            store.shutdown()
        }
        let sequence = CaptureSequence(rawValue: 1)
        store.registerCapture(sequence)
        guard let image = makeImage(width: 360, height: 220),
              let artifact = try? store.admit(sequence: sequence, image: image) else {
            failures.append("display-pass: снимок не создан")
            return
        }
        manager.add(artifact: artifact, on: screen)
        manager.debugFinishMotions()
        guard let card = manager.debugThumbnail(for: artifact.id),
              let window = card.hostView.window else {
            failures.append("display-pass: карточка не появилась")
            return
        }

        // Настоящий проход отрисовки: тот самый триггер, который стирал картинку.
        card.hostView.needsDisplay = true
        window.displayIfNeeded()
        spin(0.15)
        window.displayIfNeeded()

        let frame = card.debugCardFrame
        let inner = frame.insetBy(dx: frame.width * 0.25, dy: frame.height * 0.25)
        guard let host = window.contentView,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            failures.append("display-pass: нет буфера отображения")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let (sampled, painted) = sampleFixtureBlue(rep: rep, host: host, rect: inner, step: 4)
        guard sampled > 50 else {
            failures.append("display-pass: рамка карточки вне буфера (\(sampled) точек)")
            return
        }
        if Double(painted) / Double(sampled) < 0.5 {
            failures.append("display-pass: после прохода отрисовки карточка пуста — "
                + "закрашено \(painted) из \(sampled) точек")
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

    /// `TR-4a`: перетягивание к кнопке собирает ВСЕ карточки в стопку —
    /// новейшая лежит целиком сверху, остальные видны кромками не выше 7pt.
    private func overscrollCollectsAllCards() {
        guard let fixture = makeOverflowingTray(label: "collect") else { return }
        defer { fixture.teardown() }
        guard compress(fixture, label: "collect") else { return }

        let newest = fixture.cards[fixture.cards.count - 1]
        if newest.hostView.isHidden || newest.debugOpacity < 0.999 {
            failures.append("collect: новейшая карточка не видна на вершине стопки")
        }
        let newestFrame = newest.debugCardFrame
        if newestFrame.height < 100 {
            failures.append("collect: новейшая карточка сжата: высота \(newestFrame.height)")
        }
        // Кромки — целые карточки, ушедшие под верхнюю: из-под её низа торчат
        // ярусы по 7pt, наверху не торчит ничего.
        let edge = TrayStripLayout.edgeLength
        var visibleEdges = 0
        for (index, card) in fixture.cards.enumerated() where index != fixture.cards.count - 1 {
            guard !card.hostView.isHidden else { continue }
            visibleEdges += 1
            let frame = card.debugCardFrame
            if frame.maxY > newestFrame.maxY + 0.5 {
                failures.append("collect: карточка \(index) торчит над стопкой: \(frame.maxY)")
            }
            let protrusion = newestFrame.minY - frame.minY
            if protrusion < edge - 1.5 || protrusion > 2 * edge + 1.5 {
                failures.append("collect: выступ карточки \(index) не на ярусе: \(protrusion)")
            }
        }
        if visibleEdges == 0 {
            failures.append("collect: у стопки нет ни одной кромки")
        }
    }

    /// Жест прокрутки никогда не прячет и не показывает трей: перетягивание за
    /// край только пружинит, сворачивание — исключительно клик по кнопке.
    private func gestureNeverHidesTheTray() {
        guard let fixture = makeOverflowingTray(label: "no-collapse") else { return }
        defer { fixture.teardown() }
        let point = NSPoint(x: fixture.cards[0].layoutFrame.midX,
                            y: fixture.cards[0].layoutFrame.midY)
        for sign in [CGFloat(1), -1] {
            post(scroll: 300 * sign, phase: .began, at: point, window: fixture.window)
            for _ in 0..<10 {
                post(scroll: 300 * sign, phase: .changed, at: point, window: fixture.window)
            }
            post(scroll: 0, phase: .ended, at: point, window: fixture.window)
            spin(0.4)
            if fixture.manager.debugIsCollapsed {
                failures.append("no-collapse: жест свернул трей")
            }
            if !fixture.window.isVisible {
                failures.append("no-collapse: окно трея исчезло после жеста")
            }
            if !fixture.cards.contains(where: { !$0.hostView.isHidden }) {
                failures.append("no-collapse: все карточки скрылись после жеста")
            }
        }
    }

    /// `TR-5`: вставка в собранную стопку молча кладёт новый снимок верхним
    /// элементом, лента остаётся полностью сжатой.
    private func captureWhileCompressedStaysCompressed() {
        guard let fixture = makeOverflowingTray(label: "insert-compressed") else { return }
        defer { fixture.teardown() }
        guard compress(fixture, label: "insert-compressed") else { return }

        let previousNewest = fixture.cards[fixture.cards.count - 1]
        guard let added = addCapture(to: fixture, label: "insert-compressed") else { return }

        let offset = fixture.manager.debugScrollOffset
        let maximum = fixture.manager.debugMaximumScrollOffset
        if offset < maximum - 1 {
            failures.append("insert-compressed: лента раскрылась: \(offset) из \(maximum)")
        }
        if added.hostView.isHidden || added.debugCardFrame.height < 100 {
            failures.append("insert-compressed: новый снимок не лёг целиком поверх стопки")
        }
        if !previousNewest.hostView.isHidden {
            let prev = previousNewest.debugCardFrame
            let addedFrame = added.debugCardFrame
            if prev.maxY > addedFrame.maxY + 0.5 {
                failures.append("insert-compressed: прежняя верхняя торчит над новой: \(prev.maxY)")
            }
            let protrusion = addedFrame.minY - prev.minY
            if abs(protrusion - TrayStripLayout.edgeLength) > 1.5 {
                failures.append("insert-compressed: прежняя верхняя не ушла на ярус кромки: "
                                + "выступ \(protrusion)")
            }
        }
    }

    /// `TR-5`: вставка в развёрнутую ленту докручивает её ровно до видимости
    /// нового снимка.
    private func captureWhileUnrolledRevealsTheNewest() {
        guard let fixture = makeOverflowingTray(label: "insert-unrolled") else { return }
        defer { fixture.teardown() }

        // Увести ленту к старым снимкам: новейший гарантированно за границей.
        let point = NSPoint(x: fixture.window.frame.width / 2,
                            y: fixture.window.frame.height / 2)
        let base = fixture.manager.debugScrollOffset
        postScroll(delta: 40, scrollPhase: 0, momentumPhase: 0, at: point, window: fixture.window)
        let sign: CGFloat = fixture.manager.debugScrollOffset > base ? -1 : 1
        for _ in 0..<40 {
            postScroll(delta: 300 * sign, scrollPhase: 0, momentumPhase: 0,
                       at: point, window: fixture.window)
        }
        spin(0.1)
        if fixture.manager.debugScrollOffset > 0.5 {
            failures.append("insert-unrolled: лента не увелась к старым снимкам: "
                            + "\(fixture.manager.debugScrollOffset)")
            return
        }

        guard let added = addCapture(to: fixture, label: "insert-unrolled") else { return }
        if added.hostView.isHidden {
            failures.append("insert-unrolled: новый снимок не показан после вставки")
            return
        }
        if added.debugCardFrame.height < 100 {
            failures.append("insert-unrolled: новый снимок срезан: высота \(added.debugCardFrame.height)")
        }
        let screenLimit = (NSScreen.main?.frame.maxY ?? 0)
        if added.debugCardFrame.maxY > screenLimit {
            failures.append("insert-unrolled: новый снимок за экраном: \(added.debugCardFrame.maxY)")
        }
    }

    /// `TR-24`, `TR-25`: после НАСТОЯЩЕГО прохода отрисовки кромки собранной
    /// стопки закрашены содержимым снимков, а карточки разной высоты не
    /// выламывают силуэт — выше второй кромки пусто.
    private func stackEdgesShowContentAfterADisplayPass() {
        guard let fixture = makeOverflowingTray(label: "edges",
                                                imageHeight: { [160, 260, 220, 300][$0 % 4] })
        else { return }
        defer { fixture.teardown() }
        guard compress(fixture, label: "edges") else { return }

        let newest = fixture.cards[fixture.cards.count - 1]
        newest.hostView.needsDisplay = true
        fixture.window.displayIfNeeded()
        spin(0.15)
        fixture.window.displayIfNeeded()

        guard let host = fixture.window.contentView,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            failures.append("edges: нет буфера отображения")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / host.bounds.height
        let frame = newest.debugCardFrame

        // Доля закрашенных содержимым точек вдоль строки в центральной части
        // ширины карточки: срез снимка в фикстуре — синяя заливка.
        func paintedRatio(atY y: CGFloat) -> Double {
        let (sampled, painted) = sampleFixtureBlue(rep: rep, host: host, rect: inner, step: 2)
            return sampled > 0 ? Double(painted) / Double(sampled) : 0
        }

        // Кромки лежат между кнопкой и карточкой: слоты — константы под её
        // нижним краем.
        let e = TrayStripLayout.edgeLength
        let first = paintedRatio(atY: frame.minY - e * 0.5)
        if first < 0.5 {
            failures.append("edges: первая кромка пуста после прохода отрисовки: \(first)")
        }
        let second = paintedRatio(atY: frame.minY - e * 1.5)
        if second < 0.5 {
            failures.append("edges: вторая кромка пуста после прохода отрисовки: \(second)")
        }
        let below = paintedRatio(atY: frame.minY - e * 2 - 4)
        if below > 0.05 {
            failures.append("edges: ниже второй кромки торчит содержимое: \(below)")
        }
        let above = paintedRatio(atY: frame.maxY + 4)
        if above > 0.05 {
            failures.append("edges: над собранной стопкой торчит содержимое: \(above)")
        }
    }

    /// Углы кромок скруглены ПОСЛЕ настоящего прохода отрисовки: скругление
    /// живёт на обычном вью-обёртке, а не на слое NSImageView — тот владеет
    /// своим слоем сам и сбрасывает чужие маски при отрисовке.
    private func stackEdgeCornersStayRoundedAfterADisplayPass() {
        guard let fixture = makeOverflowingTray(label: "corners") else { return }
        defer { fixture.teardown() }
        guard compress(fixture, label: "corners") else { return }

        let edge = fixture.cards[fixture.cards.count - 2]
        edge.hostView.needsDisplay = true
        fixture.window.displayIfNeeded()
        spin(0.15)
        fixture.window.displayIfNeeded()

        guard let host = fixture.window.contentView,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            failures.append("corners: нет буфера отображения")
            return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scaleX = CGFloat(rep.pixelsWide) / host.bounds.width
        let scaleY = CGFloat(rep.pixelsHigh) / host.bounds.height

        func isPainted(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let px = Int(x * scaleX)
            let py = Int((host.bounds.height - y) * scaleY)
            guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh,
                  let colour = rep.colorAt(x: px, y: py) else { return false }
            return colour.alphaComponent > 0.5 && colour.blueComponent > 0.4
                && colour.blueComponent > colour.redComponent + 0.1
        }

        let frame = edge.debugCardFrame
        if !isPainted(frame.midX, frame.minY + 1.5) {
            failures.append("corners: середина нижнего края кромки пуста — замер не на кромке")
            return
        }
        if isPainted(frame.minX + 1.5, frame.minY + 1.5) {
            failures.append("corners: левый нижний угол кромки закрашен — скругление потеряно")
        }
        if isPainted(frame.maxX - 1.5, frame.minY + 1.5) {
            failures.append("corners: правый нижний угол кромки закрашен — скругление потеряно")
        }
    }

    /// Служебный дамп живого рендера трея в PNG для просмотра глазами:
    /// состояние покоя, середина наезда и полное сжатие.
    private func dumpTrayStates() {
        guard let fixture = makeOverflowingTray(label: "dump") else { return }
        defer { fixture.teardown() }
        let point = NSPoint(x: fixture.window.frame.width / 2,
                            y: fixture.window.frame.height / 2)
        let base = fixture.manager.debugScrollOffset
        postScroll(delta: 40, scrollPhase: 0, momentumPhase: 0, at: point, window: fixture.window)
        let sign: CGFloat = fixture.manager.debugScrollOffset > base ? 1 : -1

        func dump(_ name: String) {
            fixture.window.displayIfNeeded()
            spin(0.2)
            fixture.window.displayIfNeeded()
            guard let host = fixture.window.contentView,
                  let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/tray-live-\(name).png"))
                print("dumped /tmp/tray-live-\(name).png offset=\(fixture.manager.debugScrollOffset)")
            }
        }

        // Продвинуться до середины ленты и остановиться в произвольной фазе.
        for _ in 0..<3 {
            postScroll(delta: 137 * sign, scrollPhase: 0, momentumPhase: 0,
                       at: point, window: fixture.window)
        }
        dump("mid")
        for _ in 0..<2 {
            postScroll(delta: 61 * sign, scrollPhase: 0, momentumPhase: 0,
                       at: point, window: fixture.window)
        }
        dump("phase")
        while fixture.manager.debugScrollOffset < fixture.manager.debugMaximumScrollOffset - 0.5 {
            postScroll(delta: 300 * sign, scrollPhase: 0, momentumPhase: 0,
                       at: point, window: fixture.window)
        }
        dump("full")
    }

    /// Дожать ленту до полного сбора: направление определяется по факту роста
    /// смещения, колёсные события без фаз упираются в край без резинки.
    private func compress(_ fixture: Fixture, label: String) -> Bool {
        let point = NSPoint(x: fixture.window.frame.width / 2,
                            y: fixture.window.frame.height / 2)
        let base = fixture.manager.debugScrollOffset
        postScroll(delta: 40, scrollPhase: 0, momentumPhase: 0, at: point, window: fixture.window)
        let sign: CGFloat = fixture.manager.debugScrollOffset > base ? 1 : -1
        var attempts = 0
        while fixture.manager.debugScrollOffset < fixture.manager.debugMaximumScrollOffset - 0.5,
              attempts < 200 {
            postScroll(delta: 300 * sign, scrollPhase: 0, momentumPhase: 0,
                       at: point, window: fixture.window)
            attempts += 1
        }
        spin(0.1)
        if fixture.manager.debugScrollOffset < fixture.manager.debugMaximumScrollOffset - 0.5 {
            failures.append("\(label): лента не дожалась до полного сбора: "
                            + "\(fixture.manager.debugScrollOffset) из \(fixture.manager.debugMaximumScrollOffset)")
            return false
        }
        return true
    }

    /// Новый снимок через настоящий магазин артефактов: как из захвата.
    private func addCapture(to fixture: Fixture, label: String) -> ThumbnailWindow? {
        guard let screen = NSScreen.main else { return nil }
        let sequence = CaptureSequence(rawValue: UInt64(1000 + fixture.cards.count))
        fixture.store.registerCapture(sequence)
        guard let image = makeImage(width: 360, height: 220),
              let artifact = try? fixture.store.admit(sequence: sequence, image: image) else {
            failures.append("\(label): новый снимок не создан")
            return nil
        }
        fixture.manager.add(artifact: artifact, on: screen)
        fixture.manager.debugFinishMotions()
        spin(0.1)
        guard let card = fixture.manager.debugThumbnail(for: artifact.id) else {
            failures.append("\(label): карточка нового снимка не появилась")
            return nil
        }
        return card
    }

    /// Трей, в котором карточек заведомо больше, чем помещается на экран.
    /// `imageHeight` задаёт высоту снимка по индексу: тесты силуэта собирают
    /// стопку из карточек разной высоты.
    private func makeOverflowingTray(label: String,
                                     imageHeight: (Int) -> Int = { _ in 220 }) -> Fixture? {
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
            guard let image = makeImage(width: 360, height: imageHeight(index)),
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
        // Дамп со светлыми карточками воспроизводит реальные скриншоты: форму
        // светлой кромки на светлом фоне рисует только тень.
        if ProcessInfo.processInfo.environment["QUICKSHOT_DUMP_WHITE"] == "1" {
            context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1))
        } else {
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        }
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
