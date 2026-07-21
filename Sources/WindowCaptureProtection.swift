import AppKit

enum WindowCaptureProtection {
    @MainActor
    private static var externalWindowProviders: [() -> NSWindow?] = []

    static func excludeFromScreenCapture(_ window: NSWindow) {
        window.sharingType = .none
    }

    @MainActor
    static func registerExternalWindow(_ provider: @escaping () -> NSWindow?) {
        externalWindowProviders.append(provider)
    }

    @MainActor
    @discardableResult
    static func protectAllApplicationWindows() -> Int {
        let windows = allKnownWindows()
        windows.forEach { excludeFromScreenCapture($0) }
        return windows.count
    }

    @MainActor
    static func unprotectedOnScreenWindowNumbers() -> [CGWindowID]? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return unprotectedWindowNumbers(in: windowInfo, ownerPID: getpid())
    }

    static func unprotectedWindowNumbers(in windowInfo: [[String: Any]],
                                         ownerPID: pid_t) -> [CGWindowID] {
        windowInfo.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID else {
                return nil
            }
            let sharingState = (info[kCGWindowSharingState as String] as? NSNumber)?.intValue ?? -1
            guard sharingState != NSWindow.SharingType.none.rawValue else { return nil }
            return (info[kCGWindowNumber as String] as? NSNumber).map { CGWindowID($0.uint32Value) }
        }
    }

    @MainActor
    private static func allKnownWindows() -> [NSWindow] {
        var seen: Set<ObjectIdentifier> = []
        return (NSApp.windows + externalWindowProviders.compactMap { $0() }).filter { window in
            seen.insert(ObjectIdentifier(window)).inserted
        }
    }
}
