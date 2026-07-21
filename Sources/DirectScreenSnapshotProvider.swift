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

    func capture(sessionID: UUID,
                 displays: [CaptureDisplay]) async throws -> FrozenSnapshotBatch {
        guard !displays.isEmpty else { throw CaptureError.noDisplay }
        let uniqueIDs = Set(displays.map(\.id))
        guard uniqueIDs.count == displays.count else {
            throw CaptureError.snapshotUnavailable("Duplicate display identifiers")
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let captureImage = self.captureImage
        let screens = try await withThrowingTaskGroup(of: FrozenScreen.self) { group in
            for display in displays {
                group.addTask {
                    let displayStartedAt = CFAbsoluteTimeGetCurrent()
                    let image = try captureImage(display.quartzBounds)
                    guard image.width > 0, image.height > 0 else {
                        throw CaptureError.snapshotUnavailable(
                            "Display \(display.id) returned an empty image")
                    }
                    let elapsedMs = (CFAbsoluteTimeGetCurrent() - displayStartedAt) * 1000
                    Self.log.info("capture direct display ready display=\(display.id, privacy: .public) width=\(image.width, privacy: .public) height=\(image.height, privacy: .public) ms=\(elapsedMs, privacy: .public)")
                    return FrozenScreen(displayID: display.id,
                                        frame: display.frame,
                                        image: image)
                }
            }

            var captured: [FrozenScreen] = []
            captured.reserveCapacity(displays.count)
            for try await screen in group {
                captured.append(screen)
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
