import AppKit

/// Warp only the captured pixels beside the upper crease. Read the immutable
/// original for every join and keep the destination's source alpha unchanged.
enum StitchFoldWarp {
    static func apply(joins: [StitchJoin], style: StitchStyle, source: CGContext, destination: CGContext,
                      bounds: CGRect, scale: CGFloat, protectedRegions: [CGRect],
                      coverage: [StitchRenderer.CoverageSlab]) {
        guard let sourceData = source.data, let destinationData = destination.data else { return }
        let original = sourceData.assumingMemoryBound(to: UInt8.self)
        let output = destinationData.assumingMemoryBound(to: UInt8.self)
        let width = destination.width, height = destination.height
        for join in joins {
            guard let fold = StitchFoldGeometry(join: join, style: style) else { continue }
            let band = fold.bounds(from: -fold.bendWidth, to: 0)
            let x0 = max(0, min(width, Int(floor((band.minX - bounds.minX) * scale))))
            let x1 = max(0, min(width, Int(ceil((band.maxX - bounds.minX) * scale))))
            let y0 = max(0, min(height, Int(floor((band.minY - bounds.minY) * scale))))
            let y1 = max(0, min(height, Int(ceil((band.maxY - bounds.minY) * scale))))
            guard x0 < x1, y0 < y1 else { continue }
            let horizontal = join.axis == .horizontal
            let alongStart = horizontal ? x0 : y0, alongEnd = horizontal ? x1 : y1
            let normalStart = horizontal ? y0 : x0, normalEnd = horizontal ? y1 : x1
            let alongOrigin = horizontal ? bounds.minX : bounds.minY
            let normalOrigin = horizontal ? bounds.minY : bounds.minX
            // A redaction stays in native annotation coordinates. Keep the
            // sheet straight through its section instead of pulling covered
            // source pixels outside the mask. Include interpolation's reach.
            var protection = [Int](repeating: 0, count: alongEnd - alongStart + 1)
            for rect in protectedRegions where !rect.isNull && !rect.isEmpty {
                let expanded = rect.insetBy(dx: -1 / scale, dy: -1 / scale)
                let intersection = expanded.intersection(band)
                guard !intersection.isNull, !intersection.isEmpty else { continue }
                let start = horizontal ? intersection.minX : intersection.minY
                let end = horizontal ? intersection.maxX : intersection.maxY
                let first = max(alongStart, Int(floor((start - alongOrigin) * scale)))
                let last = min(alongEnd, Int(ceil((end - alongOrigin) * scale)))
                guard first < last else { continue }
                protection[first - alongStart] += 1
                protection[last - alongStart] -= 1
            }
            var covering = 0
            let envelopes = (alongStart..<alongEnd).map {
                covering += protection[$0 - alongStart]
                return covering > 0 ? 0 : fold.envelope(at: alongOrigin + (CGFloat($0) + 0.5) / scale)
            }
            let offsets = (normalStart..<normalEnd).map {
                fold.offset(at: normalOrigin + (CGFloat($0) + 0.5) / scale - join.position) * scale
            }
            let lastUpperPixel = Int(floor((join.position - normalOrigin) * scale - 0.5))

            for (slabIndex, slab) in coverage.enumerated() {
                let columnStart = max(x0, slab.columns.lowerBound), columnEnd = min(x1, slab.columns.upperBound)
                guard columnStart < columnEnd else { continue }
                let columns = columnStart..<columnEnd
                for coveredRows in slab.rows {
                    let rowStart = max(y0, coveredRows.lowerBound), rowEnd = min(y1, coveredRows.upperBound)
                    guard rowStart < rowEnd else { continue }
                    let rows = rowStart..<rowEnd
                    for y in rows {
                        // A vertical bend may cross a slab boundary only if
                        // the neighboring slab also contains captured pixels.
                        var firstCapturedColumn = slab.columns.lowerBound
                        if !horizontal, slabIndex > 0 {
                            let previous = coverage[slabIndex - 1]
                            if previous.columns.upperBound == slab.columns.lowerBound,
                               previous.rows.contains(where: { $0.contains(y) }) {
                                firstCapturedColumn = previous.columns.lowerBound
                            }
                        }
                        for x in columns {
                            let along = horizontal ? x : y, normal = horizontal ? y : x
                            let delta = offsets[normal - normalStart] * envelopes[along - alongStart]
                            guard delta > 0 else { continue }
                            let target = y * source.bytesPerRow + x * 4
                            let alpha = Double(original[target + 3])
                            guard alpha > 0 else { continue }
                            let firstCaptured = horizontal ? coveredRows.lowerBound : firstCapturedColumn
                            let sample = max(CGFloat(firstCaptured), min(CGFloat(lastUpperPixel), CGFloat(normal) - delta))
                            let first = Int(floor(sample)), second = min(lastUpperPixel, first + 1)
                            let fraction = Double(sample - CGFloat(first))
                            let a = horizontal ? first * source.bytesPerRow + x * 4 : y * source.bytesPerRow + first * 4
                            let b = horizontal ? second * source.bytesPerRow + x * 4 : y * source.bytesPerRow + second * 4
                            let sampledAlpha = Double(original[a + 3]) * (1 - fraction) + Double(original[b + 3]) * fraction
                            guard sampledAlpha > 0 else { continue }
                            let targetOutput = y * destination.bytesPerRow + x * 4
                            for channel in 0..<3 {
                                let color = Double(original[a + channel]) * (1 - fraction) + Double(original[b + channel]) * fraction
                                output[targetOutput + channel] = UInt8(max(0, min(alpha, color * alpha / sampledAlpha)).rounded())
                            }
                        }
                    }
                }
            }
        }
    }
}
