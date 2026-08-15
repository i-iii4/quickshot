import CoreGraphics

/// Толщина штриха тремя ступенями вместо произвольного числа: на скриншоте
/// разница между 3 и 4 точками не читается, а выбор из трёх — читается сразу.
enum AnnotationStrokeWeight: String, CaseIterable {
    case thin
    case medium
    case thick

    var lineWidth: CGFloat {
        switch self {
        case .thin: return 2
        case .medium: return 4
        case .thick: return 7
        }
    }

    /// Кегль подписи и диаметр метки шага следуют той же ступени: подпись
    /// «тонкого» стиля рядом с толстой стрелкой выглядит случайной.
    var fontSize: CGFloat {
        switch self {
        case .thin: return 13
        case .medium: return 17
        case .thick: return 24
        }
    }
}

/// Инструменты редактора. Значения совпадают с именами команд модели Native SDK,
/// поэтому строковое представление — часть контракта, а не деталь.
enum AnnotationTool: String, CaseIterable {
    case select
    case crop
    case arrow
    case box
    case ellipse
    case line
    case pen
    case text
    case mark
    case step
    case hide

    /// Клавиша инструмента (`D-1`): одна буква без модификатора.
    var shortcut: String {
        switch self {
        case .select: return "v"
        case .crop: return "c"
        case .arrow: return "a"
        case .box: return "r"
        case .ellipse: return "o"
        case .line: return "l"
        case .pen: return "p"
        case .text: return "t"
        case .mark: return "h"
        case .step: return "s"
        case .hide: return "b"
        }
    }

    static func tool(forShortcut key: String) -> AnnotationTool? {
        allCases.first { $0.shortcut == key.lowercased() }
    }

    /// Тип объекта, создаваемого инструментом. `select` ничего не создаёт.
    var kind: AnnotationKind? {
        switch self {
        case .select, .crop: return nil
        case .arrow: return .arrow
        case .box: return .rectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .pen: return .pencil
        case .text: return .text
        case .mark: return .highlighter
        case .step: return .counter
        case .hide: return .redaction
        }
    }
}
