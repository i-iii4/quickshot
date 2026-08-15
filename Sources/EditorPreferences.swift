import AppKit

/// Последние подписи для повторной вставки (`D-30`).
///
/// Список короткий намеренно: он помогает повторить «Broken here» в серии
/// снимков, а не заменяет буфер обмена.
struct RecentTextStore {
    private static let key = "editorRecentTexts"
    private static let limit = 8

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var recent: [String] {
        defaults.stringArray(forKey: Self.key) ?? []
    }

    /// Повтор поднимается наверх, а не дублируется: список коротких подписей
    /// быстро вырождается в один и тот же текст.
    mutating func remember(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var items = recent.filter { $0 != value }
        items.insert(value, at: 0)
        defaults.set(Array(items.prefix(Self.limit)), forKey: Self.key)
    }
}

/// Быстрые стили и умолчания стиля по инструменту (`F-5`, `F-6`, `P-4`).
struct QuickStyleStore {
    private static let namedKey = "editorQuickStyles"
    private static let defaultsKey = "editorToolStyleDefaults"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func style(named name: String) -> AnnotationStyle? {
        guard let raw = defaults.dictionary(forKey: Self.namedKey)?[name] as? [String: Double] else {
            return nil
        }
        return Self.style(from: raw)
    }

    mutating func save(_ style: AnnotationStyle, as name: String) {
        var all = defaults.dictionary(forKey: Self.namedKey) ?? [:]
        all[name] = Self.payload(from: style)
        defaults.set(all, forKey: Self.namedKey)
    }

    func defaultStyle(for tool: AnnotationTool) -> AnnotationStyle? {
        guard let raw = defaults.dictionary(forKey: Self.defaultsKey)?[tool.rawValue]
            as? [String: Double] else { return nil }
        return Self.style(from: raw)
    }

    mutating func saveDefault(_ style: AnnotationStyle, for tool: AnnotationTool) {
        var all = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        all[tool.rawValue] = Self.payload(from: style)
        defaults.set(all, forKey: Self.defaultsKey)
    }

    /// `P-5`: сброс к заводским умолчаниям.
    mutating func reset() {
        defaults.removeObject(forKey: Self.namedKey)
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private static func payload(from style: AnnotationStyle) -> [String: Double] {
        ["palette": Double(style.paletteIndex),
         "width": Double(style.lineWidth),
         "filled": style.filled ? 1 : 0,
         "opacity": Double(style.fillOpacity),
         "font": Double(style.fontSize)]
    }

    private static func style(from payload: [String: Double]) -> AnnotationStyle {
        AnnotationStyle(paletteIndex: Int(payload["palette"] ?? 0),
                        lineWidth: CGFloat(payload["width"] ?? 3),
                        filled: (payload["filled"] ?? 0) > 0.5,
                        fillOpacity: CGFloat(payload["opacity"] ?? 0.2),
                        fontSize: CGFloat(payload["font"] ?? 14))
    }
}

/// Настраиваемая раскладка сокращений (`H-6`).
///
/// Хранится только то, что пользователь переназначил: остальное берётся из
/// умолчаний инструмента, поэтому новые инструменты не требуют миграции.
struct ShortcutMap {
    private static let key = "editorShortcutOverrides"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var overrides: [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func tool(for key: String) -> AnnotationTool? {
        let lowered = key.lowercased()
        if let raw = overrides[lowered] { return AnnotationTool(rawValue: raw) }
        // Переназначенная буква не должна одновременно работать по умолчанию.
        guard let fallback = AnnotationTool.tool(forShortcut: lowered) else { return nil }
        guard !overrides.values.contains(fallback.rawValue) else { return nil }
        return fallback
    }

    mutating func assign(_ key: String, to tool: AnnotationTool) {
        var all = overrides
        all = all.filter { $0.value != tool.rawValue }
        all[key.lowercased()] = tool.rawValue
        defaults.set(all, forKey: Self.key)
    }

    mutating func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}

/// Ограничения истории снимков (`K-3`).
struct HistoryLimits {
    private static let key = "historyMaximumItems"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var maximumItems: Int {
        get {
            let stored = defaults.integer(forKey: Self.key)
            return stored > 0 ? stored : 50
        }
        nonmutating set { defaults.set(max(1, newValue), forKey: Self.key) }
    }

    /// Обрезка оставляет последние записи: старое уходит первым.
    func trim<T>(_ items: [T]) -> [T] {
        guard items.count > maximumItems else { return items }
        return Array(items.suffix(maximumItems))
    }
}

/// Объединение кадров в одно изображение (`I-1`).
enum ImageComposer {
    enum Direction { case vertical, horizontal }

    static func combine(_ images: [CGImage], direction: Direction, gap: CGFloat) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let gapPixels = Int(gap.rounded())
        let width: Int
        let height: Int
        switch direction {
        case .vertical:
            width = images.map(\.width).max() ?? 0
            height = images.map(\.height).reduce(0, +) + gapPixels * (images.count - 1)
        case .horizontal:
            width = images.map(\.width).reduce(0, +) + gapPixels * (images.count - 1)
            height = images.map(\.height).max() ?? 0
        }
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // Прозрачные промежутки выдали бы себя на тёмном фоне мессенджера,
        // поэтому подложка непрозрачная.
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var cursor = 0
        for image in images {
            let rect: CGRect
            switch direction {
            case .vertical:
                cursor += image.height + (cursor == 0 ? 0 : gapPixels)
                rect = CGRect(x: 0, y: height - cursor, width: image.width, height: image.height)
            case .horizontal:
                rect = CGRect(x: cursor, y: 0, width: image.width, height: image.height)
                cursor += image.width + gapPixels
            }
            context.draw(image, in: rect)
        }
        return context.makeImage()
    }
}

/// Действия для Shortcuts (`O-1`).
enum ShortcutsActions {
    static let available = ["annotate", "export"]
}
