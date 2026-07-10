import AppKit
import CoreGraphics
import QuartzCore

private enum NativeHubMetrics {
    private static func token(_ metric: NativeSDKMetric) -> CGFloat {
        let value = CGFloat(quickshot_native_ui_metric(metric.rawValue))
        precondition(value > 0, "Missing Native SDK metric: \(metric)")
        return value
    }

    static let height = token(.controlHeight)
    static let radius = token(.controlRadius)
    static let groupGap = token(.groupGap)
    static let shellInset = token(.shellInset)
    static let bubbleRadius = token(.bubbleRadius)
    static var animationDuration: CFTimeInterval {
        let metric: NativeSDKMetric = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .reducedAnimationDurationMilliseconds
            : .animationDurationMilliseconds
        return CFTimeInterval(CGFloat(quickshot_native_ui_metric(metric.rawValue)) / 1000)
    }
}

private func nativeHubLinear(_ f: CGFloat) -> CGFloat { f }

private enum NativeHubPressedButton: Int32 {
    case none = 0
    case toggle
    case delete
    case saveAs
    case copyAll
    case copy
    case dismiss
    case positionLeft
    case positionRight
    case positionBottom
    case positionTop
    case menuCapture
    case menuSettings
    case menuAccess
    case menuQuit
}

private enum NativeControlSurface: String {
    case hub
    case hubBubble = "hub_bubble"
    case thumbnail
    case pinned
    case settings
    case statusMenu = "status_menu"
}

private enum NativeInteractionChannel: String {
    case hover
    case pressed
}

private struct NativeHubButtonNode {
    let id: UInt64
    let identifier: String
    let title: String
    let frame: NSRect
    let flags: UInt32
    let action: NativeHubPressedButton

    var isHovered: Bool { (flags & nativeSDKWidgetHoveredFlag) != 0 }
    var isPressed: Bool { (flags & nativeSDKWidgetPressedFlag) != 0 }
}

private struct NativeHubRenderSignature: Equatable {
    let width: Int
    let height: Int
    let scale: Int
    let revision: UInt64
}

private struct NativeHubSurfaceSignature: Equatable {
    let width: Int
    let height: Int
    let scale: Int
}

#if TESTING
struct NativeControlDebugButtonSnapshot {
    let identifier: String
    let title: String
    let frame: NSRect
    let isHovered: Bool
    let isPressed: Bool
}
#endif

private final class NativeHubRenderView: NSView {
    var onButtonPressed: ((NativeHubPressedButton) -> Void)?
    private(set) var isPressing = false

