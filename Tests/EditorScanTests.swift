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
    /// `TR-41`: СТЫК структуры ступени с обработчиком жеста.
    ///
    /// Перебор последовательностей проверяет саму структуру и об обработчике
    /// не знает ничего. На стыке ломалось дважды при зелёных тестах: сперва
    /// потерялся вызов на начале жеста, потом оказалось, что из четырёх веток
    /// завершения вызов стоит в одной.
    ///
    /// Проверка читает ЖИВОЙ КОД: тело обработчика прокрутки без комментариев.
    /// Прежняя считала подстроки по всему файлу и потому проходила и на
    /// закомментированном вызове, и на вызове, перенесённом в чужой метод
    /// (аудит 22.08.2026).
    private static func stowGateIsWiredIntoEveryGesturePhase() throws {
        let source = try String(contentsOfFile: "Sources/ThumbnailManager.swift", encoding: .utf8)
        let live = liveCode(of: source)
        let handler = try body(of: "func scrollTray(with event: NSEvent)", in: live)

        // Каждая форма события доходит до ступени ИЗ ТЕЛА обработчика.
        // Каждая форма события доходит до ступени ИЗ ТЕЛА обработчика — либо
        // прямым вызовом, либо через перевод фазы в форму.
        for kind in ["began", "changed", "momentum", "ended", "cancelled"] {
            let direct = handler.contains("kind: .\(kind)")
            let mapped = handler.contains("stepKind = .\(kind)")
            guard direct || mapped else {
                throw Failure("форма события «\(kind)» не доходит до ступени из обработчика")
            }
        }

        // Все ветки завершения жеста ведут в ступень. Ветки считаются ПО КОДУ:
        // каждое место, где снимается признак активного жеста.
        let endings = live.components(separatedBy: "\n").filter {
            $0.contains("scrollGestureActive = false") && !$0.contains("private var")
        }.count
        let finishes = live.components(separatedBy: "\n").filter {
            $0.contains("finishGestureForStep(") && !$0.contains("private func")
        }.count
        guard finishes >= endings else {
            throw Failure("веток завершения жеста \(endings), а завершений ступени \(finishes)")
        }

        // Состояние ступени не живёт в обработчике.
        guard !live.contains("private var stow") else {
            throw Failure("обработчик снова держит своё состояние ступени")
        }

        // `TR-41`: новый снимок не меняет фазу ленты. Признак «была собрана»
        // обязан смотреть на ФАКТИЧЕСКОЕ положение ленты у упора.
        guard let line = live.components(separatedBy: "\n")
            .first(where: { $0.contains("let wasCompressed") }) else {
            throw Failure("признак состояния ленты при вставке не найден")
        }
        guard !line.contains("maximumOffset > 0.5") else {
            throw Failure("состояние ленты определяется прокручиваемостью, а не положением")
        }
        guard line.contains("offset >= scrollModel.maximumOffset") else {
            throw Failure("состояние ленты не читается по её положению у упора")
        }
        // Корень (аудит 22.08.2026): форма события берётся ИЗ ФАЗЫ, а не
        // подставляется движением. Иначе конец жеста уходит в ступень как
        // движение и обходит воронку завершения сверху.
        guard handler.contains("kind: stepKind") else {
            throw Failure("форма события подставляется вместо чтения фазы")
        }

        // Спящие конфликты, которые будит починка корня.
        guard live.contains("scrollSettleAnimating || stepSettling") else {
            throw Failure("анимация ступени не входит в условие раннего выхода синхронизации")
        }
        guard live.contains("private func cancelStepMotion") else {
            throw Failure("пружина ступени нигде не отменяется")
        }

        guard let readAt = live.range(of: "let wasStowed = deckStep.stowed"),
              let decisionAt = live.range(of: "scrollIntent = wasCompressed"),
              readAt.lowerBound < decisionAt.lowerBound else {
            throw Failure("фаза ступени читается позже решения о ленте")
        }
    }

    /// Исходник без комментариев: закомментированный вызов кодом не является.
    private static func liveCode(of source: String) -> String {
        source.components(separatedBy: "\n").map { line -> String in
            guard let mark = line.range(of: "//") else { return line }
            return String(line[line.startIndex..<mark.lowerBound])
        }.joined(separator: "\n")
    }

    /// Тело метода по его сигнатуре: вызов, перенесённый в другой метод, сюда
    /// не попадёт.
    private static func body(of signature: String, in source: String) throws -> String {
        guard let start = source.range(of: signature) else {
            throw Failure("метод «\(signature)» не найден")
        }
        var depth = 0
        var started = false
        var result = ""
        for character in source[start.lowerBound...] {
            result.append(character)
            if character == "{" { depth += 1; started = true }
            if character == "}" {
                depth -= 1
                if started && depth == 0 { break }
            }
        }
        return result
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
