import AppKit

func trayHostIgnoresMouseEvents(isVisible: Bool,
                                captureActive: Bool,
                                dragActive: Bool,
                                pointerOverContent: Bool) -> Bool {
    !isVisible || captureActive || dragActive || !pointerOverContent
}

/// Content view полноэкранного прозрачного tray-host окна.
/// Обычный `NSView` может вернуть сам себя для пустой области, а это ломает
/// прозрачный hit-testing: события не доходят до расширившегося хаба/карточек.
/// Здесь события получают только реальные интерактивные сабвью; пустота возвращает nil.
final class TrayHostContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard !isHidden, alphaValue > 0.01, bounds.contains(local) else { return nil }
        for child in subviews.reversed() where !child.isHidden && child.alphaValue > 0.01 {
            // hitTest ребёнка ждёт точку в координатах СВОЕГО супервью — то
            // есть в наших локальных, без предварительной конвертации.
            if let hit = child.hitTest(local) { return hit }
        }
        return nil
    }
}
