import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import OSLog
@preconcurrency import ScreenCaptureKit

enum FreshRegionCapture {
    private static let log = Logger(subsystem: "com.iiii.quickshot", category: "capture")

    static func capture(selection: CGRect,
                        display: CaptureDisplay,
                        startedAt: CFAbsoluteTime) async throws -> CGImage {
        let spec = CoordinateMath.captureSpec(globalSelection: selection,
                                              displayFrame: display.frame,
                                              scale: display.scale)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw captureError(from: error, context: "fresh region shareable content unavailable")
        }

        guard let targetDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw CaptureError.captureStackUnavailable("No SCDisplay matching displayID \(display.id)")
        }

        let filter = contentFilter(for: targetDisplay, content: content)
        let config = configuration(for: spec)
        let captureStartedAt = CFAbsoluteTimeGetCurrent()

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                    configuration: config)
            let captureMs = (CFAbsoluteTimeGetCurrent() - captureStartedAt) * 1000
            let totalMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            log.info("capture fresh region raw ready display=\(display.id, privacy: .public) width=\(image.width, privacy: .public) height=\(image.height, privacy: .public) captureMs=\(captureMs, privacy: .public) totalMs=\(totalMs, privacy: .public)")

            if image.width == spec.pixelWidth, image.height == spec.pixelHeight {
                return image
            }

            if let cropped = cropIfFullDisplayImage(image, spec: spec, scale: display.scale) {
                log.info("capture fresh region cropped rawWidth=\(image.width, privacy: .public) rawHeight=\(image.height, privacy: .public) width=\(cropped.width, privacy: .public) height=\(cropped.height, privacy: .public)")
                return cropped
            }

            throw CaptureError.captureStackUnavailable("fresh region size mismatch \(image.width)x\(image.height), expected \(spec.pixelWidth)x\(spec.pixelHeight)")
        } catch {
            throw captureError(from: error, context: "fresh region capture failed")
        }
    }

    private static func contentFilter(for display: SCDisplay,
                                      content: SCShareableContent) -> SCContentFilter {
        let processID = getpid()
        if let currentApplication = content.applications.first(where: { $0.processID == processID }) {
            log.info("capture fresh region excludes app pid=\(processID, privacy: .public) bundle=\(currentApplication.bundleIdentifier, privacy: .public)")
            return SCContentFilter(display: display,
                                   excludingApplications: [currentApplication],
                                   exceptingWindows: [])
        }

        let currentWindows = content.windows.filter { $0.owningApplication?.processID == processID }
        if !currentWindows.isEmpty {
            log.info("capture fresh region excludes windows count=\(currentWindows.count, privacy: .public) pid=\(processID, privacy: .public)")
            return SCContentFilter(display: display, excludingWindows: currentWindows)
        }

        log.warning("capture fresh region exclusion fallback empty pid=\(processID, privacy: .public)")
        return SCContentFilter(display: display, excludingWindows: [])
    }

    private static func configuration(for spec: CaptureSpec) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.sourceRect = spec.sourceRect
        config.width = spec.pixelWidth
        config.height = spec.pixelHeight
        config.captureResolution = .best
        config.showsCursor = false
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 1
        return config
    }

    private static func cropIfFullDisplayImage(_ image: CGImage,
                                               spec: CaptureSpec,
                                               scale: CGFloat) -> CGImage? {
        let px = CGRect(x: spec.sourceRect.minX * scale,
                        y: spec.sourceRect.minY * scale,
                        width: CGFloat(spec.pixelWidth),
                        height: CGFloat(spec.pixelHeight))
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard px.width >= 1, px.height >= 1 else { return nil }
        return image.cropping(to: px)
    }

    private static func captureError(from error: Error, context: String) -> CaptureError {
        if let captureError = error as? CaptureError {
            return captureError
        }
        if let streamError = error as? SCStreamError, streamError.code == .userDeclined {
            return .permissionDenied
        }
        return .captureStackUnavailable("\(context): \(error.localizedDescription)")
    }
}
