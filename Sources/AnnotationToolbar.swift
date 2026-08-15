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
        case colour(Int)
        case weight(AnnotationStrokeWeight)
        case fill(Bool)
        case undo
        case redo
        case save
        case copy
        case close
        case scan
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
    func setStyle(paletteIndex: Int, weight: AnnotationStrokeWeight, filled: Bool) {
        surface.setStyle(paletteIndex: paletteIndex, weight: weight, filled: filled)
    }

#if TESTING
    func debugButtons() -> [NativeControlDebugButtonSnapshot] { surface.debugButtons() }
#endif
}
