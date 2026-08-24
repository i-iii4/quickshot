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



/// A finite, critically damped reveal. Retargeting keeps the presentation
/// velocity, while the House fast token remains a hard perceptual deadline.
@MainActor

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
    case retentionDay
    case retentionWeek
    case retentionMonth
    case retentionForever
    case autosaveOn
    case autosaveOff
    case openFolder
    case toolSelect
    case toolCrop
    case toolArrow
    case toolBox
    case toolEllipse
    case toolLine
    case toolPen
    case toolText
    case toolMark
    case toolStep
    case toolHide
    case editorUndo
    case editorRedo
    case editorSave
    case editorCopy
    case editorClose
    case editorScan
    case editorRotate
    case colour0
    case colour1
    case colour2
    case colour3
    case colour4
    case colour5
    case weightThin
    case weightMedium
    case weightThick
    case fillOn
    case fillOff
}

private enum NativeControlSurface: String {
    case hub
    case thumbnailCopy = "thumbnail_copy"
    case thumbnailDismiss = "thumbnail_dismiss"
    case casePanel = "case_panel"
    case pinned
    case settings
    case annotationToolbar = "annotation_toolbar"
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
#if TESTING
    /// Размер последнего фактически отрисованного растра в точках. Замер
    /// панели рендерит её в пробный кадр, и если после этого не перерисовать,
    /// на экран уходит растр от пробного размера — та самая «каша пикселей».
    var debugRenderedSize: NSSize {
        guard let signature = lastRenderSignature, signature.scale > 0 else { return .zero }
        // Масштаб хранится умноженным на 1000, чтобы подпись оставалась целой.
        let scale = CGFloat(signature.scale) / 1000
        return NSSize(width: CGFloat(signature.width) / scale,
                      height: CGFloat(signature.height) / scale)
    }
#endif
    private var lastSurfaceSignature: NativeHubSurfaceSignature?
    private var renderRevision: UInt64 = 0
    private var cachedButtonNodes: (key: NativeButtonNodesCacheKey, nodes: [NativeHubButtonNode])?
    private(set) var semanticsPassCount = 0
    private(set) var renderPassCount = 0
    private(set) var totalRenderDuration: CFTimeInterval = 0
    private var count = -1
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

    func sendEditorTool(_ rawValue: String) {
        sendCommand("editor.tool:\(rawValue)")
    }

    func sendToolbarCompact(_ compact: Bool) {
        sendCommand("editor.compact:\(compact ? 1 : 0)")
    }

    func sendSelectionPresence(_ hasSelection: Bool) {
        sendCommand("editor.selection:\(hasSelection ? 1 : 0)")
    }

    func sendEditorStyle(paletteIndex: Int, weight: String, filled: Bool) {
        sendCommand("editor.colour:\(max(0, paletteIndex))")
        sendCommand("editor.weight:\(weight)")
        sendCommand("editor.fill:\(filled ? 1 : 0)")
    }

    func sendEditorHistory(canUndo: Bool, canRedo: Bool) {
        sendCommand("editor.can_undo:\(canUndo ? 1 : 0)")
        sendCommand("editor.can_redo:\(canRedo ? 1 : 0)")
    }

    func sendSettingsRetention(_ rawValue: String) {
        sendCommand("settings.retention:\(rawValue)")
    }