    private let nativeApp: UnsafeMutableRawPointer?
    private var rgbaBytes: [UInt8] = []
    private var retainedImageData: Data?
    private var lastRenderSignature: NativeHubRenderSignature?
    private var lastSurfaceSignature: NativeHubSurfaceSignature?
    private var renderRevision: UInt64 = 0
    private(set) var renderPassCount = 0
    private(set) var totalRenderDuration: CFTimeInterval = 0
    private var count = -1
    private var collapsed = false
    private var vertical = true
    private var expanded = false
    private var actionsAfter = false
    private var surface: NativeControlSurface = .hub
    private var compact = false
    private var copied = false
    private var hoveredNodeID: UInt64?
    private var trackingArea: NSTrackingArea?
    private var lastAppearance: (dark: Bool, highContrast: Bool, reduceMotion: Bool)?
    private var accessibilityObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        nativeApp = native_sdk_app_create()
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.contentsGravity = .resize
        layer?.masksToBounds = false
        native_sdk_app_start(nativeApp)
        native_sdk_app_activate(nativeApp)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncSystemAppearance()
        }
        syncSystemAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
        native_sdk_app_stop(nativeApp)
        native_sdk_app_destroy(nativeApp)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncSystemAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncSystemAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    func setState(count: Int, collapsed: Bool, vertical: Bool, expanded: Bool, actionsAfter: Bool) {
        setSurface(.hub)
        if self.count != count {
            self.count = count
            sendCommand("hub.count:\(max(0, count))")
        }
        if self.collapsed != collapsed {
            self.collapsed = collapsed
            sendCommand("hub.collapsed:\(collapsed ? 1 : 0)")
        }
        if self.vertical != vertical {
            self.vertical = vertical
            sendCommand("hub.vertical:\(vertical ? 1 : 0)")
        }
        if self.expanded != expanded {
            self.expanded = expanded
            sendCommand("hub.expanded:\(expanded ? 1 : 0)")
        }
        if self.actionsAfter != actionsAfter {
            self.actionsAfter = actionsAfter
            sendCommand("hub.actions_after:\(actionsAfter ? 1 : 0)")
        }
    }

    func setSurface(_ surface: NativeControlSurface) {
        guard self.surface != surface else { return }
        self.surface = surface
        sendCommand("surface:\(surface.rawValue)")
    }

    func setCompact(_ compact: Bool) {
        guard self.compact != compact else { return }
        self.compact = compact
        sendCommand("control.compact:\(compact ? 1 : 0)")
    }

    func setCopied(_ copied: Bool) {
        guard self.copied != copied else { return }
        self.copied = copied
        sendCommand("control.copied:\(copied ? 1 : 0)")
    }

    func sendSettingsPosition(_ rawValue: String) {
        sendCommand("settings.position:\(rawValue)")
    }

    func renderNow() {
        guard let nativeApp, bounds.width > 0.5, bounds.height > 0.5 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let signature = NativeHubRenderSignature(width: Int((bounds.width * scale).rounded()),
                                                 height: Int((bounds.height * scale).rounded()),
                                                 scale: Int((scale * 1000).rounded()),
                                                 revision: renderRevision)
        guard signature != lastRenderSignature else { return }
        let startedAt = CACurrentMediaTime()
        let surfaceSignature = NativeHubSurfaceSignature(width: signature.width,
                                                         height: signature.height,
                                                         scale: signature.scale)
        if surfaceSignature != lastSurfaceSignature {
            native_sdk_app_resize(nativeApp, Float(bounds.width), Float(bounds.height), Float(scale), nil)
            lastSurfaceSignature = surfaceSignature
        }
        native_sdk_app_frame(nativeApp)

        var info = NativeSDKCanvasPixels(width: 0, height: 0, byte_len: 0)
        guard native_sdk_app_render_pixel_size(nativeApp, Float(scale), &info) == 1,
              info.width > 0,
              info.height > 0,
              info.byte_len == info.width * info.height * 4 else {
            logNativeError("render_pixel_size")
            return
        }
        if rgbaBytes.count != Int(info.byte_len) {
            rgbaBytes = Array(repeating: 0, count: Int(info.byte_len))
        }
        var rendered = NativeSDKCanvasPixels(width: 0, height: 0, byte_len: 0)
        let ok = rgbaBytes.withUnsafeMutableBufferPointer { buffer in
            native_sdk_app_render_pixels(nativeApp, Float(scale), buffer.baseAddress, info.byte_len, &rendered)
        }
        guard ok == 1,
              rendered.width > 0,
              rendered.height > 0,
              rendered.byte_len == rendered.width * rendered.height * 4 else {
            logNativeError("render_pixels")
            return
        }
        retainedImageData = Data(rgbaBytes)
        guard let retainedImageData,
              let provider = CGDataProvider(data: retainedImageData as CFData) else { return }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue).union(.byteOrder32Big)
        let image = CGImage(width: Int(rendered.width),
                            height: Int(rendered.height),
                            bitsPerComponent: 8,
                            bitsPerPixel: 32,
                            bytesPerRow: Int(rendered.width) * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: bitmapInfo,
                            provider: provider,
                            decode: nil,
                            shouldInterpolate: false,
                            intent: .defaultIntent)
        layer?.contentsScale = scale
        layer?.contents = image
        lastRenderSignature = signature
        renderPassCount += 1
        totalRenderDuration += CACurrentMediaTime() - startedAt
    }

    func hasInteractiveButton(at point: NSPoint) -> Bool {
        button(at: point) != nil
    }

    func buttonNodes() -> [NativeHubButtonNode] {
        guard let nativeApp else { return [] }
        native_sdk_app_frame(nativeApp)
        let total = native_sdk_app_widget_semantics_count(nativeApp)
        guard total > 0 else { return [] }
        var nodes: [NativeHubButtonNode] = []
        nodes.reserveCapacity(Int(total))
        for index in 0..<total {
            var node = NativeSDKWidgetSemantics.empty
            guard native_sdk_app_widget_semantics_at(nativeApp, index, &node) == 1,
                  node.role == nativeSDKWidgetRoleButton,
                  (node.actions & nativeSDKWidgetActionPressFlag) != 0 else { continue }
            let label = nativeSDKString(node.label, length: node.label_len)
            let text = nativeSDKString(node.text, length: node.text_len)
            let title = text.isEmpty ? label : text
            nodes.append(NativeHubButtonNode(id: node.id,
                                             identifier: label.isEmpty ? text : label,
                                             title: title,
                                             frame: NSRect(x: CGFloat(node.x),
                                                           y: CGFloat(node.y),
                                                           width: CGFloat(node.width),
                                                           height: CGFloat(node.height)),
                                             flags: node.flags,
                                             action: actionForButton(identifier: label.isEmpty ? text : label,
                                                                     title: title)))
        }
        return nodes
    }

    func measureButtonContentSize(height: CGFloat = NativeHubMetrics.height) -> NSSize {
        let previousFrame = frame
        frame = NSRect(x: 0, y: 0, width: 800, height: height)
        renderNow()
        let frames = buttonNodes().map(\.frame)
        let content = frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
        frame = previousFrame
        lastRenderSignature = nil
        return NSSize(width: ceil(content.width), height: ceil(content.height))
    }

    func measureSemanticContentSize(width: CGFloat, height: CGFloat = 400) -> NSSize {
        let previousFrame = frame
        frame = NSRect(x: 0, y: 0, width: width, height: height)
        renderNow()
        guard let nativeApp else { return .zero }
        native_sdk_app_frame(nativeApp)
        let total = native_sdk_app_widget_semantics_count(nativeApp)
        var content: NSRect?
        for index in 0..<total {
            var node = NativeSDKWidgetSemantics.empty
            guard native_sdk_app_widget_semantics_at(nativeApp, index, &node) == 1,
                  node.role == 2 || node.role == nativeSDKWidgetRoleButton,
                  node.width > 0,
                  node.height > 0 else { continue }
            let frame = NSRect(x: CGFloat(node.x), y: CGFloat(node.y),
                               width: CGFloat(node.width), height: CGFloat(node.height))
            content = content.map { $0.union(frame) } ?? frame
        }
        frame = previousFrame
        lastRenderSignature = nil
        guard let content else { return .zero }
        return NSSize(width: ceil(content.maxX + content.minX),
                      height: ceil(content.maxY + content.minY))
    }

    override func mouseEntered(with event: NSEvent) {
        forwardPointerMove(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        forwardPointerMove(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredNodeID != nil else { return }
        hoveredNodeID = nil
        quickshot_native_ui_pointer_move(nativeApp, -1, -1)
        sendInteraction(.hover, action: .none)
        renderNow()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let node = button(at: point) else { return }
        isPressing = true
        native_sdk_app_touch(nativeApp, 1, 0, Float(point.x), Float(point.y), 1)
        sendInteraction(.pressed, action: node.action)
        renderNow()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPressing else { return }
        let point = convert(event.locationInWindow, from: nil)
        let target = button(at: point)
        guard target?.id != hoveredNodeID else { return }
        hoveredNodeID = target?.id
        native_sdk_app_touch(nativeApp, 1, 2, Float(point.x), Float(point.y), 1)
        sendInteraction(.hover, action: target?.action ?? .none)
        renderNow()
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressing else { return }
        defer { isPressing = false }
        let point = convert(event.locationInWindow, from: nil)
        native_sdk_app_touch(nativeApp, 1, 1, Float(point.x), Float(point.y), 0)
        sendInteraction(.pressed, action: .none)
        renderNow()
        guard let action = NativeHubPressedButton(rawValue: quickshot_native_ui_take_action(nativeApp)),
              action != .none else { return }
        onButtonPressed?(action)
    }

    private func button(at point: NSPoint) -> NativeHubButtonNode? {
        buttonNodes()
            .filter { $0.frame.contains(point) }
            .sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            .first
    }

    private func sendCommand(_ command: String) {
        command.withCString { pointer in
            native_sdk_app_command(nativeApp, pointer, UInt(command.utf8.count))
        }
        invalidateRender()
    }

    private func forwardPointerMove(_ point: NSPoint) {
        let target = button(at: point)
        guard target?.id != hoveredNodeID else { return }
        hoveredNodeID = target?.id
        quickshot_native_ui_pointer_move(nativeApp, Float(point.x), Float(point.y))
        sendInteraction(.hover, action: target?.action ?? .none)
        renderNow()
    }

    private func invalidateRender() {
        renderRevision &+= 1
    }

    private func sendInteraction(_ channel: NativeInteractionChannel, action: NativeHubPressedButton) {
        sendCommand("ui.\(channel.rawValue):\(action.rawValue)")
    }

    private func actionForButton(identifier: String, title: String) -> NativeHubPressedButton {
        switch identifier {
        case "Copy screenshot", "Copied screenshot": return .copy
        case "Dismiss screenshot": return .dismiss
        case "Tray left": return .positionLeft
        case "Tray right": return .positionRight
        case "Tray bottom": return .positionBottom
        case "Tray top": return .positionTop
        case "Menu capture": return .menuCapture
        case "Menu settings": return .menuSettings
        case "Menu access": return .menuAccess
        case "Menu quit": return .menuQuit
        default: break
        }
        switch title {
        case "Delete": return .delete
        case "Save As": return .saveAs
        case "Copy All": return .copyAll
        default:
            return identifier.hasSuffix("screenshots") ? .toggle : .none
        }
    }

    private func syncSystemAppearance() {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let workspace = NSWorkspace.shared
        setAppearance(dark: dark,
                      highContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
                      reduceMotion: workspace.accessibilityDisplayShouldReduceMotion)
    }

    private func setAppearance(dark: Bool, highContrast: Bool, reduceMotion: Bool) {
        let next = (dark: dark, highContrast: highContrast, reduceMotion: reduceMotion)
        guard lastAppearance?.dark != next.dark ||
              lastAppearance?.highContrast != next.highContrast ||
              lastAppearance?.reduceMotion != next.reduceMotion else { return }
        lastAppearance = next
        quickshot_native_ui_set_appearance(nativeApp,
                                           dark ? 1 : 0,
                                           highContrast ? 1 : 0,
                                           reduceMotion ? 1 : 0)
        invalidateRender()
        renderNow()
    }

#if TESTING
    func debugMovePointer(to point: NSPoint) {
        forwardPointerMove(point)
    }

    func debugSetAppearance(dark: Bool, highContrast: Bool = false, reduceMotion: Bool = false) {
        setAppearance(dark: dark, highContrast: highContrast, reduceMotion: reduceMotion)
    }

    func debugPixel(at point: NSPoint) -> UInt32 {
        renderNow()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return 0 }
        let x = min(width - 1, max(0, Int((point.x * scale).rounded(.down))))
        let y = min(height - 1, max(0, Int((point.y * scale).rounded(.down))))
        let index = (y * width + x) * 4
        guard index + 3 < rgbaBytes.count else { return 0 }
        return (UInt32(rgbaBytes[index]) << 24) |
            (UInt32(rgbaBytes[index + 1]) << 16) |
            (UInt32(rgbaBytes[index + 2]) << 8) |
            UInt32(rgbaBytes[index + 3])
    }
#endif

    private func logNativeError(_ stage: String) {
        guard let name = native_sdk_app_last_error_name(nativeApp), name[0] != 0 else { return }
        NSLog("QuickShot Native UI: \(stage) failed: \(String(cString: name))")
    }
}

