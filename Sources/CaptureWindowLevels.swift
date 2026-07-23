import AppKit

enum CaptureWindowLevels {
    static let backdrop = NSWindow.Level.screenSaver
    static let protectedInterface = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    static let selectionChrome = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
}
