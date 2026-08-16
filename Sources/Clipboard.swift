import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Кладёт изображение в буфер обмена максимально совместимо.
///
/// Три типа в одной транзакции:
/// - PNG — его надёжнее всего читают Slack и прочие Chromium-приложения;
/// - TIFF — родной для AppKit (Preview, Заметки);
/// - fileURL на временный PNG — чтобы терминалы по Cmd-V вставляли ПУТЬ к файлу (как при copy
///   файла в Finder и как при drag-out отсюда). Без него у терминала на Cmd-V нет ни текста, ни
///   файловой ссылки — только байты картинки, и вставка «ломается». Приложения-картинки берут
///   PNG/TIFF и игнорируют файловую ссылку, поэтому их вставка не меняется.
///
/// Нельзя в одной транзакции мешать writeObjects([...]) и setData(...)/setString(...) — это
/// портит содержимое буфера; поэтому всё через declareTypes + setData/setString.
enum Clipboard {
    struct PreparedImage: Sendable {
        let png: Data?
        let tiff: Data?
        let fileURL: URL?

        var fileURLString: String? { fileURL?.absoluteString }

        var isEmpty: Bool {
            png == nil && tiff == nil && fileURL == nil
        }
    }

    static func pngData(cgImage: CGImage) -> Data? {
        imageData(cgImage: cgImage, type: .png)
    }

    /// `J-6`: экспорт в PDF. Растровый снимок кладётся страницей своего
    /// размера — векторизовать нечего, но PDF нужен для вставки в документы.
    static func pdfData(cgImage: CGImage) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.draw(cgImage, in: box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// Кодирование идёт в собственном autorelease-пуле. Без него временные
    /// объекты ImageIO — а это десятки мегабайт на кадр — остаются висеть до
    /// слива пула потока, и после серии снимков процесс раздувается на
    /// сотни мегабайт.
    /// TIFF здесь НЕ кодируется: он весит десятки мегабайт на кадр и столько же
    /// оставляет за собой при каждом кодировании, тогда как спрашивают его
    /// редко. В буфер он уходит обещанием — см. `copy(preparedImage:)`.
    static func prepareImage(cgImage: CGImage, fileURL: URL? = nil) -> PreparedImage {
        autoreleasepool {
            let png = pngData(cgImage: cgImage)

            var writtenURL: URL?
            if let png, let fileURL {
                do {
                    try png.write(to: fileURL, options: .atomic)
                    writtenURL = fileURL
                } catch {
                    writtenURL = nil
                }
            }

            return PreparedImage(png: png, tiff: nil, fileURL: writtenURL)
        }
    }

    /// TIFF из готового PNG: артефакт не удерживает несжатый кадр, но
    /// повторная доставка обязана положить в буфер тот же набор типов.
    nonisolated static func tiffData(fromPNG png: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return imageData(cgImage: image, type: .tiff)
    }

    /// Владельца обещания система не удерживает — ссылку держим сами, до
    /// следующего копирования.
    nonisolated(unsafe) private static var tiffPromise: TIFFPromise?

    static func copy(preparedImage prepared: PreparedImage) {
        let pb = NSPasteboard.general
        var types = pasteboardTypes(for: prepared)
        // TIFF объявляется всегда, когда есть из чего его собрать: приложения,
        // читающие только его, обязаны продолжать работать.
        if prepared.png != nil, !types.contains(.tiff) { types.append(.tiff) }
        guard !types.isEmpty else { return }
        let promise = prepared.png.map { TIFFPromise(png: $0) }
        tiffPromise = promise
        pb.declareTypes(types, owner: promise)

        if let png = prepared.png { pb.setData(png, forType: .png) }
        if let tiff = prepared.tiff { pb.setData(tiff, forType: .tiff) }
        if let fileURLString = prepared.fileURLString {
            pb.setString(fileURLString, forType: .fileURL)
        }
    }

    static func copy(preparedImages: [PreparedImage]) {
        multiCopyPromises.removeAll()
        let preparedImages = preparedImages.filter { !$0.isEmpty }
        guard !preparedImages.isEmpty else { return }
        if preparedImages.count == 1 {
            copy(preparedImage: preparedImages[0])
            return
        }

        let items = preparedImages.compactMap { pasteboardItem(preparedImage: $0) }
        guard !items.isEmpty else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items)
    }

