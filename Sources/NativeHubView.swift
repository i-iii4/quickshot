import AppKit
import CoreGraphics
import OSLog
import QuartzCore

private enum NativeHubMetrics {
    private static func token(_ metric: NativeSDKMetric) -> CGFloat {
        let value = CGFloat(quickshot_native_ui_metric(metric.rawValue))
        precondition(value > 0, "Missing Native SDK metric: \(metric)")
        return value
    }

    static let height = token(.controlHeight)
    static let radius = token(.controlRadius)
    static let controlInset = token(.controlInset)
    static let buttonFontSize = token(.buttonFontSize)
    static let iconSide = token(.iconSide)
    static let iconGap = token(.iconGap)
    static let countBleed: CGFloat = 4
    static let groupGap = token(.groupGap)
    static let shellInset = token(.shellInset)
    static let bubbleRadius = token(.bubbleRadius)
    static var baseAnimationDuration: CFTimeInterval {
        CFTimeInterval(CGFloat(quickshot_native_ui_metric(NativeSDKMetric.animationDurationMilliseconds.rawValue)) / 1000)
    }
    static var animationDuration: CFTimeInterval {
        let metric: NativeSDKMetric = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? .reducedAnimationDurationMilliseconds
            : .animationDurationMilliseconds
        return CFTimeInterval(CGFloat(quickshot_native_ui_metric(metric.rawValue)) / 1000)
    }
}

struct NativeHubSpringSample {
    let value: CGFloat
    let velocity: CGFloat
}

func nativeHubSpringStep(value: CGFloat,
                         velocity: CGFloat,
                         target: CGFloat,
                         angularFrequency: CGFloat,
                         deltaTime: CGFloat) -> NativeHubSpringSample {
    let displacement = value - target
    let c2 = velocity + angularFrequency * displacement
    let decay = exp(-angularFrequency * deltaTime)
    let nextDisplacement = (displacement + c2 * deltaTime) * decay
    let nextVelocity = (c2 - angularFrequency * (displacement + c2 * deltaTime)) * decay
    return NativeHubSpringSample(value: target + nextDisplacement,
                                 velocity: nextVelocity)
}

/// A finite, critically damped reveal. Retargeting keeps the presentation
/// velocity, while the House fast token remains a hard perceptual deadline.
@MainActor
private final class NativeHubSpringAnimator: NSObject {
    private weak var hostView: NSView?
    private var link: CADisplayLink?
    private var value: CGFloat = 0
    private var velocity: CGFloat = 0
    private var target: CGFloat = 0
    private var angularFrequency: CGFloat = 1
    private var lastTimestamp: CFTimeInterval = 0
    private var deadline: CFTimeInterval = 0
    private var onFrame: ((CGFloat) -> Void)?
    private var onDone: (() -> Void)?

    init(hostView: NSView) {
        self.hostView = hostView
        super.init()
    }

    func synchronize(_ value: CGFloat) {
        cancel()
        self.value = value
        target = value
        velocity = 0
    }

    func retarget(to target: CGFloat,
                  response: CFTimeInterval,
                  onFrame: @escaping (CGFloat) -> Void,
                  onDone: (() -> Void)? = nil) {
        self.target = target
        self.onFrame = onFrame
        self.onDone = onDone
        let distance = abs(target - value)
        guard distance > 0.001, response > 0, let hostView else {
            finish(at: target)
            return
        }

        let now = CACurrentMediaTime()
        let segmentDuration = max(1.0 / 240.0, response * CFTimeInterval(distance))
        angularFrequency = CGFloat(7 / segmentDuration)
        lastTimestamp = now
        deadline = now + segmentDuration
        if link == nil {
            let displayLink = hostView.displayLink(target: self, selector: #selector(step(_:)))
            displayLink.add(to: .main, forMode: .common)
            link = displayLink
        }
    }

    @objc private func step(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        if now >= deadline {
            finish(at: target)
            return
        }

        let dt = CGFloat(max(0, min(now - lastTimestamp, 1.0 / 30.0)))
        lastTimestamp = now
        guard dt > 0 else { return }

        let sample = nativeHubSpringStep(value: value,
                                         velocity: velocity,
                                         target: target,
                                         angularFrequency: angularFrequency,
                                         deltaTime: dt)
        value = sample.value
        velocity = sample.velocity
        onFrame?(min(1, max(0, value)))
    }

    private func finish(at value: CGFloat) {
        self.value = value
        target = value
        velocity = 0
        let frame = onFrame
        let completion = onDone
        cancel()
        frame?(value)
        completion?()
    }

    func cancel() {
        link?.invalidate()
        link = nil
        onFrame = nil
        onDone = nil
    }

    isolated deinit { link?.invalidate() }
}

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
}

private enum NativeControlSurface: String {
    case hub
    case hubBubble = "hub_bubble"
    case hubCoreBackground = "hub_core_background"
    case hubCoreForeground = "hub_core_foreground"
    case thumbnail
    case pinned
    case settings
}

private enum NativeInteractionChannel: String {
    case hover
    case pressed
}

private struct NativeButtonNodesCacheKey: Equatable {
    let revision: UInt64
    let size: NSSize
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
    var onInteractionChanged: ((NativeInteractionChannel, NativeHubPressedButton) -> Void)?
    var onRendered: (() -> Void)?
    var rendersPressedState = true
    var acceptsPointerInteraction = true {
        didSet {
            if oldValue != acceptsPointerInteraction {
                if !acceptsPointerInteraction {
                    cancelHoverClear()
                    clearHoverNow()
                }
                updateTrackingAreas()
            }
        }
    }
    var presentsRenderedContents = true {
        didSet {
            layer?.contents = presentsRenderedContents ? retainedCGImage : nil
        }
    }
    private(set) var isPressing = false

