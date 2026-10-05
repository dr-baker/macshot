import AppKit
import CoreImage
import simd

/// One renderer for the workspace preview, clipboard, PNG, and handoff to the annotation editor.
enum StitchRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func path(for join: StitchJoin, style: StitchStyle) -> CGPath {
        StitchSeamDrawing.path(for: join, style: style)
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

    /// Full-canvas image containing only the uncovered background. Covered rectangles stay
    /// transparent, allowing the canvas to draw unchanged source pieces over this layer.
    static func renderBackground(_ document: StitchDocument,
                                 maximumPreviewDimension: CGFloat? = nil) -> CGImage? {
        guard document.canRender else { return nil }
        let bounds = document.bounds.integral
        let requested = maximumPreviewDimension ?? max(bounds.width, bounds.height)
        guard requested.isFinite, requested > 0 else { return nil }
        let scale = min(1, requested / max(bounds.width, bounds.height))
        let width = max(1, Int(ceil(bounds.width * scale)))
        let height = max(1, Int(ceil(bounds.height * scale)))
        guard let background = bitmap(width: width, height: height) else { return nil }
        fillBackground(document, destination: background, bounds: bounds, scale: scale)
        return background.makeImage()
    }

    private static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func drawPieces(_ pieces: [StitchPiece], in context: CGContext) {
        for piece in pieces {
            guard let image = piece.image.cropping(to: piece.source) else { continue }
            context.saveGState()
            context.translateBy(x: piece.origin.x, y: piece.origin.y + piece.frame.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: piece.frame.size))
            context.restoreGState()
        }
    }

    struct CoverageSlab {
        let columns: Range<Int>
        let rows: [Range<Int>]

        func nearestRow(to y: Int) -> Int? {
            guard !rows.isEmpty else { return nil }
            var low = 0, high = rows.count
            while low < high {
                let middle = (low + high) / 2
                if rows[middle].lowerBound <= y { low = middle + 1 } else { high = middle }
            }
            if low > 0 {
                let before = rows[low - 1]
                if before.contains(y) { return y }
                let candidate = before.upperBound - 1
                if low == rows.count || y - candidate <= rows[low].lowerBound - y { return candidate }
            }
            return rows[low].lowerBound
        }
    }

    /// Rectangles change coverage only at their x edges. Within each slab, the union of
    /// covered y intervals is constant. This avoids a canvas-sized occupancy/distance map.
    private static func coverage(_ pieces: [StitchPiece], bounds: CGRect, scale: CGFloat,
                                 width: Int, height: Int) -> [CoverageSlab] {
        var rectangles: [(x: Range<Int>, y: Range<Int>)] = []
        var edges: Set<Int> = [0, width]
        for piece in pieces {
            let f = piece.frame
            let x0 = max(0, min(width, Int(floor((f.minX - bounds.minX) * scale))))
            let x1 = max(0, min(width, Int(ceil((f.maxX - bounds.minX) * scale))))
            let y0 = max(0, min(height, Int(floor((f.minY - bounds.minY) * scale))))
            let y1 = max(0, min(height, Int(ceil((f.maxY - bounds.minY) * scale))))
            guard x0 < x1, y0 < y1 else { continue }
            rectangles.append((x0..<x1, y0..<y1))
            edges.insert(x0); edges.insert(x1)
        }
        let xs = edges.sorted()
        return zip(xs, xs.dropFirst()).map { start, end in
            let intervals = rectangles.filter { $0.x.lowerBound <= start && $0.x.upperBound >= end }
                .map(\.y).sorted { $0.lowerBound < $1.lowerBound }
            var union: [Range<Int>] = []
            for interval in intervals {
                if let previous = union.last, interval.lowerBound <= previous.upperBound {
                    union[union.count - 1] = previous.lowerBound..<max(previous.upperBound, interval.upperBound)
                } else { union.append(interval) }
            }
            return CoverageSlab(columns: start..<end, rows: union)
        }
    }

    private struct BackgroundSample {
        let point: CGPoint
        let color: SIMD4<Double>
    }

    /// Broad source-space neighborhoods reject sparse text, borders, and icons. Sampling
    /// original crops keeps the color estimate independent of preview resolution.
    private static func backgroundSamples(_ pieces: [StitchPiece]) -> [BackgroundSample] {
        var samples: [BackgroundSample] = []
        for piece in pieces {
            let size = piece.source.size
            let nx = max(1, min(16, Int(ceil(size.width / 128))))
            let ny = max(1, min(16, Int(ceil(size.height / 128))))
            var points: [CGPoint] = []
            for x in 0...nx {
                let px = size.width * CGFloat(x) / CGFloat(nx)
                points.append(CGPoint(x: px, y: 0))
                points.append(CGPoint(x: px, y: size.height))
            }
            for y in 1..<ny {
                let py = size.height * CGFloat(y) / CGFloat(ny)
                points.append(CGPoint(x: 0, y: py))
                points.append(CGPoint(x: size.width, y: py))
            }
            for point in points {
                let w = min(128, size.width), h = min(128, size.height)
                let patch = CGRect(x: piece.source.minX + max(0, min(size.width - w, point.x - w / 2)),
                                   y: piece.source.minY + max(0, min(size.height - h, point.y - h / 2)),
                                   width: w, height: h).integral.intersection(piece.source)
                guard let crop = piece.image.cropping(to: patch),
                      let swatch = bitmap(width: crop.width, height: crop.height),
                      let data = swatch.data else { continue }
                swatch.interpolationQuality = .none
                swatch.draw(crop, in: CGRect(x: 0, y: 0, width: swatch.width, height: swatch.height))
                let pixels = data.assumingMemoryBound(to: UInt8.self)
                // Quantize premultiplied RGBA, retaining source transparency in the fill.
                var bins: [Int: (count: Int, sum: SIMD4<Double>)] = [:]
                for i in 0..<(swatch.width * swatch.height) {
                    let c = SIMD4<Double>(Double(pixels[i * 4]), Double(pixels[i * 4 + 1]),
                                          Double(pixels[i * 4 + 2]), Double(pixels[i * 4 + 3]))
                    let key = (Int(c.x) >> 5) | ((Int(c.y) >> 5) << 3)
                        | ((Int(c.z) >> 5) << 6) | ((Int(c.w) >> 5) << 9)
                    let old = bins[key] ?? (0, .zero)
                    bins[key] = (old.count + 1, old.sum + c)
                }
                // Stable tie breaking also makes noisy/photographic sources deterministic.
                guard let winner = bins.keys.max(by: {
                    let a = bins[$0]!.count, b = bins[$1]!.count
                    return a == b ? $0 > $1 : a < b
                }), let bin = bins[winner] else { continue }
                samples.append(BackgroundSample(point: CGPoint(x: piece.origin.x + point.x,
                                                               y: piece.origin.y + point.y),
                                                color: bin.sum / Double(bin.count)))
            }
        }
        return samples
    }

    /// Interpolate a bounded, low-frequency field of dominant neighboring colors. A coarse
    /// field deliberately cannot reproduce a text baseline or a one-pixel border as a stripe.
    /// Only uncovered pixels are written; captured pixels (including alpha) stay untouched.
    private static func fillBackground(_ document: StitchDocument, destination: CGContext, bounds: CGRect, scale: CGFloat) {
        if case .transparent = document.background { return }
        guard let outputData = destination.data else { return }
        let width = destination.width, height = destination.height
        let output = outputData.assumingMemoryBound(to: UInt32.self)
        let slabs = coverage(document.pieces, bounds: bounds, scale: scale, width: width, height: height)
        guard slabs.contains(where: { $0.rows != [0..<height] }) else { return }
        var solid: UInt32?
        if case .color(let color) = document.background,
           let swatch = bitmap(width: 1, height: 1), let bytes = swatch.data {
            swatch.setFillColor(color.cgColor)
            swatch.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            solid = bytes.assumingMemoryBound(to: UInt32.self).pointee
        }
        let columns = max(2, min(65, Int(ceil(bounds.width / 64)) + 1))
        let rows = max(2, min(65, Int(ceil(bounds.height / 64)) + 1))
        var field = [SIMD4<Double>](repeating: .zero, count: columns * rows)
        if solid == nil {
            let samples = backgroundSamples(document.pieces)
            guard !samples.isEmpty else { return }
            for y in 0..<rows {
                for x in 0..<columns {
                    let px = Double(bounds.minX + bounds.width * CGFloat(x) / CGFloat(columns - 1))
                    let py = Double(bounds.minY + bounds.height * CGFloat(y) / CGFloat(rows - 1))
                    var sum = SIMD4<Double>.zero, weight = 0.0
                    for sample in samples {
                        let dx = px - Double(sample.point.x), dy = py - Double(sample.point.y)
                        let distance = dx * dx + dy * dy + 4096
                        let w = 1 / (distance * distance)
                        sum += sample.color * w; weight += w
                    }
                    field[y * columns + x] = sum / weight
                }
            }
        }
        for y in 0..<height {
            let fy = min(Double(rows - 1), (Double(y) + 0.5) / Double(scale * bounds.height) * Double(rows - 1))
            let iy = min(rows - 2, Int(fy)), ty = fy - Double(iy)
            for slab in slabs where slab.nearestRow(to: y) != y {
                for x in slab.columns {
                    if let solid { output[y * width + x] = solid; continue }
                    let fx = min(Double(columns - 1), (Double(x) + 0.5) / Double(scale * bounds.width) * Double(columns - 1))
                    let ix = min(columns - 2, Int(fx)), tx = fx - Double(ix)
                    let top = field[iy * columns + ix] * (1 - tx) + field[iy * columns + ix + 1] * tx
                    let bottom = field[(iy + 1) * columns + ix] * (1 - tx) + field[(iy + 1) * columns + ix + 1] * tx
                    let color = top * (1 - ty) + bottom * ty
                    let r = UInt32(max(0, min(255, color.x.rounded())))
                    let g = UInt32(max(0, min(255, color.y.rounded())))
                    let b = UInt32(max(0, min(255, color.z.rounded())))
                    let a = UInt32(max(0, min(255, color.w.rounded())))
                    output[y * width + x] = r | (g << 8) | (b << 16) | (a << 24)
                }
            }
        }
    }

    static func render(_ document: StitchDocument, maximumPreviewDimension: CGFloat? = nil,
                       protectedRegions: [CGRect] = []) -> CGImage? {
        guard document.canRender else { return nil }
        let bounds = document.bounds.integral
        if let dimension = maximumPreviewDimension, (!dimension.isFinite || dimension <= 0) { return nil }
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
        drawPieces(document.pieces, in: base)
        fillBackground(document, destination: base, bounds: bounds, scale: scale)
        guard let original = base.makeImage() else { return nil }
        let style = document.style
        let joins = document.joins
        guard style.visible && !joins.isEmpty else { return original }
        guard let final = makeContext() else { return original }
        final.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
        if style.transition.usesBlur && style.blur > 0 && style.feather > 0,
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
                // Keep the seam on captured content. Blur must not paint into missing
                // canvas beside a short join, even when its fade band is wider than a piece.
                let slabs = coverage(document.pieces, bounds: bounds, scale: scale, width: width, height: height)
                for slab in slabs {
                    for rows in slab.rows {
                        for y in rows {
                            for x in slab.columns {
                                let index = y * width + x
                                guard mask[index] > 0 else { continue }
                                let weight = Int(mask[index])
                                for channel in 0..<4 {
                                    let offset = index * 4 + channel
                                    output[offset] = UInt8((Int(output[offset]) * (255 - weight)
                                                           + Int(softened[offset]) * weight + 127) / 255)
                                }
                            }
                        }
                    }
                }
            }
        }
        let usesPaper = (style.transition == .torn && style.tearWidth > 0)
            || (style.transition == .fold && style.foldDepth > 0 && style.foldStrength > 0)
        if usesPaper && style.transition == .fold {
            StitchFoldWarp.apply(joins: joins, style: style, source: base, destination: final,
                bounds: bounds, scale: scale, protectedRegions: protectedRegions,
                coverage: coverage(document.pieces, bounds: bounds, scale: scale, width: width, height: height))
        }
        if usesPaper && style.transition == .torn {
            // Source alpha prevents paper, fibers, and shadows from inventing
            // pixels in transparent parts of an otherwise covered rectangle.
            // Use actual raster dimensions so rounded previews align exactly.
            final.clip(to: CGRect(x: 0, y: 0, width: width, height: height), mask: original)
        }
        applyCoordinates(final)
        final.beginPath()
        final.addRects(document.pieces.map(\.frame))
        final.clip()
        let palettes = usesPaper ? document.paperPaletteCache.snapshot(for: joins, pieces: document.pieces).palettes : []
        for (index, join) in joins.enumerated() {
            let paper = usesPaper ? palettes[index] : .neutral
            StitchSeamDrawing.draw(join, style: style, paper: paper, in: final)
        }
        return final.makeImage()
    }
}