extension NativeSDKWidgetSemantics {
    static var empty: NativeSDKWidgetSemantics {
        NativeSDKWidgetSemantics(id: 0,
                                 parent_id: 0,
                                 role: 0,
                                 flags: 0,
                                 actions: 0,
                                 x: 0,
                                 y: 0,
                                 width: 0,
                                 height: 0,
                                 value: 0,
                                 has_value: 0,
                                 label: nil,
                                 label_len: 0,
                                 text: nil,
                                 text_len: 0,
                                 placeholder: nil,
                                 placeholder_len: 0,
                                 text_selection_start: 0,
                                 text_selection_end: 0,
                                 text_composition_start: 0,
                                 text_composition_end: 0,
                                 grid_row_index: 0,
                                 grid_column_index: 0,
                                 grid_row_count: 0,
                                 grid_column_count: 0,
                                 list_item_index: 0,
                                 list_item_count: 0,
                                 scroll_offset: 0,
                                 scroll_viewport_extent: 0,
                                 scroll_content_extent: 0,
                                 has_scroll: 0)
    }
}

final class NativeHubShellView: NSView {
    var onToggle: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onCopyAll: (() -> Void)?

    private let bubbleView = NativeHubRenderView(frame: .zero)
    private let nativeView = NativeHubRenderView(frame: .zero)
    private var trackingArea: NSTrackingArea?
    private var localHoverMonitor: Any?
    private var globalHoverMonitor: Any?
    private var collapsedOrigin: NSPoint = .zero
    private var count = 0
    private var collapsed = false
    private var vertical = true
    private var expandsRight = false
    private var progress: CGFloat = 0
    private var targetProgress: CGFloat = 0
    private var animationStartCount = 0
    private var coreWidth: CGFloat = NativeHubMetrics.height
    private var measuredExpandedWidth: CGFloat?
    private var actionWidths: [String: CGFloat] = [:]
    private lazy var animator = FrameAnimator(hostView: self)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        layer?.cornerCurve = .continuous
        bubbleView.setSurface(.hubBubble)
        bubbleView.alphaValue = 0
        nativeView.onButtonPressed = { [weak self] pressed in
            guard let self else { return }
            switch pressed {
            case .toggle: self.onToggle?()
            case .delete: self.onDelete?()
            case .saveAs: self.onSaveAs?()
            case .copyAll: self.onCopyAll?()
            case .none, .copy, .dismiss, .positionLeft, .positionRight, .positionBottom, .positionTop,
                 .menuCapture, .menuSettings, .menuAccess, .menuQuit: break
            }
        }
        addSubview(bubbleView)
        addSubview(nativeView)
        setFrameSize(NSSize(width: compactWidth, height: compactHeight))
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        stopHoverMonitoring()
    }

    var compactHeight: CGFloat { NativeHubMetrics.height + NativeHubMetrics.shellInset * 2 }
    var compactWidth: CGFloat { coreWidth }
    var coreCenter: NSPoint {
        let coreX = expandsRight ? CGFloat.zero : bounds.width - coreWidth
        return NSPoint(x: frame.minX + coreX + coreWidth / 2, y: frame.midY)
    }

    private var actionWidth: CGFloat {
        let widths = ["Delete", "Save As", "Copy All"].map { actionWidths[$0] ?? NativeHubMetrics.height }
        return widths.reduce(0, +) + NativeHubMetrics.groupGap * CGFloat(max(0, widths.count - 1))
    }

    private var expandedWidth: CGFloat {
        measuredExpandedWidth ?? (coreWidth + NativeHubMetrics.groupGap + actionWidth)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
        let nativePoint = convert(point, to: nativeView)
        return nativeView.hasInteractiveButton(at: nativePoint) ? nativeView : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setExpanded(true) }
    override func mouseMoved(with event: NSEvent) { setExpanded(true) }
    override func mouseExited(with event: NSEvent) {
        guard let superview else {
            setExpanded(false)
            return
        }
        let point = superview.convert(event.locationInWindow, from: nil)
        updateHover(at: point)
    }

    func set(count: Int, collapsed: Bool, vertical: Bool, expandsRight: Bool) {
        self.count = count
        self.collapsed = collapsed
        self.vertical = vertical
        self.expandsRight = expandsRight
        nativeView.setState(count: count,
                            collapsed: collapsed,
                            vertical: vertical,
                            expanded: progress > 0.001,
                            actionsAfter: expandsRight)
        refreshMeasuredMetrics()
        layoutForProgress(progress)
    }

    func setCollapsedOrigin(_ origin: NSPoint) {
        collapsedOrigin = origin
        layoutForProgress(progress)
    }

    private func setExpanded(_ expanded: Bool) {
        if !expanded && nativeView.isPressing { return }
        let target: CGFloat = expanded ? 1 : 0
        guard target != targetProgress else { return }
        targetProgress = target
        if expanded {
            startHoverMonitoring()
        } else {
            stopHoverMonitoring()
        }
        guard abs(progress - target) > 0.001 else { return }
        let start = progress
        let remainingDistance = abs(target - start)
        animationStartCount += 1
        animator.run(duration: NativeHubMetrics.animationDuration * CFTimeInterval(remainingDistance),
                     delay: 0,
                     easing: nativeHubLinear,
                     onFrame: { [weak self] t in
            guard let self else { return }
            self.progress = start + (target - start) * t
            self.layoutForProgress(self.progress)
        }, onDone: { [weak self] in
            guard let self else { return }
            self.progress = target
            self.layoutForProgress(target)
        })
    }

    private func layoutForProgress(_ p: CGFloat) {
        let widthProgress = min(1, max(0, p))
        let currentWidth = compactWidth + (expandedWidth - compactWidth) * widthProgress
        let originX = expandsRight ? collapsedOrigin.x : collapsedOrigin.x - (currentWidth - compactWidth)
        frame = NSRect(x: originX, y: collapsedOrigin.y, width: currentWidth, height: compactHeight)

        let nativeExpanded = p > 0.001
        let nativeWidth = nativeExpanded ? expandedWidth : compactWidth
        let nativeX = expandsRight ? CGFloat.zero : currentWidth - nativeWidth
        bubbleView.frame = NSRect(x: nativeX, y: 0, width: nativeWidth, height: compactHeight)
        bubbleView.setSurface(.hubBubble)
        bubbleView.alphaValue = bubbleOpacity(for: p)
        bubbleView.renderNow()
        nativeView.frame = NSRect(x: nativeX, y: 0, width: nativeWidth, height: compactHeight)
        nativeView.setState(count: count,
                            collapsed: collapsed,
                            vertical: vertical,
                            expanded: nativeExpanded,
                            actionsAfter: expandsRight)
        nativeView.renderNow()
        layer?.cornerRadius = p > 0.001 ? NativeHubMetrics.bubbleRadius : 0
    }

    private func bubbleOpacity(for progress: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress / 0.45))
        return t * t * (3 - 2 * t)
    }

    private func expandedHoverFrame() -> NSRect {
        let originX = expandsRight
            ? collapsedOrigin.x
            : collapsedOrigin.x - (expandedWidth - compactWidth)
        return NSRect(x: originX,
                      y: collapsedOrigin.y,
                      width: expandedWidth,
                      height: compactHeight).insetBy(dx: -2, dy: -2)
    }

    private func updateHover(at pointInSuperview: NSPoint) {
        guard targetProgress > 0 else { return }
        if !expandedHoverFrame().contains(pointInSuperview) {
            setExpanded(false)
        }
    }

    private func updateHoverFromGlobalPointer() {
        guard let window, let superview else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        updateHover(at: superview.convert(windowPoint, from: nil))
    }

    private func startHoverMonitoring() {
        guard window?.isVisible == true, localHoverMonitor == nil, globalHoverMonitor == nil else { return }
        localHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] event in
            self?.updateHoverFromGlobalPointer()
            return event
        }
        globalHoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] _ in
            DispatchQueue.main.async { self?.updateHoverFromGlobalPointer() }
        }
    }

    private func stopHoverMonitoring() {
        if let localHoverMonitor { NSEvent.removeMonitor(localHoverMonitor) }
        if let globalHoverMonitor { NSEvent.removeMonitor(globalHoverMonitor) }
        localHoverMonitor = nil
        globalHoverMonitor = nil
    }

    func resetHoverState() {
        animator.cancel()
        stopHoverMonitoring()
        targetProgress = 0
        progress = 0
        layoutForProgress(0)
    }

    private func refreshMeasuredMetrics() {
        let previousFrame = nativeView.frame
        let previousExpanded = progress > 0.001
        nativeView.frame = NSRect(x: 0, y: 0, width: 800, height: compactHeight)
        nativeView.setState(count: count,
                            collapsed: collapsed,
                            vertical: vertical,
                            expanded: true,
                            actionsAfter: expandsRight)
        nativeView.renderNow()
        let nodes = nativeView.buttonNodes()
        let actionNodes = nodes.filter { $0.title == "Delete" || $0.title == "Save As" || $0.title == "Copy All" }
        let coreNode = nodes.first { node in
            !(node.title == "Delete" || node.title == "Save As" || node.title == "Copy All")
        }
        if let coreNode {
            coreWidth = ceil(coreNode.frame.width + NativeHubMetrics.shellInset * 2)
        }
        for node in actionNodes {
            actionWidths[node.title] = ceil(node.frame.width)
        }
        if let content = union(nodes.map(\.frame)) {
            measuredExpandedWidth = ceil(content.maxX + content.minX)
        }
        nativeView.setState(count: count,
                            collapsed: collapsed,
                            vertical: vertical,
                            expanded: previousExpanded,
                            actionsAfter: expandsRight)
        nativeView.frame = previousFrame
    }

    private func union(_ rects: [NSRect]) -> NSRect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() {
            result = result.union(rect)
        }
        return result
    }

