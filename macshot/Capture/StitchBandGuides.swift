import CoreGraphics

/// Pure analysis of source pixels. Run away from the UI thread and cache by document revision.
enum StitchBandGuides {
    struct Result: Equatable {
        let rows: [CGFloat]
        let columns: [CGFloat]
        func values(for axis: StitchAxis) -> [CGFloat] { axis == .horizontal ? rows : columns }
    }
    static let maximumSampleDimension = 768
    static let maximumSamplePixels = 2_000_000
    static let maximumContentGapsPerAxis = 8

    static func geometry(document: StitchDocument) -> Result {
        var rows: [CGFloat] = [], columns: [CGFloat] = []
        for piece in document.pieces {
            rows += [piece.frame.minY, piece.frame.maxY]
            columns += [piece.frame.minX, piece.frame.maxX]
        }
        for join in document.joins {
            if join.axis == .horizontal { rows.append(join.position) }
            else { columns.append(join.position) }
        }
        return Result(rows: Array(Set(rows.filter(\.isFinite))).sorted(),
                      columns: Array(Set(columns.filter(\.isFinite))).sorted())
    }

    /// Include this value in the analysis cache key when seam settings change.
    static func contentPadding(document: StitchDocument) -> CGFloat {
        let style = document.style
        guard style.visible, style.blur > 0, style.feather.isFinite else { return 16 }
        return max(16, style.feather / 2 + 4)
    }

