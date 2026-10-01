import CoreGraphics

/// Owns selected pixels without expanding fractional bounds to neighboring source pixels.
enum StitchCaptureImageCrop {
    /// `rect` uses top-left source pixels; `scale` converts those pixels to reference pixels.
    static func copy(image: CGImage, rect: CGRect, scale: CGFloat) -> CGImage? {
        guard scale.isFinite, scale > 0, !rect.isNull, !rect.isInfinite,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0 else { return nil }
        let sourceBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.intersection(sourceBounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let outputWidth = (clipped.width * scale).rounded()
        let outputHeight = (clipped.height * scale).rounded()
        guard outputWidth.isFinite, outputHeight.isFinite,
              outputWidth >= 1, outputHeight >= 1,
              outputWidth < CGFloat(Int.max / 4), outputHeight < CGFloat(Int.max) else { return nil }
        let width = Int(outputWidth), height = Int(outputHeight)
        let rowBytes = width * 4
        guard !rowBytes.multipliedReportingOverflow(by: height).overflow,
              let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CGContext is bottom-up. Place the exact source rectangle over the full
        // destination; independent rounded output dimensions avoid an extra edge pixel.
        context.scaleBy(x: CGFloat(width) / clipped.width, y: CGFloat(height) / clipped.height)
        context.translateBy(x: -clipped.minX, y: -(CGFloat(image.height) - clipped.maxY))
        context.interpolationQuality = .high
        context.draw(image, in: sourceBounds)
        return context.makeImage()
    }
}
