import AppKit

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

    static func copy(cgImage: CGImage) {
        let nsImage = NSImage(cgImage: cgImage,
                              size: NSSize(width: cgImage.width, height: cgImage.height))
        let pb = NSPasteboard.general
        pb.clearContents()

        let rep = NSBitmapImageRep(cgImage: cgImage)
        let png = rep.representation(using: .png, properties: [:])
        let tiff = nsImage.tiffRepresentation

        // Временный файл под fileURL (путь для терминалов).
        var fileURLString: String?
        if let png {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("QuickShot-\(UUID().uuidString.prefix(8)).png")
            if (try? png.write(to: url)) != nil { fileURLString = url.absoluteString }
        }

        // Порядок: сначала image-типы (картиночные приложения берут их), fileURL последним
        // (терминалы и файловые приложения берут путь).
        var types: [NSPasteboard.PasteboardType] = [.png, .tiff]
        if fileURLString != nil { types.append(.fileURL) }
        pb.declareTypes(types, owner: nil)

        if let png  { pb.setData(png,  forType: .png) }
        if let tiff { pb.setData(tiff, forType: .tiff) }
        if let fileURLString { pb.setString(fileURLString, forType: .fileURL) }
    }
}
