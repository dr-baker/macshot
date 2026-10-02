import CoreGraphics

/// Projects document layout into one screen selector without confusing page
/// coordinates with the physical crop the user can repeat after scrolling.
enum StitchSelectionGuideGeometry {
    struct Edge: Equatable {
        let position: CGFloat
        let isScreenReference: Bool
    }

    struct Result: Equatable {
        let screenReferenceRect: CGRect?
        let vertical: [Edge]
        let horizontal: [Edge]
        static let empty = Result(screenReferenceRect: nil, vertical: [], horizontal: [])
        var isEmpty: Bool { vertical.isEmpty && horizontal.isEmpty }
    }

    static func guides(frames: [CGRect], anchor: CGRect, source: StitchCaptureSource,
                       screenFrame: CGRect, scrollOffset: CGPoint,
                       pointer: CGPoint? = nil, limitPerAxis: Int = 3) -> Result {
        guard valid(source.screenRect), valid(screenFrame), valid(anchor),
              source.scrollOffset.x.isFinite, source.scrollOffset.y.isFinite,
              scrollOffset.x.isFinite, scrollOffset.y.isFinite else { return .empty }
        let pixelsPerPoint = CGSize(width: anchor.width / source.screenRect.width,
                                    height: anchor.height / source.screenRect.height)
        guard pixelsPerPoint.width.isFinite, pixelsPerPoint.width > 0,
              pixelsPerPoint.height.isFinite, pixelsPerPoint.height > 0 else { return .empty }
        let bounds = CGRect(origin: .zero, size: screenFrame.size)
        let reference = local(source.screenRect, in: screenFrame)
        let visibleReference = valid(reference) && intersects(reference, bounds) ? reference : nil
        let pointer = pointer.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil }
        let limit = max(0, min(4, limitPerAxis))

        // Registration corrects canvas positions. Translate relative to the last
        // accepted piece and its exact screen crop, then apply observed scroll.
        // Its image dimensions provide the real reference-pixel density on both
        // axes, including display conversion and fractional crop rounding.
        let topLeft = CGPoint(x: source.screenRect.minX + source.scrollOffset.x - scrollOffset.x,
                              y: source.screenRect.maxY - source.scrollOffset.y + scrollOffset.y)
        let projected = frames.enumerated().compactMap { index, frame -> (Int, CGRect)? in
            guard valid(frame) else { return nil }
            let rect = CGRect(x: topLeft.x + (frame.minX - anchor.minX) / pixelsPerPoint.width,
                              y: topLeft.y - (frame.minY - anchor.minY + frame.height) / pixelsPerPoint.height,
                              width: frame.width / pixelsPerPoint.width, height: frame.height / pixelsPerPoint.height)
            guard valid(rect) else { return nil }
            let rectOnScreen = local(rect, in: screenFrame)
            guard valid(rectOnScreen), intersects(rectOnScreen, bounds) else { return nil }
            return (index, rectOnScreen)
        }

        func edges(vertical: Bool) -> [Edge] {
            let low = vertical ? bounds.minX : bounds.minY
            let high = vertical ? bounds.maxX : bounds.maxY
            var result: [Edge] = []
            func append(_ position: CGFloat, screenReference: Bool) {
                guard result.count < limit, position.isFinite, position >= low, position <= high,
                      !result.contains(where: { abs($0.position - position) < 0.5 }) else { return }
                result.append(Edge(position: position, isScreenReference: screenReference))
            }
            // The original physical region remains available even when its
            // content has scrolled completely off the current desktop snapshot.
            if let visibleReference {
                append(vertical ? visibleReference.minX : visibleReference.minY, screenReference: true)
                append(vertical ? visibleReference.maxX : visibleReference.maxY, screenReference: true)
            }
            struct Ranked { let position: CGFloat; let score: CGFloat }
            var ranked: [Ranked] = []
            for (index, rect) in projected {
                for position in vertical ? [rect.minX, rect.maxX] : [rect.minY, rect.maxY] {
                    guard position >= low, position <= high else { continue }
                    let target = pointer.map { vertical ? $0.x : $0.y }
                        ?? (vertical ? visibleReference?.minX ?? bounds.midX : visibleReference?.maxY ?? bounds.midY)
                    let distance = abs(position - target)
                    let across = pointer.map { vertical ? $0.y : $0.x }
                    let lower = vertical ? rect.minY : rect.minX
                    let upper = vertical ? rect.maxY : rect.maxX
                    let acrossDistance = across.map { max(0, max(lower - $0, $0 - upper)) } ?? 0
                    ranked.append(Ranked(position: position,
                        score: distance + acrossDistance * 0.25 - CGFloat(index) * 0.1))
                }
            }
            ranked.sort { $0.score == $1.score ? $0.position < $1.position : $0.score < $1.score }
            for candidate in ranked { append(candidate.position, screenReference: false) }
            return result
        }
        return Result(screenReferenceRect: visibleReference,
                      vertical: edges(vertical: true), horizontal: edges(vertical: false))
    }

    private static func local(_ rect: CGRect, in screen: CGRect) -> CGRect {
        rect.offsetBy(dx: -screen.minX, dy: -screen.minY)
    }

    private static func intersects(_ rect: CGRect, _ bounds: CGRect) -> Bool {
        let intersection = rect.intersection(bounds)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.minX.isFinite && rect.minY.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite && rect.size.width > 0 && rect.size.height > 0
            && rect.maxX.isFinite && rect.maxY.isFinite
    }
}
