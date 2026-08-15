import Foundation

/// Настройки редактора (`P-1`…`P-5`).
///
/// Хранятся в `UserDefaults`, а не в файле: это предпочтения, а не документ, и
/// переживать их между сборками не требуется — при несовпадении значения
/// просто берётся умолчание.
struct EditorSettings {
    enum ApplyAction: String, CaseIterable {
        case clipboard
        case file
        case both
    }

    private enum Key {
        static let defaultTool = "editorDefaultTool"
        static let keepsTool = "editorKeepsToolAfterDraw"
        static let applyAction = "editorApplyAction"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Инструмент при открытии редактора. Умолчание — выделение: первое
    /// действие чаще всего «поправить уже нарисованное», а не «рисовать».
    var defaultTool: AnnotationTool {
        get {
            guard let raw = defaults.string(forKey: Key.defaultTool),
                  let tool = AnnotationTool(rawValue: raw) else { return .select }
            return tool
        }
        set { defaults.set(newValue.rawValue, forKey: Key.defaultTool) }
    }

    /// Остаётся ли инструмент активным после создания объекта (`D-3`).
    /// Умолчание — нет: одиночная стрелка нужна чаще, чем серия.
    var keepsToolAfterDraw: Bool {
        get { defaults.bool(forKey: Key.keepsTool) }
        set { defaults.set(newValue, forKey: Key.keepsTool) }
    }

    /// Что делает применение результата (`P-3`).
    var applyAction: ApplyAction {
        get {
            guard let raw = defaults.string(forKey: Key.applyAction),
                  let action = ApplyAction(rawValue: raw) else { return .clipboard }
            return action
        }
        set { defaults.set(newValue.rawValue, forKey: Key.applyAction) }
    }

    /// `P-5`: сброс настроек редактора к заводским.
    func reset() {
        defaults.removeObject(forKey: Key.defaultTool)
        defaults.removeObject(forKey: Key.keepsTool)
        defaults.removeObject(forKey: Key.applyAction)
    }
}
