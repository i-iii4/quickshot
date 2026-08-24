import AppKit
import Foundation

/// Оснастка живых прогонов интерфейса: прокрутка цикла событий.
///
/// Оба живых набора — клики по карточке и прокрутка трея — крутили цикл
/// дословно одинаково.

/// Даёт циклу событий поработать заданное время.
func spin(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

/// Крутит цикл, пока условие не выполнится или не выйдет время.
func spinUntil(_ timeout: TimeInterval, condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}
