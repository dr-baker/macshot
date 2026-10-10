import CoreGraphics
import Foundation

/// Samples only the already-composited flat screenshot. Source captures and
/// removed pixels are never available to this renderer.
nonisolated enum StitchAccordionWarp {
    nonisolated struct PaperColor: Sendable {
        /// Premultiplied sRGB components in 0...1, matching the raster renderer.
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        var cgColor: CGColor {
            CGColor(srgbRed: alpha > 0 ? red / alpha : 0,
                    green: alpha > 0 ? green / alpha : 0,
                    blue: alpha > 0 ? blue / alpha : 0, alpha: alpha)
        }
    }

    /// Shared by the layer preview and the native renderer. Only a small window
    /// around a seam in the composited image is rasterized, never the source captures.
    static func paperColor(image: CGImage, sample: CGPoint, documentBounds: CGRect) -> PaperColor? {
        guard let window = sampleWindow(sample: sample, bounds: documentBounds,
                                        width: image.width, height: image.height),
              let crop = image.cropping(to: CGRect(x: window.x, y: window.y,
                                                  width: window.width, height: window.height)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: window.width, height: window.height,
                  bitsPerComponent: 8, bytesPerRow: window.width * 4, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        // CGImage cropping uses pixel rows. Translating the full image in a
        // small Quartz context would sample its mirrored vertical window.
        context.draw(crop, in: CGRect(x: 0, y: 0, width: window.width, height: window.height))
        return dominantColor(data.assumingMemoryBound(to: UInt8.self), width: window.width,
                             window: SampleWindow(x: 0, y: 0, width: window.width, height: window.height))
    }

    static func render(_ image: CGImage, projection: StitchAccordionProjection) -> CGImage? {
        guard projection.hasProjectedOutput else { return image }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 30_000, height <= 30_000,
              width * height <= 100_000_000,
              let dimensions = projection.outputPixelDimensions(pixelWidth: width, pixelHeight: height),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let source = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let destination = CGContext(data: nil, width: dimensions.width, height: dimensions.height, bitsPerComponent: 8,
                  bytesPerRow: dimensions.width * 4, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let sourceData = source.data, let destinationData = destination.data else { return nil }
        source.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let input = sourceData.assumingMemoryBound(to: UInt8.self)
        let output = destinationData.assumingMemoryBound(to: UInt8.self)
        let bounds = projection.documentBounds
        let outputBounds = projection.outputBounds
        let outputWidth = dimensions.width, outputHeight = dimensions.height
        let scaleX = CGFloat(width) / bounds.width, scaleY = CGFloat(height) / bounds.height
        var colors: [SampleWindow: PaperColor] = [:]
        let rasterFaces = projection.faces.compactMap { face -> RasterFace? in
            guard face.isFrontFacing || face.paperSample != nil else { return nil }
            let paperColor: PaperColor?
            if let sample = face.paperSample {
                guard let window = sampleWindow(sample: sample, bounds: bounds, width: width, height: height) else { return nil }
                if let existing = colors[window] { paperColor = existing }
                else {
                    let color = dominantColor(input, width: width, window: window)
                    colors[window] = color; paperColor = color
                }
            } else { paperColor = nil }
            let a = CGPoint(x: (face.a.projected.x - outputBounds.minX) * scaleX,
                            y: (face.a.projected.y - outputBounds.minY) * scaleY)
            let b = CGPoint(x: (face.b.projected.x - outputBounds.minX) * scaleX,
                            y: (face.b.projected.y - outputBounds.minY) * scaleY)
            let c = CGPoint(x: (face.c.projected.x - outputBounds.minX) * scaleX,
                            y: (face.c.projected.y - outputBounds.minY) * scaleY)
            let denominator = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
            guard denominator.isFinite, abs(denominator) > 0.000000001 else { return nil }
            let x0 = max(0, Int(floor(min(a.x, b.x, c.x) - 0.5)))
            let x1 = min(outputWidth - 1, Int(ceil(max(a.x, b.x, c.x) + 0.5)))
            let y0 = max(0, Int(floor(min(a.y, b.y, c.y) - 0.5)))
            let y1 = min(outputHeight - 1, Int(ceil(max(a.y, b.y, c.y) + 0.5)))
            guard x1 >= x0, y1 >= y0 else { return nil }
            return RasterFace(face: face, paperColor: paperColor, a: a, b: b, c: c, denominator: denominator,
                              edgeA: abs(denominator) / hypot(b.x - c.x, b.y - c.y),
                              edgeB: abs(denominator) / hypot(c.x - a.x, c.y - a.y),
                              edgeC: abs(denominator) / hypot(a.x - b.x, a.y - b.y),
                              x0: x0, x1: x1, y0: y0, y1: y1)
        }
        guard !rasterFaces.isEmpty else { return nil }
        let enteringOrder = rasterFaces.indices.sorted {
            rasterFaces[$0].y0 != rasterFaces[$1].y0
                ? rasterFaces[$0].y0 < rasterFaces[$1].y0 : $0 < $1
        }
        var nextFace = 0, activeFaces: [Int] = []
        // Resolve occlusion with a single scanline of depth, rather than a second
        // full-canvas image or a canvas allocation for every folded face.
        var nearestDepth = [CGFloat](repeating: .infinity, count: outputWidth)
        for y in 0..<outputHeight {
            for x in 0..<outputWidth { nearestDepth[x] = .infinity }
            activeFaces.removeAll { rasterFaces[$0].y1 < y }
            while nextFace < enteringOrder.count, rasterFaces[enteringOrder[nextFace]].y0 <= y {
                activeFaces.append(enteringOrder[nextFace])
                nextFace += 1
            }
            for index in activeFaces {
                let triangle = rasterFaces[index]
                let face = triangle.face
                for x in triangle.x0...triangle.x1 {
                    let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    let weights = triangle.weights(point)
                    guard triangle.containsInterior(weights),
                          let coverage = triangle.coverage(at: point, center: weights), coverage > 0 else { continue }
                    let wa = weights.x / face.a.depth, wb = weights.y / face.b.depth, wc = weights.z / face.c.depth
                    let total = wa + wb + wc
                    guard total > 0 else { continue }
                    let depth = 1 / total
                    guard depth < nearestDepth[x] - 0.000000001 else { continue }
                    if let color = triangle.paperColor {
                        let alpha = color.alpha * 255 * coverage
                        let offset = (y * outputWidth + x) * 4
                        let light = 255 * face.shade * coverage
                        output[offset] = UInt8(max(0, min(alpha, color.red * light)).rounded())
                        output[offset + 1] = UInt8(max(0, min(alpha, color.green * light)).rounded())
                        output[offset + 2] = UInt8(max(0, min(alpha, color.blue * light)).rounded())
                        output[offset + 3] = UInt8(max(0, min(255, alpha)).rounded())
                        nearestDepth[x] = depth
                        continue
                    }
                    let sourceX = ((wa * face.a.source.x + wb * face.b.source.x + wc * face.c.source.x) / total - bounds.minX) * scaleX - 0.5
                    let sourceY = ((wa * face.a.source.y + wb * face.b.source.y + wc * face.c.source.y) / total - bounds.minY) * scaleY - 0.5
                    let sx = max(0, min(CGFloat(width - 1), sourceX)), sy = max(0, min(CGFloat(height - 1), sourceY))
                    let left = Int(floor(sx)), top = Int(floor(sy))
                    let right = min(width - 1, left + 1), bottom = min(height - 1, top + 1)
                    let fx = sx - CGFloat(left), fy = sy - CGFloat(top)
                    let p00 = (top * width + left) * 4, p10 = (top * width + right) * 4
                    let p01 = (bottom * width + left) * 4, p11 = (bottom * width + right) * 4
                    let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy), w01 = (1 - fx) * fy, w11 = fx * fy
                    func sampled(_ channel: Int) -> CGFloat {
                        CGFloat(input[p00 + channel]) * w00 + CGFloat(input[p10 + channel]) * w10
                            + CGFloat(input[p01 + channel]) * w01 + CGFloat(input[p11 + channel]) * w11
                    }
                    let alpha = sampled(3) * coverage
                    let offset = (y * outputWidth + x) * 4
                    for channel in 0..<3 {
                        // Keep premultiplied colors valid even on white or translucent paper.
                        output[offset + channel] = UInt8(max(0, min(alpha, sampled(channel) * face.shade * coverage)).rounded())
                    }
                    output[offset + 3] = UInt8(max(0, min(255, alpha)).rounded())
                    nearestDepth[x] = depth
                }
            }
        }
        return destination.makeImage()
    }

    private nonisolated struct SampleWindow: Hashable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private static func sampleWindow(sample: CGPoint, bounds: CGRect, width: Int, height: Int) -> SampleWindow? {
        guard sample.x.isFinite, sample.y.isFinite, bounds.minX.isFinite, bounds.minY.isFinite,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
              width > 0, height > 0, width <= 30_000, height <= 30_000 else { return nil }
        let sx = CGFloat(width) / bounds.width, sy = CGFloat(height) / bounds.height
        let px = (sample.x - bounds.minX) * sx, py = (sample.y - bounds.minY) * sy
        guard px.isFinite, py.isFinite else { return nil }
        let x = Int(max(0, min(CGFloat(width - 1), px))), y = Int(max(0, min(CGFloat(height - 1), py)))
        let rx = Int(max(2, min(96, ceil(24 * sx)))), ry = Int(max(2, min(96, ceil(24 * sy))))
        let x0 = max(0, x - rx), y0 = max(0, y - ry)
        return SampleWindow(x: x0, y: y0, width: min(width, x + rx) - x0, height: min(height, y + ry) - y0)
    }

    private nonisolated struct ColorBucket {
        var count = 0
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
    }

    /// A bounded local mode estimator rejects contrasting text and borders.
    /// Alpha participates in the mode, so empty canvas stays transparent.
    private static func dominantColor(_ pixels: UnsafePointer<UInt8>, width: Int, window: SampleWindow) -> PaperColor {
        var buckets: [UInt32: ColorBucket] = [:]
        let nx = min(25, window.width), ny = min(25, window.height)
        for row in 0..<ny {
            let y = window.y + min(window.height - 1, Int((CGFloat(row) + 0.5) * CGFloat(window.height) / CGFloat(ny)))
            for column in 0..<nx {
                let x = window.x + min(window.width - 1, Int((CGFloat(column) + 0.5) * CGFloat(window.width) / CGFloat(nx)))
                let offset = (y * width + x) * 4
                let alpha = CGFloat(pixels[offset + 3])
                func quantized(_ value: UInt8) -> UInt32 {
                    UInt32(alpha > 0 ? min(255, CGFloat(value) * 255 / alpha) / 16 : 0)
                }
                let key = quantized(pixels[offset]) << 12 | quantized(pixels[offset + 1]) << 8
                    | quantized(pixels[offset + 2]) << 4 | UInt32(pixels[offset + 3] / 16)
                var bucket = buckets[key, default: ColorBucket()]
                bucket.count += 1
                bucket.red += CGFloat(pixels[offset]); bucket.green += CGFloat(pixels[offset + 1])
                bucket.blue += CGFloat(pixels[offset + 2]); bucket.alpha += alpha
                buckets[key] = bucket
            }
        }
        let selected = buckets.sorted { $0.key < $1.key }.max { $0.value.count < $1.value.count }!.value
        let divisor = CGFloat(selected.count) * 255
        return PaperColor(red: selected.red / divisor, green: selected.green / divisor,
                          blue: selected.blue / divisor, alpha: selected.alpha / divisor)
    }

    private nonisolated struct RasterFace {
        let face: StitchAccordionProjection.Face
        let paperColor: PaperColor?
        let a: CGPoint
        let b: CGPoint
        let c: CGPoint
        let denominator: CGFloat
        let edgeA: CGFloat
        let edgeB: CGFloat
        let edgeC: CGFloat
        let x0: Int
        let x1: Int
        let y0: Int
        let y1: Int

        func weights(_ point: CGPoint) -> StitchAccordionProjection.Weights {
            let wa = ((b.y - c.y) * (point.x - c.x) + (c.x - b.x) * (point.y - c.y)) / denominator
            let wb = ((c.y - a.y) * (point.x - c.x) + (a.x - c.x) * (point.y - c.y)) / denominator
            return .init(x: wa, y: wb, z: 1 - wa - wb)
        }

        /// Shared internal edges are sampled once at the pixel center. Antialiasing
        /// those edges independently would leave translucent lines between faces.
        func containsInterior(_ weights: StitchAccordionProjection.Weights) -> Bool {
            (face.boundaryEdges & 1 != 0 || weights.x >= -0.000000001)
                && (face.boundaryEdges & 2 != 0 || weights.y >= -0.000000001)
                && (face.boundaryEdges & 4 != 0 || weights.z >= -0.000000001)
        }

        func coverage(at point: CGPoint, center: StitchAccordionProjection.Weights) -> CGFloat? {
            guard face.boundaryEdges != 0 else {
                return min(center.x, center.y, center.z) >= -0.000000001 ? 1 : nil
            }
            // Fully interior pixels do not need subpixel work.
            if (face.boundaryEdges & 1 == 0 || center.x * edgeA >= 0.71)
                && (face.boundaryEdges & 2 == 0 || center.y * edgeB >= 0.71)
                && (face.boundaryEdges & 4 == 0 || center.z * edgeC >= 0.71) { return 1 }
            var covered = 0
            for dy in [CGFloat(-0.25), 0.25] {
                for dx in [CGFloat(-0.25), 0.25] {
                    let sample = weights(CGPoint(x: point.x + dx, y: point.y + dy))
                    if (face.boundaryEdges & 1 == 0 || sample.x >= 0)
                        && (face.boundaryEdges & 2 == 0 || sample.y >= 0)
                        && (face.boundaryEdges & 4 == 0 || sample.z >= 0) { covered += 1 }
                }
            }
            return CGFloat(covered) / 4
        }
    }
}
