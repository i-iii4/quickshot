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
    let coreChromeOwnerCount: Int
    let coreChromeUsesStretchableNativeRaster: Bool
    let coreChromeFrame: NSRect
    let coreChromeRenderScale: CGFloat
    let compactForegroundPerimeterAlpha: UInt8
    let revealedForegroundPerimeterAlpha: UInt8
    let revealedForegroundHovered: Bool
    let coreFrame: NSRect
    let coreBackgroundFrame: NSRect
    let coreCountFrame: NSRect
    let odometerViewportFrame: NSRect
    let odometerClips: Bool
    let odometerLayerCount: Int
    let odometerHasOutgoingContent: Bool
    let odometerUsesEdgeFade: Bool
    let coreLabelFrame: NSRect
    let coreLabelRequiredWidth: CGFloat
    let coreIconFrame: NSRect
    let chevronRotation: CGFloat
    let chevronTargetRotation: CGFloat
    let chevronHostTransformIsIdentity: Bool
    let chevronHostClips: Bool
    let coreTitle: String
    let coreHasIcon: Bool
    let stableCoreContentAlpha: CGFloat
    let revealedLabelAlpha: CGFloat
    let compactTextUsesCompleteNativeRender: Bool
    let revealedTextUsesCompleteNativeRender: Bool
    let odometerHiddenAtRest: Bool
    let coreCornerRadius: CGFloat
    let actionClipFrame: NSRect
    let actionPills: [HubDebugPillSnapshot]
    let animationDuration: CFTimeInterval
    let contentFadeDuration: CFTimeInterval
    let nativeRenderPassCount: Int
    let nativeRenderDuration: CFTimeInterval
}
#endif

/// Public tray hub wrapper. The visible controls are rendered by Native SDK:
/// `NativeQuickShotUI/src/hub.native` owns the real `<button>` and `<button-group>`.
@MainActor
final class HubWindow {
    private let shell: NativeHubShellView

    var view: NSView { shell }
    var onClick: (() -> Void)? { didSet { shell.onToggle = onClick } }
    var onDelete: (() -> Void)? { didSet { shell.onDelete = onDelete } }
    var onSaveAs: (() -> Void)? { didSet { shell.onSaveAs = onSaveAs } }
    var onCopyAll: (() -> Void)? { didSet { shell.onCopyAll = onCopyAll } }
    var onHoverChanged: ((Bool) -> Void)? { didSet { shell.onHoverChanged = onHoverChanged } }

    var width: CGFloat { shell.compactWidth }
    var height: CGFloat { shell.compactHeight }
    var leadingRevealClearance: CGFloat { shell.requiredLeadingClearance }
    var center: NSPoint { shell.coreCenter }

    init() {
        shell = NativeHubShellView(frame: .zero)
    }

    func setState(count: Int,
                  collapsed: Bool,
                  animateChevron: Bool = true,
                  animateCount: Bool = false) {
        shell.set(count: count,
                  collapsed: collapsed,
                  vertical: TrayPosition.current.isVertical,
                  expandsRight: TrayPosition.current == .left,
                  animateChevron: animateChevron,
                  animateCount: animateCount)
        shell.setAccessibilityValue("\(count)")
        shell.setAccessibilityLabel(collapsed ? "Развернуть скриншоты" : "Свернуть скриншоты")
        shell.setAccessibilityHelp("Нажмите, чтобы развернуть или свернуть трей")
    }

    func setOrigin(_ point: NSPoint) { shell.setCollapsedOrigin(point) }
    func setTrayCollapseProgress(_ progress: CGFloat) { shell.setChevronProgress(progress) }
    func setTrayHoverActive(_ active: Bool) { shell.setTrayHoverHeld(active) }
    func setCountTransitionProgress(_ progress: CGFloat) { shell.setCountTransitionProgress(progress) }
    func contains(_ pointInHost: NSPoint) -> Bool { shell.containsVisiblePointInSuperview(pointInHost) }
    func show() { shell.isHidden = false }
    func hide() {
        shell.resetHoverState()
        shell.isHidden = true
    }

#if TESTING
    func debugTransitionCount(to count: Int) { shell.debugTransitionCount(to: count) }
    func debugSetCountTransitionProgress(_ progress: CGFloat) {
        shell.debugSetCountTransitionProgress(progress)
    }
    func debugSetExpansionProgress(_ progress: CGFloat) { shell.debugSetExpansionProgress(progress) }
    func debugSetChevronProgress(_ progress: CGFloat) { shell.debugSetChevronProgress(progress) }
    func debugSnapshot() -> HubDebugSnapshot { shell.debugSnapshot() }
    func debugControlButtons() -> [NativeControlDebugButtonSnapshot] { shell.debugControlButtons() }
    func debugHoverButton(title: String) { shell.debugHoverButton(title: title) }
    func debugPixel(at point: NSPoint) -> UInt32 { shell.debugPixel(at: point) }
    func debugTransitionDuration(toExpanded: Bool) -> CFTimeInterval {
        shell.debugTransitionDuration(toExpanded: toExpanded)
    }
    func debugRequestExpanded(_ expanded: Bool) { shell.debugRequestExpanded(expanded) }
    func debugSetTrayHoverActive(_ active: Bool) { shell.debugSetTrayHoverHeld(active) }
    func debugUpdateHover(at pointInSuperview: NSPoint) {
        shell.debugUpdateHover(at: pointInSuperview)
    }
#endif
}