#if TESTING
    func debugSetExpansionProgress(_ value: CGFloat) {
        progress = max(0, min(1, value))
        layoutForProgress(progress)
    }

    func debugSnapshot() -> HubDebugSnapshot {
        nativeView.renderNow()
        let buttons = nativeView.buttonNodes()
        let shellBounds = bounds
        let actionRects = buttons.compactMap { node -> NSRect? in
            guard node.title == "Delete" || node.title == "Save As" || node.title == "Copy All" else { return nil }
            return nativeView.convert(node.frame, to: self)
        }
        let actionClipFrame = union(actionRects) ?? currentActionClipFrame()
        let coreFrame = buttons
            .first(where: { !($0.title == "Delete" || $0.title == "Save As" || $0.title == "Copy All") })
            .map { nativeView.convert($0.frame, to: self) } ?? currentCoreFrame()

        let actionSnapshots = buttons.compactMap { node -> HubDebugPillSnapshot? in
            let title: String
            if node.title == "Delete" || node.title == "Save As" || node.title == "Copy All" {
                title = node.title
            } else {
                return nil
            }
            let shellRect = nativeView.convert(node.frame, to: self)
            let clipRect = shellBounds.intersection(shellRect)
            let fullyVisible = clipRect.width >= shellRect.width - 0.5 && clipRect.height >= shellRect.height - 0.5
            let relative = NSRect(x: shellRect.minX - actionClipFrame.minX,
                                  y: shellRect.minY - actionClipFrame.minY,
                                  width: shellRect.width,
                                  height: shellRect.height)
            return HubDebugPillSnapshot(title: title,
                                        frame: relative,
                                        cornerRadius: NativeHubMetrics.radius,
                                        labelAlpha: fullyVisible ? 1 : 0,
                                        isInteractive: fullyVisible && progress > 0,
                                        hasIcon: true)
        }

        return HubDebugSnapshot(shellBounds: shellBounds,
                                shellInset: NativeHubMetrics.shellInset,
                                groupGap: NativeHubMetrics.groupGap,
                                actionGap: NativeHubMetrics.groupGap,
                                progress: progress,
                                controlRadius: NativeHubMetrics.radius,
                                bubbleRadius: NativeHubMetrics.bubbleRadius,
                                bubbleAlpha: bubbleView.alphaValue,
                                expansionTarget: targetProgress,
                                animationStartCount: animationStartCount,
                                shellBorderWidth: layer?.borderWidth ?? 0,
                                shellSublayerCount: layer?.sublayers?.count ?? 0,
                                coreFrame: coreFrame,
                                coreHasIcon: true,
                                coreCornerRadius: NativeHubMetrics.radius,
                                actionClipFrame: actionClipFrame,
                                actionPills: actionSnapshots.sorted { $0.frame.minX < $1.frame.minX },
                                animationDuration: NativeHubMetrics.animationDuration,
                                nativeRenderPassCount: nativeView.renderPassCount,
                                nativeRenderDuration: nativeView.totalRenderDuration)
    }

    func debugControlButtons() -> [NativeControlDebugButtonSnapshot] {
        nativeDebugButtons(nativeView, in: self)
    }

    func debugHoverButton(title: String) {
        nativeDebugHover(title: title, nativeView: nativeView)
    }

    func debugPixel(at point: NSPoint) -> UInt32 {
        let foreground = nativeView.debugPixel(at: convert(point, to: nativeView))
        let background = bubbleView.debugPixel(at: convert(point, to: bubbleView))
        let foregroundAlpha = CGFloat(foreground & 0xff) / 255
        let backgroundAlpha = CGFloat(background & 0xff) / 255 * bubbleView.alphaValue
        let alpha = foregroundAlpha + backgroundAlpha * (1 - foregroundAlpha)
        return UInt32((alpha * 255).rounded())
    }

    func debugTransitionDuration(toExpanded: Bool) -> CFTimeInterval {
        let target: CGFloat = toExpanded ? 1 : 0
        return NativeHubMetrics.animationDuration * CFTimeInterval(abs(target - progress))
    }

    func debugRequestExpanded(_ expanded: Bool) {
        setExpanded(expanded)
    }

    func debugUpdateHover(at pointInSuperview: NSPoint) {
        updateHover(at: pointInSuperview)
    }

    private func currentCoreFrame() -> NSRect {
        let width = coreWidth - NativeHubMetrics.shellInset * 2
        return NSRect(x: expandsRight ? NativeHubMetrics.shellInset : bounds.width - NativeHubMetrics.shellInset - width,
                      y: NativeHubMetrics.shellInset,
                      width: width,
                      height: NativeHubMetrics.height)
    }

    private func currentActionClipFrame() -> NSRect {
        if expandsRight {
            let x = coreWidth + NativeHubMetrics.groupGap
            return NSRect(x: x, y: NativeHubMetrics.shellInset,
                          width: max(0, bounds.width - x - NativeHubMetrics.shellInset),
                          height: NativeHubMetrics.height)
        }
        let width = max(0, bounds.width - coreWidth - NativeHubMetrics.groupGap)
        return NSRect(x: NativeHubMetrics.shellInset, y: NativeHubMetrics.shellInset,
                      width: max(0, width - NativeHubMetrics.shellInset),
                      height: NativeHubMetrics.height)
    }

