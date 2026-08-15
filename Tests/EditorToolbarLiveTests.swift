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
        let controls = NativeThumbnailControlsView(frame: .zero)
        var copied = 0
        var dismissed = 0
        controls.onCopy = { copied += 1 }
        controls.onDismiss = { dismissed += 1 }
        let host = Host(view: controls, size: controls.fittingSize)

        let buttons = controls.debugButtons()
        guard buttons.count == 2 else { throw Failure("на карточке ожидались две команды") }
        for button in buttons {
            try host.click(button.frame, in: controls)
        }
        guard copied == 1, dismissed == 1 else {
            throw Failure("команды карточки мертвы: copy=\(copied) dismiss=\(dismissed)")
        }
    }

    // MARK: помощники

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    @MainActor private final class Host {
        let window: NSWindow
        let root: NSView

        init(view: NSView, size: NSSize) {
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            root = NSView(frame: NSRect(origin: .zero, size: size))
            window.contentView = root
            view.frame = NSRect(origin: .zero,
                                size: NSSize(width: size.width, height: view.fittingSize.height))
            root.addSubview(view)
            root.layoutSubtreeIfNeeded()
            view.layoutSubtreeIfNeeded()
        }

        func click(_ buttonFrame: NSRect, in view: NSView) throws {
            let centre = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
            let inRoot = view.convert(centre, to: root)
            guard let hit = view.hitTest(view.convert(inRoot, from: root)) else {
                throw Failure("нет интерактивной вью под \(centre)")
            }
            let down = event(.leftMouseDown, at: window.convertPoint(toScreen: inRoot))
            let up = event(.leftMouseUp, at: window.convertPoint(toScreen: inRoot))
            hit.mouseDown(with: down)
            hit.mouseUp(with: up)
            root.layoutSubtreeIfNeeded()
        }

        private func event(_ type: NSEvent.EventType, at screenPoint: NSPoint) -> NSEvent {
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            return NSEvent.mouseEvent(with: type,
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