    func sendSettingsAutosave(_ enabled: Bool) {
        sendCommand("settings.autosave:\(enabled ? 1 : 0)")
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



    /// Счётчик снимков для панели шкатулки (`TR-30`).
    func setCount(_ count: Int) {
        sendCommand("hub.count:\(max(0, count))")
    }

    func hasInteractiveButton(at point: NSPoint) -> Bool {
        button(at: point) != nil
    }

    /// Узел кнопки под точкой — для тултипов панели редактора.
    fileprivate func buttonNode(at point: NSPoint) -> NativeHubButtonNode? {
        button(at: point)
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


    private func actionForButton(identifier: String, title: String) -> NativeHubPressedButton {
        switch identifier {
        case "Copy screenshot", "Copied screenshot": return .copy
        case "Dismiss screenshot": return .dismiss
        case "Tray left": return .positionLeft
        case "Tray right": return .positionRight
        case "Tray bottom": return .positionBottom
        case "Tray top": return .positionTop
        case "Keep a day": return .retentionDay
        case "Keep a week": return .retentionWeek
        case "Keep a month": return .retentionMonth
        case "Keep forever": return .retentionForever
        case "Autosave on": return .autosaveOn
        case "Autosave off": return .autosaveOff
        case "Open folder": return .openFolder
        case "Tool select": return .toolSelect
        case "Tool crop": return .toolCrop
        case "Tool arrow": return .toolArrow
        case "Tool box": return .toolBox
        case "Tool ellipse": return .toolEllipse
        case "Tool line": return .toolLine
        case "Tool pen": return .toolPen
        case "Tool text": return .toolText
        case "Tool mark": return .toolMark
        case "Tool step": return .toolStep
        case "Tool hide": return .toolHide
        case "Editor undo": return .editorUndo
        case "Editor redo": return .editorRedo
        case "Editor save": return .editorSave
        case "Editor copy": return .editorCopy
        case "Editor close": return .editorClose
        case "Editor scan": return .editorScan
        case "Editor rotate": return .editorRotate
        case "Colour red": return .colour0
        case "Colour amber": return .colour1
        case "Colour green": return .colour2
        case "Colour blue": return .colour3
        case "Colour violet": return .colour4
        case "Colour graphite": return .colour5
        case "Weight thin": return .weightThin
        case "Weight medium": return .weightMedium
        case "Weight thick": return .weightThick
        case "Fill on": return .fillOn
        case "Fill off": return .fillOff
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



/// Одиночная кнопка карточки (`TR-28`): крестик и копирование разнесены по
/// верхним углам, поэтому каждая живёт своим вью со своей поверхностью.
final class NativeThumbnailButtonView: NSView {
    enum Kind {
        case copy
        case dismiss

    }

    var onPress: (() -> Void)?

    private let nativeView = NativeHubRenderView(frame: .zero)
    private let kind: Kind
    private var measured = NSSize(width: NativeHubMetrics.height,
                                  height: NativeHubMetrics.height)

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        applySurface()
        nativeView.setCompact(true)
        nativeView.onButtonPressed = { [weak self] pressed in
            guard let self else { return }
            switch (self.kind, pressed) {
            case (.copy, .copy), (.dismiss, .dismiss):
                self.onPress?()
            default:
                break
            }
        }
        addSubview(nativeView)
        measured = nativeView.measureButtonContentSize()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { measured }
    override var intrinsicContentSize: NSSize { measured }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard !isHidden, alphaValue > 0.01, bounds.contains(local) else { return nil }
        let inNative = convert(local, to: nativeView)
        return nativeView.hasInteractiveButton(at: inNative) ? nativeView : nil
    }

    override func layout() {
        super.layout()
        nativeView.frame = bounds
        applySurface()
        nativeView.renderNow()
    }

    func showCheck(_ on: Bool) {
        guard kind == .copy else { return }
        nativeView.setCopied(on)
        nativeView.renderNow()
        needsLayout = true
    }

    func buttonCenterInSelf() -> NSPoint {
        nativeView.renderNow()
        guard let node = nativeView.buttonNodes().first else {
            return NSPoint(x: bounds.midX, y: bounds.midY)
        }
        return convert(NSPoint(x: node.frame.midX, y: node.frame.midY), from: nativeView)
    }

    private func applySurface() {
        nativeView.setSurface(kind == .copy ? .thumbnailCopy : .thumbnailDismiss)
        nativeView.setCompact(true)
    }

#if TESTING
    func debugState(label: String) -> String {
        nativeView.renderNow()
        let nodes = nativeView.buttonNodes()
        let frame = nodes.first?.frame ?? .zero
        return "nativeFrame=\(nativeView.frame) buttonFrame=\(frame) hidden=\(isHidden) alpha=\(alphaValue) nodes=\(nodes.map(\.title))"
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
}

/// Панель шкатулки (`TR-30`): закрыть всё, копировать всё, счётчик снимков.
/// Рисуется нативной поверхностью `case_panel`, фон прозрачный — подложку даёт
/// сама шкатулка.
final class NativeCasePanelView: NSView {
    var onDeleteAll: (() -> Void)?
    var onCopyAll: (() -> Void)?
    var onSaveAll: (() -> Void)?

    private let nativeView = NativeHubRenderView(frame: .zero)
    private var measured = NSSize(width: 120, height: 28)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(nativeView)
        nativeView.setSurface(.casePanel)
        nativeView.onButtonPressed = { [weak self] pressed in
            switch pressed {
            case .delete: self?.onDeleteAll?()
            case .copyAll: self?.onCopyAll?()
            case .saveAs: self?.onSaveAll?()
            default: break
            }
        }
        setCount(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setCount(_ count: Int) {
        guard count != lastCount else { return }
        lastCount = count
        nativeView.setCount(count)
        // Замер даёт объединение рамок КНОПОК; счётчик и внутренние отступы
        // ряда в него не входят, поэтому добавляем запас — иначе панель
        // получалась короче содержимого и кнопки наезжали друг на друга.
        //
        // Замер рендерит панель шириной 800: после него ОБЯЗАТЕЛЬНО вернуть
        // рендер в реальные границы, иначе на экране остаётся вёрстка под
        // 800 pt, втиснутая в узкую панель — кнопки жмутся к левому краю и
        // сминаются (приёмка 20.08.2026). Плюс замер идёт только при смене
        // счётчика, а не на каждой раскладке.
        let buttons = nativeView.measureButtonContentSize()
        measured = NSSize(width: buttons.width + Self.counterSlack,
                          height: max(buttons.height, NativeHubMetrics.height) + Self.rowPadding * 2)
        invalidateIntrinsicContentSize()
        redrawAtCurrentBounds()
    }

    private var lastCount = -1

    /// Перерисовать панель в её настоящих границах.
    private func redrawAtCurrentBounds() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        nativeView.frame = bounds
        nativeView.renderNow()
    }

    /// Место под счётчик справа от кнопок.
    private static let counterSlack: CGFloat = 26
    /// Внутренние поля ряда из разметки панели.
    private static let rowPadding: CGFloat = 6

    override var fittingSize: NSSize { measured }
    override var intrinsicContentSize: NSSize { measured }

    override func layout() {
        super.layout()
        nativeView.frame = bounds
        // Границы изменились — вёрстка обязана пересчитаться под них.
        nativeView.renderNow()
    }

    /// Трей живёт в неактивном окне-панели: без этого первый клик уходил бы
    /// в активацию окна, а кнопка срабатывала бы лишь со второго.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Мышь ловится только кнопками: остальная площадь панели принадлежит
    /// подложке шкатулки.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return nativeView.hasInteractiveButton(at: nativeView.convert(local, from: self)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        nativeView.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        nativeView.mouseUp(with: event)
    }

    #if TESTING
    func debugButtons() -> [NativeControlDebugButtonSnapshot] { nativeDebugButtons(nativeView, in: self) }
    #endif
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
        let local = superview.map { convert(point, from: $0) } ?? point
        guard !isHidden, alphaValue > 0.01, bounds.contains(local) else { return nil }
        let inNative = convert(local, to: nativeView)
        return nativeView.hasInteractiveButton(at: inNative) ? nativeView : nil
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
    var onRetentionSelected: ((String) -> Void)?
    var onAutosaveChanged: ((Bool) -> Void)?
    var onOpenFolder: (() -> Void)?

    private let nativeView = NativeHubRenderView(frame: .zero)
    private var selectedPosition = "right"
    private var selectedRetention = "week"
    private var autosaveEnabled = true
    private var measuredFittingSize = NSSize(width: 360, height: 140)
    var onFittingSizeChanged: ((NSSize) -> Void)?

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
            case .retentionDay:
                self?.selectRetention("day")
            case .retentionWeek:
                self?.selectRetention("week")
            case .retentionMonth:
                self?.selectRetention("month")
            case .retentionForever:
                self?.selectRetention("forever")
            case .autosaveOn:
                self?.setAutosave(true)
            case .autosaveOff:
                self?.setAutosave(false)
            case .openFolder:
                self?.onOpenFolder?()
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
        let local = superview.map { convert(point, from: $0) } ?? point
        guard !isHidden, alphaValue > 0.01, bounds.contains(local) else { return nil }
        let inNative = convert(local, to: nativeView)
        return nativeView.hasInteractiveButton(at: inNative) ? nativeView : nil
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

    func setSelectedRetention(_ rawValue: String) {
        guard selectedRetention != rawValue else { return }
        selectedRetention = rawValue
        nativeView.setSurface(.settings)
        nativeView.sendSettingsRetention(rawValue)
        nativeView.renderNow()
        needsLayout = true
    }

    /// Выключение автосохранения убирает срок и папку из разметки, поэтому
    /// высота окна пересчитывается вместе с состоянием.
    func setAutosaveEnabled(_ enabled: Bool) {
        guard autosaveEnabled != enabled else { return }
        autosaveEnabled = enabled
        nativeView.setSurface(.settings)
        nativeView.sendSettingsAutosave(enabled)
        nativeView.renderNow()
        remeasure()
        needsLayout = true
    }

    private func selectRetention(_ rawValue: String) {
        setSelectedRetention(rawValue)
        onRetentionSelected?(rawValue)
    }

    private func setAutosave(_ enabled: Bool) {
        setAutosaveEnabled(enabled)
        onAutosaveChanged?(enabled)
    }

    private func remeasure() {
        let contentSize = nativeView.measureSemanticContentSize(width: 800)
        measuredFittingSize = NSSize(width: max(360, contentSize.width),
                                     height: contentSize.height)
        invalidateIntrinsicContentSize()
        onFittingSizeChanged?(measuredFittingSize)
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

/// Поверхность панели инструментов: Native SDK владеет геометрией, hover,
/// нажатием и типизированной диспетчеризацией.
@MainActor
final class NativeAnnotationToolbarSurface: NSView {
    var onCommand: ((AnnotationToolbarView.Command) -> Void)?

    private let nativeView = NativeHubRenderView(frame: .zero)
    private var measuredFittingSize = NSSize(width: 720, height: 40)
    private var selectedTool: AnnotationTool = .select
    private var isCompact = false
    private var wideLayoutWidth: CGFloat = 0
    private var showsStyleControls = false
    /// Изменение измеренного размера: владелец окна обязан переложить панель,
    /// иначе новая строка контролов окажется за её нижним краем.
    var onFittingSizeChanged: ((NSSize) -> Void)?
    private let tooltip = HubTooltipWindow()
    private var tooltipNodeID: UInt64?
    private var tooltipWork: DispatchWorkItem?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        nativeView.setSurface(.annotationToolbar)
        nativeView.onButtonPressed = { [weak self] pressed in
            guard let self, let command = Self.command(for: pressed) else { return }
            self.hideTooltip()
            if case let .tool(tool) = command { self.setSelectedTool(tool) }
            self.onCommand?(command)
        }
        addSubview(nativeView)
        remeasure()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { measuredFittingSize }
    override var intrinsicContentSize: NSSize { fittingSize }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Пустое место панели не крадёт клики: события получают только кнопки.
    /// Точка приходит в координатах супервью — контракт hitTest AppKit.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard !isHidden, alphaValue > 0.01, bounds.contains(local) else { return nil }
        let inNative = convert(local, to: nativeView)
        return nativeView.hasInteractiveButton(at: inNative) ? nativeView : nil
    }

    override func layout() {
        super.layout()
        nativeView.frame = bounds
        nativeView.setSurface(.annotationToolbar)
        nativeView.renderNow()
    }

    // MARK: тултипы панели

    /// Окно редактора — обычное key-окно, поэтому достаточно tracking-области;
    /// глобальные мониторы нужны только не-key окнам трея.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeInActiveApp, .inVisibleRect,
                                            .mouseEnteredAndExited, .mouseMoved],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let inNative = nativeView.convert(event.locationInWindow, from: nil)
        guard let node = nativeView.buttonNode(at: inNative) else {
            hideTooltip()
            return
        }
        guard node.id != tooltipNodeID else { return }
        let warm = tooltip.isVisible
        tooltipWork?.cancel()
        tooltipWork = nil
        tooltipNodeID = node.id
        if warm {
            presentTooltip(for: node)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.tooltipWork = nil
            guard let current = self.nativeView.buttonNode(at: inNative),
                  current.id == node.id else { return }
            self.presentTooltip(for: current)
        }
        tooltipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + TrayHover.tooltipDelay, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hideTooltip()
    }

    private func hideTooltip() {
        tooltipNodeID = nil
        tooltipWork?.cancel()
        tooltipWork = nil
        tooltip.hide()
    }

    private func presentTooltip(for node: NativeHubButtonNode) {
        guard let window else { return }
        let inWindow = nativeView.convert(node.frame, to: nil)
        let anchor = window.convertToScreen(inWindow)
        // Цвета берутся с отрендеренной House-поверхности, как в трее: угол
        // панели — фон, чуть светлее — штрих.
        let fill = Self.pixelColor(nativeView.surfacePixel(at: NSPoint(x: 2, y: 2)))
        let stroke = fill.blended(withFraction: 0.25, of: .white) ?? fill
        tooltip.show(text: node.title,
                     anchor: anchor,
                     below: true,
                     fill: fill,
                     stroke: stroke,
                     radius: NativeHubMetrics.radius,
                     controlHeight: NativeHubMetrics.height,
                     fontSize: NativeHubMetrics.buttonFontSize,
                     horizontalInset: NativeHubMetrics.controlInset,
                     screen: window.screen ?? NSScreen.main)
    }

    private static func pixelColor(_ pixel: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((pixel >> 24) & 0xff) / 255,
                green: CGFloat((pixel >> 16) & 0xff) / 255,
                blue: CGFloat((pixel >> 8) & 0xff) / 255,
                alpha: 1)
    }

    func setSelectedTool(_ tool: AnnotationTool) {
        guard selectedTool != tool else { return }
        let transformModeChanged = (selectedTool == .crop) != (tool == .crop)
        selectedTool = tool
        nativeView.setSurface(.annotationToolbar)
        nativeView.sendEditorTool(tool.rawValue)
        nativeView.renderNow()
        // Кадрирование добавляет свою команду: набор контролов меняется, и
        // измеренный размер панели обязан пересчитаться.
        if transformModeChanged { remeasure() }
        needsDisplay = true
    }

    /// Ширина, при которой инструменты перестают помещаться в одну строку.
    /// Порог берётся из измеренной ширины широкого варианта, а не из
    /// угаданного числа.
    func setAvailableWidth(_ width: CGFloat) {
        let compact = width < wideLayoutWidth
        guard compact != isCompact else { return }
        isCompact = compact
        nativeView.setSurface(.annotationToolbar)
        nativeView.sendToolbarCompact(compact)
        nativeView.renderNow()
        remeasure()
        needsDisplay = true
    }

    func setStyle(paletteIndex: Int, weight: AnnotationStrokeWeight, filled: Bool) {
        nativeView.setSurface(.annotationToolbar)
        nativeView.sendEditorStyle(paletteIndex: paletteIndex,
                                   weight: weight.rawValue,
                                   filled: filled)
        nativeView.renderNow()
        needsDisplay = true
    }

    /// Контролы стиля показываются только когда есть что настраивать.
    func setSelectionPresence(_ hasSelection: Bool) {
        guard hasSelection != showsStyleControls else { return }
        showsStyleControls = hasSelection
        nativeView.setSurface(.annotationToolbar)
        nativeView.sendSelectionPresence(hasSelection)
        nativeView.renderNow()
        remeasure()
        needsDisplay = true
    }

    func setHistoryState(canUndo: Bool, canRedo: Bool) {
        nativeView.setSurface(.annotationToolbar)
        nativeView.sendEditorHistory(canUndo: canUndo, canRedo: canRedo)
        nativeView.renderNow()
        needsDisplay = true
    }

    /// Высота считается по фактическим узлам кнопок, а не по кадру измерения:
    /// колонка без заданной высоты растягивается на весь пробный кадр, и
    /// «высота содержимого» оказывалась равна высоте кадра.
    private func remeasure() {
        let probe = NSSize(width: 2400, height: 400)
        let previousFrame = nativeView.frame
        nativeView.frame = NSRect(origin: .zero, size: probe)
        nativeView.setSurface(.annotationToolbar)
        nativeView.renderNow()
        let frames = nativeView.buttonNodes().map(\.frame)
        // Возврат рамки без перерисовки оставлял на экране растр от пробного
        // кадра: панель выглядела кашей пикселей после каждого замера.
        nativeView.frame = previousFrame
        nativeView.renderNow()

        guard let first = frames.first else {
            measuredFittingSize = NSSize(width: 720, height: 40)
            return
        }
        let content = frames.dropFirst().reduce(first) { $0.union($1) }
        let inset = NativeHubMetrics.shellInset
        let width = ceil(content.maxX + inset)
        let height = ceil(content.height + inset * 2)
        if !isCompact { wideLayoutWidth = width }
        let updated = NSSize(width: width, height: max(40, height))
        let changed = updated != measuredFittingSize
        measuredFittingSize = updated
        invalidateIntrinsicContentSize()
        if changed { onFittingSizeChanged?(updated) }
    }

    private static func command(for pressed: NativeHubPressedButton) -> AnnotationToolbarView.Command? {
        switch pressed {
        case .toolSelect: return .tool(.select)
        case .toolCrop: return .tool(.crop)
        case .toolArrow: return .tool(.arrow)
        case .toolBox: return .tool(.box)
        case .toolEllipse: return .tool(.ellipse)
        case .toolLine: return .tool(.line)
        case .toolPen: return .tool(.pen)
        case .toolText: return .tool(.text)
        case .toolMark: return .tool(.mark)
        case .toolStep: return .tool(.step)
        case .toolHide: return .tool(.hide)
        case .editorUndo: return .undo
        case .editorRedo: return .redo
        case .editorSave: return .save
        case .editorCopy: return .copy
        case .editorClose: return .close
        case .editorScan: return .scan
        case .editorRotate: return .rotate
        case .colour0: return .colour(0)
        case .colour1: return .colour(1)
        case .colour2: return .colour(2)
        case .colour3: return .colour(3)
        case .colour4: return .colour(4)
        case .colour5: return .colour(5)
        case .weightThin: return .weight(.thin)
        case .weightMedium: return .weight(.medium)
        case .weightThick: return .weight(.thick)
        case .fillOn: return .fill(true)
        case .fillOff: return .fill(false)
        default: return nil
        }
    }

#if TESTING
    var debugRenderedSize: NSSize { nativeView.debugRenderedSize }

    func debugButtons() -> [NativeControlDebugButtonSnapshot] {
        nativeDebugButtons(nativeView, in: self)
    }

    func debugHoverButton(title: String) {
        nativeDebugHover(title: title, nativeView: nativeView)
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
