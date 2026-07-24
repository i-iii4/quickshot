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

    static func prepareImage(cgImage: CGImage, fileURL: URL? = nil) -> PreparedImage {
        let png = pngData(cgImage: cgImage)
        let tiff = imageData(cgImage: cgImage, type: .tiff)

        var writtenURL: URL?
        if let png, let fileURL {
            do {
                try png.write(to: fileURL, options: .atomic)
                writtenURL = fileURL
            } catch {
                writtenURL = nil
            }
        }

        return PreparedImage(png: png, tiff: tiff, fileURL: writtenURL)
    }

    static func copy(preparedImage prepared: PreparedImage) {
        let pb = NSPasteboard.general
        let types = pasteboardTypes(for: prepared)
        guard !types.isEmpty else { return }
        pb.declareTypes(types, owner: nil)

        if let png = prepared.png { pb.setData(png, forType: .png) }
        if let tiff = prepared.tiff { pb.setData(tiff, forType: .tiff) }
        if let fileURLString = prepared.fileURLString {
            pb.setString(fileURLString, forType: .fileURL)
        }
    }

    static func prepareImages(cgImages: [CGImage]) -> [PreparedImage] {
        cgImages.map { prepareImage(cgImage: $0) }.filter { !$0.isEmpty }
    }

    static func prepareImage(cgImage: CGImage,
                             qos: DispatchQoS.QoSClass = .userInitiated,
                             completion: @escaping (PreparedImage) -> Void) {
        DispatchQueue.global(qos: qos).async {
            let prepared = prepareImage(cgImage: cgImage)
            DispatchQueue.main.async {
                completion(prepared)
            }
        }
    }

    static func prepareImages(cgImages: [CGImage],
                              qos: DispatchQoS.QoSClass = .userInitiated,
                              completion: @escaping ([PreparedImage]) -> Void) {
        DispatchQueue.global(qos: qos).async {
            let prepared = prepareImages(cgImages: cgImages)
            DispatchQueue.main.async {
                completion(prepared)
            }
        }
    }

    static func copy(preparedImages: [PreparedImage]) {
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
        if let tiff = prepared.tiff { item.setData(tiff, forType: .tiff) }
        if let fileURLString = prepared.fileURLString {
            item.setString(fileURLString, forType: .fileURL)
        }
        return item
    }

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
