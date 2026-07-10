import AppKit

enum StatusMenuLayout {
    static let edgeInset: CGFloat = 8

    static func origin(buttonFrame: NSRect, menuSize: NSSize, visibleFrame: NSRect) -> NSPoint {
        let minX = visibleFrame.minX + edgeInset
        let maxX = max(minX, visibleFrame.maxX - edgeInset - menuSize.width)
        let desiredX = buttonFrame.midX - menuSize.width / 2
        let x = min(max(desiredX, minX), maxX)

        let minY = visibleFrame.minY + edgeInset
        let desiredY = buttonFrame.minY - menuSize.height - edgeInset
        let y = max(minY, desiredY)
        return NSPoint(x: x, y: y)
    }
}
