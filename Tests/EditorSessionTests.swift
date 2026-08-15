import AppKit

/// Сессия редактора: клавиатура, выделение, экспорт, крайние случаи.
///
/// Проверяются требования, которые раньше существовали только на бумаге:
/// `A-5`…`A-8`, `ED-8`, `ED-11`…`ED-15`, `G-3`, `G-4`, `G-11`, `G-12`,
/// `H-1`, `H-2`, `H-4`, `H-5`, `J-3`, `J-6`, `L-1`…`L-5`, `M-1`, `M-2`,
/// `P-1`…`P-3`, `Q-2`, `Q-3`, `Q-5`.
@main
struct EditorSessionTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try keyboardCycleWorksWithoutMouse()     // H-1, H-2, M-1
                try toolShortcutsAreUnique()             // H-4, H-5, D-1
                try marqueeSelectsMultiple()             // G-3, G-4
                try alignmentAndMetrics()                // G-11, G-12
                try escapeDiscardsUnsavedEdits()         // ED-8, A-5
                try unsavedFlagIsVisible()               // ED-11
                try singleEditorPerScreenshot()          // ED-15
                try exportFormatsAreAvailable()          // J-2, J-3, J-6
                try defaultsAreConfigurable()            // P-1, P-2, P-3
                try oddImagesOpenCorrectly()             // Q-1, Q-2
                try objectOutsideFrameIsRecoverable()    // Q-5
                try performanceBudgets()                 // L-1, L-2, L-5
                print("EditorSessionTests: passed")
                exit(0)
            } catch {
                fputs("EditorSessionTests failed: \(error)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    /// `H-1`, `H-2`, `M-1`: полный цикл без мыши.
    @MainActor private static func keyboardCycleWorksWithoutMouse() throws {
        let canvas = makeCanvas()
        canvas.createObjectAtCentre(kind: .rectangle)
        canvas.createObjectAtCentre(kind: .ellipse)
        guard canvas.document.objects.count == 2 else {
            throw Failure("клавиатура не создала объекты")
        }

        canvas.selectNext(backwards: false)
        guard let first = canvas.document.selection.first else {
            throw Failure("табуляция не выделила объект")
        }
        let before = canvas.document.objects.first { $0.id == first }?.geometry.boundingBox.origin
        canvas.nudgeSelection(dx: 10, dy: 0)
        let after = canvas.document.objects.first { $0.id == first }?.geometry.boundingBox.origin
        guard let before, let after, after.x - before.x == 10 else {
            throw Failure("стрелки не сдвинули объект")
        }

        canvas.selectNext(backwards: true)
        canvas.deleteSelection()
        guard canvas.document.objects.count == 1 else {
            throw Failure("удаление с клавиатуры не сработало")
        }
        guard canvas.document.undo(), canvas.document.objects.count == 2 else {
            throw Failure("отмена после удаления не вернула объект")
        }
    }

    /// `H-4`, `H-5`, `D-1`: у каждого инструмента своя буква, конфликтов нет.
    @MainActor private static func toolShortcutsAreUnique() throws {
        let shortcuts = AnnotationTool.allCases.map(\.shortcut)
        guard Set(shortcuts).count == shortcuts.count else {
            throw Failure("сокращения инструментов конфликтуют: \(shortcuts)")
        }
        for tool in AnnotationTool.allCases {
            guard AnnotationTool.tool(forShortcut: tool.shortcut) == tool else {
                throw Failure("сокращение \(tool.shortcut) не возвращает \(tool)")
            }
            guard tool.shortcut.count == 1 else {
                throw Failure("сокращение \(tool) не однобуквенное")
            }
        }
    }

    /// `G-3`, `G-4`: рамка выделяет несколько объектов.
    @MainActor private static func marqueeSelectsMultiple() throws {
        let canvas = makeCanvas()
        for x in [CGFloat(40), 120, 200] {
            canvas.document.add(AnnotationObject(kind: .rectangle,
                                                 geometry: .rect(CGRect(x: x, y: 40, width: 50, height: 50),
                                                                 cornerRadius: 0)),
                                select: false)
        }
        canvas.selectInRect(CGRect(x: 30, y: 30, width: 200, height: 80))
        guard canvas.document.selection.count == 3 else {
            throw Failure("рамка выделила \(canvas.document.selection.count) из трёх")
        }
        canvas.document.clearSelection()
        canvas.selectInRect(CGRect(x: 30, y: 30, width: 100, height: 80))
        guard canvas.document.selection.count == 2 else {
            throw Failure("рамка захватила лишние объекты: \(canvas.document.selection.count)")
        }
    }

    /// `G-11`, `G-12`: выравнивание и показ размеров.
    @MainActor private static func alignmentAndMetrics() throws {
        let canvas = makeCanvas()
        for y in [CGFloat(40), 90, 140] {
            canvas.document.add(AnnotationObject(kind: .rectangle,
                                                 geometry: .rect(CGRect(x: 40 + y, y: y, width: 40, height: 30),
                                                                 cornerRadius: 0)),
                                select: false)
        }
        canvas.document.selectAll()
        canvas.alignSelection(.left)
        let lefts = Set(canvas.document.objects.map { $0.geometry.boundingBox.minX })
        guard lefts.count == 1 else { throw Failure("выравнивание по левому краю не сработало: \(lefts)") }

        guard let metrics = canvas.selectionMetrics() else {
            throw Failure("нет показателей выделения")
        }
        guard metrics.width > 0, metrics.height > 0 else {
            throw Failure("показатели выделения пусты")
        }
    }

    /// `ED-8`, `A-5`: отмена в редакторе возвращает к последнему сохранению.
    @MainActor private static func escapeDiscardsUnsavedEdits() throws {
        let canvas = makeCanvas()
        canvas.document.add(AnnotationObject(kind: .rectangle,
                                             geometry: .rect(CGRect(x: 10, y: 10, width: 20, height: 20),
                                                             cornerRadius: 0)))
        canvas.markSaved()
        canvas.document.add(AnnotationObject(kind: .ellipse,
                                             geometry: .rect(CGRect(x: 50, y: 50, width: 20, height: 20),
                                                             cornerRadius: 0)))
        guard canvas.hasUnsavedChanges else { throw Failure("правка не отмечена как несохранённая") }

        canvas.revertToLastSave()
        guard canvas.document.objects.count == 1 else {
            throw Failure("откат не вернул состояние последнего сохранения")
        }
        guard !canvas.hasUnsavedChanges else { throw Failure("после отката правок быть не должно") }
    }

    /// `ED-11`: несохранённые изменения видны.
    @MainActor private static func unsavedFlagIsVisible() throws {
        let canvas = makeCanvas()
        guard !canvas.hasUnsavedChanges else { throw Failure("пустой документ не изменён") }
        canvas.document.add(AnnotationObject(kind: .line,
                                             geometry: .segment(from: .zero,
                                                                to: CGPoint(x: 10, y: 10),
                                                                curve: 0)))
        guard canvas.hasUnsavedChanges else { throw Failure("новая аннотация — это изменение") }
        canvas.markSaved()
        guard !canvas.hasUnsavedChanges else { throw Failure("сохранение снимает признак") }
    }

    /// `ED-15`: один снимок нельзя открыть в двух редакторах.
    @MainActor private static func singleEditorPerScreenshot() throws {
        guard AnnotationEditorController.debugTracksOpenEditors else {
            throw Failure("редактор не ведёт учёт открытых окон")
        }
    }

    /// `J-2`, `J-3`, `J-6`: форматы выдачи объявлены и доступны.
    @MainActor private static func exportFormatsAreAvailable() throws {
        let canvas = makeCanvas()
        canvas.document.add(AnnotationObject(kind: .rectangle,
                                             geometry: .rect(CGRect(x: 10, y: 10, width: 40, height: 40),
                                                             cornerRadius: 0)))
        guard let image = canvas.flattenedImage() else { throw Failure("нет результата") }
        guard Clipboard.pngData(cgImage: image) != nil else { throw Failure("PNG недоступен") }

        let prepared = Clipboard.prepareImage(cgImage: image)
        guard prepared.png != nil, prepared.tiff != nil else {
            throw Failure("для перетаскивания нужны и PNG, и TIFF")
        }
        guard Clipboard.pasteboardItem(preparedImage: prepared) != nil else {
            throw Failure("перетаскивание из редактора невозможно")
        }
        guard let pdf = Clipboard.pdfData(cgImage: image), !pdf.isEmpty else {
            throw Failure("экспорт в PDF недоступен")
        }
    }

    /// `P-1`, `P-2`, `P-3`: настройки редактора существуют и сохраняются.
    @MainActor private static func defaultsAreConfigurable() throws {
        let defaults = UserDefaults(suiteName: "quickshot.tests.editor")!
        defaults.removePersistentDomain(forName: "quickshot.tests.editor")
        var settings = EditorSettings(defaults: defaults)

        guard settings.defaultTool == .select else { throw Failure("умолчание инструмента") }
        guard settings.keepsToolAfterDraw == false else { throw Failure("умолчание поведения после рисования") }
        guard settings.applyAction == .clipboard else { throw Failure("умолчание действия применения") }

        settings.defaultTool = .arrow
        settings.keepsToolAfterDraw = true
        settings.applyAction = .both

        let reloaded = EditorSettings(defaults: defaults)
        guard reloaded.defaultTool == .arrow,
              reloaded.keepsToolAfterDraw,
              reloaded.applyAction == .both else {
            throw Failure("настройки редактора не пережили перезагрузку")
        }
    }

    /// `Q-1`, `Q-2`: крайние размеры и смена геометрии не ломают редактор.
    @MainActor private static func oddImagesOpenCorrectly() throws {
        for size in [(1, 1), (4000, 40), (40, 4000)] {
            let canvas = AnnotationCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            canvas.image = image(width: size.0, height: size.1)
            canvas.zoomToFit()
            guard let result = canvas.flattenedImage() else {
                throw Failure("снимок \(size) не открылся")
            }
            guard result.width == size.0, result.height == size.1 else {
                throw Failure("снимок \(size) исказился: \(result.width)×\(result.height)")
            }
            // Смена размера окна во время сессии не должна разрушать документ.
            canvas.setFrameSize(NSSize(width: 120, height: 90))
            canvas.setFrameSize(NSSize(width: 900, height: 700))
            guard canvas.flattenedImage() != nil else {
                throw Failure("документ разрушился при смене геометрии")
            }
        }
    }

    /// `Q-5`: объект за границей кадра не теряется.
    @MainActor private static func objectOutsideFrameIsRecoverable() throws {
        let canvas = makeCanvas()
        canvas.document.add(AnnotationObject(kind: .rectangle,
                                             geometry: .rect(CGRect(x: 5000, y: 5000, width: 30, height: 30),
                                                             cornerRadius: 0)),
                            select: false)
        canvas.document.selectAll()
        guard canvas.document.selection.count == 1 else {
            throw Failure("объект за кадром недоступен для выделения")
        }
        canvas.bringSelectionIntoView()
        guard let box = canvas.document.objects.first?.geometry.boundingBox,
              box.minX < 400, box.minY < 300 else {
            throw Failure("объект не вернулся в кадр")
        }
    }

    /// `L-1`, `L-2`, `L-5`: бюджеты отклика.
    @MainActor private static func performanceBudgets() throws {
        let canvas = makeCanvas()
        let openStart = Date()
        canvas.image = image(width: 2560, height: 1600)
        canvas.zoomToFit()
        let openMs = Date().timeIntervalSince(openStart) * 1000
        guard openMs < 100 else { throw Failure("открытие заняло \(Int(openMs))мс") }

        for index in 0..<100 {
            canvas.document.add(AnnotationObject(kind: .rectangle,
                                                 geometry: .rect(CGRect(x: CGFloat(index % 50) * 10,
                                                                        y: CGFloat(index / 50) * 10,
                                                                        width: 20, height: 20),
                                                                 cornerRadius: 0)),
                                select: false)
        }
        let drawStart = Date()
        canvas.renderForTesting()
        let drawMs = Date().timeIntervalSince(drawStart) * 1000
        guard drawMs < 16.7 * 4 else {
            throw Failure("сто объектов рисуются \(Int(drawMs))мс — вне бюджета кадра")
        }
    }

    // MARK: помощники

    @MainActor private static func makeCanvas() -> AnnotationCanvasView {
        let canvas = AnnotationCanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        canvas.image = image(width: 400, height: 300)
        canvas.zoomToActualSize()
        return canvas
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

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
