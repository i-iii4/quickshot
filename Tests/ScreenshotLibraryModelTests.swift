import Foundation

@main
struct ScreenshotLibraryModelTests {
    private static let folder = URL(fileURLWithPath: "/tmp/QuickShotLibraryTests",
                                    isDirectory: true)
    private static let now = Date(timeIntervalSince1970: 1_760_000_000)

    static func main() {
        retentionAgesAreExplicit()
        expiryUsesStrictBoundary()
        foreverNeverExpires()
        shorterRetentionCatchesOlderFiles()
        ownershipGuardsForeignFiles()
        namesCarrySecondsAndAvoidCollisions()
        defaultsMatchRequirements()
        print("ScreenshotLibraryModelTests: passed")
    }

    private static func retentionAgesAreExplicit() {
        expect(ScreenshotRetention.day.maximumAge == 86_400, "day must be 24h")
        expect(ScreenshotRetention.week.maximumAge == 604_800, "week must be 7 days")
        expect(ScreenshotRetention.month.maximumAge == 2_592_000, "month must be 30 days")
        expect(ScreenshotRetention.forever.maximumAge == nil, "forever must not expire")
    }

    /// Файл ровно на границе срока ещё живёт: иначе недельный снимок исчезал бы
    /// в произвольный момент секунды, в которую совпал возраст.
    private static func expiryUsesStrictBoundary() {
        let exactlyWeekOld = record("a.png", ageSeconds: 604_800)
        let justOverWeek = record("b.png", ageSeconds: 604_801)
        let expired = expiredScreenshots([exactlyWeekOld, justOverWeek],
                                         now: now,
                                         retention: .week)
        expect(expired == [justOverWeek.url],
               "only files strictly older than the retention window expire; got \(expired)")
    }

    private static func foreverNeverExpires() {
        let ancient = record("old.png", ageSeconds: 10 * 365 * 24 * 60 * 60)
        expect(expiredScreenshots([ancient], now: now, retention: .forever).isEmpty,
               "forever retention must never delete")
    }

    /// `ST-8`: уменьшение срока применяется к уже сохранённым снимкам.
    private static func shorterRetentionCatchesOlderFiles() {
        let twoDaysOld = record("c.png", ageSeconds: 2 * 24 * 60 * 60)
        expect(expiredScreenshots([twoDaysOld], now: now, retention: .week).isEmpty,
               "two-day-old file survives a week-long retention")
        expect(expiredScreenshots([twoDaysOld], now: now, retention: .day) == [twoDaysOld.url],
               "shortening retention to a day must expire the same file")
    }

    /// `ST-17`: уборка удаляет только собственные файлы.
    private static func ownershipGuardsForeignFiles() {
        expect(isScreenshotOwnedByQuickShot(fileName: "QuickShot 2026-08-13 at 10.00.00.png"),
               "own screenshot must be recognised")
        expect(isScreenshotOwnedByQuickShot(fileName: "QuickShot 2026-08-13 at 10.00.00 (2).png"),
               "de-duplicated own screenshot must be recognised")
        expect(!isScreenshotOwnedByQuickShot(fileName: "family-photo.png"),
               "foreign file must never be swept")
        expect(!isScreenshotOwnedByQuickShot(fileName: "QuickShot notes.txt"),
               "non-png with our prefix must not be swept")
    }

    private static func namesCarrySecondsAndAvoidCollisions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let name = ScreenshotNaming.fileName(date: date, calendar: calendar)
        expect(name.hasPrefix(ScreenshotNaming.prefix), "name must carry the ownership prefix")
        expect(name.hasSuffix(".png"), "name must end with .png")
        expect(name.contains(" at "), "name must separate date and time")
        expect(isScreenshotOwnedByQuickShot(fileName: name),
               "generated name must satisfy the ownership check")

        let second = ScreenshotNaming.fileName(date: date,
                                               calendar: calendar,
                                               existingNames: [name])
        expect(second != name, "collision must produce a different name")
        expect(isScreenshotOwnedByQuickShot(fileName: second),
               "de-duplicated name must stay ours")
        let third = ScreenshotNaming.fileName(date: date,
                                              calendar: calendar,
                                              existingNames: [name, second])
        expect(third != name && third != second, "second collision must resolve too")
    }

    private static func defaultsMatchRequirements() {
        let settings = ScreenshotStorageSettings.makeDefault()
        expect(settings.autosaveEnabled, "autosave is on by default (ST-5)")
        expect(settings.retention == .week, "default retention is a week (ST-4)")
        let folder = ScreenshotStorageSettings.defaultFolderURL(
            home: URL(fileURLWithPath: "/Users/tester", isDirectory: true))
        expect(folder.path == "/Users/tester/Pictures/QuickShot",
               "default folder lives in Pictures (ST-2); got \(folder.path)")
    }

    private static func record(_ name: String, ageSeconds: TimeInterval) -> ScreenshotFileRecord {
        ScreenshotFileRecord(url: folder.appendingPathComponent(name),
                             createdAt: now.addingTimeInterval(-ageSeconds))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("ScreenshotLibraryModelTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
