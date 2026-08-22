import AppKit

/// Сканирование личных данных: тихо, когда нечего показывать, и отменяемо.
///
/// Раньше окно с сообщением «ничего не найдено» всплывало даже после закрытия
/// редактора: сильная ссылка на контроллер удерживалась через приостановку, а
/// задача при закрытии не отменялась.
@main
struct EditorScanTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try emptyResultShowsNothing()
                try closingCancelsScan()
                try foundItemsStillAsk()
                try stowGateIsWiredIntoEveryGesturePhase()
                print("EditorScanTests: passed")
                exit(0)
            } catch {
                fputs("EditorScanTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// Ничего не найдено — ничего и не показываем: молчание и есть ответ.
    /// `TR-41`: СТЫК структуры ступени с обработчиком жеста.
    ///
    /// Перебор последовательностей проверяет саму структуру и ничего не знает
    /// об обработчике. Ровно там и сломалось: при правке потерялся вызов на
    /// начале жеста — разрешение не выдавалось, ступень не реагировала вовсе,
    /// а все тесты оставались зелёными (приёмка 21.08.2026).
    ///
    /// Проверка читает исходник и требует, чтобы событие доходило до
    /// структуры из КАЖДОЙ ветки: начало, движение, конец, отмена, инерция.
    @MainActor private static func stowGateIsWiredIntoEveryGesturePhase() throws {
        let source = try String(contentsOfFile: "Sources/ThumbnailManager.swift", encoding: .utf8)

        for kind in ["began", "changed", "momentum"] {
            guard source.contains("kind: .\(kind)") else {
                throw Failure("форма события «\(kind)» не доходит до ступени")
            }
        }
        guard source.contains("TrayStowGate.Kind.cancelled"), source.contains(": .ended") else {
            throw Failure("конец и отмена жеста не доходят до ступени")
        }

        // Вызовов ровно столько, сколько веток: меньше — ветка осталась без
        // связи, больше — решение снова размазано по обработчику.
        let calls = source.components(separatedBy: "deckStep.handle(").count - 1
        guard calls == 4 else {
            throw Failure("вызовов ступени \(calls) вместо четырёх: ветка осталась без связи")
        }
        guard !source.contains("private var stow") else {
            throw Failure("обработчик снова держит своё состояние ступени")
        }

        // `TR-41`: новый снимок не меняет фазу ленты. Признак «была собрана»
        // обязан смотреть на ФАКТИЧЕСКОЕ положение ленты у упора. Прежний
        // проверял прокручиваемость — `maximumOffset > 0.5`, — и раскрытая
        // лента собиралась от каждого снимка (приёмка 21.08.2026).
        guard let line = source.components(separatedBy: "\n")
            .first(where: { $0.contains("let wasCompressed") }) else {
            throw Failure("признак состояния ленты при вставке не найден")
        }
        guard !line.contains("maximumOffset > 0.5") else {
            throw Failure("состояние ленты определяется прокручиваемостью, а не положением")
        }
        guard line.contains("offset >= scrollModel.maximumOffset") else {
            throw Failure("состояние ленты не читается по её положению у упора")
        }
        // И убранная колода учитывается: иначе снимок вернёт её в собранную.
        guard source.contains("let wasStowed = deckStep.stowed") else {
            throw Failure("фаза ступени не читается до решения о ленте")
        }
        let decisionAt = source.range(of: "scrollIntent = wasCompressed")
        let readAt = source.range(of: "let wasStowed = deckStep.stowed")
        guard let decisionAt, let readAt, readAt.lowerBound < decisionAt.lowerBound else {
            throw Failure("фаза читается позже решения о ленте")
        }
    }

    @MainActor private static func emptyResultShowsNothing() throws {
        let controller = AnnotationEditorController.debugController()
        controller.debugPresentScanResult([], imageSize: CGSize(width: 400, height: 300))
        guard AnnotationEditorController.debugLastAlert == nil else {
            throw Failure("пустой результат показал окно: \(AnnotationEditorController.debugLastAlert ?? "")")
        }
    }

    /// Закрытое окно не показывает результат: сканирование отменяется.
    @MainActor private static func closingCancelsScan() throws {
        let controller = AnnotationEditorController.debugController()
        controller.debugMarkClosed()
        controller.debugPresentScanResult([SensitiveMatch(kind: .email,
                                                          text: "a@b.c",
                                                          normalizedRect: CGRect(x: 0.1, y: 0.1,
                                                                                 width: 0.2, height: 0.05))],
                                          imageSize: CGSize(width: 400, height: 300))
        guard AnnotationEditorController.debugLastAlert == nil else {
            throw Failure("закрытый редактор показал окно: \(AnnotationEditorController.debugLastAlert ?? "")")
        }
    }

    /// Находки по-прежнему требуют решения пользователя: молча ничего не
    /// скрываем.
    @MainActor private static func foundItemsStillAsk() throws {
        let controller = AnnotationEditorController.debugController()
        controller.debugPresentScanResult([SensitiveMatch(kind: .email,
                                                          text: "a@b.c",
                                                          normalizedRect: CGRect(x: 0.1, y: 0.1,
                                                                                 width: 0.2, height: 0.05))],
                                          imageSize: CGSize(width: 400, height: 300))
        guard let alert = AnnotationEditorController.debugLastAlert, alert.contains("1") else {
            throw Failure("находка не показала окно с решением: \(AnnotationEditorController.debugLastAlert ?? "нет")")
        }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
