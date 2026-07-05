import AppKit

enum WindowCaptureProtection {
    static func excludeFromScreenCapture(_ window: NSWindow) {
        window.sharingType = .none
    }
}