#endif
}

final class NativeThumbnailControlsView: NSView {
    var onCopy: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let nativeView = NativeHubRenderView(frame: .zero)
    private var compact = false
    private var fullFittingSize = NSSize(width: NativeHubMetrics.height * 3,
                                         height: NativeHubMetrics.height)
    private var compactFittingSize = NSSize(width: NativeHubMetrics.height * 2 + NativeHubMetrics.groupGap,
                                            height: NativeHubMetrics.height)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        nativeView.setSurface(.thumbnail)
        nativeView.onButtonPressed = { [weak self] pressed in
            switch pressed {
            case .copy:
                self?.onCopy?()
            case .dismiss:
                self?.onDismiss?()
            default:
                break
            }
        }
        addSubview(nativeView)
        refreshFittingSizes()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        compact ? compactFittingSize : fullFittingSize
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
        let p = convert(point, to: nativeView)
        return nativeView.hasInteractiveButton(at: p) ? nativeView : nil
    }

    override func layout() {
        super.layout()
        nativeView.frame = bounds
        nativeView.setSurface(.thumbnail)
        nativeView.setCompact(compact)
        nativeView.renderNow()
    }

    func setCompact(_ compact: Bool) {
        guard self.compact != compact else { return }
        self.compact = compact
        nativeView.setCompact(compact)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func showCheck(_ on: Bool) {
        nativeView.setCopied(on)
        nativeView.renderNow()
        needsLayout = true
    }

    func buttonCenterInSelf(matching predicate: (String) -> Bool) -> NSPoint {
        nativeView.renderNow()
        guard let node = nativeView.buttonNodes().first(where: { predicate($0.title) }) else {
            return NSPoint(x: bounds.midX, y: bounds.midY)
        }
        return convert(NSPoint(x: node.frame.midX, y: node.frame.midY), from: nativeView)
    }

#if TESTING
    func debugState(label: String) -> String {
        nativeView.renderNow()
        let nodes = nativeView.buttonNodes()
        let node = nodes.first { $0.title == label || (label == "Copy" && ($0.title == "Copy screenshot" || $0.title == "Copied screenshot")) }
        let frame = node?.frame ?? .zero
        return "nativeFrame=\(nativeView.frame) buttonFrame=\(frame) hidden=\(isHidden) alpha=\(alphaValue) compact=\(compact) nodes=\(nodes.map(\.title))"
    }

    func debugButtons() -> [NativeControlDebugButtonSnapshot] {
        nativeDebugButtons(nativeView, in: self)
    }

    func debugHoverButton(title: String) {
        nativeDebugHover(title: title, nativeView: nativeView)
    }

    func debugPixel(at point: NSPoint) -> UInt32 {
        nativeView.debugPixel(at: point)
    }
#endif

    private func refreshFittingSizes() {
        nativeView.setCompact(false)
        nativeView.setCopied(false)
        let copySize = nativeView.measureButtonContentSize()
        nativeView.setCopied(true)
        let copiedSize = nativeView.measureButtonContentSize()
        fullFittingSize = NSSize(width: max(copySize.width, copiedSize.width),
                                 height: max(copySize.height, copiedSize.height))

        nativeView.setCompact(true)
        compactFittingSize = nativeView.measureButtonContentSize()
        nativeView.setCopied(false)
        nativeView.setCompact(compact)
    }
}

