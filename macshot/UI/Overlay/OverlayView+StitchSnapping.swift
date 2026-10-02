import AppKit

struct StitchDimensionGuide {
    let isWidth: Bool
    let position: CGFloat
    let dimension: CGFloat
    let matched: Bool
}

struct StitchStartingFeedback: Equatable {
    let point: CGPoint
    let verticalEdge: CGFloat?
    let horizontalEdge: CGFloat?
}

extension OverlayView {
    func refreshStitchStartingModifiers(_ modifiers: NSEvent.ModifierFlags) {
        guard state == .idle, stitchStartingGuideProvider != nil,
              let point = stitchSelectionHoverPoint
                ?? window.map({ convert($0.mouseLocationOutsideOfEventStream, from: nil) }) else { return }
        updateStitchStartingHover(at: point, modifiers: modifiers)
    }

    func updateStitchStartingHover(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard state == .idle, stitchStartingGuideProvider != nil else { return }
        stitchSelectionHoverPoint = point
        _ = stitchSnappedStartingPoint(raw: point,
            enabled: stitchAllowsStartingCornerSnap && !modifiers.contains(.option))
        needsDisplay = true
    }

    /// Resolve once at mouseDown. Modifiers can release moving-corner snapping
    /// during the drag while the established capture anchor stays fixed.
    func stitchSnappedStartingPoint(raw: CGPoint, enabled: Bool) -> CGPoint {
        stitchStartingGuides = stitchStartingGuideProvider?(raw) ?? .empty
        stitchStartingFeedback = nil
        guard enabled, raw.x.isFinite, raw.y.isFinite,
              raw.x >= bounds.minX, raw.x <= bounds.maxX,
              raw.y >= bounds.minY, raw.y <= bounds.maxY else { return raw }
        func closest(_ edges: [StitchSelectionGuideGeometry.Edge], cursor: CGFloat,
                     lower: CGFloat, upper: CGFloat) -> CGFloat? {
            let edge = edges.filter { $0.position.isFinite && $0.position >= lower && $0.position <= upper }
                .min { abs($0.position - cursor) < abs($1.position - cursor) }
            return edge.flatMap { abs($0.position - cursor) <= 6 ? $0.position : nil }
        }
        let x = closest(stitchStartingGuides.vertical, cursor: raw.x, lower: bounds.minX, upper: bounds.maxX)
        let y = closest(stitchStartingGuides.horizontal, cursor: raw.y, lower: bounds.minY, upper: bounds.maxY)
        let point = CGPoint(x: x ?? raw.x, y: y ?? raw.y)
        if x != nil || y != nil {
            stitchStartingFeedback = StitchStartingFeedback(point: point, verticalEdge: x, horizontalEdge: y)
        }
        return point
    }

    func drawStitchStartingGuides() {
        guard !isEditorMode, state == .idle || state == .selecting, !stitchStartingGuides.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).setClip()

