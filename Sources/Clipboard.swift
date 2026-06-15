import AppKit

/// Кладёт изображение в буфер обмена максимально совместимо.
///
/// Одна транзакция с двумя типами: PNG (его надёжнее всего читают Slack и прочие
/// Chromium-приложения) и TIFF (родной для AppKit — Preview, Заметки). Нельзя в одной
/// транзакции мешать writeObjects([...]) и setData(...) — это портит содержимое буфера.
enum Clipboard {

    static func copy(cgImage: CGImage) {
        let nsImage = NSImage(cgImage: cgImage,
                              size: NSSize(width: cgImage.width, height: cgImage.height))
        let pb = NSPasteboard.general
        pb.clearContents()

        let rep = NSBitmapImageRep(cgImage: cgImage)
        let png = rep.representation(using: .png, properties: [:])
        let tiff = nsImage.tiffRepresentation

        pb.declareTypes([.png, .tiff], owner: nil)
        if let png  { pb.setData(png,  forType: .png) }
        if let tiff { pb.setData(tiff, forType: .tiff) }
    }
}
