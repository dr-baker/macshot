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
        guard case .automatic = document.background else {
            fillBackground(document, source: background, destination: background, bounds: bounds, scale: scale)
            return background.makeImage()
        }
        guard let source = bitmap(width: width, height: height) else { return nil }
        source.translateBy(x: 0, y: CGFloat(height))
        source.scaleBy(x: scale, y: -scale)
        source.translateBy(x: -bounds.minX, y: -bounds.minY)
        drawPieces(document.pieces, in: source)
        fillBackground(document, source: source, destination: background, bounds: bounds, scale: scale)
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

    private struct CoverageSlab {
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

    /// Extend the exact nearest covered pixel into every gap. For each output row, each
    /// slab supplies its nearest vertical source pixel. The nearest source in another slab
    /// must be on that slab's left/right edge, so only those endpoint parabolas enter the
    /// one-dimensional squared-distance envelope. Work is linear in gap pixels plus the
    /// number of slab endpoints per row; scratch storage depends only on piece count.
    private static func fillBackground(_ document: StitchDocument, source: CGContext,
                                       destination: CGContext, bounds: CGRect, scale: CGFloat) {
        if case .transparent = document.background { return }
        guard let inputData = source.data, let outputData = destination.data else { return }
        let width = source.width, height = source.height
        let input = inputData.assumingMemoryBound(to: UInt32.self)
        let output = outputData.assumingMemoryBound(to: UInt32.self)
        let slabs = coverage(document.pieces, bounds: bounds, scale: scale, width: width, height: height)
        guard !slabs.isEmpty else { return }
        var solid: UInt32?
        if case .color(let color) = document.background,
           let swatch = bitmap(width: 1, height: 1), let bytes = swatch.data {
            swatch.setFillColor(color.cgColor)
            swatch.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            solid = bytes.assumingMemoryBound(to: UInt32.self).pointee
        }
        var rowSeeds = [Int](repeating: -1, count: slabs.count)
        let capacity = slabs.count * 2
        var vertices = [Int](repeating: 0, count: capacity)
        var seedRows = [Int](repeating: 0, count: capacity)
        var costs = [Double](repeating: 0, count: capacity)
        var transitions = [Double](repeating: 0, count: capacity + 1)
        for y in 0..<height {
            var hasGap = false
            for index in slabs.indices {
                rowSeeds[index] = slabs[index].nearestRow(to: y) ?? -1
                if rowSeeds[index] != y { hasGap = true }
            }
            guard hasGap else { continue }
            var last = -1
            if solid == nil {
                for index in slabs.indices where rowSeeds[index] >= 0 {
                    let seedY = rowSeeds[index]
                    let dy = Double(y - seedY)
                    let cost = dy * dy
                    let slab = slabs[index]
                    for endpoint in 0..<(slab.columns.count == 1 ? 1 : 2) {
                        let x = endpoint == 0 ? slab.columns.lowerBound : slab.columns.upperBound - 1
                        var intersection = -Double.infinity
                        while last >= 0 {
                            let previous = vertices[last]
                            intersection = (cost + Double(x) * Double(x) - costs[last]
                                            - Double(previous) * Double(previous)) / Double(2 * (x - previous))
                            if intersection > transitions[last] { break }
                            last -= 1
                        }
                        last += 1
                        vertices[last] = x; seedRows[last] = seedY; costs[last] = cost
                        transitions[last] = last == 0 ? -.infinity : intersection
                        transitions[last + 1] = .infinity
                    }
                }
            }
            var segment = 0
            for index in slabs.indices where rowSeeds[index] != y {
                let columns = slabs[index].columns
                if let solid {
                    for x in columns { output[y * width + x] = solid }
                    continue
                }
                guard last >= 0 else { continue }
                let ownY = rowSeeds[index]
                let ownDistance = ownY >= 0 ? Double(y - ownY) * Double(y - ownY) : .infinity
                for x in columns {
                    while segment < last && transitions[segment + 1] < Double(x) { segment += 1 }
                    let dx = Double(x - vertices[segment])
                    if ownDistance <= dx * dx + costs[segment] {
                        output[y * width + x] = input[ownY * width + x]
                    } else {
                        output[y * width + x] = input[seedRows[segment] * width + vertices[segment]]
                    }
                }
            }
        }
    }

    static func render(_ document: StitchDocument, maximumPreviewDimension: CGFloat? = nil) -> CGImage? {
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
        fillBackground(document, source: base, destination: base, bounds: bounds, scale: scale)
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