        if let rect = stitchStartingGuides.screenReferenceRect {
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 1
            outline.setLineDash([4, 5], count: 2, phase: 0)
            outline.stroke()
        }
        for vertical in [true, false] {
            for edge in vertical ? stitchStartingGuides.vertical : stitchStartingGuides.horizontal {
                guard edge.position.isFinite,
                      edge.position >= (vertical ? bounds.minX : bounds.minY),
                      edge.position <= (vertical ? bounds.maxX : bounds.maxY) else { continue }
                let matched = edge.position == (vertical ? stitchStartingFeedback?.verticalEdge
                    : stitchStartingFeedback?.horizontalEdge)
                let color = matched ? ToolbarLayout.accentColor
                    : NSColor.white.withAlphaComponent(edge.isScreenReference ? 0.32 : 0.18)
                color.setStroke()
                let line = NSBezierPath()
                if vertical {
                    line.move(to: CGPoint(x: edge.position, y: bounds.minY))
                    line.line(to: CGPoint(x: edge.position, y: bounds.maxY))
                } else {
                    line.move(to: CGPoint(x: bounds.minX, y: edge.position))
                    line.line(to: CGPoint(x: bounds.maxX, y: edge.position))
                }
                line.lineWidth = matched ? 1.5 : 1
                if !matched { line.setLineDash([4, 5], count: 2, phase: 0) }
                line.stroke()
            }
        }
        if let feedback = stitchStartingFeedback {
            let marker = NSBezierPath(ovalIn: CGRect(x: feedback.point.x - 4.5, y: feedback.point.y - 4.5,
                                                   width: 9, height: 9))
            NSColor.black.withAlphaComponent(0.7).setFill()
            marker.fill()
            ToolbarLayout.accentColor.setStroke()
            marker.lineWidth = 1.5
            marker.stroke()
        }
    }

    /// Compare against the raw cursor so competing image edges cannot pull a
    /// nearly matching dimension out of range. The fixed corner never moves.
    func stitchSnappedSelectionPoint(raw: CGPoint, boundaryAdjusted: CGPoint,
                                     anchor: CGPoint, enabled: Bool) -> CGPoint {
        stitchDimensionGuides = []
        guard enabled, let provider = stitchSizeRecommendations else { return boundaryAdjusted }
        let rawRect = CGRect(x: min(anchor.x, raw.x), y: min(anchor.y, raw.y),
                             width: abs(raw.x - anchor.x), height: abs(raw.y - anchor.y))
        let availableSize = CGSize(width: raw.x < anchor.x ? anchor.x - bounds.minX : bounds.maxX - anchor.x,
                                   height: raw.y < anchor.y ? anchor.y - bounds.minY : bounds.maxY - anchor.y)
        let recommendations = provider(rawRect, availableSize)
        var point = boundaryAdjusted
        for isWidth in [true, false] {
            let candidates = isWidth ? recommendations.widths : recommendations.heights
            let start = isWidth ? anchor.x : anchor.y
            let cursor = isWidth ? raw.x : raw.y
            let sign: CGFloat = cursor < start ? -1 : 1
            let dimension = abs(cursor - start)
            let low = isWidth ? bounds.minX : bounds.minY
            let high = isWidth ? bounds.maxX : bounds.maxY
            let available = candidates.filter {
                $0.value.isFinite && $0.value >= 1 && start + sign * $0.value >= low
                    && start + sign * $0.value <= high
            }
            let closest = available.min { abs($0.value - dimension) < abs($1.value - dimension) }
            let match = closest.flatMap { abs($0.value - dimension) <= 6 ? $0 : nil }
            if let match {
                if isWidth { point.x = start + sign * match.value }
                else { point.y = start + sign * match.value }
            }
            // Always expose the best layout target. Nearby alternatives appear
            // as the cursor approaches them; distant sizes don't cover the page.
            var visible = available.prefix(1).map { $0 }
            if let closest, abs(closest.value - dimension) <= 48,
               !visible.contains(where: { $0.value == closest.value }) { visible.append(closest) }
            for candidate in visible {
                stitchDimensionGuides.append(StitchDimensionGuide(isWidth: isWidth,
                    position: start + sign * candidate.value, dimension: candidate.value,
                    matched: match?.value == candidate.value))
            }
        }
        return point
    }

    func drawStitchDimensionGuides() {
        var labelFrames: [CGRect] = []
        let ordered = stitchDimensionGuides.enumerated().sorted {
            if $0.element.matched != $1.element.matched { return $0.element.matched }
            return $0.offset < $1.offset
        }
        for (_, guide) in ordered {
            let color = guide.matched ? ToolbarLayout.accentColor : NSColor.white.withAlphaComponent(0.55)
            color.setStroke()
            let line = NSBezierPath()
            if guide.isWidth {
                line.move(to: CGPoint(x: guide.position, y: max(bounds.minY, selectionRect.minY - 10)))
                line.line(to: CGPoint(x: guide.position, y: min(bounds.maxY, selectionRect.maxY + 10)))
            } else {
                line.move(to: CGPoint(x: max(bounds.minX, selectionRect.minX - 10), y: guide.position))
                line.line(to: CGPoint(x: min(bounds.maxX, selectionRect.maxX + 10), y: guide.position))
            }
            line.lineWidth = guide.matched ? 1.5 : 1
            if !guide.matched { line.setLineDash([3, 4], count: 2, phase: 0) }
            line.stroke()

            let pixels = Int((guide.dimension * stitchReferencePixelsPerPoint).rounded())
            let text = guide.isWidth ? String(format: L("%d px wide"), pixels)
                : String(format: L("%d px tall"), pixels)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let labelSize = CGSize(width: size.width + 12, height: size.height + 8)
            var origin = guide.isWidth
                ? CGPoint(x: guide.position - labelSize.width / 2, y: selectionRect.maxY + 12)
                : CGPoint(x: selectionRect.maxX + 12, y: guide.position - labelSize.height / 2)
            origin.x = max(bounds.minX + 4, min(origin.x, bounds.maxX - labelSize.width - 4))
            origin.y = max(bounds.minY + 4, min(origin.y, bounds.maxY - labelSize.height - 4))
            let rect = CGRect(origin: origin, size: labelSize)
            // Keep magnetic guides available when targets are close, without
            // piling their labels on top of one another.
            guard !labelFrames.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(rect) }) else { continue }
            labelFrames.append(rect)
            (guide.matched ? ToolbarLayout.accentColor : NSColor.black.withAlphaComponent(0.75)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 4), withAttributes: attributes)
        }
    }
}
