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
