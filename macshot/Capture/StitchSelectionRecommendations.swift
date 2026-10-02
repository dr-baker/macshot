import CoreGraphics

/// Suggested dimensions in document pixels. No screen scale, capture state, or axis lock is applied.
enum StitchSelectionRecommendations {
    enum Reason: Equatable { case capture, column, row }
    struct Candidate: Equatable {
        let value: CGFloat
        let reason: Reason
    }
    struct Result: Equatable {
        let widths: [Candidate]
        let heights: [Candidate]

        func scaled(by factor: CGFloat) -> Result {
            guard factor.isFinite, factor > 0 else { return Result(widths: [], heights: []) }
            func scaled(_ candidates: [Candidate]) -> [Candidate] {
                candidates.compactMap { candidate in
                    let value = candidate.value * factor
                    guard value.isFinite, value > 0 else { return nil }
                    return Candidate(value: value, reason: candidate.reason)
                }
            }
            return Result(widths: scaled(widths), heights: scaled(heights))
        }
    }

    /// Frames retain capture/layer order; the last frame is the default recent anchor.
    /// A proposed top-left origin makes recommendations local to the region being drawn.
    static func recommendations(frames: [CGRect], proposedOrigin: CGPoint? = nil,
                                preferredIndex: Int? = nil, limitPerAxis: Int = 4, maximumSize: CGSize? = nil) -> Result {
        let entries = frames.enumerated().filter { _, rect in
            !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
                && rect.size.width > 0 && rect.size.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
        }
        guard let anchor = entries.first(where: { $0.offset == preferredIndex }) ?? entries.last else {
            return Result(widths: [], heights: [])
        }
        let proposed = proposedOrigin.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
        let point = proposed ?? anchor.element.origin
        let dx = (point.x - anchor.element.minX) / anchor.element.width
        let dy = (point.y - anchor.element.minY) / anchor.element.height
        let vertical = proposed != nil && abs(dy) > abs(dx)
        let horizontal = proposed != nil && abs(dx) > abs(dy)
        let limit = max(0, min(8, limitPerAxis))

        func axisCandidates(width: Bool) -> [Candidate] {
            struct Ranked {
                let value: CGFloat
                let reason: Reason
                let score: CGFloat
            }
            let maximum = maximumSize.map { width ? $0.width : $0.height }
            let alongPoint = width ? point.x : point.y
            let acrossPoint = width ? point.y : point.x
            let alongScale = width ? anchor.element.width : anchor.element.height
            let acrossScale = width ? anchor.element.height : anchor.element.width
            var ranked: [Ranked] = []
            func add(_ rect: CGRect, reason: Reason, bonus: CGFloat) {
                let start = width ? rect.minX : rect.minY
                let value = width ? rect.width : rect.height
                guard value.isFinite, value > 0 else { return }
                if let maximum, maximum.isFinite, value > maximum { return }
                let lower = width ? rect.minY : rect.minX
                let upper = width ? rect.maxY : rect.maxX
                let alignment = abs(start - alongPoint) / alongScale
                let distance = max(0, max(lower - acrossPoint, acrossPoint - upper)) / acrossScale
                let followsDirection = width ? vertical : horizontal
                let directionBonus: CGFloat = followsDirection && alignment < 0.01 ? 30 : 0
                ranked.append(Ranked(value: value, reason: reason,
                    score: 400 - alignment * 100 - distance * 30 + bonus + directionBonus))
            }
            for entry in entries {
                let isAnchor = entry.offset == anchor.offset
                let aligned = abs((width ? entry.element.minX : entry.element.minY) - alongPoint) < 0.5
                let reason: Reason = !isAnchor && aligned ? (width ? .column : .row) : .capture
                let recency = CGFloat(entry.offset + 1) / CGFloat(frames.count) * 5
                add(entry.element, reason: reason,
                    bonus: (isAnchor ? (proposed == nil ? 80 : 10) : 0) + recency)
            }

            // Sweep perpendicular bands. Every merged span is fully covered along
            // an actual row/column strip; a connected zigzag cannot bridge a hole.
            let edges = Array(Set(entries.flatMap { entry in
                width ? [entry.element.minY, entry.element.maxY] : [entry.element.minX, entry.element.maxX]
            })).sorted()
            for (lower, upper) in zip(edges, edges.dropFirst()) {
                let middle = lower / 2 + upper / 2
                let intervals = entries.compactMap { entry -> (CGFloat, CGFloat)? in
                    let rect = entry.element
                    let lo = width ? rect.minY : rect.minX, hi = width ? rect.maxY : rect.maxX
                    guard lo < middle, hi > middle else { return nil }
                    return width ? (rect.minX, rect.maxX) : (rect.minY, rect.maxY)
                }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
                guard var span = intervals.first else { continue }
                var members = 1
                func appendSpan() {
                    guard members > 1 else { return }
                    let rect = width
                        ? CGRect(x: span.0, y: lower, width: span.1 - span.0, height: upper - lower)
                        : CGRect(x: lower, y: span.0, width: upper - lower, height: span.1 - span.0)
                    add(rect, reason: width ? .row : .column, bonus: -8)
                }
                for interval in intervals.dropFirst() {
                    if interval.0 <= span.1 {
                        span.1 = max(span.1, interval.1); members += 1
                    } else {
                        appendSpan(); span = interval; members = 1
                    }
                }
                appendSpan()
            }
            ranked.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.value != $1.value { return $0.value < $1.value }
                return reasonOrder($0.reason) < reasonOrder($1.reason)
            }
            var result: [Candidate] = []
            for item in ranked {
                guard result.count < limit else { break }
                // Subpixel differences should not create visually identical choices.
                guard !result.contains(where: { abs($0.value - item.value) < 0.5 }) else { continue }
                result.append(Candidate(value: item.value, reason: item.reason))
            }
            return result
        }
        return Result(widths: axisCandidates(width: true), heights: axisCandidates(width: false))
    }

    private static func reasonOrder(_ reason: Reason) -> Int {
        switch reason { case .capture: return 0; case .column: return 1; case .row: return 2 }
    }
}
