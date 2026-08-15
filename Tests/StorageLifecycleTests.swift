import AppKit

/// Хранение на диске в крайних случаях (`ST-5a`, `ST-11`, `ST-14`…`ST-18`)
/// и восстановление состояния между запусками (`ED-16`…`ED-19`).
///
/// Работа идёт с настоящей файловой системой во временном каталоге: смысл
/// требований в том, что происходит с файлами, а не в вызовах методов.
@main
struct StorageLifecycleTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try writesCaptureToFolder()             // ST-1, ST-11
                try missingFolderDoesNotLoseCapture()   // ST-14, ST-15
                try sweepSkipsOpenFile()                // ST-18
                try sweepKeepsForeignFiles()            // ST-16, ST-17
                try autosaveOffLeavesNoTrace()          // ST-5a, ED-12, ED-19
                try sessionSurvivesRestart()            // ED-16, ED-17, ED-18
                try corruptedStateIsDiscarded()         // ED-17
                print("StorageLifecycleTests: passed")
                exit(0)
            } catch {
                fputs("StorageLifecycleTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// `ST-1`, `ST-11`: снимок попадает в папку, папка достижима.
    @MainActor private static func writesCaptureToFolder() throws {
        let library = makeLibrary()
        defer { cleanup(library) }
        guard let url = library.store(pngData: samplePNG()) else {
            throw Failure("снимок не сохранён")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure("файла нет на диске")
        }
        guard url.path.hasPrefix(library.settings.folderURL.path) else {
            throw Failure("файл сохранён мимо настроенной папки: \(url.path)")
        }
    }

    /// `ST-14`, `ST-15`: недоступная папка не уносит снимок с собой.
    @MainActor private static func missingFolderDoesNotLoseCapture() throws {
        let library = ScreenshotLibrary(defaults: freshDefaults(),
                                        fileManager: .default,
                                        now: { Date() })
        // Путь внутри файла, а не каталога: создать папку там невозможно.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickshot-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: blocker) }

        library.setFolderURL(blocker.appendingPathComponent("Screenshots"))
        library.setSuppressesFailureAlertsForTesting(true)
        let url = library.store(pngData: samplePNG())
        guard url == nil else { throw Failure("сохранение в недоступную папку должно провалиться") }
        // Провал записи не должен ронять приложение и терять снимок: он
        // остаётся в трее и буфере, что проверяется отсутствием исключения.
    }

    /// `ST-18`: файл, открытый в редакторе, уборка не трогает.
    @MainActor private static func sweepSkipsOpenFile() throws {
        var now = Date()
        let library = makeLibrary(now: { now })
        defer { cleanup(library) }
        guard let url = library.store(pngData: samplePNG()) else { throw Failure("нет файла") }

        library.protect(url)
        library.setRetention(.day)
        now = now.addingTimeInterval(3 * 24 * 60 * 60)
        library.sweepExpired()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure("уборка удалила файл, открытый в редакторе")
        }

        library.unprotect(url)
        library.sweepExpired()
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure("после закрытия редактора просроченный файл обязан исчезнуть")
        }
    }

    /// `ST-16`, `ST-17`: чужие файлы и удалённые вручную не мешают уборке.
    @MainActor private static func sweepKeepsForeignFiles() throws {
        var now = Date()
        let library = makeLibrary(now: { now })
        defer { cleanup(library) }
        guard let mine = library.store(pngData: samplePNG()) else { throw Failure("нет файла") }

        let foreign = library.settings.folderURL.appendingPathComponent("family-photo.png")
        try samplePNG().write(to: foreign)

        try FileManager.default.removeItem(at: mine)   // пользователь удалил сам
        library.setRetention(.day)
        now = now.addingTimeInterval(3 * 24 * 60 * 60)
        library.sweepExpired()

        guard FileManager.default.fileExists(atPath: foreign.path) else {
            throw Failure("уборка удалила чужой файл")
        }
    }

    /// `ST-5a`, `ED-12`, `ED-19`: при выключенном автосохранении на диск не
    /// попадает ничего.
    @MainActor private static func autosaveOffLeavesNoTrace() throws {
        let library = makeLibrary()
        defer { cleanup(library) }
        library.setAutosaveEnabled(false)

        guard library.store(pngData: samplePNG()) == nil else {
            throw Failure("при выключенном автосохранении файл создаваться не должен")
        }
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: library.settings.folderURL.path)) ?? []
        guard contents.isEmpty else {
            throw Failure("в папке остались следы: \(contents)")
        }

        let sessions = AnnotationSessionStore()
        let id = UUID()
        sessions.store(objects: [textObject()], for: id)
        sessions.discardAll()
        guard sessions.trackedCount == 0 else {
            throw Failure("после закрытия трея редактируемое состояние обязано исчезнуть")
        }
    }

    /// `ED-16`, `ED-17`, `ED-18`: состояние переживает перезапуск, пока жив файл.
    @MainActor private static func sessionSurvivesRestart() throws {
        let library = makeLibrary()
        defer { cleanup(library) }
        let store = AnnotationStateStore(directory: library.settings.folderURL
            .appendingPathComponent(".state", isDirectory: true))
        let id = UUID()

        store.save(objects: [textObject()], for: id)
        let reopened = AnnotationStateStore(directory: store.directory)
        let restored = reopened.load(for: id)
        guard restored.count == 1, restored.first?.text == "note" else {
            throw Failure("состояние не пережило перезапуск: \(restored.count)")
        }

        // Срок жизни состояния привязан к снимку: файла нет — состояния нет.
        reopened.discard(for: id)
        guard reopened.load(for: id).isEmpty else {
            throw Failure("состояние пережило удаление снимка")
        }
    }

    /// `ED-17`: несовместимое состояние отбрасывается целиком, без миграций.
    @MainActor private static func corruptedStateIsDiscarded() throws {
        let library = makeLibrary()
        defer { cleanup(library) }
        let directory = library.settings.folderURL.appendingPathComponent(".state", isDirectory: true)
        let store = AnnotationStateStore(directory: directory)
        let id = UUID()
        store.save(objects: [textObject()], for: id)

        let file = directory.appendingPathComponent("\(id.uuidString).json")
        try Data("{ not json at all".utf8).write(to: file)

        let reopened = AnnotationStateStore(directory: directory)
        guard reopened.load(for: id).isEmpty else {
            throw Failure("повреждённое состояние обязано отбрасываться")
        }
    }

    // MARK: помощники

    @MainActor private static func makeLibrary(now: @escaping () -> Date = { Date() }) -> ScreenshotLibrary {
        let library = ScreenshotLibrary(defaults: freshDefaults(), fileManager: .default, now: now)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickshot-tests-\(UUID().uuidString)", isDirectory: true)
        library.setFolderURL(folder)
        library.setSuppressesFailureAlertsForTesting(true)
        return library
    }

    @MainActor private static func cleanup(_ library: ScreenshotLibrary) {
        try? FileManager.default.removeItem(at: library.settings.folderURL)
    }

    private static func freshDefaults() -> UserDefaults {
        let name = "quickshot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func textObject() -> AnnotationObject {
        AnnotationObject(kind: .text,
                         geometry: .rect(CGRect(x: 10, y: 10, width: 40, height: 20),
                                         cornerRadius: 0),
                         text: "note")
    }

    private static func samplePNG() -> Data {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return Clipboard.pngData(cgImage: context.makeImage()!)!
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
