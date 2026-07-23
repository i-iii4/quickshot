import AppKit

@main
struct TrayPointerRoutingTests {
    static func main() {
        expect(trayHostIgnoresMouseEvents(isVisible: false,
                                          captureActive: false,
                                          pointerOverContent: true),
               "hidden host must never capture the pointer")
        expect(trayHostIgnoresMouseEvents(isVisible: true,
                                          captureActive: true,
                                          pointerOverContent: true),
               "capture presentation must keep the tray passive")
        expect(trayHostIgnoresMouseEvents(isVisible: true,
                                          captureActive: false,
                                          pointerOverContent: false),
               "full-screen host blocked the desktop outside tray content")
        expect(!trayHostIgnoresMouseEvents(isVisible: true,
                                           captureActive: false,
                                           pointerOverContent: true),
               "visible tray content must remain clickable")
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
