import AppKit
import CoreImage
import simd

/// One renderer for the workspace preview, clipboard, PNG, and handoff to the annotation editor.
enum StitchRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func path(for join: StitchJoin, style: StitchStyle) -> CGPath {
        let path = CGMutablePath()
        let length = join.end - join.start
        let steps = max(2, Int(ceil(length / 2)))
        for i in 0...steps {
            let along = join.start + length * CGFloat(i) / CGFloat(steps)
            let envelope = min(1, min(along - join.start, join.end - along) / 12)
            let wave = sin((along - join.start) * .pi * 2 / 28) * style.wave * envelope
            let point = join.axis == .horizontal
                ? CGPoint(x: along, y: join.position + wave)
                : CGPoint(x: join.position + wave, y: along)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// `feather` is the total band width. Distance is perpendicular to the sampled path,
    /// so the same symmetric fade follows horizontal, vertical, and curved joins.
    private static func blurMask(joins: [StitchJoin], style: StitchStyle, bounds: CGRect,
                                 scale: CGFloat, width: Int, height: Int) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: width * height)
        let radius = style.feather * scale / 2
        guard radius > 0 else { return mask }
        // A squared-distance lookup avoids a square root and cosine per pixel.
        // Its quantization is below one alpha level in the final 8-bit mask.
        let tableSize = 4096
        let fades = (0...tableSize).map { index in
            pow(cos(sqrt(CGFloat(index) / CGFloat(tableSize)) * .pi / 2), 2) * 255
        }
        let distanceToIndex = CGFloat(tableSize) / (radius * radius)
        for join in joins {
            var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                              tx: -bounds.minX * scale, ty: -bounds.minY * scale)
            guard let scaledPath = path(for: join, style: style).copy(using: &transform) else { continue }
            let band = scaledPath.boundingBoxOfPath.insetBy(dx: -radius - 1, dy: -radius - 1)
                .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !band.isNull, band.width > 0, band.height > 0 else { continue }
            let bandWidth = Int(band.width), bandHeight = Int(band.height)
            var points: [CGPoint] = []
            scaledPath.applyWithBlock { element in
                if element.pointee.type == .moveToPoint || element.pointee.type == .addLineToPoint {
                    points.append(element.pointee.points[0])
                }
            }
            // Keep squared distances in a bounded strip and update four pixels at a time.
            // The fade lookup runs once per affected pixel, never once per segment.
            var distances = [Float](repeating: Float(radius * radius), count: bandWidth * bandHeight)
            for index in 1..<points.count {
                let a = points[index - 1], b = points[index]
                let dx = Float(b.x - a.x), dy = Float(b.y - a.y)
                let inverseLength = 1 / (dx * dx + dy * dy)
                let minX = max(0, Int(floor(min(a.x, b.x) - radius - band.minX)))
                let maxX = min(bandWidth - 1, Int(ceil(max(a.x, b.x) + radius - band.minX)))
                let minY = max(0, Int(floor(min(a.y, b.y) - radius - band.minY)))
                let maxY = min(bandHeight - 1, Int(ceil(max(a.y, b.y) + radius - band.minY)))
                guard minX <= maxX, minY <= maxY else { continue }
                distances.withUnsafeMutableBufferPointer { buffer in
                    for y in minY...maxY {
                        let py = Float(band.minY + CGFloat(y) + 0.5 - a.y)
                        let row = y * bandWidth
                        let startX = Float(band.minX + CGFloat(minX) + 0.5 - a.x)
                        var x = minX
                        while x + 3 <= maxX {
                            let px = SIMD4<Float>(repeating: startX + Float(x - minX)) + SIMD4<Float>(0, 1, 2, 3)
                            let t = simd_clamp((px * dx + SIMD4<Float>(repeating: py * dy)) * inverseLength,
                                               SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 1))
                            let nx = px - t * dx, ny = SIMD4<Float>(repeating: py) - t * dy
                            let squared = nx * nx + ny * ny
                            let offset = row + x
                            let existing = SIMD4<Float>(buffer[offset], buffer[offset + 1], buffer[offset + 2], buffer[offset + 3])
                            let closest = simd_min(existing, squared)
                            buffer[offset] = closest.x; buffer[offset + 1] = closest.y
                            buffer[offset + 2] = closest.z; buffer[offset + 3] = closest.w
                            x += 4
                        }
                        while x <= maxX {
                            let px = startX + Float(x - minX)
                            let t = max(0, min(1, (px * dx + py * dy) * inverseLength))
                            let nx = px - t * dx, ny = py - t * dy
                            buffer[row + x] = min(buffer[row + x], nx * nx + ny * ny)
                            x += 1
                        }
                    }
                }
            }
            let length = (join.end - join.start) * scale
            let endpointFade = min(radius, length / 4)
            let horizontal = join.axis == .horizontal
            let tapers = (0..<(horizontal ? bandWidth : bandHeight)).map { index -> CGFloat in
                let along = (horizontal ? band.minX : band.minY) + CGFloat(index) + 0.5
                    - (join.start - (horizontal ? bounds.minX : bounds.minY)) * scale
                let endpoint = min(1, max(0, min(along, length - along) / endpointFade))
                return endpoint * endpoint * (3 - 2 * endpoint)
            }
            for y in 0..<bandHeight {
                for x in 0..<bandWidth {
                    let distanceSquared = CGFloat(distances[y * bandWidth + x])
                    guard distanceSquared < radius * radius else { continue }
                    let fade = fades[min(tableSize, Int((distanceSquared * distanceToIndex).rounded()))]
                    let taper = tapers[horizontal ? x : y]
                    let offset = (Int(band.minY) + y) * width + Int(band.minX) + x
                    mask[offset] = max(mask[offset], UInt8((fade * taper).rounded()))
                }
            }
        }
        return mask
    }

    static func render(_ document: StitchDocument, maximumPreviewDimension: CGFloat? = nil) -> CGImage? {
        guard document.canRender else { return nil }
        let bounds = document.bounds.integral
        let scale = maximumPreviewDimension.map { min(1, $0 / max(bounds.width, bounds.height)) } ?? 1
        let width = max(1, Int(ceil(bounds.width * scale))), height = max(1, Int(ceil(bounds.height * scale)))
        func makeContext() -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        func applyCoordinates(_ ctx: CGContext) {
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        }
        guard let base = makeContext() else { return nil }
        applyCoordinates(base)
        for piece in document.pieces {
            guard let image = piece.image.cropping(to: piece.source) else { continue }
            base.saveGState()
            base.translateBy(x: piece.origin.x, y: piece.origin.y + piece.frame.height)
            base.scaleBy(x: 1, y: -1)
            base.draw(image, in: CGRect(origin: .zero, size: piece.frame.size))
            base.restoreGState()
        }
        guard let original = base.makeImage() else { return nil }
        let style = document.style
        let joins = document.joins
        guard style.visible && !joins.isEmpty else { return original }
        guard let final = makeContext() else { return original }
        final.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        if style.blur > 0 && style.feather > 0,
           let blurredPixels = makeContext(), let destination = final.data {
            let source = CIImage(cgImage: original)
            let blurred = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: style.blur * scale
            ]).cropped(to: source.extent)
            if let image = context.createCGImage(blurred, from: source.extent), let pixels = blurredPixels.data {
                blurredPixels.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                let mask = blurMask(joins: joins, style: style, bounds: bounds, scale: scale,
                                    width: width, height: height)
                let output = destination.assumingMemoryBound(to: UInt8.self)
                let softened = pixels.assumingMemoryBound(to: UInt8.self)
                // Composite only inside the band. Pixels outside it remain byte-for-byte intact.
                for index in mask.indices where mask[index] > 0 {
                    let weight = Int(mask[index])
                    for channel in 0..<4 {
                        let offset = index * 4 + channel
                        output[offset] = UInt8((Int(output[offset]) * (255 - weight)
                                               + Int(softened[offset]) * weight + 127) / 255)
                    }
                }
            }
        }
        applyCoordinates(final)
        final.setLineCap(.round)
        final.setLineJoin(.round)
        final.setStrokeColor(style.color.cgColor)
        final.setLineWidth(style.lineWidth)
        for join in joins where style.lineWidth > 0 {
            final.addPath(path(for: join, style: style))
            final.strokePath()
        }
        return final.makeImage()
    }
}
