import AppKit

// Точка входа. Файл назван main.swift, поэтому допускается код верхнего уровня.
// AppKit стартует на главном потоке; `assumeIsolated` делает этот контракт явным
// для Swift Concurrency без перехода на @main-структуру.
//
// .accessory — приложение-агент: нет иконки в Dock, нет главного меню,
// вся работа идёт из пункта в строке меню (NSStatusItem). Совпадает с LSUIElement.

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()      // удерживается до конца жизни процесса
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