    static func pasteboardItem(preparedImage prepared: PreparedImage) -> NSPasteboardItem? {
        let types = pasteboardTypes(for: prepared)
        guard !types.isEmpty else { return nil }
        let item = NSPasteboardItem()
        if let png = prepared.png { item.setData(png, forType: .png) }
        if let tiff = prepared.tiff {
            item.setData(tiff, forType: .tiff)
        } else if let png = prepared.png {
            // Тот же принцип для набора снимков: TIFF по запросу.
            let provider = TIFFPromise(png: png)
            multiCopyPromises.append(provider)
            item.setDataProvider(provider, forTypes: [.tiff])
        }
        if let fileURLString = prepared.fileURLString {
            item.setString(fileURLString, forType: .fileURL)
        }
        return item
    }

#if TESTING
    /// Только для стенда: замер стоимости кодирования TIFF отдельно от PNG.
    static func debugTIFFData(cgImage: CGImage) -> Data? {
        imageData(cgImage: cgImage, type: .tiff)
    }

    static func debugTIFFDataViaAppKit(cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .tiff, properties: [:])
    }
#endif

    /// Превращение обещаний в данные. Обещание исполняет живой процесс: при
    /// завершении приложения его надо материализовать, иначе получатель,
    /// который спросит TIFF уже после закрытия QuickShot, не получит ничего.
    /// Чтение типа из буфера и есть запрос к владельцу — система вызывает его
    /// и запоминает отданные данные.
    static func materializePendingPromises() {
        let pb = NSPasteboard.general
        guard let types = pb.types, types.contains(.tiff) else { return }
        _ = pb.data(forType: .tiff)
        if let items = pb.pasteboardItems {
            for item in items where item.types.contains(.tiff) {
                _ = item.data(forType: .tiff)
            }
        }
    }

#if TESTING
    /// Сколько раз у обещания спрашивали данные. После материализации данные
    /// лежат в буфере, и повторное чтение обязано обходиться без обещания.
    static var debugPromiseRequestCount: Int { TIFFPromise.debugRequestCount }
    static func debugResetPromiseRequestCount() { TIFFPromise.debugRequestCount = 0 }
#endif

    /// Обещания для набора снимков живут до следующего копирования.
    nonisolated(unsafe) private static var multiCopyPromises: [TIFFPromise] = []

    private static func imageData(cgImage: CGImage, type: UTType) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 type.identifier as CFString,
                                                                 1,
                                                                 nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func pasteboardTypes(for prepared: PreparedImage) -> [NSPasteboard.PasteboardType] {
        // Порядок: сначала image-типы (картиночные приложения берут их), fileURL последним
        // (терминалы и файловые приложения берут путь).
        var types: [NSPasteboard.PasteboardType] = []
        if prepared.png != nil { types.append(.png) }
        if prepared.tiff != nil { types.append(.tiff) }
        if prepared.fileURL != nil { types.append(.fileURL) }
        return types
    }
}

/// Обещание TIFF: кодирование запускается, только если получатель прямо
/// попросил этот тип. Хранится сжатый PNG (единицы мегабайт), а не готовый
/// несжатый кадр — именно он и раздувал процесс.
final class TIFFPromise: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private let png: Data

    init(png: Data) {
        self.png = png
        super.init()
    }

    @objc func pasteboard(_ pasteboard: NSPasteboard,
                          provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let tiff = Clipboard.tiffData(fromPNG: png) else { return }
#if TESTING
        Self.debugRequestCount += 1
#endif
        pasteboard.setData(tiff, forType: .tiff)
    }

    func pasteboard(_ pasteboard: NSPasteboard?,
                    item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let tiff = Clipboard.tiffData(fromPNG: png) else { return }
#if TESTING
        Self.debugRequestCount += 1
#endif
        item.setData(tiff, forType: .tiff)
    }

#if TESTING
    nonisolated(unsafe) static var debugRequestCount = 0
#endif
}
