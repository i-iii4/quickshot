import AppKit

/// Content view полноэкранного прозрачного tray-host окна.
/// Обычный `NSView` может вернуть сам себя для пустой области, а это ломает
/// прозрачный hit-testing: события не доходят до расширившегося хаба/карточек.
/// Здесь события получают только реальные интерактивные сабвью; пустота возвращает nil.
final class TrayHostContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
        for child in subviews.reversed() where !child.isHidden && child.alphaValue > 0.01 {
            let converted = child.convert(point, from: self)
            if let hit = child.hitTest(converted) { return hit }
        }
        return nil
    }
}
