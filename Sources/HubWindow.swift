import AppKit

#if TESTING
struct HubDebugPillSnapshot {
    let title: String
    let frame: NSRect
    let cornerRadius: CGFloat
    let labelAlpha: CGFloat
    let isInteractive: Bool
    let hasIcon: Bool
}

struct HubDebugSnapshot {
    let shellBounds: NSRect
    let shellInset: CGFloat
    let groupGap: CGFloat
    let actionGap: CGFloat
    let progress: CGFloat
    let controlRadius: CGFloat
    let bubbleRadius: CGFloat
    let bubbleAlpha: CGFloat
    let expansionTarget: CGFloat
    let animationStartCount: Int
    let shellBorderWidth: CGFloat
    let shellSublayerCount: Int
    let coreFrame: NSRect
    let coreHasIcon: Bool
    let coreCornerRadius: CGFloat
    let actionClipFrame: NSRect
    let actionPills: [HubDebugPillSnapshot]
    let animationDuration: CFTimeInterval
    let nativeRenderPassCount: Int
    let nativeRenderDuration: CFTimeInterval
}
#endif

/// Public tray hub wrapper. The visible controls are rendered by Native SDK:
/// `NativeQuickShotUI/src/hub.native` owns the real `<button>` and `<button-group>`.
final class HubWindow {
    private let shell: NativeHubShellView

    var view: NSView { shell }
    var onClick: (() -> Void)? { didSet { shell.onToggle = onClick } }
    var onDelete: (() -> Void)? { didSet { shell.onDelete = onDelete } }
    var onSaveAs: (() -> Void)? { didSet { shell.onSaveAs = onSaveAs } }
    var onCopyAll: (() -> Void)? { didSet { shell.onCopyAll = onCopyAll } }

    var width: CGFloat { shell.compactWidth }
    var height: CGFloat { shell.compactHeight }
    var center: NSPoint { shell.coreCenter }

    init() {
        shell = NativeHubShellView(frame: .zero)
    }

    func setState(count: Int, collapsed: Bool) {
        shell.set(count: count,
                  collapsed: collapsed,
                  vertical: TrayPosition.current.isVertical,
                  expandsRight: TrayPosition.current == .left)
        shell.setAccessibilityValue("\(count)")
        shell.setAccessibilityLabel(collapsed ? "Развернуть скриншоты" : "Свернуть скриншоты")
        shell.setAccessibilityHelp("Нажмите, чтобы развернуть или свернуть трей")
    }

    func setOrigin(_ point: NSPoint) { shell.setCollapsedOrigin(point) }
    func show() { shell.isHidden = false }
    func hide() {
        shell.resetHoverState()
        shell.isHidden = true
    }

#if TESTING
    func debugSetExpansionProgress(_ progress: CGFloat) { shell.debugSetExpansionProgress(progress) }
    func debugSnapshot() -> HubDebugSnapshot { shell.debugSnapshot() }
    func debugControlButtons() -> [NativeControlDebugButtonSnapshot] { shell.debugControlButtons() }
    func debugHoverButton(title: String) { shell.debugHoverButton(title: title) }
    func debugPixel(at point: NSPoint) -> UInt32 { shell.debugPixel(at: point) }
    func debugTransitionDuration(toExpanded: Bool) -> CFTimeInterval {
        shell.debugTransitionDuration(toExpanded: toExpanded)
    }
    func debugRequestExpanded(_ expanded: Bool) { shell.debugRequestExpanded(expanded) }
    func debugUpdateHover(at pointInSuperview: NSPoint) {
        shell.debugUpdateHover(at: pointInSuperview)
    }
#endif
}
