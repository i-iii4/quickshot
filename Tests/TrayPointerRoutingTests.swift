import AppKit

@main
struct TrayPointerRoutingTests {
    static func main() {
        expect(trayHostIgnoresMouseEvents(isVisible: false,
                                          captureActive: false,
                                          dragActive: false,
                                          pointerOverContent: true),
               "hidden host must never capture the pointer")
        expect(trayHostIgnoresMouseEvents(isVisible: true,
                                          captureActive: true,
                                          dragActive: false,
                                          pointerOverContent: true),
               "capture presentation must keep the tray passive")
        expect(trayHostIgnoresMouseEvents(isVisible: true,
                                          captureActive: false,
                                          dragActive: false,
                                          pointerOverContent: false),
               "full-screen host blocked the desktop outside tray content")
        expect(!trayHostIgnoresMouseEvents(isVisible: true,
                                           captureActive: false,
                                           dragActive: false,
                                           pointerOverContent: true),
               "visible tray content must remain clickable")
        expect(trayHostIgnoresMouseEvents(isVisible: true,
                                          captureActive: false,
                                          dragActive: true,
                                          pointerOverContent: true),
               "active drag must make its full-screen source host pointer-transparent")
        expect(trayHostIgnoresMouseEvents(isVisible: true,
                                          captureActive: true,
                                          dragActive: true,
                                          pointerOverContent: false),
               "capture safety must take priority over a stale drag session")
        print("TrayPointerRoutingTests: passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) {
        guard condition() else {
            fputs("TrayPointerRoutingTests failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
