import AppKit
import Darwin

@MainActor
@main
struct WindowCaptureProtectionCompatibilityTests {
    private static let controlColor = NSColor(calibratedRed: 0.94, green: 0.12, blue: 0.22, alpha: 1)
    private static let protectedColor = NSColor(calibratedRed: 0.16, green: 0.82, blue: 0.30, alpha: 1)
    private static let backdropColor = NSColor(calibratedRed: 0.08, green: 0.28, blue: 0.88, alpha: 1)

    static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main else { fail("no main screen") }

        let quartzBounds = CGDisplayBounds(CGMainDisplayID())
        let captureRect = CGRect(x: quartzBounds.minX + 80,
                                 y: quartzBounds.minY + 100,
                                 width: 460,
                                 height: 220)
        let appKitRect = NSRect(x: screen.frame.minX + captureRect.minX - quartzBounds.minX,
                                y: screen.frame.maxY - (captureRect.maxY - quartzBounds.minY),
                                width: captureRect.width,
                                height: captureRect.height)

        let backdrop = makeWindow(frame: appKitRect, color: backdropColor)
        let control = makeWindow(frame: NSRect(x: appKitRect.minX + 20, y: appKitRect.minY + 30,
                                               width: 190, height: 160), color: controlColor)
        let protected = makeWindow(frame: NSRect(x: appKitRect.minX + 250, y: appKitRect.minY + 30,
                                                 width: 190, height: 160), color: protectedColor)
        control.sharingType = .readOnly
        WindowCaptureProtection.excludeFromScreenCapture(protected)
        [backdrop, control, protected].forEach { $0.orderFrontRegardless(); $0.displayIfNeeded() }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))

        defer {
            [protected, control, backdrop].forEach { $0.close() }
        }

        let displayID = CGMainDisplayID()
        let display = CaptureDisplay(id: displayID,
                                     frame: screen.frame,
                                     quartzBounds: CGDisplayBounds(displayID))
        let batch: FrozenSnapshotBatch
        do {
            batch = try await DirectScreenSnapshotProvider()
                .capture(sessionID: UUID(), displays: [display])
        } catch {
            fail("direct capture failed: \(error)")
        }
        guard let frozen = batch.screens.first,
              let crop = frozen.crop(globalSelection: appKitRect) else {
            fail("direct capture did not return the test region")
        }
        let image = NSBitmapImageRep(cgImage: crop)

        let controlSample = sample(image, xFraction: 0.25, yFraction: 0.50)
        let protectedSample = sample(image, xFraction: 0.75, yFraction: 0.50)
        guard close(controlSample, to: controlColor) else {
            fail("A/B control window was not captured")
        }
        guard close(protectedSample, to: backdropColor), !close(protectedSample, to: protectedColor) else {
            fail(".sharingType = .none no longer excludes a window on this macOS build")
        }
        print("WindowCaptureProtectionCompatibilityTests: passed")
    }

    private static func makeWindow(frame: NSRect, color: NSColor) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = color
        window.hasShadow = false
        window.level = .statusBar
        return window
    }

    private static func sample(_ image: NSBitmapImageRep, xFraction: CGFloat, yFraction: CGFloat) -> NSColor {
        image.colorAt(x: Int(CGFloat(image.pixelsWide - 1) * xFraction),
                      y: Int(CGFloat(image.pixelsHigh - 1) * yFraction))?.usingColorSpace(.sRGB) ?? .clear
    }

    private static func close(_ actual: NSColor, to expected: NSColor) -> Bool {
        guard let a = actual.usingColorSpace(.sRGB), let e = expected.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - e.redComponent)
            + abs(a.greenComponent - e.greenComponent)
            + abs(a.blueComponent - e.blueComponent) < 0.24
    }

    private static func fail(_ message: String) -> Never {
        fputs("WindowCaptureProtectionCompatibilityTests failed: \(message)\n", stderr)
        exit(1)
    }
}
