import AppKit
import Darwin

@main
struct StatusMenuLayoutTests {
    static func main() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let menu = NSSize(width: 280, height: 180)

        requireContained(button: NSRect(x: 1400, y: 870, width: 24, height: 24), menu: menu, screen: screen)
        requireContained(button: NSRect(x: 16, y: 870, width: 24, height: 24), menu: menu, screen: screen)
        requireContained(button: NSRect(x: 700, y: 200, width: 24, height: 24), menu: menu, screen: screen)

        let centeredButton = NSRect(x: 700, y: 870, width: 24, height: 24)
        let centered = StatusMenuLayout.origin(buttonFrame: centeredButton, menuSize: menu, visibleFrame: screen)
        require(abs(centered.x - (centeredButton.midX - menu.width / 2)) <= 0.001,
                "Centered menu should remain centered when it fits")

        print("StatusMenuLayoutTests: passed")
    }

    private static func requireContained(button: NSRect, menu: NSSize, screen: NSRect) {
        let origin = StatusMenuLayout.origin(buttonFrame: button, menuSize: menu, visibleFrame: screen)
        let frame = NSRect(origin: origin, size: menu)
        let allowed = screen.insetBy(dx: StatusMenuLayout.edgeInset, dy: StatusMenuLayout.edgeInset)
        require(allowed.contains(frame), "Menu escaped visible screen: \(frame) not in \(allowed)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("StatusMenuLayoutTests: \(message)\n", stderr)
            exit(1)
        }
    }
}
