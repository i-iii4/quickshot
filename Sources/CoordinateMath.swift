import CoreGraphics

enum CoordinateMath {

    /// Converts an AppKit-global selection into the actual pixel coordinates of
    /// a captured display image. The image dimensions are authoritative: this
    /// also handles scaled and rotated displays where an assumed 1x/2x factor is
    /// not reliable.
    static func pixelCropRect(globalSelection selection: CGRect,
                              displayFrame: CGRect,
                              imageSize: CGSize) -> CGRect {
        guard displayFrame.width > 0, displayFrame.height > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            return .null
        }

        let clamped = selection.intersection(displayFrame)
        guard !clamped.isNull, !clamped.isEmpty else { return .null }

        let scaleX = imageSize.width / displayFrame.width
        let scaleY = imageSize.height / displayFrame.height
        let localMinX = clamped.minX - displayFrame.minX
        let localTopY = displayFrame.maxY - clamped.maxY

        let minX = floor(localMinX * scaleX)
        let minY = floor(localTopY * scaleY)
        let maxX = ceil((localMinX + clamped.width) * scaleX)
        let maxY = ceil((localTopY + clamped.height) * scaleY)
        return CGRect(x: minX,
                      y: minY,
                      width: max(1, maxX - minX),
                      height: max(1, maxY - minY))
    }

}
