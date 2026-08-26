import AppKit
import Darwin

@MainActor
@main
struct NativeSurfaceBehaviorTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)

        run("House metrics come from Native SDK", testHouseMetrics)
        run("floating surfaces have transparent canvas gaps", testFloatingSurfaceTransparency)
        run("thumbnail controls fit, hover, and click", testThumbnailControls)
        run("case panel lays out without overlap", testCasePanelLayout)
        run("pinned copy control fits, hovers, and clicks", testPinnedControl)
        run("settings controls fit, hover, and dispatch", testSettingsControls)

        print("NativeSurfaceBehaviorTests: passed")
    }

    private static func run(_ name: String, _ test: () throws -> Void) {
        do {
            try test()
        } catch {
            fputs("NativeSurfaceBehaviorTests: \(name) failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func testHouseMetrics() throws {
        let expected: [(NativeSDKMetric, CGFloat)] = [
            (.controlHeight, 28),
            (.controlRadius, 8),
            (.controlInset, 10),
            (.iconSide, 16),
            (.iconGap, 6),
            (.buttonFontSize, 14),
            (.groupGap, 8),
            (.shellInset, 6),
            (.bubbleRadius, 14),
            (.animationDurationMilliseconds, 120),
            (.reducedAnimationDurationMilliseconds, 0),
        ]
        for (metric, value) in expected {
            let actual = CGFloat(quickshot_native_ui_metric(metric.rawValue))
            try require(abs(actual - value) <= 0.001,
                        "\(metric) drifted from pinned House tokens: \(actual) != \(value)")
        }
    }

    private static func testFloatingSurfaceTransparency() throws {
        let copyView = NativeThumbnailButtonView(kind: .copy)
        _ = Host(view: copyView, size: copyView.fittingSize)
        let copyButtons = copyView.debugButtons()
        try require(alpha(copyView.debugPixel(at: NSPoint(x: 1, y: 1))) == 0,
                    "Thumbnail canvas corner must be transparent")
        try require(alpha(copyView.debugPixel(at: center(of: copyButtons[0].frame))) > 0,
                    "Thumbnail button pixels must remain visible")

        let dismissView = NativeThumbnailButtonView(kind: .dismiss)
        _ = Host(view: dismissView, size: dismissView.fittingSize)
        let dismissButtons = dismissView.debugButtons()
        try require(alpha(dismissView.debugPixel(at: NSPoint(x: 1, y: 1))) == 0,
                    "Dismiss canvas corner must be transparent")
        try require(alpha(dismissView.debugPixel(at: center(of: dismissButtons[0].frame))) > 0,
                    "Dismiss button pixels must remain visible")

        let pinned = NativePinnedCopyButtonView(frame: .zero)
        _ = Host(view: pinned, size: pinned.fittingSize)
        try require(alpha(pinned.debugPixel(at: NSPoint(x: 1, y: 1))) == 0,
                    "Pinned-control canvas corner must be transparent")
        try require(alpha(pinned.debugPixel(at: center(of: pinned.debugButtons()[0].frame))) > 0,
                    "Pinned button pixels must remain visible")

        let settings = NativeSettingsContentView(frame: .zero)
        _ = Host(view: settings, size: settings.fittingSize)
        try require(alpha(settings.debugPixel(at: NSPoint(x: 1, y: 1))) == 255,
                    "Settings canvas must remain an opaque application surface")
    }

    private static func testThumbnailControls() throws {
        let copyView = NativeThumbnailButtonView(kind: .copy)
        var copyCount = 0
        copyView.onPress = { copyCount += 1 }
        let host = Host(view: copyView, size: copyView.fittingSize)

        let buttons = copyView.debugButtons()
        try require(buttons.map(\.title) == ["Copy screenshot"],
                    "Unexpected copy control: \(buttons.map(\.title))")
        try require(buttons.map(\.identifier) == ["Copy screenshot"],
                    "Copy identifier is not stable: \(buttons.map(\.identifier))")
        try requireContainedAndSeparated(buttons, in: copyView.bounds, context: "thumbnail copy")

        let copyFrame = buttons[0].frame
        let pixelProbes = stride(from: copyView.bounds.minX, through: copyView.bounds.maxX - 1, by: 2).flatMap { x in
            stride(from: copyView.bounds.minY, through: copyView.bounds.maxY - 1, by: 2).map { y in NSPoint(x: x, y: y) }
        }
        let restPixels = pixelProbes.map(copyView.debugPixel)
        copyView.debugHoverButton(title: "Copy screenshot")
        try require(copyView.debugButtons().filter(\.isHovered).map(\.title) == ["Copy screenshot"],
                    "Native SDK did not own thumbnail hover")
        let hoverPixels = pixelProbes.map(copyView.debugPixel)
        try require(hoverPixels != restPixels, "Thumbnail hover state did not repaint control pixels")

        let press = try host.press(copyFrame, in: copyView)
        try require(copyView.debugButtons().filter(\.isPressed).map(\.title) == ["Copy screenshot"],
                    "Native SDK did not own thumbnail pressed state")
        let pressedPixels = pixelProbes.map(copyView.debugPixel)
        try require(pressedPixels != hoverPixels, "Thumbnail pressed state did not repaint control pixels")
        host.release(press)
        try require(copyCount == 1, "Copy click dispatched the wrong thumbnail action")

        // Кнопки карточки непрозрачны в ЛЮБОМ состоянии (`TR-28`): гашение
        // фона под курсором читалось как прозрачность.
        try require(alpha(copyView.debugPixel(at: center(of: copyFrame))) == 255,
                    "Copy button must stay opaque while hovered")

        let dismissView = NativeThumbnailButtonView(kind: .dismiss)
        var dismissCount = 0
        dismissView.onPress = { dismissCount += 1 }
        let dismissHost = Host(view: dismissView, size: dismissView.fittingSize)
        let dismissButtons = dismissView.debugButtons()
        try require(dismissButtons.map(\.identifier) == ["Dismiss screenshot"],
                    "Dismiss identifier is not stable: \(dismissButtons.map(\.identifier))")
        dismissView.debugHoverButton(title: "Dismiss screenshot")
        try require(alpha(dismissView.debugPixel(at: center(of: dismissButtons[0].frame))) == 255,
                    "Dismiss button must stay opaque while hovered")
        try dismissHost.click(dismissButtons[0].frame, in: dismissView)
        try require(dismissCount == 1 && copyCount == 1,
                    "Dismiss click dispatched the wrong thumbnail action")
    }

    /// Панель шкатулки (`TR-43`): свёрнутая – одна пилюля со счётчиком,
    /// раскрытая – пилюля и три команды, без наложений и целиком внутри
    /// измеренного размера. Растянутая на всю ширину панель рисовала ряд у
    /// левого края и сминала кнопки – приёмка 19.08.2026.
    private static func testCasePanelLayout() throws {
        let panel = NativeCasePanelView(frame: .zero)
        panel.setCount(4)
        let size = panel.fittingSize
        let pill = panel.pillSize
        panel.frame = NSRect(origin: .zero, size: size)
        _ = Host(view: panel, size: size)
        // `TR-43`: свёрнутая панель показывает только пилюлю со счётчиком.
        let collapsed = panel.debugButtons()
        try require(collapsed.count == 1,
                    "свёрнутая панель обязана показывать одну пилюлю: \(collapsed.map(\.title))")
        try require(collapsed[0].identifier == "Screenshot count",
                    "пилюля обязана быть счётчиком: \(collapsed[0].identifier)")
        try requireContainedAndSeparated(collapsed, in: panel.bounds, context: "case pill")

        // Клик по пилюле открывает ряд команд и растит панель по высоте.
        panel.debugToggleCommands()
        let expandedSize = panel.fittingSize
        try require(expandedSize.height > size.height,
                    "раскрытая панель обязана быть выше свёрнутой: \(size.height) → \(expandedSize.height)")
        try require(expandedSize.height > size.height * 1.5,
                    "панель обязана вместить меню: \(size.height) → \(expandedSize.height)")

        // Размер ПИЛЮЛИ от меню не зависит: по нему шкатулка строит свою
        // полосу, и если он растёт вместе с меню, шкатулка раздувается при
        // каждом открытии (приёмка 24.08.2026).
        try require(panel.pillSize == pill,
                    "пилюля обязана сохранить размер: \(pill) → \(panel.pillSize)")

        // Меню обязано ЛОВИТЬ МЫШЬ. Пункт меню несёт свою роль, отличную от
        // кнопки, и фильтр по одной роли кнопки оставлял его вне попадания:
        // меню рисовалось, но не нажималось.
        panel.frame = NSRect(origin: .zero, size: expandedSize)
        let host = Host(view: panel, size: expandedSize)
        // Рамка выросла – вёрстка обязана лечь в неё до того, как с неё
        // снимают кнопки: иначе они берутся от прежнего, тесного размера.
        // Шкатулка ставит `needsLayout` вместе с рамкой – здесь так же.
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        let expanded = panel.debugButtons()
        try require(expanded.map(\.title) == ["Screenshot count", "Copy", "Download", "Clear all"],
                    "раскрытая панель обязана отдать пилюлю и три команды: \(expanded.map(\.title))")
        try requireContainedAndSeparated(expanded, in: panel.bounds, context: "case menu",
                                         buttonRegister: false)

        var copied = 0
        panel.onCopyAll = { copied += 1 }
        guard let copyItem = expanded.first(where: { $0.title == "Copy" }) else {
            throw Failure("пункт Copy не найден")
        }
        host.clickDirectly(copyItem.frame, in: panel)
        try require(copied == 1, "клик по пункту меню обязан сработать: \(copied)")

        // Выбор команды сам закрывает меню: держать его открытым после
        // выполненного действия незачем, и панель возвращается к пилюле.
        try require(panel.fittingSize.height == size.height,
                    "после команды панель обязана вернуться к прежней высоте: \(panel.fittingSize.height)")
        try require(panel.debugButtons().map(\.title) == ["Screenshot count"],
                    "после команды обязана остаться одна пилюля: \(panel.debugButtons().map(\.title))")
    }

    private static func testPinnedControl() throws {
        let view = NativePinnedCopyButtonView(frame: .zero)
        var copyCount = 0
        view.onCopy = { copyCount += 1 }
        let host = Host(view: view, size: view.fittingSize)
        let buttons = view.debugButtons()

        try require(buttons.map(\.title) == ["Copy screenshot"], "Pinned surface must expose one Copy button")
        try requireContainedAndSeparated(buttons, in: view.bounds, context: "pinned")
        view.debugHoverButton(title: "Copy screenshot")
        try require(view.debugButtons().first?.isHovered == true, "Native SDK did not own pinned hover")
        try host.click(view.debugButtons()[0].frame, in: view)
        try require(copyCount == 1, "Pinned Copy did not dispatch")
    }

    private static func testSettingsControls() throws {
        let view = NativeSettingsContentView(frame: .zero)
        var positions: [String] = []
        var retentions: [String] = []
        var autosave: [Bool] = []
        var openedFolder = 0
        view.onPositionSelected = { positions.append($0) }
        view.onRetentionSelected = { retentions.append($0) }
        view.onAutosaveChanged = { autosave.append($0) }
        view.onOpenFolder = { openedFolder += 1 }
        let host = Host(view: view, size: view.fittingSize)

        // Автосохранение включено по умолчанию, поэтому срок и папка видимы.
        let expected = ["Tray bottom left", "Tray bottom right", "Tray top left", "Tray top right",
                        "Autosave on", "Autosave off",
                        "Keep a day", "Keep a week", "Keep a month", "Keep forever",
                        "Open folder"]
        try require(view.debugButtons().map(\.identifier) == expected,
                    "Unexpected settings controls: \(view.debugButtons().map(\.identifier))")
        try requireContainedAndSeparated(view.debugButtons(), in: view.bounds, context: "settings")
        view.debugHoverButton(title: view.debugButtons()[0].title)
        try require(view.debugButtons().filter(\.isHovered).count == 1,
                    "Native SDK did not own settings hover")

        for identifier in ["Tray bottom left", "Tray bottom right", "Tray top left", "Tray top right"] {
            let button = view.debugButtons().first { $0.identifier == identifier }!
            try host.click(button.frame, in: view)
        }
        try require(positions == ["bottomLeft", "bottomRight", "topLeft", "topRight"],
                    "Settings dispatch order is wrong: \(positions)")

        for identifier in ["Keep a day", "Keep a month", "Keep forever", "Keep a week"] {
            let button = view.debugButtons().first { $0.identifier == identifier }!
            try host.click(button.frame, in: view)
        }
        try require(retentions == ["day", "month", "forever", "week"],
                    "Retention dispatch is wrong: \(retentions)")

        let openFolder = view.debugButtons().first { $0.identifier == "Open folder" }!
        try host.click(openFolder.frame, in: view)
        try require(openedFolder == 1, "Open folder did not dispatch")

        // Выключение автосохранения убирает срок и папку: держать настройку
        // срока при выключенном сохранении бессмысленно.
        let off = view.debugButtons().first { $0.identifier == "Autosave off" }!
        try host.click(off.frame, in: view)
        try require(autosave == [false], "Autosave toggle did not dispatch: \(autosave)")
        let afterOff = view.debugButtons().map(\.identifier)
        try require(!afterOff.contains("Keep a week") && !afterOff.contains("Open folder"),
                    "Retention controls must disappear when autosave is off: \(afterOff)")
        try require(afterOff.contains("Autosave on") && afterOff.contains("Autosave off"),
                    "Autosave switch must stay visible")

        let on = view.debugButtons().first { $0.identifier == "Autosave on" }!
        try host.click(on.frame, in: view)
        try require(autosave == [false, true], "Autosave must dispatch both ways")
        try require(view.debugButtons().map(\.identifier).contains("Keep a week"),
                    "Retention controls must return when autosave is on")

        let points = [
            NSPoint(x: 1, y: 1),
            NSPoint(x: view.bounds.midX, y: 1),
            NSPoint(x: 1, y: view.bounds.maxY - 1),
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
        ]
        view.debugSetAppearance(dark: false)
        let darkWhileSystemIsLight = points.map(view.debugPixel)
        view.debugSetAppearance(dark: true)
        let dark = points.map(view.debugPixel)
        view.debugSetAppearance(dark: false)
        let restored = points.map(view.debugPixel)
        try require(darkWhileSystemIsLight == dark && dark == restored,
                    "House Dark must remain fixed across system Light/Dark changes")
    }

    /// `buttonRegister` – проверять ли высоту по кнопочному реестру дома.
    /// Пункт всплывающего меню кнопкой не является: его высоту задаёт свой
    /// компонент дизайн-системы, и мерить его кнопочной сеткой неверно.
    private static func requireContainedAndSeparated(_ buttons: [NativeControlDebugButtonSnapshot],
                                                     in bounds: NSRect,
                                                     context: String,
                                                     buttonRegister: Bool = true) throws {
        try require(!buttons.isEmpty, "\(context): no buttons rendered")
        let outer = bounds.insetBy(dx: -0.5, dy: -0.5)
        for button in buttons {
            try require(outer.contains(button.frame),
                        "\(context): \(button.title) escapes \(bounds): \(button.frame)")
            guard buttonRegister else { continue }
            try require(abs(button.frame.height - 28) <= 0.5,
                        "\(context): \(button.title) is not on the House sm register: \(button.frame.height)")
        }
        for leftIndex in buttons.indices {
            for rightIndex in buttons.indices where rightIndex > leftIndex {
                let overlap = buttons[leftIndex].frame.intersection(buttons[rightIndex].frame)
                try require(overlap.isNull || overlap.width <= 0.01 || overlap.height <= 0.01,
                            "\(context): controls overlap: \(buttons[leftIndex].title), \(buttons[rightIndex].title)")
            }
        }
    }

    private static func alpha(_ pixel: UInt32) -> UInt8 {
        UInt8(pixel & 0xff)
    }

    private static func center(of rect: NSRect) -> NSPoint {
        NSPoint(x: rect.midX, y: rect.midY)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor
    private final class Host {
        struct Press {
            let hit: NSView
            let location: NSPoint
        }

        let window: NSWindow
        let root: NSView

        init(view: NSView, size: NSSize) {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            root = NSView(frame: NSRect(origin: .zero, size: size))
            window.contentView = root
            view.frame = root.bounds
            root.addSubview(view)
            root.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
        }

        /// Клик по поверхности, которая ловит мышь сама: панель шкатулки
        /// возвращает из `hitTest` себя, а не дочернюю вью, поэтому общий
        /// путь через попадание в потомка ей не подходит.
        func clickDirectly(_ buttonFrame: NSRect, in view: NSView) {
            let point = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
            let location = view.convert(point, to: nil)
            view.mouseDown(with: event(.leftMouseDown, at: location))
            view.mouseUp(with: event(.leftMouseUp, at: location))
        }

        func click(_ buttonFrame: NSRect, in view: NSView) throws {
            let press = try press(buttonFrame, in: view)
            release(press)
        }

        func press(_ buttonFrame: NSRect, in view: NSView) throws -> Press {
            let point = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
            guard let hit = view.hitTest(point), hit !== view else {
                throw Failure("No interactive Native SDK control at \(point)")
            }
            guard hit.acceptsFirstMouse(for: nil) else {
                throw Failure("Native SDK control does not accept the first click in a non-key panel")
            }
            let location = view.convert(point, to: nil)
            hit.mouseDown(with: event(.leftMouseDown, at: location))
            return Press(hit: hit, location: location)
        }

        func release(_ press: Press) {
            press.hit.mouseUp(with: event(.leftMouseUp, at: press.location))
            root.layoutSubtreeIfNeeded()
        }

        private func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type,
                               location: point,
                               modifierFlags: [],
                               timestamp: 0,
                               windowNumber: window.windowNumber,
                               context: nil,
                               eventNumber: 0,
                               clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)!
        }
    }
}
