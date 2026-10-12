import CoreGraphics

/// Replicated border texels keep perspective filtering from sampling transparent
/// space outside the printed sheet. Actual transparent source pixels stay intact.
struct StitchPaperGuardedTexture {
    static let padding = 8
    let original: CGImage
    let image: CGImage

    init?(_ original: CGImage) {
        let width = original.width, height = original.height
        guard width > 0, height > 0, width <= 1600, height <= 1600,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let source = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let sourceData = source.data else { return nil }
        source.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        let padding = Self.padding
        let paddedWidth = width + padding * 2, paddedHeight = height + padding * 2
        guard let destination = CGContext(data: nil, width: paddedWidth, height: paddedHeight,
            bitsPerComponent: 8, bytesPerRow: paddedWidth * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let destinationData = destination.data else { return nil }
        let input = sourceData.assumingMemoryBound(to: UInt8.self)
        let output = destinationData.assumingMemoryBound(to: UInt8.self)
        for y in 0..<paddedHeight {
            let row = input.advanced(by: max(0, min(height - 1, y - padding)) * width * 4)
            let target = output.advanced(by: y * paddedWidth * 4)
            target.advanced(by: padding * 4).update(from: row, count: width * 4)
            for x in 0..<padding {
                for channel in 0..<4 {
                    target[x * 4 + channel] = row[channel]
                    target[(padding + width + x) * 4 + channel] = row[(width - 1) * 4 + channel]
                }
            }
        }
        guard let image = withExtendedLifetime(source, { destination.makeImage() }) else { return nil }
        self.original = original
        self.image = image
    }

    func contentsRect(for crop: CGRect) -> CGRect {
        let padding = CGFloat(Self.padding)
        return CGRect(x: (crop.minX + padding) / CGFloat(image.width),
            y: (crop.minY + padding) / CGFloat(image.height),
            width: crop.width / CGFloat(image.width), height: crop.height / CGFloat(image.height))
    }
}
