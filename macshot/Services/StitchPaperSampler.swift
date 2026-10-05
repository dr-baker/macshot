import AppKit
import simd

/// Colors immediately beside a join, in document coordinates. Each face keeps
/// the background of its own sheet when two different surfaces meet.
struct StitchPaperPalette {
    let negative: [NSColor]
    let positive: [NSColor]

    static let neutral = StitchPaperPalette(negative: [.init(white: 0.95, alpha: 1), .init(white: 0.95, alpha: 1)],
                                            positive: [.init(white: 0.95, alpha: 1), .init(white: 0.95, alpha: 1)])

    var blended: [NSColor] {
        zip(negative, positive).map { a, b in
            let a = Self.components(a), b = Self.components(b)
            return Self.color((a + b) / 2)
        }
    }

    var hasVisiblePaper: Bool { (negative + positive).contains { $0.alphaComponent > 0 } }

    /// Premultiplied interpolation avoids dark fringes around transparent paper.
    fileprivate static func components(_ color: NSColor) -> SIMD4<Double> {
        let rgb = color.usingColorSpace(.sRGB)!
        let a = Double(rgb.alphaComponent)
        return SIMD4(Double(rgb.redComponent) * a, Double(rgb.greenComponent) * a,
                     Double(rgb.blueComponent) * a, a)
    }

    fileprivate static func color(_ value: SIMD4<Double>) -> NSColor {
        guard value.w > 0 else { return .clear }
        return NSColor(srgbRed: CGFloat(value.x / value.w), green: CGFloat(value.y / value.w),
                       blue: CGFloat(value.z / value.w), alpha: CGFloat(value.w))
    }
}

enum StitchPaperSampler {
    /// Shared by value copies of one document. Style-only edits reuse source
    /// colors; a crop, move, reorder, or source replacement invalidates them.
    final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var latest: Snapshot?