final class NativePinnedCopyButtonView: NSView {
    var onCopy: (() -> Void)?

    private let nativeView = NativeHubRenderView(frame: .zero)
    private var measuredFittingSize = NSSize(width: NativeHubMetrics.height * 2,
                                             height: NativeHubMetrics.height)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        nativeView.setSurface(.pinned)
        nativeView.onButtonPressed = { [weak self] pressed in
            if case .copy = pressed { self?.onCopy?() }
        }
        addSubview(nativeView)
        refreshFittingSize()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        measuredFittingSize
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
        let p = convert(point, to: nativeView)
        return nativeView.hasInteractiveButton(at: p) ? nativeView : nil
    }

    override func layout() {
        super.layout()
        nativeView.frame = bounds
        nativeView.setSurface(.pinned)
        nativeView.renderNow()
    }

    func showCheck(_ on: Bool) {
        nativeView.setCopied(on)
        nativeView.renderNow()
        needsLayout = true
    }

#if TESTING
    func debugButtons() -> [NativeControlDebugButtonSnapshot] {
        nativeDebugButtons(nativeView, in: self)
    }

    func debugHoverButton(title: String) {
        nativeDebugHover(title: title, nativeView: nativeView)
    }

    func debugPixel(at point: NSPoint) -> UInt32 {
        nativeView.debugPixel(at: convert(point, to: nativeView))
    }
