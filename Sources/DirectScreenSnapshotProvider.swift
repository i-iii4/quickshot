import CoreGraphics
import Darwin
import Foundation
import OSLog

struct DirectScreenSnapshotProvider: Sendable {
    typealias CaptureImage = @Sendable (CGRect) throws -> CGImage

    nonisolated private static let log = Logger(subsystem: "com.iiii.quickshot",
                                                category: "capture")
    private let captureImage: CaptureImage

    init() {
        captureImage = { bounds in
            try LegacyWindowSnapshotBackend.capture(bounds: bounds)
        }
    }

    init(captureImage: @escaping CaptureImage) {
        self.captureImage = captureImage
    }

    static var isDirectCaptureAvailable: Bool {
        LegacyWindowSnapshotBackend.isAvailable
    }

    /// Pays the one-time WindowServer setup cost without retaining or publishing pixels.
    /// The tiny probe shares the same compositor path as a real full-display request.
    func prepare(quartzBounds: CGRect) throws {
        guard quartzBounds.width > 0, quartzBounds.height > 0 else { return }
        let probe = CGRect(x: quartzBounds.minX,
                           y: quartzBounds.minY,
                           width: min(64, quartzBounds.width),
                           height: min(64, quartzBounds.height))
        let startedAt = CFAbsoluteTimeGetCurrent()
        try DirectCaptureLane.shared.sync {
            _ = try autoreleasepool { try captureImage(probe) }
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        Self.log.info("capture direct prepare complete ms=\(elapsedMs, privacy: .public)")
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
                guard image.width > 0, image.height > 0 else {
                    throw CaptureError.snapshotUnavailable(
                        "Display \(display.id) returned an empty image")
                }
                let elapsedMs = (CFAbsoluteTimeGetCurrent() - displayStartedAt) * 1000
                Self.log.info("capture direct display ready display=\(display.id, privacy: .public) width=\(image.width, privacy: .public) height=\(image.height, privacy: .public) ms=\(elapsedMs, privacy: .public)")
                captured.append(FrozenScreen(displayID: display.id,
                                             frame: display.frame,
                                             image: image))
            }
            return captured
        }

        guard screens.count == displays.count else {
            throw CaptureError.snapshotUnavailable(
                "Captured \(screens.count) of \(displays.count) displays")
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        Self.log.info("capture direct batch ready session=\(sessionID.uuidString, privacy: .public) displays=\(screens.count, privacy: .public) ms=\(elapsedMs, privacy: .public)")
        return FrozenSnapshotBatch(sessionID: sessionID, screens: screens)
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

    private static let coreGraphicsHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
               RTLD_LAZY | RTLD_LOCAL)
    }()

    private static let createImage: CreateImageFunction? = {
        guard let coreGraphicsHandle,
              let symbol = dlsym(coreGraphicsHandle, "CGWindowListCreateImage") else {
            return nil
        }
        return unsafeBitCast(symbol, to: CreateImageFunction.self)
    }()

    static var isAvailable: Bool { createImage != nil }

    static func capture(bounds: CGRect) throws -> CGImage {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            throw CaptureError.snapshotUnavailable("Invalid display bounds: \(bounds)")
        }
        guard let createImage else {
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