        func snapshot(for joins: [StitchJoin], pieces: [StitchPiece]) -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            if let latest, latest.matches(joins: joins, pieces: pieces) { return latest }
            let sampling = SamplingRun(joins: joins, pieces: pieces)
            let palettes = sampling.plans.map { sampling.palette(for: $0) }
            let result = Snapshot(joins: joins, pieces: pieces, palettes: palettes,
                                  rasterPixelCount: sampling.rasterPixelCount, rasterCount: sampling.rasterCount)
            latest = result
            return result
        }
    }

    final class Snapshot {
        let palettes: [StitchPaperPalette]
        /// Work performed once for these source edges, including alpha composites.
        let rasterPixelCount: Int
        let rasterCount: Int
        private let joins: [StitchJoin]
        private let pieces: [StitchPiece]

        fileprivate init(joins: [StitchJoin], pieces: [StitchPiece], palettes: [StitchPaperPalette],
                         rasterPixelCount: Int, rasterCount: Int) {
            self.joins = joins; self.pieces = pieces; self.palettes = palettes
            self.rasterPixelCount = rasterPixelCount; self.rasterCount = rasterCount
        }

        fileprivate func matches(joins: [StitchJoin], pieces: [StitchPiece]) -> Bool {
            self.joins.count == joins.count && self.pieces.count == pieces.count
                && zip(self.joins, joins).allSatisfy {
                    $0.axis == $1.axis && $0.position == $1.position && $0.start == $1.start && $0.end == $1.end
                } && zip(self.pieces, pieces).allSatisfy {
                    $0.image === $1.image && $0.source == $1.source && $0.origin == $1.origin
                }
        }
    }

    /// Sample original pixels, never the scaled preview or a rendered seam.
    /// Local windows in continuous edge strips reject sparse text and borders.
    /// Raster density is bounded across the document; palette stops stay dense.
    static func palette(for join: StitchJoin, pieces: [StitchPiece]) -> StitchPaperPalette {
        let sampling = SamplingRun(joins: [join], pieces: pieces)
        return sampling.palette(for: sampling.plans[0])
    }

    private struct RasterSize {
        let width: Int
        let height: Int
        var pixelCount: Int { width * height }

        func scaled(by resolution: CGFloat) -> RasterSize {
            RasterSize(width: max(1, Int(CGFloat(width) * resolution)),
                       height: max(1, Int(CGFloat(height) * resolution)))
        }
    }

    private struct Candidate {
        let sheet: Int
        let rect: CGRect
        let size: RasterSize
    }

    private struct JoinPlan {
        let join: StitchJoin
        let steps: Int
        let negative: [Candidate]
        let positive: [Candidate]

        init(join: StitchJoin, pieces: [StitchPiece]) {
            self.join = join
            let length = max(0, join.end - join.start)
            steps = max(1, min(128, Int(ceil(length / 16))))
            let alongDensity = length > 0 ? min(1, CGFloat(steps * 4) / length) : 1
            func candidates(before: Bool) -> [Candidate] {
                let normal = before ? join.position - 40 : join.position
                let strip = join.axis == .horizontal
                    ? CGRect(x: join.start, y: normal, width: length, height: 40)
                    : CGRect(x: normal, y: join.start, width: 40, height: length)
                return pieces.indices.reversed().compactMap { index in
                    let frame = pieces[index].frame
                    let lower = join.axis == .horizontal ? frame.minY : frame.minX
                    let upper = join.axis == .horizontal ? frame.maxY : frame.maxX
                    let touches = before ? lower < join.position && upper > join.position - 0.5
                        : upper > join.position && lower < join.position + 0.5
                    let rect = strip.intersection(frame)
                    guard touches, !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
                    let width = join.axis == .horizontal ? ceil(rect.width * alongDensity) : ceil(rect.width)
                    let height = join.axis == .vertical ? ceil(rect.height * alongDensity) : ceil(rect.height)
                    return Candidate(sheet: index, rect: rect,
                                     size: RasterSize(width: max(1, Int(width)), height: max(1, Int(height))))
                }
            }
            negative = candidates(before: true); positive = candidates(before: false)
        }
    }

    /// Temporary source crops and rasters belong to one sampling pass. Only the
    /// finished palettes and their immutable work counts survive in the cache.
    private final class SamplingRun {
        let plans: [JoinPlan]
        let pieces: [StitchPiece]
        let resolution: CGFloat
        private var sources: [Int: CGImage] = [:]
        private var unavailableSources: Set<Int> = []
        private(set) var rasterPixelCount = 0
        private(set) var rasterCount = 0

        init(joins: [StitchJoin], pieces: [StitchPiece]) {
            let plans = joins.map { JoinPlan(join: $0, pieces: pieces) }
            self.plans = plans; self.pieces = pieces
            let sizes = plans.flatMap { ($0.negative + $0.positive).map(\.size) }
            // Reserve a second strip for each candidate that may need alpha
            // compositing. Opaque and wholly clear candidates use only one.
            func work(at resolution: CGFloat) -> Int {
                sizes.reduce(0) { $0 + 2 * $1.scaled(by: resolution).pixelCount }
            }
            let budget = 8_000_000
            if work(at: 1) <= budget {
                resolution = 1
            } else {
                var lower: CGFloat = 0, upper: CGFloat = 1
                for _ in 0..<24 {
                    let middle = (lower + upper) / 2
                    if work(at: middle) <= budget { lower = middle } else { upper = middle }
                }
                resolution = lower
            }
        }

        func palette(for plan: JoinPlan) -> StitchPaperPalette {
            let join = plan.join, length = join.end - join.start
            guard length > 0 else { return .neutral }
            let negative = SideSampler(plan: plan, before: true, sampling: self)
            let positive = SideSampler(plan: plan, before: false, sampling: self)
            var a: [SIMD4<Double>] = [], b: [SIMD4<Double>] = []
            a.reserveCapacity(plan.steps + 1); b.reserveCapacity(plan.steps + 1)
            for index in 0...plan.steps {
                let along = join.start + length * CGFloat(index) / CGFloat(plan.steps)
                a.append(negative.sample(at: along)); b.append(positive.sample(at: along))
            }
            // Bilateral smoothing removes isolated noise without blurring a
            // change between differently colored sections of the seam.
            func smooth(_ values: [SIMD4<Double>]) -> [NSColor] {
                values.indices.map { index in
                    let previous = values[max(0, index - 1)], next = values[min(values.count - 1, index + 1)]
                    let current = values[index]
                    func weight(_ neighbor: SIMD4<Double>) -> Double {
                        let difference = neighbor - current
                        return exp(-simd_dot(difference, difference) / 0.015)
                    }
                    let before = weight(previous), after = weight(next)
                    return StitchPaperPalette.color((previous * before + current * 6 + next * after) / (6 + before + after))
                }
            }
            return StitchPaperPalette(negative: smooth(a), positive: smooth(b))
        }

        func raster(for candidate: Candidate, composite: Bool) -> EdgeStrip? {
            let rect = candidate.rect, size = candidate.size.scaled(by: resolution)
            guard let context = CGContext(data: nil, width: size.width, height: size.height,
                bitsPerComponent: 8, bytesPerRow: size.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            rasterPixelCount += size.pixelCount; rasterCount += 1
            // Map the exact sheet bounds to the raster. An integral document
            // rect adds uncovered pixels to a thin sheet at a fractional origin.
            context.translateBy(x: 0, y: CGFloat(size.height))
            context.scaleBy(x: CGFloat(size.width) / rect.width, y: -CGFloat(size.height) / rect.height)
            context.translateBy(x: -rect.minX, y: -rect.minY)
            context.interpolationQuality = .none
            let indices = composite ? Array(pieces.indices) : [candidate.sheet]
            for index in indices {
                let frame = pieces[index].frame, overlap = rect.intersection(frame)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0,
                      let source = source(for: index) else { continue }
                // Match the renderer's rounded source crop and image-to-frame
                // scale, then crop that image to the local edge before drawing.
                let scaleX = CGFloat(source.width) / frame.width, scaleY = CGFloat(source.height) / frame.height
                let sourceRect = CGRect(x: (overlap.minX - frame.minX) * scaleX,
                    y: (overlap.minY - frame.minY) * scaleY, width: overlap.width * scaleX, height: overlap.height * scaleY)
                    .integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
                guard let crop = source.cropping(to: sourceRect) else { continue }
                let destination = CGRect(x: frame.minX + sourceRect.minX / scaleX,
                    y: frame.minY + sourceRect.minY / scaleY,
                    width: sourceRect.width / scaleX, height: sourceRect.height / scaleY)
                context.saveGState()
                context.clip(to: overlap)
                context.translateBy(x: destination.minX, y: destination.maxY)
                context.scaleBy(x: 1, y: -1)
                context.draw(crop, in: CGRect(origin: .zero, size: destination.size))
                context.restoreGState()
            }
            return EdgeStrip(rect: rect, context: context)
        }

        private func source(for index: Int) -> CGImage? {
            if let source = sources[index] { return source }
            guard !unavailableSources.contains(index) else { return nil }
            guard let source = pieces[index].image.cropping(to: pieces[index].source) else {
                unavailableSources.insert(index)
                return nil
            }
            sources[index] = source
            return source
        }
    }

    private struct RectKey: Hashable {
        let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
        init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    }

    private final class SideSampler {
        let plan: JoinPlan
        let before: Bool
        let sampling: SamplingRun
        let candidates: [Candidate]
        private var foreground: [Int: EdgeStrip] = [:]
        private var unavailable: Set<Int> = []
        private var composites: [RectKey: EdgeStrip] = [:]
        private var unavailableComposites: Set<RectKey> = []

        init(plan: JoinPlan, before: Bool, sampling: SamplingRun) {
            self.plan = plan; self.before = before; self.sampling = sampling
            candidates = before ? plan.negative : plan.positive
        }

        func sample(at along: CGFloat) -> SIMD4<Double> {
            let join = plan.join
            let start = max(join.start, along - 48), end = min(join.end, along + 48)
            let normal = before ? join.position - 40 : join.position
            let patch = join.axis == .horizontal
                ? CGRect(x: start, y: normal, width: end - start, height: 40)
                : CGRect(x: normal, y: start, width: 40, height: end - start)
            let inset = min(0.25, (join.end - join.start) / 2)
            let inside = max(join.start + inset, min(join.end - inset, along))
            for index in candidates.indices {
                let candidate = candidates[index]
                let lower = join.axis == .horizontal ? candidate.rect.minX : candidate.rect.minY
                let upper = join.axis == .horizontal ? candidate.rect.maxX : candidate.rect.maxY
                guard inside >= lower, inside < upper else { continue }
                if foreground[index] == nil, !unavailable.contains(index) {
                    if let strip = sampling.raster(for: candidate, composite: false) { foreground[index] = strip }
                    else { unavailable.insert(index) }
                }
                guard let strip = foreground[index] else { continue }
                let local = patch.intersection(candidate.rect)
                let neighborhood = strip.neighborhood(in: local)
                // Clear overlays fall through to the underlying sheet's broader
                // neighborhood. Partial alpha reveals the visible layers below.
                guard neighborhood.color.w > 0 else { continue }
                if neighborhood.isOpaque { return neighborhood.color }
                let key = RectKey(candidate.rect)
                if composites[key] == nil, !unavailableComposites.contains(key) {
                    if let strip = sampling.raster(for: candidate, composite: true) { composites[key] = strip }
                    else { unavailableComposites.insert(key) }
                }
                return composites[key]?.neighborhood(in: local).color ?? .zero
            }
            return .zero
        }
    }

    private struct Neighborhood {
        let color: SIMD4<Double>
        let isOpaque: Bool
        static let empty = Neighborhood(color: .zero, isOpaque: false)
    }

    private final class EdgeStrip {
        let rect: CGRect
        let context: CGContext

        init(rect: CGRect, context: CGContext) { self.rect = rect; self.context = context }

        func neighborhood(in window: CGRect) -> Neighborhood {
            let local = rect.intersection(window)
            guard !local.isNull, local.width > 0, local.height > 0,
                  let data = context.data else { return .empty }
            let scaleX = CGFloat(context.width) / rect.width, scaleY = CGFloat(context.height) / rect.height
            let minX = max(0, Int(floor((local.minX - rect.minX) * scaleX)))
            let minY = max(0, Int(floor((local.minY - rect.minY) * scaleY)))
            let maxX = min(context.width, Int(ceil((local.maxX - rect.minX) * scaleX)))
            let maxY = min(context.height, Int(ceil((local.maxY - rect.minY) * scaleY)))
            guard minX < maxX, minY < maxY else { return .empty }
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            var bins: [Int: (count: Int, sum: SIMD4<Double>)] = [:]
            var sum = SIMD4<Double>.zero, count = 0, opaque = true
            for y in minY..<maxY {
                for x in minX..<maxX {
                    let i = y * context.bytesPerRow + x * 4
                    let c = SIMD4<Double>(Double(pixels[i]), Double(pixels[i + 1]),
                                          Double(pixels[i + 2]), Double(pixels[i + 3])) / 255
                    if c.w < 1 { opaque = false }
                    // Uncovered canvas does not vote. Source alpha also clips
                    // paper and shadow when the renderer draws the seam.
                    guard c.w > 0 else { continue }
                    let key = (Int(pixels[i]) >> 5) | ((Int(pixels[i + 1]) >> 5) << 3)
                        | ((Int(pixels[i + 2]) >> 5) << 6) | ((Int(pixels[i + 3]) >> 5) << 9)
                    let old = bins[key] ?? (0, .zero)
                    bins[key] = (old.count + 1, old.sum + c)
                    sum += c; count += 1
                }
            }
            guard count > 0, let winner = bins.keys.max(by: {
                let a = bins[$0]!.count, b = bins[$1]!.count
                return a == b ? $0 > $1 : a < b
            }), let bin = bins[winner] else { return .empty }
            // Flat backgrounds use their dominant bin. Photos and gradients
            // with low confidence use the local mean in premultiplied space.
            let confidence = min(1, max(0, (Double(bin.count) / Double(count) - 0.05) / 0.2))
            return Neighborhood(color: bin.sum / Double(bin.count) * confidence + sum / Double(count) * (1 - confidence),
                                isOpaque: opaque)
        }
    }
}
