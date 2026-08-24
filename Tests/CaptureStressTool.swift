import AppKit
import CoreGraphics
import Darwin

/// Стенд для замера серии снимков подряд — того сценария, в котором хоткей
/// «уставал». Печатает числа, а не выносит вердикт: сначала факты, потом
/// правки.
///
/// Две независимые части:
/// 1. Путь доставки: приём артефакта, карточка в трее, запись в библиотеку,
///    публикация в буфер. Изображения синтетические, но размера настоящего
///    экрана — именно объём данных и подозревается.
/// 2. Съёмка дисплеев настоящим провайдером, повторно. Это сторона
///    WindowServer, где и вырос разброс в журнале пользователя.
@main
struct CaptureStressTool {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            let iterations = CommandLine.arguments.count > 1
                ? Int(CommandLine.arguments[1]) ?? 10
                : 10
            await measureDeliveryPath(iterations: iterations)
            await measureCardCost(iterations: iterations)
            measurePreparation(iterations: iterations)
            exit(0)
        }
        RunLoop.main.run()
    }

    // MARK: путь доставки

    @MainActor private static func measureDeliveryPath(iterations: Int) async {
        guard let screen = NSScreen.main else {
            print("нет экрана")
            return
        }
        let scale = screen.backingScaleFactor
        let width = Int(screen.frame.width * scale)
        let height = Int(screen.frame.height * scale)
        print("=== путь доставки: \(iterations) снимков \(width)x\(height) ===")
        print("№   admit   card    store   clipbrd  всего   память   данные")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickShotStress-\(UUID().uuidString)")
        let store = CaptureArtifactStore(rootURL: root)
        let manager = ThumbnailManager(artifactStore: store)
        let defaults = UserDefaults(suiteName: "quickshot-stress-\(UUID().uuidString)") ?? .standard
        let library = ScreenshotLibrary(defaults: defaults)
        library.setFolderURL(root.appendingPathComponent("Library"))
        library.setAutosaveEnabled(true)
        library.setRetention(.forever)
        library.setSuppressesFailureAlertsForTesting(true)
        manager.library = library

        ThumbnailManager.debugDisablesInsertionMotion =
            ProcessInfo.processInfo.environment["QUICKSHOT_STRESS_NO_MOTION"] != nil
        let baseline = footprintMB()
        var previousFootprint = baseline
        var previousNamed = 0.0
        var previousPreview = 0.0
        var previousData = 0.0
        var previousCard = 0.0
        for index in 0..<iterations {
            guard let image = solidImage(width: width, height: height, seed: index) else { continue }
            let skipTray = ProcessInfo.processInfo.environment["QUICKSHOT_STRESS_SKIP_TRAY"] != nil
            let sequence = CaptureSequence(rawValue: UInt64(index + 1))
            store.registerCapture(sequence)

            let admitStart = CFAbsoluteTimeGetCurrent()
            guard let artifact = try? store.admit(sequence: sequence, image: image) else {
                print("\(index): отказ приёма")
                continue
            }
            let admitMs = ms(since: admitStart)
            let afterAdmit = footprintMB()

            let cardStart = CFAbsoluteTimeGetCurrent()
            if !skipTray {
                manager.add(artifact: artifact, on: screen)
                manager.debugFinishMotions()
            }
            let cardMs = ms(since: cardStart)
            let afterCard = footprintMB()

            // Библиотека и буфер работают так же, как в контроллере захвата:
            // PNG готовится в фоне, а запись и публикация идут на главном.
            let prepared = await artifact.preparedImage()
            let afterPrepare = footprintMB()

            let storeStart = CFAbsoluteTimeGetCurrent()
            if let png = prepared.png { _ = library.store(pngData: png) }
            let storeMs = ms(since: storeStart)

            let clipboardStart = CFAbsoluteTimeGetCurrent()
            if ProcessInfo.processInfo.environment["QUICKSHOT_STRESS_SKIP_CLIPBOARD"] == nil {
                Clipboard.copy(preparedImage: prepared)
            }
            let clipboardMs = ms(since: clipboardStart)

            // Настоящее приложение между снимками возвращается в run loop, и
            // autorelease-пулы сливаются. Без этого стенд копит временные
            // объекты и приписывает их продукту.
            if ProcessInfo.processInfo.environment["QUICKSHOT_STRESS_REMOVE_CARDS"] != nil,
               let card = manager.debugThumbnail(for: artifact.id) {
                manager.remove(card)
                manager.debugFinishMotions()
            }
            await drainRunLoop()
            // Освобождённые, но не возвращённые системе блоки: если после
            // сброса след падает, память держит аллокатор, а не наш граф.
            let beforeRelief = footprintMB()
            malloc_zone_pressure_relief(nil, 0)
            let afterRelief = footprintMB()

            let total = admitMs + cardMs + storeMs + clipboardMs
            let pngMB = Double(prepared.png?.count ?? 0) / 1_048_576
            let tiffMB = Double(prepared.tiff?.count ?? 0) / 1_048_576
            print(String(format: "%-3d %-7.1f %-7.1f %-7.1f %-8.1f %-7.1f %-8.0f png %.1f, tiff %.1f",
                         index + 1, admitMs, cardMs, storeMs, clipboardMs, total,
                         footprintMB() - baseline, pngMB, tiffMB))
            print(String(format: "    память по шагам: приём %.0f, карточка %.0f, подготовка %.0f, буфер %.0f; кадров в памяти %d, данных %.1f MB",
                         afterAdmit - baseline, afterCard - baseline,
                         afterPrepare - baseline, footprintMB() - baseline,
                         store.debugRetainedSourceCount, store.debugRetainedDataMB))
            _ = beforeRelief
            _ = afterRelief
            let previewMB = store.debugRetainedPreviewMB
            let dataMB = store.debugRetainedDataMB
            let sourceMB = store.debugRetainedSourceMB
            let cardMB = manager.debugCardRasterMB
            let named = previewMB + dataMB + sourceMB + cardMB
            let now = footprintMB()
            // Прирост считается ЗА СНИМОК: одноразовые кэши и полноэкранный
            // слой окна-хоста появляются один раз и к цене снимка отношения
            // не имеют.
            let growth = now - previousFootprint
            let namedGrowth = named - previousNamed
            let remainder = growth - namedGrowth
            let share = growth > 0 ? remainder / growth * 100 : 0
            previousFootprint = now
            previousNamed = named
            print(String(format: "    на снимок: прирост %.1f MB; названо %.1f (превью %.1f, данные %.1f, растры карточек %.1f); неучтено %.1f MB (%.0f%%)",
                         growth, namedGrowth,
                         previewMB - previousPreview, dataMB - previousData, cardMB - previousCard,
                         remainder, share))
            previousPreview = previewMB
            previousData = dataMB
            previousCard = cardMB
        }
        // Итог по серии: одиночная итерация шумит на аллокаторе, судить надо по
        // среднему.
        let series = max(1, iterations)
        let totalGrowth = footprintMB() - baseline
        let namedTotal = store.debugRetainedPreviewMB + store.debugRetainedDataMB
            + store.debugRetainedSourceMB + manager.debugCardRasterMB
        let remainderShare = totalGrowth > 0 ? (totalGrowth - namedTotal) / totalGrowth * 100 : 0
        print(String(format: "прирост памяти за серию: %.0f MB (%.1f MB на снимок)",
                     totalGrowth, totalGrowth / Double(series)))
        print(String(format: "названо за серию: %.1f MB (превью %.1f, данные %.1f, кадры %.1f, растры карточек %.1f); неучтено %.1f MB (%.0f%%)",
                     namedTotal,
                     store.debugRetainedPreviewMB, store.debugRetainedDataMB,
                     store.debugRetainedSourceMB, manager.debugCardRasterMB,
                     totalGrowth - namedTotal, remainderShare))
        manager.shutdown()
        store.shutdown()
        // Если после разбора след возвращается — память держал наш граф, и
        // перечень просто неполон. Если остаётся — держат кэши и аллокатор.
        await drainRunLoop()
        malloc_zone_pressure_relief(nil, 0)
        print(String(format: "после разбора трея и хранилища: %.0f MB сверх базы",
                     footprintMB() - baseline))
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: съёмка дисплеев

    /// Из чего состоит цена карточки: сама вью, её слои, размещение в окне.
    @MainActor private static func measureCardCost(iterations: Int) async {
        guard let screen = NSScreen.main else { return }
        print("")
        print("=== цена карточки: \(iterations) штук ===")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickShotCardCost-\(UUID().uuidString)")
        let store = CaptureArtifactStore(rootURL: root)
        let scale = screen.backingScaleFactor
        let width = Int(screen.frame.width * scale)
        let height = Int(screen.frame.height * scale)

        var artifacts: [CaptureArtifact] = []
        let beforeArtifacts = footprintMB()
        for index in 0..<iterations {
            guard let image = solidImage(width: width, height: height, seed: index) else { continue }
            let sequence = CaptureSequence(rawValue: UInt64(500 + index))
            store.registerCapture(sequence)
            if let artifact = try? store.admit(sequence: sequence, image: image) {
                _ = await artifact.preparedImage()
                artifacts.append(artifact)
            }
            await drainRunLoop()
        }
        let afterArtifacts = footprintMB()
        print(String(format: "артефакт без карточки: %.1f MB на штуку",
                     (afterArtifacts - beforeArtifacts) / Double(max(1, iterations))))

        let host = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                            backing: .buffered, defer: false)
        let content = NSView(frame: screen.frame)
        host.contentView = content
        // Один менеджер на весь замер: он держит окно-хост и хаб, и это цена
        // трея, а не карточки.
        let sharedManager = ThumbnailManager(artifactStore: store)
        await drainRunLoop()
        var cards: [ThumbnailWindow] = []
        let beforeCards = footprintMB()
        for (index, artifact) in artifacts.enumerated() {
            let card = ThumbnailWindow(artifact: artifact,
                                       screen: screen,
                                       manager: sharedManager,
                                       width: 240,
                                       screenHeight: screen.frame.height)
            content.addSubview(card.hostView)
            card.placeInstant(origin: NSPoint(x: 20, y: 20 + CGFloat(index) * 10))
            cards.append(card)
            await drainRunLoop()
        }
        content.layoutSubtreeIfNeeded()
        await drainRunLoop()
        print(String(format: "карточка поверх артефакта: %.1f MB на штуку",
                     (footprintMB() - beforeCards) / Double(max(1, cards.count))))

        sharedManager.shutdown()
        for card in cards { card.close() }
        cards.removeAll()
        artifacts.removeAll()
        store.shutdown()
        await drainRunLoop()
        try? FileManager.default.removeItem(at: root)
    }

    /// Бисекция внутри подготовки: что именно оставляет след — кодирование PNG,
    /// кодирование TIFF или запись файла.
    @MainActor private static func measurePreparation(iterations: Int) {
        guard let screen = NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        let width = Int(screen.frame.width * scale)
        let height = Int(screen.frame.height * scale)
        print("")
        print("=== подготовка по частям: \(iterations) прогонов \(width)x\(height) ===")

        func run(_ name: String, _ body: (CGImage) -> Void) {
            let before = footprintMB()
            for index in 0..<iterations {
                autoreleasepool {
                    guard let image = solidImage(width: width, height: height, seed: index) else { return }
                    body(image)
                }
            }
            malloc_zone_pressure_relief(nil, 0)
            print(String(format: "%-24s прирост %.0f MB", (name as NSString).utf8String!, footprintMB() - before))
        }

        run("только кадр", { _ in })
        run("PNG", { image in _ = Clipboard.pngData(cgImage: image) })
        run("TIFF", { image in _ = Clipboard.debugTIFFData(cgImage: image) })
        run("TIFF через AppKit", { image in _ = Clipboard.debugTIFFDataViaAppKit(cgImage: image) })
        run("полная подготовка", { image in _ = Clipboard.prepareImage(cgImage: image) })
    }

    // MARK: помощники

    private static func quartzBounds(for screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGRect(x: screen.frame.minX,
                      y: primaryHeight - screen.frame.maxY,
                      width: screen.frame.width,
                      height: screen.frame.height)
    }

    /// Возврат в run loop между снимками: пулы сливаются так же, как в
    /// работающем приложении.
    @MainActor private static func drainRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                autoreleasepool { }
                continuation.resume()
            }
        }
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    private static func ms(since start: CFAbsoluteTime) -> Double {
        (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private static func solidImage(width: Int, height: Int, seed: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Заливка с шумом: одноцветный кадр сжимается в ничто и занижает
        // стоимость подготовки PNG.
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in stride(from: 0, to: height, by: 7) {
            context.setFillColor(CGColor(red: Double((row + seed) % 255) / 255,
                                         green: 0.3, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: width, height: 3))
        }
        return context.makeImage()
    }
}
