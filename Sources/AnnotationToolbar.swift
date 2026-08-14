import AppKit

/// Панель инструментов редактора аннотаций.
///
/// Выбор инструмента — взаимоисключающий выбор, владельцем которого является
/// модель, поэтому он собран из `button-group`: контракт резервирует эту группу
/// ровно для таких случаев. Команды истории, сохранения и выхода — независимые
/// кнопки рядом с группой.
///
/// Подписи текстовые, а не иконочные: в закреплённой ревизии дизайн-системы нет
/// иконок инструментов рисования, а рисовать свои означало бы нарушить правило
/// «каждый видимый контрол — примитив Native SDK».
@MainActor
final class AnnotationToolbarView: NSView {
    enum Command: Equatable {
        case tool(AnnotationTool)
        case undo
        case redo
        case save
        case copy
        case close
    }

    var onCommand: ((Command) -> Void)?

    private let surface = NativeAnnotationToolbarSurface(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        surface.onCommand = { [weak self] command in self?.onCommand?(command) }
        addSubview(surface)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { surface.fittingSize }
    override var intrinsicContentSize: NSSize { fittingSize }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
        return surface.hitTest(convert(point, to: surface))
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
    }

    func setSelectedTool(_ tool: AnnotationTool) { surface.setSelectedTool(tool) }
    func setHistoryState(canUndo: Bool, canRedo: Bool) {
        surface.setHistoryState(canUndo: canUndo, canRedo: canRedo)
    }

#if TESTING
    func debugButtons() -> [NativeControlDebugButtonSnapshot] { surface.debugButtons() }
#endif
}

/// Инструменты редактора. Значения совпадают с именами команд модели Native SDK,
/// поэтому строковое представление — часть контракта, а не деталь.
enum AnnotationTool: String, CaseIterable {
    case select
    case arrow
    case box
    case ellipse
    case line
    case pen
    case text
    case mark
    case step
    case hide
    case blur

    /// Клавиша инструмента (`D-1`): одна буква без модификатора.
    var shortcut: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .box: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .pen: return "p"
        case .text: return "t"
        case .mark: return "h"
        case .step: return "s"
        case .hide: return "b"
        case .blur: return "u"
        }
    }

    static func tool(forShortcut key: String) -> AnnotationTool? {
        allCases.first { $0.shortcut == key.lowercased() }
    }

    /// Тип объекта, создаваемого инструментом. `select` ничего не создаёт.
    var kind: AnnotationKind? {
        switch self {
        case .select: return nil
        case .arrow: return .arrow
        case .box: return .rectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .pen: return .pencil
        case .text: return .text
        case .mark: return .highlighter
        case .step: return .counter
        case .hide: return .redaction
        case .blur: return .blur
        }
    }
}
