import AppKit
import CoreGraphics
import Darwin

/// Доставка снимка в буфер обмена: набор типов и цена подготовки.
///
/// Кодирование TIFF полноразмерного кадра оставляет за собой около 30 МБ за
/// вызов и делает это линейно — серия снимков раздувала процесс на сотни
/// мегабайт, из-за чего система уходила в нехватку памяти, съёмка дисплея
/// замедлялась и захват начинал отклоняться. Поэтому TIFF готовится по
/// запросу. Набор типов в буфере при этом обязан остаться прежним.
@main
struct ClipboardDeliveryTests {
    @MainActor
    static func main() {
        do {
            try preparationSkipsTIFF()
            try pasteboardStillOffersPNGAndTIFF()
            try multipleImagesStillOfferTIFF()
            try preparationDoesNotAccumulateMemory()
            try promisedTIFFSurvivesTermination()
            print("ClipboardDeliveryTests: passed")
            exit(0)
        } catch {
            fputs("ClipboardDeliveryTests failed: \(error)\n", stderr)
            exit(1)
        }
    }

    /// Подготовка не кодирует TIFF: именно она стоила памяти.
    @MainActor private static func preparationSkipsTIFF() throws {
        let prepared = Clipboard.prepareImage(cgImage: try image(width: 400, height: 300))
        guard prepared.png != nil else { throw Failure("подготовка не дала PNG") }
        guard prepared.tiff == nil else { throw Failure("подготовка снова кодирует TIFF заранее") }
    }

    /// Приложение-получатель по-прежнему находит и PNG, и TIFF.
    @MainActor private static func pasteboardStillOffersPNGAndTIFF() throws {
        let prepared = Clipboard.prepareImage(cgImage: try image(width: 320, height: 200))
        NSPasteboard.general.clearContents()
        Clipboard.copy(preparedImage: prepared)

        let types = NSPasteboard.general.types ?? []
        guard types.contains(.png) else { throw Failure("в буфере нет PNG: \(types)") }
        guard types.contains(.tiff) else { throw Failure("в буфере не объявлен TIFF: \(types)") }
        guard NSPasteboard.general.data(forType: .png) != nil else {
            throw Failure("PNG объявлен, но не отдаётся")
        }
        guard let tiff = NSPasteboard.general.data(forType: .tiff), !tiff.isEmpty else {
            throw Failure("TIFF объявлен, но обещание не исполняется")
        }
        guard NSImage(data: tiff) != nil else { throw Failure("отданный TIFF нечитаем") }
    }

    /// Копирование набора снимков ведёт себя так же.
    @MainActor private static func multipleImagesStillOfferTIFF() throws {
        let images = [try image(width: 200, height: 150), try image(width: 220, height: 160)]
        let prepared = images.map { Clipboard.prepareImage(cgImage: $0) }
        NSPasteboard.general.clearContents()
        Clipboard.copy(preparedImages: prepared)

        guard let items = NSPasteboard.general.pasteboardItems, items.count == prepared.count else {
            throw Failure("в буфере не тот набор элементов")
        }
        for (index, item) in items.enumerated() {
            guard item.types.contains(.png) else { throw Failure("элемент \(index) без PNG") }
            guard item.types.contains(.tiff) else { throw Failure("элемент \(index) без TIFF") }
            guard let tiff = item.data(forType: .tiff), !tiff.isEmpty else {
                throw Failure("элемент \(index): обещание TIFF не исполняется")
            }
        }
    }

    /// Сторожевой замер: серия подготовок не должна раздувать процесс.
    /// До правки десять прогонов оставляли за собой около 300 МБ.
    @MainActor private static func preparationDoesNotAccumulateMemory() throws {
        let source = try image(width: 2560, height: 1600)
        // Прогрев: первая подготовка поднимает общие таблицы кодировщика.
        _ = Clipboard.prepareImage(cgImage: source)
        malloc_zone_pressure_relief(nil, 0)

        let before = footprintMB()
        for _ in 0..<10 {
            autoreleasepool { _ = Clipboard.prepareImage(cgImage: source) }
        }
        malloc_zone_pressure_relief(nil, 0)
        let growth = footprintMB() - before
        guard growth < 60 else {
            throw Failure("десять подготовок оставили \(Int(growth)) MB")
        }
    }

    /// Обещание исполняет живой процесс. При завершении приложения оно обязано
    /// превратиться в данные, иначе вставка TIFF после закрытия QuickShot
    /// перестаёт работать.
    @MainActor private static func promisedTIFFSurvivesTermination() throws {
        let prepared = Clipboard.prepareImage(cgImage: try image(width: 300, height: 200))
        NSPasteboard.general.clearContents()
        Clipboard.copy(preparedImage: prepared)

        Clipboard.debugResetPromiseRequestCount()
        Clipboard.materializePendingPromises()
        let afterMaterialize = Clipboard.debugPromiseRequestCount
        guard afterMaterialize == 1 else {
            throw Failure("материализация не запросила обещание: \(afterMaterialize)")
        }

        // Данные теперь лежат в буфере: чтение обязано обойтись без обещания —
        // именно этим вставка и переживает завершение приложения.
        guard let tiff = NSPasteboard.general.data(forType: .tiff), !tiff.isEmpty else {
            throw Failure("после материализации TIFF из буфера пропал")
        }
        guard Clipboard.debugPromiseRequestCount == afterMaterialize else {
            throw Failure("чтение снова обратилось к обещанию — данные не осели в буфере")
        }
        guard NSImage(data: tiff) != nil else { throw Failure("оставшийся TIFF нечитаем") }
        guard NSPasteboard.general.data(forType: .png) != nil else {
            throw Failure("PNG из буфера пропал")
        }
    }

    // MARK: помощники

    private static func image(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure("не удалось создать кадр")
        }
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in stride(from: 0, to: height, by: 5) {
            context.setFillColor(CGColor(red: Double(row % 255) / 255, green: 0.2, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: width, height: 2))
        }
        guard let image = context.makeImage() else { throw Failure("не удалось собрать кадр") }
        return image
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
