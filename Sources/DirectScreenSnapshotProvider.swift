import CoreGraphics
import Darwin
import Foundation
import OSLog

protocol ScreenSnapshotProviding: Sendable {
    func capture(sessionID: UUID,
                 displays: [CaptureDisplay]) async throws -> FrozenSnapshotBatch
}

struct DirectScreenSnapshotProvider: ScreenSnapshotProviding {
    typealias CaptureImage = @Sendable (CGRect) throws -> CGImage

    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot",
                                                category: "capture")
    private let captureImage: CaptureImage
    private let maximumAcceptedDisplaySkew: TimeInterval

    init() {
        captureImage = { bounds in
            try LegacyWindowSnapshotBackend.capture(bounds: bounds)
        }
        maximumAcceptedDisplaySkew = 0.120
    }

    init(maximumAcceptedDisplaySkew: TimeInterval = 0.120,
         captureImage: @escaping CaptureImage) {
        self.captureImage = captureImage
        self.maximumAcceptedDisplaySkew = maximumAcceptedDisplaySkew
    }

    static var isDirectCaptureAvailable: Bool {
        LegacyWindowSnapshotBackend.isAvailable
    }

    func capture(sessionID: UUID,
                 displays: [CaptureDisplay]) async throws -> FrozenSnapshotBatch {
        guard !displays.isEmpty else { throw CaptureError.noDisplay }
        let uniqueIDs = Set(displays.map(\.id))
        guard uniqueIDs.count == displays.count else {
            throw CaptureError.snapshotUnavailable("Duplicate display identifiers")
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        // CGWindowListCreateImage is a synchronous request to one WindowServer compositor.
        // Concurrent calls do not provide parallel work there; on current macOS they can
        // contend for the same capture proxy and turn a normally 20-30ms batch into a
        // multi-second outlier. Keep one ordered request lane while preserving each display's
        // native pixel resolution (a single union capture downscales mixed-DPI displays).
        let screens = try DirectCaptureLane.shared.sync {
            var captured: [FrozenScreen] = []
            captured.reserveCapacity(displays.count)
            for display in displays {
                try Task.checkCancellation()
                let displayStartedAt = CFAbsoluteTimeGetCurrent()
                let image = try autoreleasepool {
                    try captureImage(display.quartzBounds)
                }
                let displayCompletedAt = CFAbsoluteTimeGetCurrent()
                guard image.width > 0, image.height > 0 else {
                    throw CaptureError.snapshotUnavailable(
                        "Display \(display.id) returned an empty image")
                }
                let duration = displayCompletedAt - displayStartedAt
                let elapsedMs = duration * 1000
                Self.log.info("capture direct display ready display=\(display.id, privacy: .public) width=\(image.width, privacy: .public) height=\(image.height, privacy: .public) ms=\(elapsedMs, privacy: .public)")
                captured.append(FrozenScreen(displayID: display.id,
                                             frame: display.frame,
                                             image: image,
                                             capturedAt: displayStartedAt + duration / 2,
                                             captureDuration: duration))
            }
            return captured
        }
        try Task.checkCancellation()

        guard screens.count == displays.count else {
            throw CaptureError.snapshotUnavailable(
                "Captured \(screens.count) of \(displays.count) displays")
        }
        let completedAt = CFAbsoluteTimeGetCurrent()
        let timestamps = screens.map(\.capturedAt)
        let skew = (timestamps.max() ?? startedAt) - (timestamps.min() ?? startedAt)
        // Рассинхронизация НЕ отменяет снимок. Итоговое изображение вырезается
        // из одного дисплея, а кадры остальных лишь подкладываются под оверлей
        // на их экранах: разъезд по времени между дисплеями ухудшает подложку,
        // но не результат. Прежний жёсткий отказ означал, что под нагрузкой —
        // а несколько снимков подряд её и создают — каждый вызов хоткея молча
        // отклонялся, и приложение выглядело зависшим.
        if skew > maximumAcceptedDisplaySkew {
            let budgetMs = maximumAcceptedDisplaySkew * 1000
            Self.log.error("capture direct batch skew high session=\(sessionID.uuidString, privacy: .public) skewMs=\(skew * 1000, privacy: .public) budgetMs=\(budgetMs, privacy: .public)")
        }
        let elapsedMs = (completedAt - startedAt) * 1000
        Self.log.info("capture direct batch ready session=\(sessionID.uuidString, privacy: .public) displays=\(screens.count, privacy: .public) skewMs=\(skew * 1000, privacy: .public) ms=\(elapsedMs, privacy: .public)")
        return FrozenSnapshotBatch(sessionID: sessionID,
                                   screens: screens,
                                   captureStartedAt: startedAt,
                                   captureCompletedAt: completedAt,
                                   maximumDisplaySkew: skew)
    }
}

/// Every direct request targets the same WindowServer compositor. One process-wide
/// lane prevents startup preparation and user captures from contending with it.
private final class DirectCaptureLane: @unchecked Sendable {
    static let shared = DirectCaptureLane()
    private let lock = NSLock()

    func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private enum LegacyWindowSnapshotBackend {
    typealias CreateImageFunction = @convention(c) (
        CGRect, UInt32, UInt32, UInt32
    ) -> Unmanaged<CGImage>?

    private final class Resolver: @unchecked Sendable {
        let handle: UnsafeMutableRawPointer?
        let createImage: CreateImageFunction?

        init() {
            let handle = dlopen(
                "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
                RTLD_LAZY | RTLD_LOCAL)
            self.handle = handle
            if let handle, let symbol = dlsym(handle, "CGWindowListCreateImage") {
                createImage = unsafeBitCast(symbol, to: CreateImageFunction.self)
            } else {
                createImage = nil
            }
        }
    }

    private static let resolver = Resolver()

    static var isAvailable: Bool { resolver.createImage != nil }

    static func capture(bounds: CGRect) throws -> CGImage {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            throw CaptureError.snapshotUnavailable("Invalid display bounds: \(bounds)")
        }
        guard let createImage = resolver.createImage else {
            let reason = dlerror().map { String(cString: $0) }
                ?? "CGWindowListCreateImage is unavailable"
            throw CaptureError.captureStackUnavailable(reason)
        }

        let listOptions = UInt32(CGWindowListOption.optionOnScreenOnly.rawValue)
        let imageOptions = UInt32(CGWindowImageOption.bestResolution.rawValue)
        guard let retained = createImage(bounds,
                                         listOptions,
                                         UInt32(kCGNullWindowID),
                                         imageOptions) else {
            throw CaptureError.snapshotUnavailable(
                "CoreGraphics returned no image for bounds \(bounds)")
        }
        return retained.takeRetainedValue()
    }
}
