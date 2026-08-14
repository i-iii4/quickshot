import Foundation

/// Срок жизни снимка в пользовательской папке. `forever` означает, что уборка
/// не удаляет ничего: пользователь распоряжается папкой сам.
enum ScreenshotRetention: String, CaseIterable {
    case day
    case week
    case month
    case forever

    static let `default` = ScreenshotRetention.week

    /// Возраст, после которого снимок удаляется. `nil` — не удалять никогда.
    var maximumAge: TimeInterval? {
        switch self {
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        case .forever: return nil
        }
    }
}

/// Запись о файле в папке снимков. Отделена от `FileManager`, чтобы решение
/// об удалении проверялось без диска и без ожидания реального времени.
struct ScreenshotFileRecord: Equatable {
    let url: URL
    let createdAt: Date

    init(url: URL, createdAt: Date) {
        self.url = url
        self.createdAt = createdAt
    }
}

/// Файлы, подлежащие удалению по сроку. Возраст считается от `createdAt`;
/// файл ровно на границе срока ещё живёт — удаление начинается строго за ней,
/// иначе снимок недельной давности исчезал бы в произвольный момент секунды.
func expiredScreenshots(_ records: [ScreenshotFileRecord],
                        now: Date,
                        retention: ScreenshotRetention) -> [URL] {
    guard let maximumAge = retention.maximumAge else { return [] }
    return records
        .filter { now.timeIntervalSince($0.createdAt) > maximumAge }
        .map(\.url)
}

/// Принадлежит ли файл QuickShot. Уборка удаляет только собственные снимки:
/// пользователь вправе положить в ту же папку что угодно, и это не должно
/// исчезнуть по нашему таймеру.
func isScreenshotOwnedByQuickShot(fileName: String) -> Bool {
    guard fileName.hasPrefix(ScreenshotNaming.prefix) else { return false }
    guard fileName.hasSuffix(".png") else { return false }
    return true
}

enum ScreenshotNaming {
    /// Префикс собственных файлов. Он же признак владения для уборки.
    static let prefix = "QuickShot "

    /// Имя файла снимка. Секунды обязательны: серия быстрых снимков не должна
    /// драться за одно имя, а уникальный суффикс добавляется только при
    /// реальном совпадении.
    static func fileName(date: Date,
                         calendar: Calendar = .current,
                         existingNames: Set<String> = []) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: date)
        let base = String(format: "%@%04d-%02d-%02d at %02d.%02d.%02d",
                          prefix,
                          parts.year ?? 0,
                          parts.month ?? 0,
                          parts.day ?? 0,
                          parts.hour ?? 0,
                          parts.minute ?? 0,
                          parts.second ?? 0)
        var candidate = base + ".png"
        var attempt = 2
        while existingNames.contains(candidate) {
            candidate = "\(base) (\(attempt)).png"
            attempt += 1
        }
        return candidate
    }
}

/// Настройки хранения. Значения по умолчанию соответствуют требованиям
/// `ST-2`, `ST-4` и `ST-5`: папка в пользовательских изображениях, срок неделя,
/// автосохранение включено.
struct ScreenshotStorageSettings: Equatable {
    var autosaveEnabled: Bool
    var retention: ScreenshotRetention
    var folderURL: URL

    static func defaultFolderURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("QuickShot", isDirectory: true)
    }

    static func makeDefault() -> ScreenshotStorageSettings {
        ScreenshotStorageSettings(autosaveEnabled: true,
                                  retention: .default,
                                  folderURL: defaultFolderURL())
    }
}