    private let nativeApp: UnsafeMutableRawPointer?
    private var rgbaBytes: [UInt8] = []
    private var retainedImageData: Data?
    private var retainedCGImage: CGImage?
    private var lastRenderSignature: NativeHubRenderSignature?
    private var lastSurfaceSignature: NativeHubSurfaceSignature?
    private var renderRevision: UInt64 = 0
    private var cachedButtonNodes: (key: NativeButtonNodesCacheKey, nodes: [NativeHubButtonNode])?
    private(set) var semanticsPassCount = 0
    private(set) var renderPassCount = 0
    private(set) var totalRenderDuration: CFTimeInterval = 0
    private var count = -1
    private var collapsed = false
    private var vertical = true
    private var expanded = false
    private var coreRevealed = false
    private var coreWidth: CGFloat?
    private var bubbleWidth: CGFloat?
    private var actionsAfter = false
    private var surface: NativeControlSurface = .hub
    private var compact = false
    private var copied = false
    private var hoveredNodeID: UInt64?
    private var hoverClearWorkItem: DispatchWorkItem?
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
            Task { @MainActor [weak self] in
                self?.syncSystemAppearance()
            }
        }
        syncSystemAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateRender()
        renderNow()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard acceptsPointerInteraction else { return }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    func setState(count: Int,
                  collapsed: Bool,
                  vertical: Bool,
                  expanded: Bool,
                  coreRevealed: Bool,
                  actionsAfter: Bool) {
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
        if self.coreRevealed != coreRevealed {
            self.coreRevealed = coreRevealed
            sendCommand("hub.core_revealed:\(coreRevealed ? 1 : 0)")
        }
        if self.actionsAfter != actionsAfter {
            self.actionsAfter = actionsAfter
            sendCommand("hub.actions_after:\(actionsAfter ? 1 : 0)")
        }
    }

    func setCoreWidth(_ width: CGFloat?) {
        let normalized = width.flatMap { $0 > 0 ? $0 : nil }
        guard coreWidth != normalized else { return }
        coreWidth = normalized
        sendCommand("hub.core_width:\(normalized ?? 0)")
    }

    /// Панель капсулы обязана совпадать по ширине с кадром рендера: всё, что
    /// шире кадра, срезается вместе с правым штрихом обводки.
    func setBubbleWidth(_ width: CGFloat) {
        guard width > 0, bubbleWidth != width else { return }
        bubbleWidth = width
        sendCommand("hub.bubble_width:\(width)")
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
        layer?.contents = presentsRenderedContents ? image : nil
        retainedCGImage = image
        lastRenderSignature = signature
        renderPassCount += 1
        totalRenderDuration += CACurrentMediaTime() - startedAt
        onRendered?()
    }

    func currentRenderedImage() -> CGImage? {
        renderNow()
        return retainedCGImage
    }

    func renderedCrop(in rect: NSRect) -> CGImage? {
        renderNow()
        guard let image = retainedCGImage else { return nil }
        let scale = CGFloat(image.width) / max(1, bounds.width)
        let pixelRect = CGRect(x: rect.minX * scale,
                               y: rect.minY * scale,
                               width: rect.width * scale,
                               height: rect.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixelRect.width > 0, pixelRect.height > 0 else { return nil }
        return image.cropping(to: pixelRect)
    }

    func hasInteractiveButton(at point: NSPoint) -> Bool {
        button(at: point) != nil
    }

    /// Сырой RGBA-пиксель отрендеренного растра. Не отладочный: тултип берёт
    /// отсюда цвета House-поверхности, а не дублирует токены в Swift.
    func surfacePixel(at point: NSPoint) -> UInt32 {
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

    /// Семантика кнопок пересчитывается только после команды или смены кадра:
    /// мониторы трея зовут этот метод на каждом движении мыши, и без кэша
    /// каждое движение платило бы за layout-проход и перечисление узлов.
    func buttonNodes() -> [NativeHubButtonNode] {
        let key = NativeButtonNodesCacheKey(revision: renderRevision, size: bounds.size)
        if let cachedButtonNodes, cachedButtonNodes.key == key {
            return cachedButtonNodes.nodes
        }
        let nodes = computeButtonNodes()
        cachedButtonNodes = (key, nodes)
        return nodes
    }

    private func computeButtonNodes() -> [NativeHubButtonNode] {
        guard let nativeApp else { return [] }
        semanticsPassCount += 1
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
        guard acceptsPointerInteraction else { return }
        forwardPointerMove(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard acceptsPointerInteraction else { return }
        forwardPointerMove(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard acceptsPointerInteraction else { return }
        scheduleHoverClear()
    }

    /// Указатель, ведомый от одной команды к соседней, проходит через зазор
    /// ряда. Мгновенное снятие подсветки превращает этот проход в мигание,
    /// поэтому цель отпускается только если за grace-период не нашлась новая.
    private func scheduleHoverClear() {
        guard hoveredNodeID != nil, hoverClearWorkItem == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverClearWorkItem = nil
            self.clearHoverNow()
        }
        hoverClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TrayHover.controlGrace, execute: work)
    }

    private func cancelHoverClear() {
        hoverClearWorkItem?.cancel()
        hoverClearWorkItem = nil
    }

    /// Немедленно отпустить подсветку: трей скрывается или выходит из hover.
    func clearPointerHover() {
        cancelHoverClear()
        clearHoverNow()
    }

    private func clearHoverNow() {
        guard hoveredNodeID != nil else { return }
        hoveredNodeID = nil
        quickshot_native_ui_pointer_move(nativeApp, -1, -1)
        sendInteraction(.hover, action: .none)
        renderNow()
    }

    override func mouseDown(with event: NSEvent) {
        guard acceptsPointerInteraction else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let node = button(at: point) else { return }
        isPressing = true
        native_sdk_app_touch(nativeApp, 1, 0, Float(point.x), Float(point.y), 1)
        guard rendersPressedState else { return }
        sendInteraction(.pressed, action: node.action)
        renderNow()
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsPointerInteraction else { return }
        guard isPressing else { return }
        let point = convert(event.locationInWindow, from: nil)
        let target = button(at: point)
        guard target?.id != hoveredNodeID else { return }
        hoveredNodeID = target?.id
        native_sdk_app_touch(nativeApp, 1, 2, Float(point.x), Float(point.y), 1)
        guard rendersPressedState else { return }
        sendInteraction(.hover, action: target?.action ?? .none)
        renderNow()
    }

    override func mouseUp(with event: NSEvent) {
        guard acceptsPointerInteraction else { return }
        guard isPressing else { return }
        defer { isPressing = false }
        let point = convert(event.locationInWindow, from: nil)
        native_sdk_app_touch(nativeApp, 1, 1, Float(point.x), Float(point.y), 0)
        if rendersPressedState {
            sendInteraction(.pressed, action: .none)
            renderNow()
        }
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

    /// Внешняя подача позиции указателя (мониторы трея). Тот же путь, что и
    /// у событий tracking area, поэтому повторные вызовы с той же целью дёшевы.
    func syncPointer(at point: NSPoint) {
        guard acceptsPointerInteraction else { return }
        forwardPointerMove(point)
    }

    private func forwardPointerMove(_ point: NSPoint) {
        guard let target = button(at: point) else {
            scheduleHoverClear()
            return
        }
        cancelHoverClear()
        guard target.id != hoveredNodeID else { return }
        hoveredNodeID = target.id
        quickshot_native_ui_pointer_move(nativeApp, Float(point.x), Float(point.y))
        sendInteraction(.hover, action: target.action)
        renderNow()
    }

    private func invalidateRender() {
        renderRevision &+= 1
    }

    private func sendInteraction(_ channel: NativeInteractionChannel, action: NativeHubPressedButton) {
        sendCommand("ui.\(channel.rawValue):\(action.rawValue)")
        onInteractionChanged?(channel, action)
    }

    func mirrorInteraction(_ channel: NativeInteractionChannel, action: NativeHubPressedButton) {
        sendInteraction(channel, action: action)
        renderNow()
    }

    private func actionForButton(identifier: String, title: String) -> NativeHubPressedButton {
        switch identifier {
        case "Copy screenshot", "Copied screenshot": return .copy
        case "Dismiss screenshot": return .dismiss
        case "Tray left": return .positionLeft
        case "Tray right": return .positionRight
        case "Tray bottom": return .positionBottom
        case "Tray top": return .positionTop
        default: break
        }
        switch title {
        case "Close": return .delete
        case "Save As": return .saveAs
        case "Copy All": return .copyAll
        default:
            return identifier.hasPrefix("Show ") || identifier.hasPrefix("Hide ") ? .toggle : .none
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
        surfacePixel(at: point)
    }

    func debugInkPixelCount(in rect: NSRect) -> Int {
        renderNow()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return 0 }
        let pixelRect = CGRect(x: rect.minX * scale,
                               y: rect.minY * scale,
                               width: rect.width * scale,
                               height: rect.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !pixelRect.isNull, pixelRect.width > 0, pixelRect.height > 0 else { return 0 }
        var count = 0
        for y in Int(pixelRect.minY)..<Int(pixelRect.maxY) {
            for x in Int(pixelRect.minX)..<Int(pixelRect.maxX) {
                let index = (y * width + x) * 4
                guard index + 3 < rgbaBytes.count else { continue }
                let luminance = max(rgbaBytes[index], rgbaBytes[index + 1], rgbaBytes[index + 2])
                if rgbaBytes[index + 3] > 0, luminance > 96 {
                    count += 1
                }
            }
        }
        return count
    }
#endif

    private func logNativeError(_ stage: String) {
        guard let name = native_sdk_app_last_error_name(nativeApp), name[0] != 0 else { return }
        NSLog("QuickShot Native UI: \(stage) failed: \(String(cString: name))")
    }
}

/// Presents one Native SDK-rendered control chrome while allowing only its
/// center fill to stretch. The rasterized corners and stroke keep their exact
/// device pixels, so hover geometry can change without repainting or scaling
/// the Retina edge.
private final class NativeStretchableChromeView: NSView {
    private let chromeLayer = CALayer()
    private var renderScale: CGFloat = 1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        chromeLayer.contentsGravity = .resize
        chromeLayer.minificationFilter = .linear
        chromeLayer.magnificationFilter = .linear
        chromeLayer.masksToBounds = false
        layer?.addSublayer(chromeLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setSource(image: CGImage, sourceBounds: NSRect, buttonFrame: NSRect, radius: CGFloat) {
        guard sourceBounds.width > 0.5, sourceBounds.height > 0.5 else { return }
        renderScale = CGFloat(image.width) / sourceBounds.width
        let leftStretchEdge = min(buttonFrame.midX, buttonFrame.minX + radius)
        let rightStretchEdge = max(buttonFrame.midX, buttonFrame.maxX - radius)
        let center = CGRect(
            x: leftStretchEdge / sourceBounds.width,
            y: 0,
            width: max(1 / CGFloat(image.width),
                       (rightStretchEdge - leftStretchEdge) / sourceBounds.width),
            height: 1
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chromeLayer.contentsScale = renderScale
        chromeLayer.contentsCenter = center
        chromeLayer.contents = image
        CATransaction.commit()
    }

    func setPresentationFrame(_ frame: NSRect) {
        let scale = max(1, renderScale)
        let minX = (frame.minX * scale).rounded() / scale
        let minY = (frame.minY * scale).rounded() / scale
        let maxX = (frame.maxX * scale).rounded() / scale
        let maxY = (frame.maxY * scale).rounded() / scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        chromeLayer.frame = NSRect(x: minX,
                                   y: minY,
                                   width: max(0, maxX - minX),
                                   height: max(0, maxY - minY))
        CATransaction.commit()
    }

#if TESTING
    var debugPresentationFrame: NSRect { chromeLayer.frame }
    var debugContentsCenter: NSRect { chromeLayer.contentsCenter }
    var debugRenderScale: CGFloat { renderScale }
    var debugHasSource: Bool { chromeLayer.contents != nil }
#endif
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

private final class NativeOdometerView: NSView {
    private let outgoingLayer = CALayer()
    private let incomingLayer = CALayer()
    private let edgeFadeMask = CAGradientLayer()
    private(set) var currentImage: CGImage?
    private var outgoingImage: CGImage?
    private var incomingOffset: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        edgeFadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        edgeFadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        edgeFadeMask.colors = [NSColor.clear.cgColor,
                               NSColor.black.cgColor,
                               NSColor.black.cgColor,
                               NSColor.clear.cgColor]
        edgeFadeMask.locations = [0, 0.16, 0.84, 1]
        layer?.mask = edgeFadeMask
        for imageLayer in [outgoingLayer, incomingLayer] {
            imageLayer.contentsGravity = .resizeAspect
            imageLayer.magnificationFilter = .nearest
            imageLayer.minificationFilter = .trilinear
            layer?.addSublayer(imageLayer)
        }
        outgoingLayer.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        updateImageLayerGeometry()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateImageLayerGeometry()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateImageLayerGeometry()
    }

    private func updateImageLayerGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry(of: outgoingLayer, image: outgoingImage)
        updateGeometry(of: incomingLayer, image: currentImage)
        edgeFadeMask.frame = bounds
        CATransaction.commit()
    }

    private func updateGeometry(of imageLayer: CALayer, image: CGImage?) {
        let rect = displayFrame(for: image)
        imageLayer.bounds = NSRect(origin: .zero, size: rect.size)
        imageLayer.position = CGPoint(x: rect.midX, y: rect.midY)
    }

    private func displayFrame(for image: CGImage?) -> NSRect {
        guard let image, image.height > 0, bounds.height > 0 else { return bounds }
        let naturalWidth = bounds.height * CGFloat(image.width) / CGFloat(image.height)
        let width = min(bounds.width, naturalWidth)
        return NSRect(x: bounds.maxX - width,
                      y: bounds.minY,
                      width: width,
                      height: bounds.height)
    }

    func setCurrent(_ image: CGImage?) {
        currentImage = image
        outgoingImage = nil
        isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incomingLayer.contents = image
        incomingLayer.opacity = 1
        incomingLayer.transform = CATransform3DIdentity
        outgoingLayer.contents = nil
        outgoingLayer.isHidden = true
        outgoingLayer.opacity = 0
        outgoingLayer.transform = CATransform3DIdentity
        CATransaction.commit()
        incomingOffset = 0
        updateImageLayerGeometry()
    }

    func prepareTransition(from oldImage: CGImage?, to newImage: CGImage?, increasing: Bool) {
        currentImage = newImage
        outgoingImage = oldImage
        isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoingLayer.contents = oldImage
        outgoingLayer.isHidden = oldImage == nil
        incomingLayer.contents = newImage
        CATransaction.commit()
        updateImageLayerGeometry()
        setProgress(0, increasing: increasing)
    }

    func setProgress(_ progress: CGFloat, increasing: Bool) {
        let p = min(1, max(0, progress))
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let motion = odometerPresentationState(progress: p,
                                               increasing: increasing,
                                               distance: max(1, bounds.height),
                                               reduceMotion: reduceMotion)
        let opacity = motionStrongEaseInOut(p)
        incomingOffset = motion.incomingOffset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outgoingLayer.transform = CATransform3DMakeTranslation(0, motion.outgoingOffset, 0)
        incomingLayer.transform = CATransform3DMakeTranslation(0, motion.incomingOffset, 0)
        outgoingLayer.opacity = Float(1 - opacity)
        incomingLayer.opacity = Float(opacity)
        CATransaction.commit()
        if p >= 0.999 {
            finishTransition()
        }
    }

    func finishTransition() {
        outgoingImage = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incomingLayer.contents = currentImage
        incomingLayer.opacity = 1
        incomingLayer.transform = CATransform3DIdentity
        outgoingLayer.contents = nil
        outgoingLayer.opacity = 0
        outgoingLayer.transform = CATransform3DIdentity
        outgoingLayer.isHidden = true
        CATransaction.commit()
        incomingOffset = 0
        updateImageLayerGeometry()
        isHidden = true
    }

#if TESTING
    var debugIncomingFrame: NSRect {
        let local = displayFrame(for: currentImage)
        return NSRect(x: frame.minX + local.minX,
                      y: frame.minY + local.minY + incomingOffset,
                      width: local.width,
                      height: local.height)
    }
    var debugClips: Bool { layer?.masksToBounds == true }
    var debugLayerCount: Int { layer?.sublayers?.count ?? 0 }
    var debugHasOutgoingContent: Bool { outgoingLayer.contents != nil && !outgoingLayer.isHidden }
    var debugUsesEdgeFade: Bool { layer?.mask === edgeFadeMask }
#endif
}

final class NativeHubShellView: NSView {
    var onToggle: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSaveAs: (() -> Void)?
    var onCopyAll: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private let bubbleView = NativeHubRenderView(frame: .zero)
    private let coreChromeView = NativeStretchableChromeView(frame: .zero)
    private let coreBackgroundView = NativeHubRenderView(frame: .zero)
    private let nativeView = NativeHubRenderView(frame: .zero)
    private let revealedLabelView = NativeHubRenderView(frame: .zero)
    private let compactCoreView = NativeHubRenderView(frame: .zero)
    private let odometerView = NativeOdometerView(frame: .zero)
    private let compactIconRotationView = NSView(frame: .zero)
    private let compactIconContentView = NSView(frame: .zero)
    private let compactIconView = NativeHubRenderView(frame: .zero)
    private let revealMaskLayer = CAShapeLayer()
    private let coreBackgroundMaskLayer = CAShapeLayer()
    private let revealedContentMaskLayer = CAShapeLayer()
    private let revealedLabelMaskLayer = CAShapeLayer()
    private let compactContentMaskLayer = CAShapeLayer()
    private let compactIconMaskLayer = CAShapeLayer()
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
    nonisolated static let tooltipLog = Logger(subsystem: "com.iiii.quickshot",
                                               category: "tooltip")
    private var pointerHoverActive = false
    private var trayHoverHeld = false
    private let tooltip = HubTooltipWindow()
    private var tooltipWorkItem: DispatchWorkItem?
    private var tooltipAction: NativeHubPressedButton = .none
    var tooltipBelow = false
    private var chevronProgress: CGFloat = 0
    private var chevronTargetProgress: CGFloat = 0
    private var hasConfiguredChevron = false
    private var animationStartCount = 0
    private var coreWidth: CGFloat = NativeHubMetrics.height
    private var stableCompactButtonWidth: CGFloat = NativeHubMetrics.height
    private var stableCompactCountFrame: NSRect = .zero
    private var stableCompactIconFrame: NSRect = .zero
    private var compactCoreNativeFrame = NSRect(x: NativeHubMetrics.shellInset,
                                                y: NativeHubMetrics.shellInset,
                                                width: NativeHubMetrics.height,
                                                height: NativeHubMetrics.height)
    private var revealedCoreNativeFrame = NSRect(x: NativeHubMetrics.shellInset,
                                                 y: NativeHubMetrics.shellInset,
                                                 width: NativeHubMetrics.height,
                                                 height: NativeHubMetrics.height)
    private var backgroundCoreNativeFrame = NSRect(x: NativeHubMetrics.shellInset,
                                                   y: NativeHubMetrics.shellInset,
                                                   width: NativeHubMetrics.height,
                                                   height: NativeHubMetrics.height)
    private var currentBackgroundButtonRect = NSRect(x: NativeHubMetrics.shellInset,
                                                     y: NativeHubMetrics.shellInset,
                                                     width: NativeHubMetrics.height,
                                                     height: NativeHubMetrics.height)
    private var revealedActionNativeFrames: [NSRect] = []
    private var revealedIntrinsicCoreWidth: CGFloat = NativeHubMetrics.height
    private var countTranslationX: CGFloat = 0
    private var compactContentBaseFrame: NSRect = .zero
    private var expandedCountTargetMinX: CGFloat = 0
    private var compactCountMaskFrame: NSRect = .zero
    private var compactIconMaskFrame: NSRect = .zero
    private var revealedCountMaskFrame: NSRect = .zero
    private var revealedIconMaskFrame: NSRect = .zero
    private var revealedLabelNativeFrame: NSRect = .zero
    private var revealedForegroundCoreFrame: NSRect = .zero
    private var measuredExpandedWidth: CGFloat?
    private var actionWidths: [String: CGFloat] = [:]
    private var hasCountTransition = false
    private var countTransitionProgress: CGFloat = 1
    private var countTransitionDirection: CGFloat = 1
    private var countTransitionStartButtonWidth: CGFloat = NativeHubMetrics.height
    private var countTransitionEndButtonWidth: CGFloat = NativeHubMetrics.height
    private lazy var geometryAnimator = NativeHubSpringAnimator(hostView: self)
    private lazy var chevronAnimator = NativeHubSpringAnimator(hostView: self)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        layer?.cornerCurve = .continuous
        revealMaskLayer.fillColor = NSColor.black.cgColor
        layer?.mask = revealMaskLayer
        coreBackgroundMaskLayer.fillColor = NSColor.black.cgColor
        revealedContentMaskLayer.fillColor = NSColor.black.cgColor
        revealedLabelMaskLayer.fillColor = NSColor.black.cgColor
        revealedLabelMaskLayer.fillRule = .evenOdd
        compactContentMaskLayer.fillColor = NSColor.black.cgColor
        compactContentMaskLayer.fillRule = .evenOdd
        compactIconMaskLayer.fillColor = NSColor.black.cgColor
        coreBackgroundView.layer?.mask = coreBackgroundMaskLayer
        nativeView.layer?.mask = revealedContentMaskLayer
        revealedLabelView.layer?.mask = revealedLabelMaskLayer
        compactCoreView.layer?.mask = compactContentMaskLayer
        compactIconView.layer?.mask = compactIconMaskLayer
        compactIconRotationView.wantsLayer = true
        compactIconRotationView.layer?.backgroundColor = NSColor.clear.cgColor
        compactIconRotationView.layer?.masksToBounds = true
        compactIconContentView.wantsLayer = true
        compactIconContentView.layer?.backgroundColor = NSColor.clear.cgColor
        compactIconContentView.layer?.masksToBounds = false
        compactIconContentView.addSubview(compactIconView)
        compactIconRotationView.addSubview(compactIconContentView)
        compactCoreView.isHidden = false
        bubbleView.setSurface(.hubBubble)
        coreBackgroundView.setSurface(.hubCoreBackground)
        coreBackgroundView.rendersPressedState = false
        coreBackgroundView.presentsRenderedContents = false
        revealedLabelView.acceptsPointerInteraction = false
        compactCoreView.acceptsPointerInteraction = false
        compactIconView.acceptsPointerInteraction = false
        bubbleView.alphaValue = 0
        let handlePress: (NativeHubPressedButton) -> Void = { [weak self] pressed in
            guard let self else { return }
            switch pressed {
            case .toggle: self.onToggle?()
            case .delete: self.onDelete?()
            case .saveAs: self.onSaveAs?()
            case .copyAll: self.onCopyAll?()
            case .none, .copy, .dismiss, .positionLeft, .positionRight, .positionBottom, .positionTop:
                break
            }
        }
        nativeView.onButtonPressed = handlePress
        revealedLabelView.onButtonPressed = handlePress
        compactCoreView.onButtonPressed = handlePress
        compactIconView.onButtonPressed = handlePress
        coreBackgroundView.onButtonPressed = handlePress
        coreBackgroundView.onInteractionChanged = { [weak self] channel, action in
            self?.nativeView.mirrorInteraction(channel, action: action)
        }
        nativeView.onInteractionChanged = { [weak self] channel, action in
            self?.handleTooltipInteraction(channel, action)
        }
        coreBackgroundView.onRendered = { [weak self] in
            self?.refreshCoreChromeSource()
        }
        addSubview(bubbleView)
        addSubview(coreChromeView)
        addSubview(coreBackgroundView)
        addSubview(nativeView)
        addSubview(revealedLabelView)
        addSubview(compactCoreView)
        addSubview(odometerView)
        addSubview(compactIconRotationView)
        setFrameSize(NSSize(width: compactWidth, height: compactHeight))
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        stopHoverMonitoring()
    }

    var compactHeight: CGFloat { NativeHubMetrics.height + NativeHubMetrics.shellInset * 2 }
    var compactWidth: CGFloat { coreWidth }
    var requiredLeadingClearance: CGFloat { leadingReveal }
    var coreCenter: NSPoint {
        NSPoint(x: collapsedOrigin.x + coreWidth / 2,
                y: collapsedOrigin.y + compactHeight / 2)
    }

    /// Текущая видимая геометрия хаба в координатах хоста: компактное ядро или
    /// раскрытый ряд команд, в зависимости от прогресса раскрытия.
    var visibleFrameInSuperview: NSRect {
        NSRect(x: frame.minX + visibleBounds.minX,
               y: frame.minY + visibleBounds.minY,
               width: visibleBounds.width,
               height: visibleBounds.height)
    }

    func containsVisiblePointInSuperview(_ point: NSPoint) -> Bool {
        visibleFrameInSuperview.contains(point)
    }

    // MARK: тултип команды-иконки

    /// Показ откладывается: проезд курсора через ряд не должен мигать ярлыками.
    /// Смена цели до срабатывания перезапускает таймер; любой не-hover сигнал
    /// и уход с командных кнопок прячут ярлык немедленно.
    /// Холодный показ ждёт `TrayHover.tooltipDelay`; пока ярлык виден, переход
    /// на соседнюю команду перенацеливает его мгновенно — стандартное «тёплое»
    /// поведение тултип-рядов, без прятанья и повторной задержки.
    private func handleTooltipInteraction(_ channel: NativeInteractionChannel,
                                          _ action: NativeHubPressedButton) {
        guard channel == .hover else {
            cancelTooltip()
            return
        }
        let isIconCommand = action == .delete || action == .saveAs || action == .copyAll
        guard isIconCommand else {
            cancelTooltip()
            return
        }
        guard action != tooltipAction else { return }
        let warm = tooltip.isVisible
        tooltipWorkItem?.cancel()
        tooltipWorkItem = nil
        tooltipAction = action
        if warm {
            presentTooltip(for: action)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.tooltipWorkItem = nil
            self.presentTooltip(for: action)
        }
        tooltipWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TrayHover.tooltipDelay,
                                      execute: work)
    }

    private func cancelTooltip() {
        tooltipAction = .none
        tooltipWorkItem?.cancel()
        tooltipWorkItem = nil
        tooltip.hide()
    }

    private func presentTooltip(for action: NativeHubPressedButton) {
        guard let window,
              let node = nativeView.buttonNodes().first(where: { $0.action == action }) else {
            NativeHubShellView.tooltipLog.error("present failed: window=\(self.window != nil) action=\(action.rawValue)")
            return
        }
        let inWindow = nativeView.convert(node.frame, to: nil)
        let anchor = window.convertToScreen(inWindow)
        let bubbleCenter = NSPoint(x: bubbleView.bounds.midX, y: bubbleView.bounds.midY)
        let bubbleEdge = NSPoint(x: 0.75, y: bubbleView.bounds.midY)
        tooltip.show(text: node.title,
                     anchor: anchor,
                     below: tooltipBelow,
                     fill: nativeColor(bubbleView.surfacePixel(at: bubbleCenter)),
                     stroke: nativeColor(bubbleView.surfacePixel(at: bubbleEdge)),
                     radius: NativeHubMetrics.radius,
                     controlHeight: NativeHubMetrics.height,
                     fontSize: NativeHubMetrics.buttonFontSize,
                     horizontalInset: NativeHubMetrics.controlInset,
                     screen: window.screen ?? NSScreen.main)
    }

    private func nativeColor(_ pixel: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((pixel >> 24) & 0xff) / 255,
                green: CGFloat((pixel >> 16) & 0xff) / 255,
                blue: CGFloat((pixel >> 8) & 0xff) / 255,
                alpha: 1)
    }

    private var actionWidth: CGFloat {
        let widths = ["Close", "Save As", "Copy All"].map { actionWidths[$0] ?? NativeHubMetrics.height }
        return widths.reduce(0, +) + NativeHubMetrics.groupGap * CGFloat(max(0, widths.count - 1))
    }

    private var expandedWidth: CGFloat {
        max(compactWidth,
            measuredExpandedWidth ?? (coreWidth + NativeHubMetrics.groupGap + actionWidth))
    }

    private var leadingReveal: CGFloat {
        expandsRight ? max(0, revealedCoreNativeFrame.width - stableCompactButtonWidth) : 0
    }

    private var compactShellX: CGFloat {
        expandsRight ? leadingReveal : max(0, expandedWidth - compactWidth)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, visibleBounds.contains(point) else { return nil }
        let backgroundPoint = convert(point, to: coreBackgroundView)
        if coreBackgroundMaskLayer.path?.contains(backgroundPoint) == true,
           coreBackgroundView.hasInteractiveButton(at: backgroundPoint) {
            return coreBackgroundView
        }
        let nativePoint = convert(point, to: nativeView)
        return nativeView.alphaValue > 0.01 &&
            revealedContentMaskLayer.path?.contains(nativePoint) == true &&
            nativeView.hasInteractiveButton(at: nativePoint) ? nativeView : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: compactBounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setPointerHover(true) }
    override func mouseMoved(with event: NSEvent) { setPointerHover(true) }
    override func mouseExited(with event: NSEvent) {
        guard let superview else {
            setPointerHover(false)
            return
        }
        let point = superview.convert(event.locationInWindow, from: nil)
        updateHover(at: point)
    }

    func set(count: Int,
             collapsed: Bool,
             vertical: Bool,
             expandsRight: Bool,
             animateChevron: Bool = true,
             animateCount: Bool = false) {
        let previousCount = self.count
        let previousCountImage = odometerView.currentImage
        let previousCompactButtonWidth = compactCoreNativeFrame.width
        let previousCollapsed = self.collapsed
        let previousVertical = self.vertical
        let shouldAnimateChevron = hasConfiguredChevron
            && previousCollapsed != collapsed
            && previousVertical == vertical

        self.count = count
        self.collapsed = collapsed
        self.vertical = vertical
        self.expandsRight = expandsRight
        refreshMeasuredMetrics()
        configureStaticGeometry()
        if previousCount != count && animateCount {
            prepareCountTransition(from: previousCount,
                                   to: count,
                                   oldImage: previousCountImage,
                                   newImage: odometerView.currentImage,
                                   oldButtonWidth: previousCompactButtonWidth,
                                   newButtonWidth: compactCoreNativeFrame.width)
        } else if previousCount != count {
            finishCountTransitionImmediately()
        }

        let target: CGFloat = collapsed ? 1 : 0
        chevronTargetProgress = target
        if !animateChevron {
            chevronAnimator.synchronize(chevronProgress)
            applyChevronRotation()
            hasConfiguredChevron = true
            return
        }
        if !hasConfiguredChevron || previousVertical != vertical || NativeHubMetrics.animationDuration == 0 {
            chevronAnimator.synchronize(target)
            chevronProgress = target
            applyChevronRotation()
        } else if shouldAnimateChevron {
            chevronAnimator.retarget(to: target,
                                     response: NativeHubMetrics.baseAnimationDuration,
                                     onFrame: { [weak self] value in
                guard let self else { return }
                self.chevronProgress = value
                self.applyChevronRotation()
            }, onDone: { [weak self] in
                guard let self else { return }
                self.chevronProgress = target
                self.applyChevronRotation()
            })
        } else {
            applyChevronRotation()
        }
        hasConfiguredChevron = true
    }

    func setCountTransitionProgress(_ value: CGFloat) {
        guard hasCountTransition else { return }
        countTransitionProgress = min(1, max(0, value))
        layoutForProgress(progress)
    }

    private func finishCountTransitionImmediately() {
        hasCountTransition = false
        countTransitionProgress = 1
        countTransitionStartButtonWidth = compactCoreNativeFrame.width
        countTransitionEndButtonWidth = compactCoreNativeFrame.width
        odometerView.finishTransition()
        updateCoreContentMasks(progress: progress)
    }

    private func prepareCountTransition(from oldCount: Int,
                                        to newCount: Int,
                                        oldImage: CGImage?,
                                        newImage: CGImage?,
                                        oldButtonWidth: CGFloat,
                                        newButtonWidth: CGFloat) {
        hasCountTransition = true
        countTransitionProgress = 0
        countTransitionDirection = newCount >= oldCount ? 1 : -1
        countTransitionStartButtonWidth = oldButtonWidth
        countTransitionEndButtonWidth = newButtonWidth
        odometerView.prepareTransition(from: oldImage,
                                       to: newImage,
                                       increasing: countTransitionDirection > 0)
        updateCoreContentMasks(progress: progress)
        layoutForProgress(progress)
    }

    private func applyCountTransition() {
        odometerView.setProgress(countTransitionProgress,
                                 increasing: countTransitionDirection > 0)
        if countTransitionProgress >= 0.999 {
            hasCountTransition = false
            updateCoreContentMasks(progress: progress)
        }
    }

    func setChevronProgress(_ value: CGFloat) {
        chevronProgress = max(0, min(1, value))
        chevronTargetProgress = chevronProgress
        chevronAnimator.synchronize(chevronProgress)
        applyChevronRotation()
    }

    private func applyChevronRotation() {
        let angle = CGFloat.pi * min(1, max(0, chevronProgress))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        compactIconContentView.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
    }

    func setCollapsedOrigin(_ origin: NSPoint) {
        collapsedOrigin = origin
        configureStaticGeometry()
    }

    private func setExpanded(_ expanded: Bool) {
        if !expanded && (nativeView.isPressing || coreBackgroundView.isPressing) { return }
        if !expanded { cancelTooltip() }
        let target: CGFloat = expanded ? 1 : 0
        guard target != targetProgress else { return }
        targetProgress = target
        if expanded {
            startHoverMonitoring()
        } else {
            stopHoverMonitoring()
        }
        guard abs(progress - target) > 0.001 else { return }
        animationStartCount += 1
        if NativeHubMetrics.animationDuration == 0 {
            geometryAnimator.synchronize(target)
            progress = target
            layoutForProgress(progress)
        } else {
            geometryAnimator.retarget(to: target,
                                      response: NativeHubMetrics.baseAnimationDuration,
                                      onFrame: { [weak self] value in
                guard let self else { return }
                self.progress = value
                self.layoutForProgress(value)
            }, onDone: { [weak self] in
                guard let self else { return }
                self.progress = target
                self.layoutForProgress(target)
            })
        }

    }

    private func setPointerHover(_ active: Bool) {
        guard pointerHoverActive != active else { return }
        pointerHoverActive = active
        setExpanded(pointerHoverActive || trayHoverHeld)
        onHoverChanged?(active)
    }

    func setTrayHoverHeld(_ held: Bool) {
        guard trayHoverHeld != held else { return }
        trayHoverHeld = held
        setExpanded(pointerHoverActive || trayHoverHeld)
    }

    private func layoutForProgress(_ p: CGFloat) {
        let clippedProgress = min(1, max(0, p))
        let clippedContent = clippedProgress
        let contentHandoff = contentPhase(clippedProgress, from: 0.24, to: 0.44)
        let compactContentAlpha = 1 - contentHandoff
        let revealedContentAlpha = contentHandoff
        let rect = visibleBounds(for: clippedProgress)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMaskLayer.frame = bounds
        revealMaskLayer.path = CGPath(roundedRect: rect,
                                      cornerWidth: NativeHubMetrics.bubbleRadius,
                                      cornerHeight: NativeHubMetrics.bubbleRadius,
                                      transform: nil)
        coreBackgroundMaskLayer.frame = coreBackgroundView.bounds
        let compactButtonWidth: CGFloat
        if hasCountTransition {
            let widthProgress = motionStrongEaseInOut(countTransitionProgress)
            compactButtonWidth = countTransitionStartButtonWidth
                + (countTransitionEndButtonWidth - countTransitionStartButtonWidth) * widthProgress
            updateOdometerViewport(forButtonWidth: compactButtonWidth)
        } else {
            compactButtonWidth = compactCoreNativeFrame.width
        }
        let revealedButtonWidth = backgroundCoreNativeFrame.width
        let currentButtonWidth = compactButtonWidth + (revealedButtonWidth - compactButtonWidth) * clippedProgress
        let buttonRect = NSRect(x: backgroundCoreNativeFrame.maxX - currentButtonWidth,
                                y: backgroundCoreNativeFrame.minY,
                                width: currentButtonWidth,
                                height: backgroundCoreNativeFrame.height)
        currentBackgroundButtonRect = buttonRect
        coreBackgroundMaskLayer.path = CGPath(roundedRect: buttonRect,
                                              cornerWidth: NativeHubMetrics.radius,
                                              cornerHeight: NativeHubMetrics.radius,
                                              transform: nil)
        updateCoreChromePresentation(buttonRect: buttonRect)
        bubbleView.alphaValue = clippedContent
        nativeView.alphaValue = clippedContent
        revealedLabelView.alphaValue = revealedContentAlpha
        compactCoreView.alphaValue = compactContentAlpha
        odometerView.alphaValue = hasCountTransition ? 1 : 0
        compactIconRotationView.alphaValue = 1
        updateCoreContentMasks(progress: clippedProgress)
#if TESTING
        odometerView.frame.origin.x = compactContentBaseFrame.minX + countTranslationX * clippedProgress
#else
        odometerView.layer?.transform = CATransform3DMakeTranslation(countTranslationX * clippedProgress, 0, 0)
#endif
        if hasCountTransition { applyCountTransition() }
        CATransaction.commit()
    }

    private func contentPhase(_ progress: CGFloat, from start: CGFloat, to end: CGFloat) -> CGFloat {
        guard end > start else { return progress >= end ? 1 : 0 }
        return motionStrongEaseOut((progress - start) / (end - start))
    }

    private func refreshCoreChromeSource() {
        guard backgroundCoreNativeFrame.width > 0.5,
              backgroundCoreNativeFrame.height > 0.5,
              let image = coreBackgroundView.currentRenderedImage() else { return }
        coreChromeView.setSource(image: image,
                                 sourceBounds: coreBackgroundView.bounds,
                                 buttonFrame: backgroundCoreNativeFrame,
                                 radius: NativeHubMetrics.radius)
    }

    private func updateCoreChromePresentation(buttonRect: NSRect) {
        let buttonInShell = coreBackgroundView.convert(buttonRect, to: self)
        let left = backgroundCoreNativeFrame.minX
        let right = max(0, coreBackgroundView.bounds.width - backgroundCoreNativeFrame.maxX)
        let top = backgroundCoreNativeFrame.minY
        let bottom = max(0, coreBackgroundView.bounds.height - backgroundCoreNativeFrame.maxY)
        coreChromeView.setPresentationFrame(
            NSRect(x: buttonInShell.minX - left,
                   y: buttonInShell.minY - top,
                   width: buttonInShell.width + left + right,
                   height: buttonInShell.height + top + bottom)
        )
    }

    private var compactBounds: NSRect {
        NSRect(x: compactShellX,
               y: 0,
               width: compactWidth,
               height: compactHeight)
    }

    private var visibleBounds: NSRect { visibleBounds(for: progress) }

    private func visibleBounds(for progress: CGFloat) -> NSRect {
        let compact = NSRect(x: compactShellX, y: 0, width: compactWidth, height: compactHeight)
        let minX = compact.minX * (1 - progress)
        let maxX = compact.maxX + (expandedWidth - compact.maxX) * progress
        return NSRect(x: minX,
                      y: 0,
                      width: maxX - minX,
                      height: compactHeight)
    }

    private func configureStaticGeometry() {
        // Любая перекладка ряда (счётчик, позиция трея, ширина ядра) делает
        // якорь ярлыка недействительным — ярлык не должен висеть на старых
        // координатах.
        cancelTooltip()
        let width = expandedWidth
        let originX = collapsedOrigin.x - compactShellX
        frame = NSRect(x: originX,
                       y: collapsedOrigin.y,
                       width: width,
                       height: compactHeight)

        bubbleView.frame = bounds
        coreChromeView.frame = bounds
        bubbleView.setSurface(.hubBubble)
        bubbleView.setBubbleWidth(width)
        bubbleView.renderNow()

        let stableCompactButtonMaxX = compactCoreNativeFrame.minX + stableCompactButtonWidth
        let nativeX = compactShellX + stableCompactButtonMaxX - revealedCoreNativeFrame.maxX
        nativeView.frame = NSRect(x: nativeX, y: 0, width: width, height: compactHeight)
        nativeView.setState(count: count,
                            collapsed: collapsed,
                            vertical: vertical,
                            expanded: true,
                            coreRevealed: true,
                            actionsAfter: expandsRight)
        nativeView.renderNow()
        let targetCoreFrame = NSRect(x: nativeX + revealedCoreNativeFrame.minX,
                                     y: revealedCoreNativeFrame.minY,
                                     width: revealedCoreNativeFrame.width,
                                     height: revealedCoreNativeFrame.height)
        revealedLabelView.frame = NSRect(
            x: 0,
            y: 0,
            width: revealedCoreNativeFrame.width + NativeHubMetrics.shellInset * 2,
            height: compactHeight
        )
        revealedLabelView.setCoreWidth(revealedCoreNativeFrame.width)
        revealedLabelView.setState(count: count,
                                    collapsed: collapsed,
                                    vertical: vertical,
                                    expanded: true,
                                    coreRevealed: true,
                                    actionsAfter: expandsRight)
        revealedLabelView.setSurface(.hubCoreForeground)
        revealedLabelView.renderNow()
        revealedForegroundCoreFrame = revealedLabelView.buttonNodes().first?.frame
            ?? NSRect(x: NativeHubMetrics.shellInset,
                      y: NativeHubMetrics.shellInset,
                      width: revealedCoreNativeFrame.width,
                      height: revealedCoreNativeFrame.height)
        revealedLabelView.frame.origin = NSPoint(
            x: targetCoreFrame.minX - revealedForegroundCoreFrame.minX,
            y: targetCoreFrame.minY - revealedForegroundCoreFrame.minY
        )
        let backgroundWidth = backgroundCoreNativeFrame.width + NativeHubMetrics.shellInset * 2
        let backgroundX = targetCoreFrame.minX - backgroundCoreNativeFrame.minX
        coreBackgroundView.frame = NSRect(x: backgroundX,
                                          y: 0,
                                          width: backgroundWidth,
                                          height: compactHeight)
        coreBackgroundView.setState(count: count,
                                    collapsed: collapsed,
                                    vertical: vertical,
                                    expanded: false,
                                    coreRevealed: false,
                                    actionsAfter: expandsRight)
        coreBackgroundView.setCoreWidth(revealedCoreNativeFrame.width)
        coreBackgroundView.setSurface(.hubCoreBackground)
        coreBackgroundView.renderNow()
        refreshCoreChromeSource()

        let compactContentOffset = max(0, stableCompactButtonWidth - compactCoreNativeFrame.width)
        let compactX = compactShellX + compactContentOffset
        compactCoreView.frame = NSRect(x: compactX,
                                       y: 0,
                                       width: compactWidth,
                                       height: compactHeight)
        compactCoreView.setState(count: count,
                                 collapsed: collapsed,
                                 vertical: vertical,
                                 expanded: false,
                                 coreRevealed: false,
                                 actionsAfter: expandsRight)
        compactCoreView.setSurface(.hubCoreForeground)
        compactCoreView.renderNow()
        compactIconView.frame = compactCoreView.bounds
        compactIconView.setState(count: count,
                                 collapsed: false,
                                 vertical: vertical,
                                 expanded: false,
                                 coreRevealed: false,
                                 actionsAfter: expandsRight)
        compactIconView.setSurface(.hubCoreForeground)
        compactIconView.renderNow()
        configureContentMasks()
        updateTrackingAreas()
        layoutForProgress(progress)
    }

    private func compactSlices(for buttonFrame: NSRect) -> (count: NSRect, icon: NSRect) {
        let rowY = buttonFrame.minY + 4
        let rowHeight = max(1, buttonFrame.height - 8)
        let contentWidth = max(1, buttonFrame.width - NativeHubMetrics.controlInset * 2)
        let textWidth = max(1, contentWidth - NativeHubMetrics.iconSide - NativeHubMetrics.iconGap)
        let startX = buttonFrame.midX - contentWidth / 2
        return (
            NSRect(x: startX, y: rowY, width: textWidth, height: rowHeight),
            NSRect(x: startX + textWidth + NativeHubMetrics.iconGap,
                   y: rowY,
                   width: NativeHubMetrics.iconSide,
                   height: rowHeight)
        )
    }

    private func configureContentMasks() {
        let compactSlices = compactSlices(for: compactCoreNativeFrame)
        let compactCountRect = compactSlices.count
        let compactCountCropRect = compactCountRect
            .insetBy(dx: -NativeHubMetrics.countBleed, dy: 0)
            .intersection(compactCoreView.bounds)
        let compactIconRect = compactSlices.icon
        let revealedContentWidth = max(
            1,
            revealedIntrinsicCoreWidth - NativeHubMetrics.controlInset * 2
        )
        let revealedTextWidth = max(compactCountRect.width,
                                    revealedContentWidth - NativeHubMetrics.iconSide - NativeHubMetrics.iconGap)
        let revealedStartX = revealedForegroundCoreFrame.midX - revealedContentWidth / 2
        let revealedCountRect = NSRect(x: revealedStartX,
                                       y: revealedForegroundCoreFrame.minY + 4,
                                       width: compactCountRect.width,
                                       height: max(1, revealedForegroundCoreFrame.height - 8))
        let revealedLabelRect = NSRect(x: revealedCountRect.maxX,
                                       y: revealedCountRect.minY,
                                       width: max(1, revealedTextWidth - stableCompactCountFrame.width),
                                       height: revealedCountRect.height)
        let revealedIconRect = NSRect(x: revealedStartX + revealedContentWidth - NativeHubMetrics.iconSide,
                                      y: revealedCountRect.minY,
                                      width: NativeHubMetrics.iconSide,
                                      height: revealedCountRect.height)
        compactCountMaskFrame = compactCountCropRect
        compactIconMaskFrame = compactIconRect
        revealedCountMaskFrame = revealedCountRect
            .insetBy(dx: -NativeHubMetrics.countBleed, dy: 0)
            .intersection(revealedLabelView.bounds)
        revealedIconMaskFrame = revealedIconRect
        revealedLabelNativeFrame = revealedLabelRect
        revealedContentMaskLayer.frame = nativeView.bounds
        let actionPath = CGMutablePath()
        for frame in revealedActionNativeFrames { actionPath.addRect(frame) }
        revealedContentMaskLayer.path = actionPath
        revealedLabelMaskLayer.frame = revealedLabelView.bounds

        compactContentMaskLayer.frame = compactCoreView.bounds
        updateOdometerViewport(forButtonWidth: compactCoreNativeFrame.width)
        if !hasCountTransition {
            odometerView.setCurrent(compactCoreView.renderedCrop(in: compactCountCropRect))
        }
        compactIconMaskLayer.frame = compactIconView.bounds
        compactIconMaskLayer.path = CGPath(rect: compactIconRect, transform: nil)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        compactIconContentView.layer?.setAffineTransform(.identity)
        let rotationSide = max(stableCompactIconFrame.width, stableCompactIconFrame.height)
        let targetRotationOrigin = NSPoint(x: stableCompactIconFrame.midX - rotationSide / 2,
                                           y: stableCompactIconFrame.midY - rotationSide / 2)
        let sourceRotationOrigin = NSPoint(x: compactIconRect.midX - rotationSide / 2,
                                           y: compactIconRect.midY - rotationSide / 2)
        compactIconRotationView.frame = NSRect(x: compactShellX + targetRotationOrigin.x,
                                               y: targetRotationOrigin.y,
                                               width: rotationSide,
                                               height: rotationSide)
        compactIconContentView.frame = compactIconRotationView.bounds
        compactIconContentView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        compactIconContentView.layer?.position = CGPoint(x: compactIconRotationView.bounds.midX,
                                                        y: compactIconRotationView.bounds.midY)
        compactIconView.frame = NSRect(x: -sourceRotationOrigin.x,
                                       y: -sourceRotationOrigin.y,
                                       width: compactCoreView.bounds.width,
                                       height: compactCoreView.bounds.height)
        CATransaction.commit()
        applyChevronRotation()

        expandedCountTargetMinX = revealedLabelView.frame.minX + revealedCountRect.minX
        countTranslationX = expandedCountTargetMinX - odometerView.frame.minX
        updateCoreContentMasks(progress: progress)
    }

    private func updateOdometerViewport(forButtonWidth buttonWidth: CGFloat) {
        let countWidth = max(1,
                             buttonWidth
                                - NativeHubMetrics.controlInset * 2
                                - NativeHubMetrics.iconSide
                                - NativeHubMetrics.iconGap)
        let width = countWidth + NativeHubMetrics.countBleed * 2
        let rightEdge = compactShellX
            + stableCompactCountFrame.maxX
            + NativeHubMetrics.countBleed
        odometerView.frame = NSRect(x: rightEdge - width,
                                    y: stableCompactCountFrame.minY,
                                    width: width,
                                    height: stableCompactCountFrame.height)
        compactContentBaseFrame = odometerView.frame
        if expandedCountTargetMinX != 0 {
            countTranslationX = expandedCountTargetMinX - odometerView.frame.minX
        }
    }

    private func updateCoreContentMasks(progress _: CGFloat) {
        compactContentMaskLayer.path = hasCountTransition
            ? nil
            : contentMaskPath(outer: compactCoreNativeFrame, holes: [compactIconMaskFrame])
        revealedLabelMaskLayer.path = contentMaskPath(
            outer: revealedForegroundCoreFrame,
            holes: [revealedIconMaskFrame] + (hasCountTransition ? [revealedCountMaskFrame] : [])
        )
    }

    private func contentMaskPath(outer: NSRect, holes: [NSRect]) -> CGPath? {
        guard outer.width > 0.5, outer.height > 0.5 else { return nil }
        let path = CGMutablePath()
        path.addRect(outer)
        for hole in holes where hole.width > 0.5 && hole.height > 0.5 {
            path.addRect(hole)
        }
        return path
    }

    /// Область удержания уже открытого hover: раскрытый ряд плюс защитный
    /// запас. Вход считается по видимой геометрии, выход — по этой рамке,
    /// иначе граница дребезжит при движении вдоль края.
    private func expandedHoverFrame() -> NSRect {
        return NSRect(x: collapsedOrigin.x - compactShellX,
                      y: collapsedOrigin.y,
                      width: expandedWidth,
                      height: compactHeight)
            .insetBy(dx: -TrayHover.shield, dy: -TrayHover.shield)
    }

    /// Внешнее обновление указателя. Владелец позиции — трей: его мониторы
    /// живут всегда, а собственные tracking areas хаба глохнут, как только
    /// окно-хост становится прозрачным для мыши.
    func updatePointer(at pointInSuperview: NSPoint) {
        forwardPointerToRevealedRow(pointInSuperview)
        if !pointerHoverActive, containsVisiblePointInSuperview(pointInSuperview) {
            setPointerHover(true)
            return
        }
        updateHover(at: pointInSuperview)
    }

    /// Подсветка и тултип раскрытого ряда не могут полагаться на tracking
    /// areas: mouseMoved у окна, которое не key, доставляется нерегулярно.
    /// Мониторы трея видят каждое движение — с них и кормим кнопочную
    /// поверхность.
    private func forwardPointerToRevealedRow(_ pointInSuperview: NSPoint) {
        guard progress > 0.5, nativeView.alphaValue > 0.01 else { return }
        let local = convert(convert(pointInSuperview, from: superview), to: nativeView)
        nativeView.syncPointer(at: local)
    }

    private func updateHover(at pointInSuperview: NSPoint) {
        if pointerHoverActive, !expandedHoverFrame().contains(pointInSuperview) {
            setPointerHover(false)
        } else if !pointerHoverActive, !trayHoverHeld {
            // A long press can defer closing until mouse-up. The shared monitor
            // retries the effective target without manufacturing a new hover.
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
            Task { @MainActor [weak self] in
                self?.updateHoverFromGlobalPointer()
            }
        }
    }

    private func stopHoverMonitoring() {
        if let localHoverMonitor { NSEvent.removeMonitor(localHoverMonitor) }
        if let globalHoverMonitor { NSEvent.removeMonitor(globalHoverMonitor) }
        localHoverMonitor = nil
        globalHoverMonitor = nil
    }

    func resetHoverState() {
        if pointerHoverActive { onHoverChanged?(false) }
        pointerHoverActive = false
        trayHoverHeld = false
        cancelTooltip()
        nativeView.clearPointerHover()
        coreBackgroundView.clearPointerHover()
        geometryAnimator.synchronize(0)
        stopHoverMonitoring()
        targetProgress = 0
        progress = 0
        layoutForProgress(0)
    }

    private func refreshMeasuredMetrics() {
        let previousCompactFrame = compactCoreView.frame
        let previousBackgroundFrame = coreBackgroundView.frame
        compactCoreView.frame = NSRect(x: 0, y: 0, width: 800, height: compactHeight)
        compactCoreView.setCoreWidth(nil)
        if stableCompactCountFrame.isEmpty || stableCompactIconFrame.isEmpty {
            compactCoreView.setState(count: 100,
                                     collapsed: collapsed,
                                     vertical: vertical,
                                     expanded: false,
                                     coreRevealed: false,
                                     actionsAfter: expandsRight)
            compactCoreView.setSurface(.hubCoreForeground)
            compactCoreView.renderNow()
            if let stableCompactNode = compactCoreView.buttonNodes().first {
                stableCompactButtonWidth = ceil(stableCompactNode.frame.width)
                let slices = compactSlices(for: stableCompactNode.frame)
                stableCompactCountFrame = slices.count
                stableCompactIconFrame = slices.icon
            }
        }
        compactCoreView.setState(count: count,
                                 collapsed: collapsed,
                                 vertical: vertical,
                                 expanded: false,
                                 coreRevealed: false,
                                 actionsAfter: expandsRight)
        compactCoreView.setSurface(.hubCoreForeground)
        compactCoreView.renderNow()
        if let compactCoreNode = compactCoreView.buttonNodes().first {
            compactCoreNativeFrame = compactCoreNode.frame
            coreWidth = ceil(stableCompactButtonWidth + NativeHubMetrics.shellInset * 2)
        }

        let previousFrame = nativeView.frame
        nativeView.frame = NSRect(x: 0, y: 0, width: 800, height: compactHeight)
        nativeView.setCoreWidth(nil)
        nativeView.setState(count: 100,
                            collapsed: false,
                            vertical: vertical,
                            expanded: true,
                            coreRevealed: true,
                            actionsAfter: expandsRight)
        nativeView.renderNow()
        let hideCoreNode = nativeView.buttonNodes().first { node in
            !(node.title == "Close" || node.title == "Save As" || node.title == "Copy All")
        }
        nativeView.setState(count: 100,
                            collapsed: true,
                            vertical: vertical,
                            expanded: true,
                            coreRevealed: true,
                            actionsAfter: expandsRight)
        nativeView.renderNow()
        let showCoreNode = nativeView.buttonNodes().first { node in
            !(node.title == "Close" || node.title == "Save As" || node.title == "Copy All")
        }
        let fixedCoreWidth = ceil(max(hideCoreNode?.frame.width ?? 0, showCoreNode?.frame.width ?? 0))

        nativeView.setCoreWidth(nil)
        nativeView.setState(count: count,
                            collapsed: collapsed,
                            vertical: vertical,
                            expanded: true,
                            coreRevealed: true,
                            actionsAfter: expandsRight)
        nativeView.renderNow()
        let intrinsicCurrentCoreNode = nativeView.buttonNodes().first { node in
            !(node.title == "Close" || node.title == "Save As" || node.title == "Copy All")
        }
        revealedIntrinsicCoreWidth = intrinsicCurrentCoreNode?.frame.width ?? NativeHubMetrics.height

        coreBackgroundView.frame = NSRect(x: 0, y: 0, width: 800, height: compactHeight)
        coreBackgroundView.setState(count: count,
                                    collapsed: collapsed,
                                    vertical: vertical,
                                    expanded: false,
                                    coreRevealed: false,
                                    actionsAfter: expandsRight)
        coreBackgroundView.setCoreWidth(fixedCoreWidth)
        coreBackgroundView.setSurface(.hubCoreBackground)
        coreBackgroundView.renderNow()
        if let backgroundCoreNode = coreBackgroundView.buttonNodes().first {
            backgroundCoreNativeFrame = backgroundCoreNode.frame
        }

        nativeView.setCoreWidth(fixedCoreWidth)
        nativeView.setState(count: count,
                            collapsed: collapsed,
                            vertical: vertical,
                            expanded: true,
                            coreRevealed: true,
                            actionsAfter: expandsRight)
        nativeView.renderNow()
        let revealedNodes = nativeView.buttonNodes()
        let actionNodes = revealedNodes.filter { $0.title == "Close" || $0.title == "Save As" || $0.title == "Copy All" }
        revealedActionNativeFrames = actionNodes.map(\.frame)
        let revealedCoreNode = revealedNodes.first { node in
            !(node.title == "Close" || node.title == "Save As" || node.title == "Copy All")
        }
        if let revealedCoreNode { revealedCoreNativeFrame = revealedCoreNode.frame }
        for node in actionNodes {
            actionWidths[node.title] = ceil(node.frame.width)
        }
        if let content = union(revealedNodes.map(\.frame)) {
            measuredExpandedWidth = ceil(content.maxX + content.minX)
        }
        nativeView.frame = previousFrame
        compactCoreView.frame = previousCompactFrame
        coreBackgroundView.frame = previousBackgroundFrame
    }

    private func union(_ rects: [NSRect]) -> NSRect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() {
            result = result.union(rect)
        }
        return result
    }

#if TESTING
    func debugTransitionCount(to newCount: Int) {
        set(count: newCount,
            collapsed: collapsed,
            vertical: vertical,
            expandsRight: expandsRight,
            animateChevron: false,
            animateCount: true)
    }

    func debugSetCountTransitionProgress(_ value: CGFloat) {
        setCountTransitionProgress(value)
    }

    func debugSetExpansionProgress(_ value: CGFloat) {
        progress = max(0, min(1, value))
        geometryAnimator.synchronize(progress)
        layoutForProgress(progress)
    }

    func debugSetChevronProgress(_ value: CGFloat) {
        setChevronProgress(value)
    }

    func debugSnapshot() -> HubDebugSnapshot {
        nativeView.renderNow()
        revealedLabelView.renderNow()
        compactCoreView.renderNow()
        compactIconView.renderNow()
        coreBackgroundView.renderNow()
        let buttons = nativeView.buttonNodes()
        let shellBounds = visibleBounds
        let actionRects = buttons.compactMap { node -> NSRect? in
            guard node.title == "Close" || node.title == "Save As" || node.title == "Copy All" else { return nil }
            return nativeView.convert(node.frame, to: self)
        }
        let actionClipFrame = union(actionRects) ?? currentActionClipFrame()
        let coreFrame = coreBackgroundMaskLayer.path
            .map { coreBackgroundView.convert($0.boundingBox, to: self) }
            ?? currentCoreFrame()
        let coreBackgroundFrame = coreBackgroundView.buttonNodes().first
            .map { coreBackgroundView.convert($0.frame, to: self) } ?? coreFrame
        let strokeInset: CGFloat = 0.25
        let strokeProbes = [
            NSPoint(x: coreFrame.midX, y: coreFrame.minY + strokeInset),
            NSPoint(x: coreFrame.midX, y: coreFrame.maxY - strokeInset),
        ]
        var foregroundStrokeOwners = 0
        var compactForegroundPerimeterAlpha: UInt8 = 0
        var revealedForegroundPerimeterAlpha: UInt8 = 0
        for point in strokeProbes {
            var owners = 0
            let compactPoint = convert(point, to: compactCoreView)
            let compactAlpha = UInt8(compactCoreView.debugPixel(at: compactPoint) & 0xff)
            if compactCoreView.alphaValue > 0.01,
               compactContentMaskLayer.path?.contains(compactPoint) == true,
               compactAlpha > 0 {
                owners += 1
                compactForegroundPerimeterAlpha = max(compactForegroundPerimeterAlpha, compactAlpha)
            }
            let revealedPoint = convert(point, to: revealedLabelView)
            let revealedAlpha = UInt8(revealedLabelView.debugPixel(at: revealedPoint) & 0xff)
            if revealedLabelView.alphaValue > 0.01,
               revealedLabelMaskLayer.path?.contains(revealedPoint) == true,
               revealedAlpha > 0 {
                owners += 1
                revealedForegroundPerimeterAlpha = max(revealedForegroundPerimeterAlpha, revealedAlpha)
            }
            foregroundStrokeOwners = max(foregroundStrokeOwners, owners)
        }
        let coreCountFrame = hasCountTransition
            ? odometerView.debugIncomingFrame.insetBy(dx: NativeHubMetrics.countBleed, dy: 0)
            : compactCoreView.convert(
                compactCountMaskFrame.insetBy(dx: NativeHubMetrics.countBleed, dy: 0),
                to: self
            )
        let odometerViewportFrame = odometerView.frame
        let coreIconFrame = compactIconRotationView.frame
        let coreLabelFrame = progress > 0.001
            ? revealedLabelView.convert(revealedLabelNativeFrame, to: self)
            : .zero
        let countText = count > 99 ? "99+" : "\(count)"
        let coreTitle = progress > 0.001
            ? "\(countText) \(collapsed ? "Show" : "Hide")"
            : countText

        let actionSnapshots = buttons.compactMap { node -> HubDebugPillSnapshot? in
            let title: String
            if node.title == "Close" || node.title == "Save As" || node.title == "Copy All" {
                title = node.title
            } else {
                return nil
            }
            let shellRect = nativeView.convert(node.frame, to: self)
            let clipRect = shellBounds.intersection(shellRect)
            let fullyVisible = clipRect.width >= shellRect.width - 0.5 && clipRect.height >= shellRect.height - 0.5
            let maskCoversCenter = revealedContentMaskLayer.path?.contains(
                NSPoint(x: node.frame.midX, y: node.frame.midY)
            ) == true
            let relative = NSRect(x: shellRect.minX - actionClipFrame.minX,
                                  y: shellRect.minY - actionClipFrame.minY,
                                  width: shellRect.width,
                                  height: shellRect.height)
            return HubDebugPillSnapshot(title: title,
                                        frame: relative,
                                        cornerRadius: NativeHubMetrics.radius,
                                        labelAlpha: fullyVisible && maskCoversCenter ? 1 : 0,
                                        isInteractive: fullyVisible && maskCoversCenter && nativeView.alphaValue > 0.01,
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
                                coreChromeOwnerCount: 1 + foregroundStrokeOwners,
                                coreChromeUsesStretchableNativeRaster: coreChromeView.debugHasSource &&
                                    coreChromeView.debugContentsCenter.width < 1 &&
                                    !coreBackgroundView.presentsRenderedContents,
                                coreChromeFrame: coreChromeView.debugPresentationFrame,
                                coreChromeRenderScale: coreChromeView.debugRenderScale,
                                compactForegroundPerimeterAlpha: compactForegroundPerimeterAlpha,
                                revealedForegroundPerimeterAlpha: revealedForegroundPerimeterAlpha,
                                revealedForegroundHovered: revealedLabelView.buttonNodes().contains(where: \.isHovered),
                                revealedCountInkPixelCount:
                                    revealedLabelView.debugInkPixelCount(in: revealedCountMaskFrame),
                                revealedLabelInkPixelCount:
                                    revealedLabelView.debugInkPixelCount(in: revealedLabelNativeFrame),
                                coreFrame: coreFrame,
                                coreBackgroundFrame: coreBackgroundFrame,
                                coreCountFrame: coreCountFrame,
                                odometerViewportFrame: odometerViewportFrame,
                                odometerClips: odometerView.debugClips,
                                odometerLayerCount: odometerView.debugLayerCount,
                                odometerHasOutgoingContent: odometerView.debugHasOutgoingContent,
                                odometerUsesEdgeFade: odometerView.debugUsesEdgeFade,
                                coreLabelFrame: coreLabelFrame,
                                coreLabelRequiredWidth: revealedLabelNativeFrame.width,
                                coreIconFrame: coreIconFrame,
                                chevronRotation: CGFloat.pi * chevronProgress,
                                chevronTargetRotation: CGFloat.pi * chevronTargetProgress,
                                chevronHostTransformIsIdentity: CATransform3DIsIdentity(
                                    compactIconRotationView.layer?.transform ?? CATransform3DIdentity
                                ),
                                chevronHostClips: compactIconRotationView.layer?.masksToBounds == true,
                                coreTitle: coreTitle,
                                coreHasIcon: true,
                                stableCoreContentAlpha: compactCoreView.alphaValue + revealedLabelView.alphaValue,
                                revealedLabelAlpha: revealedLabelView.alphaValue,
                                compactTextUsesCompleteNativeRender:
                                    compactContentMaskLayer.path?.boundingBox == compactCoreNativeFrame,
                                revealedTextUsesCompleteNativeRender:
                                    revealedLabelMaskLayer.path?.boundingBox == revealedForegroundCoreFrame,
                                odometerHiddenAtRest: !hasCountTransition && odometerView.isHidden,
                                coreCornerRadius: NativeHubMetrics.radius,
                                actionClipFrame: actionClipFrame,
                                actionPills: actionSnapshots.sorted { $0.frame.minX < $1.frame.minX },
                                animationDuration: NativeHubMetrics.animationDuration,
                                contentFadeDuration: NativeHubMetrics.animationDuration,
                                nativeRenderPassCount: nativeView.renderPassCount + revealedLabelView.renderPassCount + compactCoreView.renderPassCount + compactIconView.renderPassCount + coreBackgroundView.renderPassCount,
                                nativeRenderDuration: nativeView.totalRenderDuration + revealedLabelView.totalRenderDuration + compactCoreView.totalRenderDuration + compactIconView.totalRenderDuration + coreBackgroundView.totalRenderDuration)
    }

    func debugControlButtons() -> [NativeControlDebugButtonSnapshot] {
        nativeDebugButtons(nativeView, in: self)
    }

    func debugHoverButton(title: String) {
        nativeDebugHover(title: title, nativeView: nativeView)
    }

    /// Сырой RGBA растра капсулы, без композита кнопок поверх: проба обводки
    /// должна видеть цвет штриха, а не только итоговую прозрачность.
    func debugBubblePixel(at point: NSPoint) -> UInt32 {
        bubbleView.debugPixel(at: convert(point, to: bubbleView))
    }

    func debugFlushTooltip() {
        guard tooltipWorkItem != nil, tooltipAction != .none else { return }
        tooltipWorkItem?.cancel()
        tooltipWorkItem = nil
        presentTooltip(for: tooltipAction)
    }

    func debugTooltipState() -> (text: String, sharingNone: Bool, ignoresMouse: Bool)? {
        guard let text = tooltip.debugVisibleText else { return nil }
        return (text, tooltip.debugSharingIsNone, tooltip.debugIgnoresMouse)
    }

    var debugSemanticsPassCount: Int { nativeView.semanticsPassCount }

    func debugPixel(at point: NSPoint) -> UInt32 {
        guard visibleBounds.contains(point) else { return 0 }
        let revealedPoint = convert(point, to: nativeView)
        let compactPoint = convert(point, to: compactCoreView)
        let backgroundPoint = convert(point, to: coreBackgroundView)
        let revealed = revealedContentMaskLayer.path?.contains(revealedPoint) == true
            ? nativeView.debugPixel(at: revealedPoint) : 0
        let compact = compactContentMaskLayer.path?.contains(compactPoint) == true
            ? compactCoreView.debugPixel(at: compactPoint) : 0
        let coreBackground = coreBackgroundMaskLayer.path?.contains(backgroundPoint) == true
            ? coreBackgroundView.debugPixel(at: backgroundPoint) : 0
        let background = bubbleView.debugPixel(at: convert(point, to: bubbleView))
        let revealedAlpha = CGFloat(revealed & 0xff) / 255 * nativeView.alphaValue
        let compactAlpha = CGFloat(compact & 0xff) / 255 * compactCoreView.alphaValue
        let coreBackgroundAlpha = CGFloat(coreBackground & 0xff) / 255
        let backgroundAlpha = CGFloat(background & 0xff) / 255 * bubbleView.alphaValue
        let baseAlpha = coreBackgroundAlpha + backgroundAlpha * (1 - coreBackgroundAlpha)
        let revealedComposite = revealedAlpha + baseAlpha * (1 - revealedAlpha)
        let alpha = compactAlpha + revealedComposite * (1 - compactAlpha)
        return UInt32((alpha * 255).rounded())
    }

    func debugTransitionDuration(toExpanded: Bool) -> CFTimeInterval {
        let target: CGFloat = toExpanded ? 1 : 0
        return NativeHubMetrics.animationDuration * CFTimeInterval(abs(target - progress))
    }

    func debugRequestExpanded(_ expanded: Bool) {
        setPointerHover(expanded)
    }

    func debugSetTrayHoverHeld(_ held: Bool) { setTrayHoverHeld(held) }

    func debugUpdateHover(at pointInSuperview: NSPoint) {
        updateHover(at: pointInSuperview)
    }

    private func currentCoreFrame() -> NSRect {
        let width = coreWidth - NativeHubMetrics.shellInset * 2
        return NSRect(x: compactShellX + NativeHubMetrics.shellInset,
                      y: NativeHubMetrics.shellInset,
                      width: width,
                      height: NativeHubMetrics.height)
    }

    private func currentActionClipFrame() -> NSRect {
        if expandsRight {
            let x = compactShellX + coreWidth + NativeHubMetrics.groupGap
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

#if TESTING
@MainActor
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

@MainActor
private func nativeDebugHover(title: String, nativeView: NativeHubRenderView) {
    nativeView.renderNow()
    guard let node = nativeView.buttonNodes().first(where: { $0.title == title }) else { return }
    nativeView.debugMovePointer(to: NSPoint(x: node.frame.midX, y: node.frame.midY))
}
#endif
