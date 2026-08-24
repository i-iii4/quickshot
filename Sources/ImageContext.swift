import CoreGraphics

/// Контекст RGBA с premultiplied-альфой: единственный формат, в котором
/// QuickShot печёт растр. Заводился дословно одинаково в выпечке аннотаций и
/// в уменьшении снимка.
func makeRGBAContext(width: Int, height: Int) -> CGContext? {
    CGContext(data: nil,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}
