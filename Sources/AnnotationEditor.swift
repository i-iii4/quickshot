import AppKit

/// Окно редактора аннотаций.
///
/// Открывается для готового снимка — из карточки трея или закреплённого окна.
/// Оверлей захвата редактор не трогает: смешение выделения области с рисованием
/// отклонено (`X-1`), потому что рисковало бы главным сценарием продукта.
@MainActor
final class AnnotationEditorController: NSObject, NSWindowDelegate {
    /// Открытые редакторы по идентификатору снимка: один снимок нельзя
    /// открыть дважды (`ED-15`).
    private static var open: [UUID: AnnotationEditorController] = [:]

    /// Учёт открытых окон существует: один снимок нельзя редактировать дважды.
    static var debugTracksOpenEditors: Bool { true }

    /// `A-7`: изображение из буфера обмена как источник для аннотирования.
    static func imageFromPasteboard() -> CGImage? {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let source = CGImageSourceCreateWithData(data as CFData, nil) {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return nil
    }

    private let artifact: CaptureArtifact
    private let library: ScreenshotLibrary?
    private let onSaved: (CaptureArtifact, CGImage, [AnnotationObject]) -> Void

    private var window: NSWindow?
    /// Идущее сканирование: закрытие окна обязано его отменить, иначе результат
    /// всплывает поверх уже закрытого редактора.
    private var scanTask: Task<Void, Never>?
    private var isClosed = false
    private let canvas = AnnotationCanvasView(frame: .zero)
    private let toolbar = AnnotationToolbarView(frame: .zero)
    private var textField: NSTextField?
    private var editingObjectID: UUID?

    static func present(artifact: CaptureArtifact,
                        library: ScreenshotLibrary?,
                        restoring objects: [AnnotationObject] = [],
                        onSaved: @escaping (CaptureArtifact, CGImage, [AnnotationObject]) -> Void) {
        if let existing = open[artifact.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = AnnotationEditorController(artifact: artifact,
                                                    library: library,
                                                    onSaved: onSaved)
        open[artifact.id] = controller
        controller.show(restoring: objects)
    }

    /// Показ решения о скрытии. Отдельной точкой — чтобы тест видел, что
    /// именно было предъявлено пользователю, не открывая модальное окно.
    private func confirmHiding(title: String, details: String) -> Bool {
#if TESTING
        Self.debugLastAlert = title
        return false
#else
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = details
        alert.addButton(withTitle: "Hide All")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
#endif
    }

#if TESTING
    /// Последнее предъявленное пользователю решение; `nil` — окна не было.
    static var debugLastAlert: String?

    static func debugController() -> AnnotationEditorController {
        debugLastAlert = nil
        let store = CaptureArtifactStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickShotScanTests-\(UUID().uuidString)"))
        let sequence = CaptureSequence(rawValue: UInt64.random(in: 1...UInt64.max))
        store.registerCapture(sequence)
        let context = CGContext(data: nil, width: 40, height: 30,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let artifact = try! store.admit(sequence: sequence, image: context.makeImage()!)
        return AnnotationEditorController(artifact: artifact, library: nil, onSaved: { _, _, _ in })
    }

    func debugMarkClosed() { isClosed = true }

    func debugPresentScanResult(_ matches: [SensitiveMatch], imageSize: CGSize) {
        presentScanResult(matches, imageSize: imageSize)
    }
#endif

    private init(artifact: CaptureArtifact,
                 library: ScreenshotLibrary?,
                 onSaved: @escaping (CaptureArtifact, CGImage, [AnnotationObject]) -> Void) {
        self.artifact = artifact
        self.library = library
        self.onSaved = onSaved
        super.init()
    }

    private func show(restoring objects: [AnnotationObject] = []) {
        let image = artifact.fullImage() ?? artifact.previewImage
        canvas.image = image
        // `ED-5`: повторное открытие возвращает объекты редактируемыми.
        canvas.restoreObjects(objects)
        canvas.onDocumentChanged = { [weak self] in self?.syncToolbar() }
        canvas.onRequestTextEditing = { [weak self] id in self?.beginTextEditing(id) }
        toolbar.onCommand = { [weak self] command in self?.handle(command) }

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maximum = CGSize(width: screen.width * 0.9, height: screen.height * 0.9)
        let fitted = Self.windowSize(for: CGSize(width: image.width, height: image.height),
                                     maximum: maximum,
                                     toolbarHeight: toolbar.fittingSize.height)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fitted),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Annotate Screenshot"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.titlebarAppearsTransparent = false
        WindowCaptureProtection.excludeFromScreenCapture(window)

        let container = NSView(frame: NSRect(origin: .zero, size: fitted))
        container.autoresizingMask = [.width, .height]
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
        container.addSubview(toolbar)
        window.contentView = container
        layoutContents(in: container)

        // Файл, открытый в редакторе, не удаляется уборкой (`ST-18`).
        if let url = artifact.libraryURL { library?.protect(url) }

        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        syncToolbar()
    }

    /// Окно вмещает снимок целиком, пока он помещается на экран; иначе
    /// ограничивается экраном, а холст сам вписывает изображение.
    static func windowSize(for imageSize: CGSize,
                           maximum: CGSize,
                           toolbarHeight: CGFloat) -> CGSize {
        let width = min(max(720, imageSize.width), maximum.width)
        let height = min(max(480, imageSize.height + toolbarHeight), maximum.height)
        return CGSize(width: width, height: height)
    }

    private func layoutContents(in container: NSView) {
        // Панель узнаёт доступную ширину раньше, чем считает свою высоту:
        // в компактном режиме строк больше и высота другая.
        toolbar.setAvailableWidth(container.bounds.width)
        let toolbarHeight = toolbar.fittingSize.height
        toolbar.frame = NSRect(x: 0,
                               y: container.bounds.maxY - toolbarHeight,
                               width: container.bounds.width,
                               height: toolbarHeight)
        toolbar.autoresizingMask = [.width, .minYMargin]
        canvas.frame = NSRect(x: 0, y: 0,
                              width: container.bounds.width,
                              height: container.bounds.height - toolbarHeight)
    }

    func windowDidResize(_ notification: Notification) {
        guard let container = window?.contentView else { return }
        layoutContents(in: container)
    }

    func windowWillClose(_ notification: Notification) {
        isClosed = true
        scanTask?.cancel()
        scanTask = nil
        if let url = artifact.libraryURL { library?.unprotect(url) }
        Self.open.removeValue(forKey: artifact.id)
    }

    // MARK: команды

    private func handle(_ command: AnnotationToolbarView.Command) {
        switch command {
        case let .tool(tool):
            canvas.tool = tool
            window?.makeFirstResponder(canvas)
        case let .colour(index):
            canvas.setPaletteIndex(index)
        case let .weight(weight):
            canvas.setStrokeWeight(weight)
        case let .fill(filled):
            canvas.setFilled(filled)
        case .undo:
            _ = canvas.document.undo()
            canvas.needsDisplay = true
            syncToolbar()
        case .redo:
            _ = canvas.document.redo()
            canvas.needsDisplay = true
            syncToolbar()
        case .save:
            save()
        case .copy:
            copyToClipboard()
        case .close:
            window?.performClose(nil)
        case .scan:
            scanForSensitiveData()
        case .rotate:
            canvas.rotateQuarterTurn()
        }
    }

    private func syncToolbar() {
        toolbar.setSelectedTool(canvas.tool)
        toolbar.setHistoryState(canUndo: canvas.document.canUndo,
                                canRedo: canvas.document.canRedo)
        toolbar.setStyle(paletteIndex: canvas.paletteIndex,
                         weight: canvas.strokeWeight,
                         filled: canvas.isFilled)
        toolbar.setSelectionPresence(!canvas.document.selection.isEmpty)
    }

    /// `ED-2`: сохранение перезаписывает файл в папке; при выключенном
    /// автосохранении файла нет, и сохранение только фиксирует изменения на
    /// карточке (`ED-12`).
    private func save() {
        commitTextEditing()
        guard let flattened = canvas.flattenedImage() else { return }
        onSaved(artifact, flattened, canvas.document.objects)

        // При выключенном автосохранении файла в папке нет, и сохранение
        // фиксирует изменения только на карточке. Чтобы получить файл,
        // пользователь выбирает место сам (`ED-12`).
        guard library?.settings.autosaveEnabled != true else { return }
        exportToFile(flattened)
    }

    private func exportToFile(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.title = "Save Screenshot"
        panel.prompt = "Save"
        panel.nameFieldStringValue = ScreenshotNaming.fileName(date: Date())
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url,
              let png = Clipboard.pngData(cgImage: image) else { return }
        try? png.write(to: url, options: .atomic)
    }

    /// `E-6`, `E-7`: находки подсвечиваются и закрываются одним действием, но
    /// никогда не закрываются молча — пользователь видит, что именно скрыто, и
    /// решает сам. Автоматика неполна по природе, и молчаливое доверие к ней
    /// приводит к опубликованному ключу.
    private func scanForSensitiveData() {
        guard let image = canvas.image else { return }
        scanTask?.cancel()
        // Слабая ссылка обязана проверяться ПОСЛЕ приостановки: `guard let self`
        // до `await` удерживает контроллер живым через всё распознавание, и
        // результат всплывал поверх уже закрытого редактора.
        scanTask = Task { @MainActor [weak self] in
            let matches = await SensitiveDataDetector.detect(in: image)
            guard !Task.isCancelled, let self, !self.isClosed else { return }
            self.scanTask = nil
            self.presentScanResult(matches, imageSize: CGSize(width: image.width,
                                                              height: image.height))
        }
    }

    private func presentScanResult(_ matches: [SensitiveMatch], imageSize: CGSize) {
        guard !isClosed else { return }
        // Пустой результат — не новость: сообщать «ничего не найдено» значит
        // требовать действия там, где действия нет.
        guard !matches.isEmpty else { return }

        let summary = Dictionary(grouping: matches, by: \.kind)
            .map { "\($0.value.count) × \($0.key.title)" }
            .sorted()
            .joined(separator: ", ")
        let title = "Found \(matches.count) items to hide"
        guard confirmHiding(title: title,
                            details: "\(summary)\n\nThey will be covered with opaque bars.") else { return }

        canvas.document.beginGesture()
        for match in matches {
            let rect = SensitiveDataDetector.documentRect(for: match.normalizedRect,
                                                          imageSize: imageSize)
            canvas.document.add(AnnotationObject(kind: .redaction,
                                                 geometry: .rect(rect.insetBy(dx: -2, dy: -2),
                                                                 cornerRadius: 0)),
                                select: false)
        }
        canvas.document.endGesture()
        canvas.needsDisplay = true
        syncToolbar()
    }

    private func copyToClipboard() {
        commitTextEditing()
        guard let flattened = canvas.flattenedImage() else { return }
        Clipboard.copy(preparedImage: Clipboard.prepareImage(cgImage: flattened))
    }

    // MARK: текст

    private func beginTextEditing(_ id: UUID) {
        commitTextEditing()
        guard let object = canvas.document.objects.first(where: { $0.id == id }) else { return }
        let rect = canvas.textEditingFrame(for: object)
        let field = NSTextField(frame: rect)
        field.stringValue = object.text ?? ""
        // Кегль поля совпадает с экранным кеглем текста, то есть учитывает зум.
        field.font = .systemFont(ofSize: max(11, object.style.fontSize * canvas.zoomFactor))
        field.isBordered = true
        field.backgroundColor = .white
        field.focusRingType = .none
        field.target = self
        field.action = #selector(textFieldCommitted)
        canvas.addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        editingObjectID = id
    }

    @objc private func textFieldCommitted() {
        commitTextEditing()
    }

    private func commitTextEditing() {
        guard let field = textField, let id = editingObjectID else { return }
        let value = field.stringValue
        canvas.document.update(id: id) { object in
            object.text = value
            if case let .rect(rect, radius) = object.geometry {
                let size = (value as NSString).size(withAttributes: [
                    .font: NSFont.systemFont(ofSize: object.style.fontSize),
                ])
                object.geometry = .rect(CGRect(origin: rect.origin,
                                               size: CGSize(width: max(size.width, 8),
                                                            height: max(size.height, 8))),
                                        cornerRadius: radius)
            }
        }
        // Пустая подпись — это отказ от неё, а не пустой объект на снимке.
        if value.isEmpty { canvas.document.remove(ids: [id]) }
        field.removeFromSuperview()
        textField = nil
        editingObjectID = nil
        canvas.needsDisplay = true
        window?.makeFirstResponder(canvas)
        syncToolbar()
    }
}
