import CoreGraphics

/// The selected desktop region in global, bottom-up AppKit points. Keep this
/// separate from the estimated content position, which changes with page scroll.
struct StitchCaptureSource: Equatable {
    let screenRect: CGRect
    let scrollOffset: CGPoint

    static func fromPixels(screenFrame: CGRect, pixelRect: CGRect,
                           pixelsPerPoint: CGSize, scrollOffset: CGPoint) -> Self? {
        guard valid(screenFrame), valid(pixelRect),
              pixelsPerPoint.width.isFinite, pixelsPerPoint.width > 0,
              pixelsPerPoint.height.isFinite, pixelsPerPoint.height > 0,
              scrollOffset.x.isFinite, scrollOffset.y.isFinite else { return nil }
        let pixelBounds = CGRect(x: 0, y: 0,
            width: screenFrame.width * pixelsPerPoint.width,
            height: screenFrame.height * pixelsPerPoint.height)
        guard valid(pixelBounds) else { return nil }
        let pixels = pixelRect.intersection(pixelBounds)
        guard valid(pixels) else { return nil }
        let rect = CGRect(x: screenFrame.minX + pixels.minX / pixelsPerPoint.width,
                          y: screenFrame.maxY - pixels.maxY / pixelsPerPoint.height,
                          width: pixels.width / pixelsPerPoint.width,
                          height: pixels.height / pixelsPerPoint.height).intersection(screenFrame)
        guard valid(rect) else { return nil }
        return Self(screenRect: rect, scrollOffset: scrollOffset)
    }

    func estimatedPosition(referenceScale: CGFloat) -> CGPoint? {
        guard Self.valid(screenRect) else { return nil }
        return Self.estimatedPosition(screenTopLeft: CGPoint(x: screenRect.minX, y: screenRect.maxY),
                                      scrollOffset: scrollOffset, referenceScale: referenceScale)
    }

    /// A dimension recommendation also needs a position when a drag still has
    /// zero width or height. It does not yet represent a captured rectangle.
    static func estimatedPosition(screenTopLeft: CGPoint, scrollOffset: CGPoint,
                                  referenceScale: CGFloat) -> CGPoint? {
        guard screenTopLeft.x.isFinite, screenTopLeft.y.isFinite,
              referenceScale.isFinite, referenceScale > 0,
              scrollOffset.x.isFinite, scrollOffset.y.isFinite else { return nil }
        let x = (screenTopLeft.x + scrollOffset.x) * referenceScale
        let y = (-screenTopLeft.y + scrollOffset.y) * referenceScale
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite && rect.size.width > 0 && rect.size.height > 0
            && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
