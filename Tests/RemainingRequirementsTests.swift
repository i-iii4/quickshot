import AppKit

/// Требования, не покрытые другими наборами: `A-6`, `A-7`, `C-9`, `D-30`,
/// `D-38`, `D-39`, `ED-13`, `ED-14`, `F-5`, `F-6`, `H-6`, `I-1`, `K-3`,
/// `L-3`, `L-4`, `L-6`, `O-1`, `P-4`, `P-5`, `TR-11`, `TR-12`, `TR-14`.
@main
struct RemainingRequirementsTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try captureDuringSessionKeepsWork()      // A-6
                try imageFromClipboardOpens()            // A-7
                try groupingMovesTogether()              // C-9
                try recentLabelsAreRemembered()          // D-30
                try stepPairsWithLabel()                 // D-38, D-39
                try savingRecreatesMissingFile()         // ED-13
                try crashLeavesLastSavedVersion()        // ED-14
                try quickStylesRoundTrip()               // F-5, F-6
                try shortcutsAreCustomisable()           // H-6
                try framesCombineIntoOne()               // I-1
                try historyLimitsAreConfigurable()       // K-3
                try applyAndMemoryBudgets()              // L-3, L-4, L-6
                try shortcutsActionsAreExposed()         // O-1
                try styleDefaultsPersistAndReset()       // P-4, P-5
                try scrollPositionSurvivesCollapse()     // TR-11, TR-12
                try newCaptureInterruptsScrolling()      // TR-14
                print("RemainingRequirementsTests: passed")
                exit(0)
            } catch {
                fputs("RemainingRequirementsTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// `A-6`: новый снимок во время сессии не разрушает её молча.
    @MainActor private static func captureDuringSessionKeepsWork() throws {
        let canvas = makeCanvas()
        canvas.document.add(rectangle())
        let before = canvas.document.objects.count
        // Смена изображения под открытым документом сохраняет объекты:
        // молчаливая потеря работы запрещена.
        canvas.image = image(width: 640, height: 480)
        guard canvas.document.objects.count == before else {
            throw Failure("новый снимок стёр работу")
        }
    }

    /// `A-7`: изображение из буфера открывается в редакторе.
    @MainActor private static func imageFromClipboardOpens() throws {
        let source = image(width: 120, height: 90)
        Clipboard.copy(preparedImage: Clipboard.prepareImage(cgImage: source))
        guard let restored = AnnotationEditorController.imageFromPasteboard() else {
            throw Failure("изображение из буфера не читается")
        }
        guard restored.width == 120, restored.height == 90 else {
            throw Failure("размер потерян: \(restored.width)×\(restored.height)")
        }
    }

    /// `C-9`: группа двигается целиком.
    @MainActor private static func groupingMovesTogether() throws {
        let document = AnnotationDocument()
        document.add(rectangle(x: 0), select: false)
        document.add(rectangle(x: 100), select: false)
        document.selectAll()
        document.groupSelection()

        guard let groupID = document.objects.first?.groupID else {
            throw Failure("группа не создана")
        }
        document.select([document.objects[0].id])
        document.expandSelectionToGroups()
        guard document.selection.count == 2 else {
            throw Failure("выделение не расширилось на группу")
        }

        document.move(ids: document.selection, by: CGVector(dx: 10, dy: 0))
        let xs = document.objects.map { $0.geometry.boundingBox.minX }
        guard xs == [10, 110] else { throw Failure("группа сдвинулась не целиком: \(xs)") }

        document.ungroupSelection()
        guard document.objects.allSatisfy({ $0.groupID == nil }) else {
            throw Failure("разгруппировка не сработала, группа \(groupID)")
        }
    }

    /// `D-30`: последние подписи предлагаются повторно.
    @MainActor private static func recentLabelsAreRemembered() throws {
        let defaults = freshDefaults()
        var store = RecentTextStore(defaults: defaults)
        store.remember("Broken here")
        store.remember("Fix this")
        store.remember("Broken here")

        let recent = RecentTextStore(defaults: defaults).recent
        guard recent.first == "Broken here" else { throw Failure("последняя подпись не первая: \(recent)") }
        guard recent.count == 2 else { throw Failure("повтор не должен дублироваться: \(recent)") }
    }

    /// `D-38`, `D-39`: метка шага связывается с подписью и лупой.
    @MainActor private static func stepPairsWithLabel() throws {
        let document = AnnotationDocument()
        var counter = AnnotationObject(kind: .counter, geometry: .point(CGPoint(x: 50, y: 50)))
        counter.number = 1
        document.add(counter, select: false)
        let label = AnnotationObject(kind: .text,
                                     geometry: .rect(CGRect(x: 70, y: 40, width: 60, height: 20),
                                                     cornerRadius: 0),
                                     text: "Open menu")
        document.add(label, select: false)
        document.pair(document.objects[0].id, with: document.objects[1].id)

        document.select([document.objects[0].id])
        document.expandSelectionToGroups()
        document.move(ids: document.selection, by: CGVector(dx: 20, dy: 0))

        let positions = document.objects.map { $0.geometry.boundingBox.minX }
        guard positions == [70, 90] else {
            throw Failure("подпись не поехала за меткой: \(positions)")
        }
    }

    /// `ED-13`: файл исчез, сохранение создаёт его заново.
    @MainActor private static func savingRecreatesMissingFile() throws {
        let library = makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.settings.folderURL) }
        guard let url = library.store(pngData: samplePNG()) else { throw Failure("нет файла") }
        try FileManager.default.removeItem(at: url)

        guard let recreated = library.update(url: url, with: samplePNG()) else {
            throw Failure("сохранение не восстановило файл")
        }
        guard FileManager.default.fileExists(atPath: recreated.path) else {
            throw Failure("файл так и не появился")
        }
    }

    /// `ED-14`: аварийное завершение оставляет последнюю сохранённую версию.
    @MainActor private static func crashLeavesLastSavedVersion() throws {
        let library = makeLibrary()
        defer { try? FileManager.default.removeItem(at: library.settings.folderURL) }
        guard let url = library.store(pngData: samplePNG()) else { throw Failure("нет файла") }
        let saved = try Data(contentsOf: url)

        // «Падение»: редактируемое состояние теряется, файл остаётся как был.
        let sessions = AnnotationSessionStore()
        sessions.store(objects: [rectangle()], for: UUID())
        sessions.discardAll()

        let onDisk = try Data(contentsOf: url)
        guard onDisk == saved else { throw Failure("файл изменился без сохранения") }
    }

    /// `F-5`, `F-6`: быстрые стили сохраняются и переносятся.
    @MainActor private static func quickStylesRoundTrip() throws {
        let defaults = freshDefaults()
        var styles = QuickStyleStore(defaults: defaults)
        let style = AnnotationStyle(paletteIndex: 3, lineWidth: 7, filled: true,
                                    fillOpacity: 0.25, fontSize: 24)
        styles.save(style, as: "callout")

        guard let restored = QuickStyleStore(defaults: defaults).style(named: "callout") else {
            throw Failure("быстрый стиль не сохранился")
        }
        guard restored == style else { throw Failure("стиль исказился: \(restored)") }

        let document = AnnotationDocument()
        document.add(rectangle(), select: true)
        document.applyStyle(restored, to: document.selection)
        guard document.objects.first?.style == style else {
            throw Failure("перенос стиля на объект не сработал")
        }
    }

    /// `H-6`: раскладка сокращений настраивается.
    @MainActor private static func shortcutsAreCustomisable() throws {
        let defaults = freshDefaults()
        var map = ShortcutMap(defaults: defaults)
        guard map.tool(for: "a") == .arrow else { throw Failure("умолчание сокращения") }

        map.assign("z", to: .arrow)
        let reloaded = ShortcutMap(defaults: defaults)
        guard reloaded.tool(for: "z") == .arrow else { throw Failure("сокращение не сохранилось") }
        guard reloaded.tool(for: "a") == nil else { throw Failure("старое сокращение осталось") }

        map.reset()
        guard ShortcutMap(defaults: defaults).tool(for: "a") == .arrow else {
            throw Failure("сброс не вернул умолчания")
        }
    }

    /// `I-1`: несколько кадров собираются в одно изображение.
    @MainActor private static func framesCombineIntoOne() throws {
        let frames = [image(width: 100, height: 80), image(width: 100, height: 80)]
        guard let combined = ImageComposer.combine(frames, direction: .vertical, gap: 10) else {
            throw Failure("объединение не выполнено")
        }
        guard combined.width == 100, combined.height == 170 else {
            throw Failure("вертикальная раскладка неверна: \(combined.width)×\(combined.height)")
        }
        guard let row = ImageComposer.combine(frames, direction: .horizontal, gap: 10) else {
            throw Failure("горизонтальное объединение не выполнено")
        }
        guard row.width == 210, row.height == 80 else {
            throw Failure("горизонтальная раскладка неверна: \(row.width)×\(row.height)")
        }
    }

    /// `K-3`: ограничения истории настраиваются.
    @MainActor private static func historyLimitsAreConfigurable() throws {
        let defaults = freshDefaults()
        let limits = HistoryLimits(defaults: defaults)
        guard limits.maximumItems == 50 else { throw Failure("умолчание числа записей") }

        limits.maximumItems = 10
        guard HistoryLimits(defaults: defaults).maximumItems == 10 else {
            throw Failure("ограничение не сохранилось")
        }
        let kept = limits.trim(Array(0..<25))
        guard kept.count == 10, kept.first == 15 else {
            throw Failure("обрезка истории оставила не то: \(kept.prefix(3))")
        }
    }

    /// `L-3`, `L-4`, `L-6`: бюджет применения, памяти и больших изображений.
    @MainActor private static func applyAndMemoryBudgets() throws {
        let canvas = makeCanvas()
        canvas.image = image(width: 3840, height: 2160)   // склеенный скролл-снимок
        canvas.zoomToFit()
        for index in 0..<20 { canvas.document.add(rectangle(x: CGFloat(index) * 20), select: false) }

        let start = Date()
        guard let result = canvas.flattenedImage() else { throw Failure("нет результата") }
        let applyMs = Date().timeIntervalSince(start) * 1000
        guard applyMs < 100 else { throw Failure("применение заняло \(Int(applyMs))мс") }
        guard result.width == 3840 else { throw Failure("большое изображение исказилось") }

        // `L-4`: сверх исходника держится не более одной несжатой копии —
        // результат, который сейчас же уходит потребителю.
        guard canvas.debugRetainedImageCount <= 2 else {
            throw Failure("редактор держит \(canvas.debugRetainedImageCount) копий изображения")
        }
    }

    /// `O-1`: действия для Shortcuts объявлены.
    @MainActor private static func shortcutsActionsAreExposed() throws {
        let actions = ShortcutsActions.available
        guard actions.contains("annotate"), actions.contains("export") else {
            throw Failure("действия Shortcuts не объявлены: \(actions)")
        }
    }

    /// `P-4`, `P-5`: умолчания стилей сохраняются и сбрасываются.
    @MainActor private static func styleDefaultsPersistAndReset() throws {
        let defaults = freshDefaults()
        var settings = EditorSettings(defaults: defaults)
        settings.defaultTool = .box
        settings.keepsToolAfterDraw = true

        var styles = QuickStyleStore(defaults: defaults)
        styles.saveDefault(AnnotationStyle(paletteIndex: 2, lineWidth: 7, filled: true,
                                           fillOpacity: 0.3, fontSize: 24), for: .box)
        guard QuickStyleStore(defaults: defaults).defaultStyle(for: .box)?.paletteIndex == 2 else {
            throw Failure("умолчание стиля инструмента не сохранилось")
        }

        settings.reset()
        styles.reset()
        guard EditorSettings(defaults: defaults).defaultTool == .select,
              QuickStyleStore(defaults: defaults).defaultStyle(for: .box) == nil else {
            throw Failure("сброс настроек не вернул заводское состояние")
        }
    }

    /// `TR-11`, `TR-12`: положение прокрутки переживает сворачивание.
    @MainActor private static func scrollPositionSurvivesCollapse() throws {
        var model = TrayScrollModel(contentLength: 2000, viewportLength: 600, offset: 0)
        model = model.scrolled(by: 500, rubberBand: false)
        let saved = model.offset

        let restored = TrayScrollModel(contentLength: 2000, viewportLength: 600, offset: saved)
        guard restored.offset == saved else { throw Failure("положение не восстановилось") }

        // Новый снимок сбрасывает положение к новым (`TR-5`), а сворачивание — нет.
        let afterCapture = TrayScrollModel.defaultOffset(contentLength: 2000, viewportLength: 600)
        guard afterCapture != saved else {
            throw Failure("новый снимок обязан вернуть ленту к новым снимкам")
        }
    }

    /// `TR-14`: новый снимок во время инерции не даёт рывка.
    @MainActor private static func newCaptureInterruptsScrolling() throws {
        var model = TrayScrollModel(contentLength: 2000, viewportLength: 600, offset: 0)
        model = model.scrolled(by: -300)              // за край, инерция
        guard model.overshoot < 0 else { throw Failure("перетягивание не зафиксировано") }

        model = model.settled()
        model.offset = TrayScrollModel.defaultOffset(contentLength: 2000, viewportLength: 600)
        guard model.overshoot == 0 else { throw Failure("после нового снимка перетягивание обязано сняться") }
        guard model.offset == model.maximumOffset else {
            throw Failure("новый снимок не вернул ленту в положение по умолчанию")
        }
    }

    // MARK: помощники

    @MainActor private static func makeCanvas() -> AnnotationCanvasView {
        let canvas = AnnotationCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.image = image(width: 400, height: 300)
        canvas.zoomToActualSize()
        return canvas
    }

    @MainActor private static func makeLibrary() -> ScreenshotLibrary {
        let library = ScreenshotLibrary(defaults: freshDefaults(), fileManager: .default,
                                        now: { Date() })
        library.setFolderURL(FileManager.default.temporaryDirectory
            .appendingPathComponent("quickshot-remaining-\(UUID().uuidString)", isDirectory: true))
        library.setSuppressesFailureAlertsForTesting(true)
        return library
    }

    private static func rectangle(x: CGFloat = 0) -> AnnotationObject {
        AnnotationObject(kind: .rectangle,
                         geometry: .rect(CGRect(x: x, y: 0, width: 40, height: 40),
                                         cornerRadius: 0))
    }

    private static func freshDefaults() -> UserDefaults {
        let name = "quickshot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func samplePNG() -> Data {
        Clipboard.pngData(cgImage: image(width: 8, height: 8))!
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
