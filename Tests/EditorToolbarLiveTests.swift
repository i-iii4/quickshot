import AppKit

/// Тест живой панели редактора: каждая кнопка нажимается и обязана дать
/// наблюдаемое следствие.
///
/// Модельные тесты этого не ловят: они дёргают методы напрямую, минуя
/// диспетчеризацию Native SDK и оконную доставку событий. Именно там панель и
/// оказалась мёртвой.
@main
struct EditorToolbarLiveTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try everyControlDispatches()          // (1) мёртвых команд нет
                try layoutFitsEveryWidth()            // (2) раскладка на реальных ширинах
                try labelsAreReadable()               // (3) подписи не однобуквенные
                try narrowWindowSwitchesToCompact()   // (2) узкое окно перестраивает строки
                try cardControlsDispatch()            // (1) меню карточки тоже живое
                try styleControlsAreContextual()      // (6) без выделения панель не свалка
                try toolbarSurvivesRemeasure()        // растр не остаётся от пробного кадра
                print("EditorToolbarLiveTests: passed")
                exit(0)
            } catch {
                fputs("EditorToolbarLiveTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// Каждая кнопка панели при нажатии обязана дойти до обработчика.
    /// `D-1`, `D-2`, `F-1`, `F-2`, `M-3`
    @MainActor private static func everyControlDispatches() throws {
        let toolbar = AnnotationToolbarView(frame: .zero)
        var received: [AnnotationToolbarView.Command] = []
        toolbar.onCommand = { received.append($0) }

        let host = Host(view: toolbar, size: NSSize(width: 1600, height: 60))
        let buttons = toolbar.debugButtons()
        guard !buttons.isEmpty else { throw Failure("панель не отрисовала ни одной кнопки") }

        var dead: [String] = []
        for button in buttons {
            let before = received.count
            try host.click(button.frame, in: toolbar)
            if received.count == before { dead.append(button.identifier) }
        }
        guard dead.isEmpty else {
            throw Failure("мёртвые команды панели: \(dead.joined(separator: ", "))")
        }

        // Каждая кнопка обязана быть распознана как конкретная команда, а не
        // проглочена как «неизвестная».
        guard received.count == buttons.count else {
            throw Failure("нажатий \(buttons.count), команд \(received.count)")
        }
    }

    /// Панель обязана укладываться в реальные ширины окна без обрезания.
    /// `A-3`, `Q-1`
    @MainActor private static func layoutFitsEveryWidth() throws {
        for width in [CGFloat(720), 1000, 1440, 1920] {
            let toolbar = AnnotationToolbarView(frame: .zero)
            let host = Host(view: toolbar, size: NSSize(width: width, height: 200))
            _ = host
            let buttons = toolbar.debugButtons()
            guard !buttons.isEmpty else { throw Failure("ширина \(width): панель пуста") }

            for button in buttons {
                guard button.frame.minX >= -0.5, button.frame.maxX <= width + 0.5 else {
                    throw Failure("ширина \(width): контрол \(button.identifier) вышел за окно: \(button.frame)")
                }
                guard button.frame.maxY <= toolbar.fittingSize.height + 0.5 else {
                    throw Failure("ширина \(width): контрол \(button.identifier) вышел по высоте: \(button.frame)")
                }
            }
            // Панель не должна съедать больше трети окна по высоте: остальное —
            // холст, ради которого редактор и открыт.
            guard toolbar.fittingSize.height <= 200 else {
                throw Failure("ширина \(width): панель заняла \(toolbar.fittingSize.height)pt")
            }
        }
    }

    /// Подпись обязана объяснять действие: однобуквенные обозначения требуют
    /// легенды, которой у пользователя нет.
    /// `N-1`, `N-2`, `N-3`, `M-4`
    @MainActor private static func labelsAreReadable() throws {
        let toolbar = AnnotationToolbarView(frame: .zero)
        _ = Host(view: toolbar, size: NSSize(width: 1600, height: 60))
        for button in toolbar.debugButtons() {
            let title = button.title.trimmingCharacters(in: .whitespaces)
            guard title.isEmpty || title.count >= 3 else {
                throw Failure("нечитаемая подпись \"\(title)\" у \(button.identifier)")
            }
        }
    }

    /// Узкое окно перестраивает инструменты в две строки: контролы обязаны
    /// остаться доступными, а не уехать за край.
    @MainActor private static func narrowWindowSwitchesToCompact() throws {
        let toolbar = AnnotationToolbarView(frame: .zero)
        _ = Host(view: toolbar, size: NSSize(width: 560, height: 200))
        let wideCount = toolbar.debugButtons().count
        toolbar.setAvailableWidth(560)
        let buttons = toolbar.debugButtons()

        guard buttons.count == wideCount else {
            throw Failure("компактный режим потерял контролы: \(wideCount) → \(buttons.count)")
        }
        for button in buttons where button.frame.maxX > 560.5 {
            throw Failure("в компактном режиме \(button.identifier) всё ещё за краем: \(button.frame)")
        }
    }

    /// Кнопки на карточке трея — тот же класс дефекта: подпись есть, действия нет.
    /// `A-2`, `Q-4`, `G-10`
    @MainActor private static func cardControlsDispatch() throws {
        let copyView = NativeThumbnailButtonView(kind: .copy)
        let dismissView = NativeThumbnailButtonView(kind: .dismiss)
        var copied = 0
        var dismissed = 0
        copyView.onPress = { copied += 1 }
        dismissView.onPress = { dismissed += 1 }
        let copyHost = Host(view: copyView, size: copyView.fittingSize)
        let dismissHost = Host(view: dismissView, size: dismissView.fittingSize)

        let copyButtons = copyView.debugButtons()
        let dismissButtons = dismissView.debugButtons()
        guard copyButtons.count == 1, dismissButtons.count == 1 else {
            throw Failure("на карточке ожидались две одиночные команды")
        }
        try copyHost.click(copyButtons[0].frame, in: copyView)
        try dismissHost.click(dismissButtons[0].frame, in: dismissView)
        guard copied == 1, dismissed == 1 else {
            throw Failure("команды карточки мертвы: copy=\(copied) dismiss=\(dismissed)")
        }
    }

    /// Без выделения панель показывает инструменты и команды; свойства стиля
    /// появляются только когда есть что настраивать. Постоянный ряд из трёх
    /// десятков контролов — это свалка независимо от того, иконки в нём или
    /// слова.
    @MainActor private static func styleControlsAreContextual() throws {
        let toolbar = AnnotationToolbarView(frame: .zero)
        _ = Host(view: toolbar, size: NSSize(width: 1600, height: 60))

        toolbar.setSelectionPresence(false)
        let idle = toolbar.debugButtons()
        guard idle.count <= 16 else {
            throw Failure("без выделения панель показывает \(idle.count) контролов: "
                + idle.map(\.identifier).joined(separator: ", "))
        }
        let styleIdentifiers = ["Red", "Amber", "Green", "Blue", "Violet", "Graphite",
                                "Thin stroke", "Medium stroke", "Thick stroke", "Fill shapes"]
        for button in idle where styleIdentifiers.contains(button.identifier) {
            throw Failure("контрол стиля \(button.identifier) виден без выделения")
        }

        toolbar.setSelectionPresence(true)
        let active = toolbar.debugButtons()
        guard active.count > idle.count else {
            throw Failure("выделение не добавило контролов стиля: \(active.count) против \(idle.count)")
        }
        guard active.contains(where: { $0.identifier == "Red" }) else {
            throw Failure("при выделении нет выбора цвета: \(active.map(\.identifier))")
        }
    }

    /// Замер панели рендерит её в пробный кадр 2400×400. Если после замера не
    /// перерисовать в настоящем размере, на экран уходит растр от пробного —
    /// панель превращается в кашу пикселей. Проверяется по фактическому
    /// размеру последнего растра.
    @MainActor private static func toolbarSurvivesRemeasure() throws {
        let toolbar = AnnotationToolbarView(frame: .zero)
        let host = Host(view: toolbar, size: NSSize(width: 1200, height: 60))
        _ = host

        for presence in [true, false, true] {
            toolbar.setSelectionPresence(presence)
            toolbar.layoutSubtreeIfNeeded()
            let rendered = toolbar.debugRenderedSize
            guard abs(rendered.width - toolbar.bounds.width) < 1,
                  abs(rendered.height - toolbar.bounds.height) < 1 else {
                throw Failure("после смены выделения растр \(rendered) не совпадает с панелью \(toolbar.bounds.size)")
            }
        }
    }

    // MARK: помощники

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Хост воспроизводит реальное размещение панели в окне редактора: вью
    /// стоит СО СМЕЩЕНИЕМ от origin контейнера, а клик доставляется через
    /// `window.sendEvent`, чтобы hitTest выполнял сам AppKit по своей
    /// конвенции координат. Прямые вызовы `view.mouseDown` и ручной hitTest
    /// однажды закодировали в харнесс ту же ошибку координат, что была в
    /// продукте, — панель была мертва при зелёных тестах.
    @MainActor private final class Host {
        let window: NSWindow
        let root: NSView

        init(view: NSView, size: NSSize) {
            let rootSize = NSSize(width: size.width, height: size.height + 120)
            window = NSWindow(contentRect: NSRect(origin: .zero, size: rootSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            root = NSView(frame: NSRect(origin: .zero, size: rootSize))
            window.contentView = root
            let height = max(1, view.fittingSize.height)
            view.frame = NSRect(x: 0, y: rootSize.height - height,
                                width: size.width, height: height)
            root.addSubview(view)
            // Невидимому окну AppKit не доставляет события: sendEvent молча
            // глотает клик, и мёртвая панель выглядела бы как живая (или
            // наоборот). Окно поднимается за пределами экрана насильно.
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.orderFrontRegardless()
            root.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
        }

        func click(_ buttonFrame: NSRect, in view: NSView) throws {
            let centre = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
            let inWindow = view.convert(centre, to: nil)
            window.sendEvent(event(.leftMouseDown, at: inWindow))
            window.sendEvent(event(.leftMouseUp, at: inWindow))
            root.layoutSubtreeIfNeeded()
        }

        private func event(_ type: NSEvent.EventType, at windowPoint: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type,
                               location: windowPoint,
                               modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber,
                               context: nil,
                               eventNumber: 0,
                               clickCount: 1,
                               pressure: 1)!
        }
    }
}
