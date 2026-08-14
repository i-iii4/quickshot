import AppKit
import OSLog

/// Пользовательская папка снимков: запись в момент захвата и уборка по сроку.
///
/// Библиотека намеренно не связана с механизмом аренд `CaptureArtifactStore`.
/// Аренды обслуживают доставку — буфер обмена и перетаскивание — и удаляют свой
/// временный файл, когда он больше не нужен. Файл библиотеки живёт по другому
/// правилу: он переживает и закрытие трея (`ST-9`), и удаление карточки
/// (`ST-10`), и исчезает только по сроку (`ST-3`) или по руке пользователя.
@MainActor
final class ScreenshotLibrary {
    nonisolated static let settingsChangedNotification =
        Notification.Name("QuickShotScreenshotStorageSettingsChanged")

    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot",
                                                category: "library")

    private enum DefaultsKey {
        static let autosaveEnabled = "screenshotAutosaveEnabled"
        static let retention = "screenshotRetention"
        static let folderBookmark = "screenshotFolderBookmark"
        static let folderPath = "screenshotFolderPath"
    }

    /// Как часто перепроверяется срок во время работы приложения (`ST-7`).
    private static let sweepInterval: TimeInterval = 60 * 60

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let now: () -> Date
    private var sweepTimer: Timer?
    private var protectedURLs: Set<URL> = []

    private(set) var settings: ScreenshotStorageSettings

    init(defaults: UserDefaults = .standard,
         fileManager: FileManager = .default,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.now = now
        self.settings = Self.loadSettings(from: defaults)
    }

    isolated deinit {
        sweepTimer?.invalidate()
    }

    // MARK: настройки

    func setAutosaveEnabled(_ enabled: Bool) {
        guard settings.autosaveEnabled != enabled else { return }
        settings.autosaveEnabled = enabled
        defaults.set(enabled, forKey: DefaultsKey.autosaveEnabled)
        announceSettingsChange()
    }

    func setRetention(_ retention: ScreenshotRetention) {
        guard settings.retention != retention else { return }
        settings.retention = retention
        defaults.set(retention.rawValue, forKey: DefaultsKey.retention)
        // `ST-8`: сокращение срока применяется к уже сохранённым снимкам сразу.
        sweepExpired()
        announceSettingsChange()
    }

    func setFolderURL(_ url: URL) {
        guard settings.folderURL != url else { return }
        settings.folderURL = url
        defaults.set(url.path, forKey: DefaultsKey.folderPath)
        announceSettingsChange()
    }

    private func announceSettingsChange() {
        NotificationCenter.default.post(name: Self.settingsChangedNotification, object: nil)
    }

    private static func loadSettings(from defaults: UserDefaults) -> ScreenshotStorageSettings {
        var settings = ScreenshotStorageSettings.makeDefault()
        if defaults.object(forKey: DefaultsKey.autosaveEnabled) != nil {
            settings.autosaveEnabled = defaults.bool(forKey: DefaultsKey.autosaveEnabled)
        }
        if let raw = defaults.string(forKey: DefaultsKey.retention),
           let retention = ScreenshotRetention(rawValue: raw) {
            settings.retention = retention
        }
        if let path = defaults.string(forKey: DefaultsKey.folderPath), !path.isEmpty {
            settings.folderURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        return settings
    }

    // MARK: жизненный цикл

    /// Уборка при запуске и периодическая (`ST-7`).
    func start() {
        sweepExpired()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.sweepInterval,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sweepExpired() }
        }
        timer.tolerance = Self.sweepInterval / 10
        sweepTimer = timer
    }

    /// `ST-18`: файл, открытый в редакторе, не удаляется уборкой.
    func protect(_ url: URL) { protectedURLs.insert(url.standardizedFileURL) }
    func unprotect(_ url: URL) { protectedURLs.remove(url.standardizedFileURL) }

    // MARK: запись

    /// Сохраняет снимок в папку. Возвращает `nil`, если автосохранение
    /// выключено (`ST-5`) или папка недоступна (`ST-14`) — в обоих случаях
    /// захват продолжается, снимок остаётся в трее и буфере.
    @discardableResult
    func store(pngData: Data, capturedAt: Date? = nil) -> URL? {
        guard settings.autosaveEnabled else { return nil }
        guard let folder = prepareFolder() else { return nil }

        let existing = Set((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
        let name = ScreenshotNaming.fileName(date: capturedAt ?? now(),
                                             existingNames: existing)
        let url = folder.appendingPathComponent(name)
        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            Self.log.error("store failed: \(error.localizedDescription, privacy: .public)")
            reportFailure(reason: error.localizedDescription)
            return nil
        }
    }

    /// Перезапись существующего файла отредактированной версией (`ED-2`).
    /// Если файл исчез по сроку или руками пользователя, он создаётся заново
    /// (`ED-13`).
    @discardableResult
    func update(url: URL, with pngData: Data) -> URL? {
        guard settings.autosaveEnabled else { return nil }
        guard prepareFolder() != nil else { return nil }
        do {
            try pngData.write(to: url, options: .atomic)
            return url
        } catch {
            Self.log.error("update failed: \(error.localizedDescription, privacy: .public)")
            return store(pngData: pngData)
        }
    }

    // MARK: уборка

    func sweepExpired() {
        guard settings.retention.maximumAge != nil else { return }
        guard let folder = existingFolder() else { return }
        let records = ownedRecords(in: folder)
        let expired = expiredScreenshots(records, now: now(), retention: settings.retention)
        for url in expired where !protectedURLs.contains(url.standardizedFileURL) {
            // `ST-6`: удаление окончательное, мимо корзины — смысл срока в том,
            // что данные исчезают, а не переезжают в другую папку на диске.
            do {
                try fileManager.removeItem(at: url)
            } catch {
                Self.log.error("sweep failed for \(url.lastPathComponent, privacy: .public)")
            }
        }
    }

    private func ownedRecords(in folder: URL) -> [ScreenshotFileRecord] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }

        return entries.compactMap { url in
            guard isScreenshotOwnedByQuickShot(fileName: url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            guard let created = values?.creationDate ?? values?.contentModificationDate else {
                return nil
            }
            return ScreenshotFileRecord(url: url, createdAt: created)
        }
    }

    // MARK: папка

    private func existingFolder() -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: settings.folderURL.path,
                                     isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return settings.folderURL
    }

    private func prepareFolder() -> URL? {
        if let folder = existingFolder() { return folder }
        do {
            try fileManager.createDirectory(at: settings.folderURL,
                                            withIntermediateDirectories: true)
            return settings.folderURL
        } catch {
            Self.log.error("folder unavailable: \(error.localizedDescription, privacy: .public)")
            reportFailure(reason: error.localizedDescription)
            return nil
        }
    }

    /// `ST-14`, `ST-15`: отказ записи сообщается явно и один раз за причину —
    /// молчаливая потеря снимка недопустима, но и модальный диалог на каждый
    /// захват недопустим тоже.
    private var reportedFailures: Set<String> = []

    private func reportFailure(reason: String) {
        guard reportedFailures.insert(reason).inserted else { return }
        let alert = NSAlert()
        alert.messageText = "Could not save the screenshot to disk"
        alert.informativeText = "\(reason)\n\nThe screenshot stays in the tray and on the clipboard."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
