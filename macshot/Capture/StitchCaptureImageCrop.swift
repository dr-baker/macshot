import CoreGraphics

/// Owns selected pixels without letting the resampling filter read outside the selection.
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
              outputWidth <= StitchDocument.maximumDimension, outputHeight <= StitchDocument.maximumDimension,
              outputWidth * outputHeight <= StitchDocument.maximumPixels else { return nil }
        let width = Int(outputWidth), height = Int(outputHeight)
        // A source pixel owns its unit cell. A partially selected boundary cell is
        // allowed; a cell with no positive overlap must never enter the filter.
        // These integer bounds only isolate storage. Output geometry still uses
        // the exact fractional rectangle, rather than its enclosing pixel cells.
        let owned = CGRect(x: clipped.minX.rounded(.down), y: clipped.minY.rounded(.down),
                           width: clipped.maxX.rounded(.up) - clipped.minX.rounded(.down),
                           height: clipped.maxY.rounded(.up) - clipped.minY.rounded(.down))
        let sourceWidth = Int(owned.width), sourceHeight = Int(owned.height)
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpaceCreateDeviceRGB()
        guard let selected = image.cropping(to: owned),
              let source = context(width: sourceWidth, height: sourceHeight, space: colorSpace),
              let sourceData = source.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Copy at 1:1 with no interpolation to sever the original screenshot's
        // backing storage before resampling. Both buffers contain premultiplied RGBA.
        source.interpolationQuality = .none
        source.setBlendMode(.copy)
        source.draw(selected, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        if clipped == owned, width == sourceWidth, height == sourceHeight { return source.makeImage() }
        guard let output = context(width: width, height: height, space: colorSpace),
              let outputData = output.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let columns = samples(start: clipped.minX - owned.minX, length: clipped.width,
                              sourceCount: sourceWidth, outputCount: width)
        let rows = samples(start: clipped.minY - owned.minY, length: clipped.height,
                           sourceCount: sourceHeight, outputCount: height)
        for y in 0..<height {
            for x in 0..<width {
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                for row in rows[y] {
                    for column in columns[x] {
                        let index = row.index * source.bytesPerRow + column.index * 4
                        let weight = row.weight * column.weight
                        red += CGFloat(sourceData[index]) * weight
                        green += CGFloat(sourceData[index + 1]) * weight
                        blue += CGFloat(sourceData[index + 2]) * weight
                        alpha += CGFloat(sourceData[index + 3]) * weight
                    }
                }
                let index = y * output.bytesPerRow + x * 4
                outputData[index] = UInt8(clamping: Int(red.rounded()))
                outputData[index + 1] = UInt8(clamping: Int(green.rounded()))
                outputData[index + 2] = UInt8(clamping: Int(blue.rounded()))
                outputData[index + 3] = UInt8(clamping: Int(alpha.rounded()))
            }
        }
        return output.makeImage()
    }

    private struct Sample {
        let index: Int
        let weight: CGFloat
    }

    /// Downsampling averages the selected footprint. Upsampling interpolates
    /// between pixel centers, clamping its support at the selected boundary cells.
    private static func samples(start: CGFloat, length: CGFloat, sourceCount: Int,
                                outputCount: Int) -> [[Sample]] {
        let step = length / CGFloat(outputCount)
        return (0..<outputCount).map { output in
            if step > 1 {
                let lower = start + CGFloat(output) * step
                let upper = min(start + length, start + CGFloat(output + 1) * step)
                return (max(0, Int(lower.rounded(.down)))..<min(sourceCount, Int(upper.rounded(.up))))
                    .compactMap { index in
                        let overlap = min(upper, CGFloat(index + 1)) - max(lower, CGFloat(index))
                        return overlap > 0 ? Sample(index: index, weight: overlap / (upper - lower)) : nil
                    }
            }
            let center = start + (CGFloat(output) + 0.5) * step - 0.5
            let lower = center.rounded(.down)
            let fraction = center - lower
            let first = max(0, min(sourceCount - 1, Int(lower)))
            let second = max(0, min(sourceCount - 1, Int(lower) + 1))
            if first == second || fraction == 0 { return [Sample(index: first, weight: 1)] }
            return [Sample(index: first, weight: 1 - fraction), Sample(index: second, weight: fraction)]
        }
    }

    private static func context(width: Int, height: Int, space: CGColorSpace) -> CGContext? {
        guard width > 0, height > 0,
              width <= Int(StitchDocument.maximumDimension), height <= Int(StitchDocument.maximumDimension),
              width <= Int(StitchDocument.maximumPixels) / height else { return nil }
        let rowBytes = width * 4
        guard !rowBytes.multipliedReportingOverflow(by: height).overflow else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: rowBytes, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