    static func analyze(document: StitchDocument) -> Result {
        let edges = geometry(document: document)
        var rowGaps: [(CGFloat, CGFloat)] = [], columnGaps: [(CGFloat, CGFloat)] = []
        var evidence: [Int: (rows: [(CGFloat, CGFloat)], columns: [(CGFloat, CGFloat)])] = [:]
        let padding = contentPadding(document: document)
        var remaining = maximumSamplePixels
        // Recent captures get analysis first when a large collage exhausts the budget.
        for (pieceIndex, piece) in document.pieces.enumerated().reversed() {
            guard remaining > 0, piece.source.width.isFinite, piece.source.height.isFinite,
                  piece.source.width > 0, piece.source.height > 0 else { continue }
            let scale = min(1, CGFloat(maximumSampleDimension) / max(piece.source.width, piece.source.height))
            let width = max(1, Int(ceil(piece.source.width * scale)))
            let height = max(1, Int(ceil(piece.source.height * scale)))
            guard width * height <= remaining else { continue }
            remaining -= width * height
            guard let pixels = sample(piece: piece, width: width, height: height) else { continue }
            let background = backgroundColor(pixels)
            func gaps(horizontal: Bool) -> (candidates: [(CGFloat, CGFloat)], blank: [(CGFloat, CGFloat)]) {
                let length = horizontal ? height : width
                let breadth = horizontal ? width : height
                let sourceLength = horizontal ? piece.source.height : piece.source.width
                let origin = horizontal ? piece.origin.y : piece.origin.x
                guard length >= 12, breadth >= 12 else { return ([], []) }
                let margin = max(1, breadth / 50)
                let count = breadth - margin * 2
                var blank = [Bool](repeating: false, count: length)
                for line in 0..<length {
                    var active = 0
                    for cross in margin..<(breadth - margin) {
                        let offset = (horizontal ? line * width + cross : cross * width + line) * 4
                        if (0..<4).contains(where: { abs(Int(pixels[offset + $0]) - background[$0]) > 20 }) { active += 1 }
                    }
                    blank[line] = active <= max(1, count / 100)
                }
                var runs: [Range<Int>] = []
                var start: Int?
                for index in 0...length {
                    if index < length && blank[index] {
                        if start == nil { start = index }
                    } else if let lower = start {
                        // Outer whitespace is already represented by the piece edge.
                        runs.append(lower..<index)
                        start = nil
                    }
                }
                let internalRuns = runs.filter { $0.lowerBound > 0 && $0.upperBound < length }
                let lengths = internalRuns.map(\.count).sorted()
                let ordinaryGap = lengths.count >= 5 ? lengths[lengths.count / 2] : 0
                let minimum = max(6, max(Int(ceil(24 * CGFloat(length) / sourceLength)), ordinaryGap * 3))
                let pixelStep = sourceLength / CGFloat(length)
                // Resampling blurs a boundary. Stay one sampled pixel inside a detected
                // gap rather than suggest an endpoint that might remove nearby content.
                let inset = pixelStep > 1 ? 1 : 0
                func coordinates(_ run: Range<Int>) -> (CGFloat, CGFloat) {
                    (origin + CGFloat(run.lowerBound + (run.lowerBound > 0 ? inset : 0)) * pixelStep,
                     origin + CGFloat(run.upperBound - (run.upperBound < length ? inset : 0)) * pixelStep)
                }
                return (internalRuns.filter { $0.count >= minimum }.map(coordinates), runs.map(coordinates))
            }
            let rows = gaps(horizontal: true), columns = gaps(horizontal: false)
            rowGaps += rows.candidates
            columnGaps += columns.candidates
            evidence[pieceIndex] = (rows.blank, columns.blank)
        }
        func safeGaps(_ candidates: [(CGFloat, CGFloat)], horizontal: Bool) -> [(CGFloat, CGFloat)] {
            candidates.compactMap { gap in
                // Retain whitespace on both sides of the removed band for the seam's fade.
                guard gap.1 - gap.0 >= padding * 2 + 12 else { return nil }
                for (index, piece) in document.pieces.enumerated() {
                    let lower = max(gap.0, horizontal ? piece.frame.minY : piece.frame.minX)
                    let upper = min(gap.1, horizontal ? piece.frame.maxY : piece.frame.maxX)
                    guard upper > lower else { continue }
                    // Unanalyzed pieces are not evidence of empty space. This also handles
                    // side-by-side captures: a local gap must be safe across the full cut.
                    guard let proof = evidence[index] else { return nil }
                    let runs = horizontal ? proof.rows : proof.columns
                    guard runs.contains(where: { $0.0 <= lower && $0.1 >= upper }) else { return nil }
                }
                return (gap.0 + padding, gap.1 - padding)
            }
        }

        func merge(_ edges: [CGFloat], _ gaps: [(CGFloat, CGFloat)]) -> [CGFloat] {
            let selected = gaps.sorted {
                let a = $0.1 - $0.0, b = $1.1 - $1.0
                return a == b ? $0.0 < $1.0 : a > b
            }.prefix(maximumContentGapsPerAxis)
            var result = edges
            for value in selected.flatMap({ [$0.0, $0.1] }) where value.isFinite {
                if !result.contains(where: { abs($0 - value) <= 0.5 }) { result.append(value) }
            }
            return result.sorted()
        }
        return Result(rows: merge(edges.rows, safeGaps(rowGaps, horizontal: true)),
                      columns: merge(edges.columns, safeGaps(columnGaps, horizontal: false)))
    }

    private static func sample(piece: StitchPiece, width: Int, height: Int) -> [UInt8]? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return nil }
        context.scaleBy(x: CGFloat(width) / piece.source.width, y: CGFloat(height) / piece.source.height)
        context.translateBy(x: -piece.source.minX, y: -(CGFloat(piece.image.height) - piece.source.maxY))
        context.interpolationQuality = .low
        context.draw(piece.image, in: CGRect(x: 0, y: 0, width: piece.image.width, height: piece.image.height))
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    private static func backgroundColor(_ pixels: [UInt8]) -> [Int] {
        var counts = [Int](repeating: 0, count: 65_536)
        var winner = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let key = (Int(pixels[offset]) >> 4) << 12 | (Int(pixels[offset + 1]) >> 4) << 8
                | (Int(pixels[offset + 2]) >> 4) << 4 | (Int(pixels[offset + 3]) >> 4)
            counts[key] += 1
            if counts[key] > counts[winner] { winner = key }
        }
        return [(winner >> 12) * 16 + 8, ((winner >> 8) & 15) * 16 + 8,
                ((winner >> 4) & 15) * 16 + 8, (winner & 15) * 16 + 8]
    }
}
