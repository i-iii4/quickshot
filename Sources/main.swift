import AppKit

// Точка входа. Файл назван main.swift, поэтому допускается код верхнего уровня —
// это избавляет от трения с актор-изоляцией @main под swiftc.
//
// .accessory — приложение-агент: нет иконки в Dock, нет главного меню,
// вся работа идёт из пункта в строке меню (NSStatusItem). Совпадает с LSUIElement.

let app = NSApplication.shared
let delegate = AppDelegate()      // удерживается до конца жизни процесса
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