#endif

    private func refreshFittingSize() {
        nativeView.setCopied(false)
        let copySize = nativeView.measureButtonContentSize()
        nativeView.setCopied(true)
        let copiedSize = nativeView.measureButtonContentSize()
        measuredFittingSize = NSSize(width: max(copySize.width, copiedSize.width),
                                     height: max(copySize.height, copiedSize.height))
        nativeView.setCopied(false)
    }
}

final class NativeSettingsContentView: NSView {
    var onPositionSelected: ((String) -> Void)?

    private let nativeView = NativeHubRenderView(frame: .zero)
    private var selectedPosition = "right"
    private var measuredFittingSize = NSSize(width: 360, height: 140)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        nativeView.setSurface(.settings)
        nativeView.onButtonPressed = { [weak self] pressed in
            switch pressed {
            case .positionLeft:
                self?.select("left")
            case .positionRight:
                self?.select("right")
            case .positionBottom:
                self?.select("bottom")
            case .positionTop:
                self?.select("top")
            default:
                break
            }
        }
        addSubview(nativeView)
        let contentSize = nativeView.measureSemanticContentSize(width: 800)
        measuredFittingSize = NSSize(width: max(360, contentSize.width),
                                     height: contentSize.height)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { measuredFittingSize }
    override var intrinsicContentSize: NSSize { fittingSize }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
        let p = convert(point, to: nativeView)
        return nativeView.hasInteractiveButton(at: p) ? nativeView : nil
    }

    override func layout() {
        super.layout()
        nativeView.frame = bounds
        nativeView.setSurface(.settings)
        nativeView.renderNow()
    }

    func setSelectedPosition(_ rawValue: String) {
        guard selectedPosition != rawValue else { return }
        selectedPosition = rawValue
        nativeView.setSurface(.settings)
        nativeView.sendSettingsPosition(rawValue)
        nativeView.renderNow()
        needsLayout = true
    }

    private func select(_ rawValue: String) {
        setSelectedPosition(rawValue)
        onPositionSelected?(rawValue)
    }

#if TESTING
    func debugButtons() -> [NativeControlDebugButtonSnapshot] {
        nativeDebugButtons(nativeView, in: self)
    }

    func debugHoverButton(title: String) {
        nativeDebugHover(title: title, nativeView: nativeView)
    }

    func debugSetAppearance(dark: Bool, highContrast: Bool = false, reduceMotion: Bool = false) {
        nativeView.debugSetAppearance(dark: dark, highContrast: highContrast, reduceMotion: reduceMotion)
    }

    func debugPixel(at point: NSPoint) -> UInt32 {
        nativeView.debugPixel(at: point)
    }
#endif
}

enum NativeStatusMenuAction {
    case capture
    case settings
    case access
    case quit
}

final class NativeStatusMenuContentView: NSView {
    var onAction: ((NativeStatusMenuAction) -> Void)?

    private let nativeView = NativeHubRenderView(frame: .zero)
    private var measuredFittingSize = NSSize(width: 260, height: 184)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        nativeView.setSurface(.statusMenu)
        nativeView.onButtonPressed = { [weak self] pressed in
            switch pressed {
            case .menuCapture:
                self?.onAction?(.capture)
            case .menuSettings:
                self?.onAction?(.settings)
            case .menuAccess:
                self?.onAction?(.access)
            case .menuQuit:
                self?.onAction?(.quit)
            default:
                break
            }
        }
        addSubview(nativeView)
        let contentSize = nativeView.measureSemanticContentSize(width: 800)
        measuredFittingSize = NSSize(width: max(260, contentSize.width),
                                     height: contentSize.height)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { measuredFittingSize }
    override var intrinsicContentSize: NSSize { fittingSize }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, bounds.contains(point) else { return nil }
        let p = convert(point, to: nativeView)
        return nativeView.hasInteractiveButton(at: p) ? nativeView : nil
    }

    override func layout() {
        super.layout()
        nativeView.frame = bounds
        nativeView.setSurface(.statusMenu)
        nativeView.renderNow()
    }

#if TESTING
    func debugButtons() -> [NativeControlDebugButtonSnapshot] {
        nativeDebugButtons(nativeView, in: self)
    }

    func debugHoverButton(title: String) {
        nativeDebugHover(title: title, nativeView: nativeView)
    }

    func debugPixel(at point: NSPoint) -> UInt32 {
        nativeView.debugPixel(at: convert(point, to: nativeView))
    }
#endif
}

#if TESTING
private func nativeDebugButtons(_ nativeView: NativeHubRenderView,
                                in host: NSView) -> [NativeControlDebugButtonSnapshot] {
    nativeView.renderNow()
    return nativeView.buttonNodes().map { node in
        NativeControlDebugButtonSnapshot(identifier: node.identifier,
                                         title: node.title,
                                         frame: nativeView.convert(node.frame, to: host),
                                         isHovered: node.isHovered,
                                         isPressed: node.isPressed)
    }
}

private func nativeDebugHover(title: String, nativeView: NativeHubRenderView) {
    nativeView.renderNow()
    guard let node = nativeView.buttonNodes().first(where: { $0.title == title }) else { return }
    nativeView.debugMovePointer(to: NSPoint(x: node.frame.midX, y: node.frame.midY))
}
#endif
