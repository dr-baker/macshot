import AppKit

/// Geometry and decoration shared by the editor, style swatches, and exported pixels.
enum StitchSeamDrawing {
    static func path(for join: StitchJoin, style: StitchStyle) -> CGPath {
        let path = CGMutablePath()
        let length = join.end - join.start
        guard length > 0 else { return path }
        let steps = max(2, Int(ceil(length / 2)))
        for index in 0...steps {
            let along = length * CGFloat(index) / CGFloat(steps)
            let envelope = min(1, min(along, length - along) / 12)
            let displacement: CGFloat
            switch style.transition {
            case .wave:
                displacement = sin(along * .pi * 2 / 28) * style.wave
            case .torn:
                // Unequal wavelengths produce a stable, irregular paper edge.
                // This is deterministic so previews, saved history, and exports agree.
                displacement = (sin(along * 0.77) * 0.42 + sin(along * 0.21 + 1.4) * 0.37
                    + sin(along * 1.7) * 0.21) * style.wave
            case .blend, .fold, .breakLine:
                displacement = 0
            }
            let p = point(join, along: join.start + along, normal: displacement * envelope)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    /// Maximum perpendicular decoration extent, excluding the blur band.
    static func decorationExtent(style: StitchStyle) -> CGFloat {
        guard style.visible, style.lineWidth > 0 else { return 0 }
        switch style.transition {
        case .wave: return style.wave + style.lineWidth / 2
        case .blend: return 0
        case .torn: return style.wave + (style.lineWidth + 3) / 2 + 1.5
        case .fold: return max(style.lineWidth / 2, min(style.feather / 2, style.wave * 3))
        case .breakLine: return max(3, style.wave * 1.5 + 3) + style.lineWidth / 2
        }
    }

    static func draw(_ join: StitchJoin, style: StitchStyle, in context: CGContext) {
        guard style.lineWidth > 0, join.end > join.start, style.transition != .blend else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(style.lineWidth)
        let spine = path(for: join, style: style)
        switch style.transition {
        case .wave:
            stroke(spine, color: style.color, in: context)
        case .blend:
            break
        case .torn:
            var shift = CGAffineTransform(translationX: join.axis == .vertical ? 1.5 : 0,
                                          y: join.axis == .horizontal ? 1.5 : 0)
            if let shadow = spine.copy(using: &shift) {
                context.setLineWidth(style.lineWidth + 3)
                stroke(shadow, color: NSColor(white: 0, alpha: 0.16), in: context)
            }
            context.setLineWidth(style.lineWidth + 1.5)
            stroke(spine, color: NSColor(white: 1, alpha: 0.78), in: context)
            context.setLineWidth(style.lineWidth)
            stroke(spine, color: style.color.withAlphaComponent(style.color.alphaComponent * 0.8), in: context)
        case .fold:
            drawFold(join, style: style, in: context)
            stroke(spine, color: style.color, in: context)
        case .breakLine:
            drawBreak(join, style: style, in: context)
        }
    }

    private static func point(_ join: StitchJoin, along: CGFloat, normal: CGFloat) -> CGPoint {
        join.axis == .horizontal ? CGPoint(x: along, y: join.position + normal)
            : CGPoint(x: join.position + normal, y: along)
    }

    private static func stroke(_ path: CGPath, color: NSColor, in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.addPath(path)
        context.strokePath()
    }

    private static func drawFold(_ join: StitchJoin, style: StitchStyle, in context: CGContext) {
        let radius = min(style.feather / 2, style.wave * 3)
        guard radius > 0 else { return }
        let colors = [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 0.32),
                      NSColor(white: 0, alpha: 0.18), NSColor(white: 0, alpha: 0)].map(\.cgColor)
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                        colors: colors as CFArray, locations: [0, 0.46, 0.54, 1]) else { return }
        context.saveGState()
        let rect = join.axis == .horizontal
            ? CGRect(x: join.start, y: join.position - radius, width: join.end - join.start, height: radius * 2)
            : CGRect(x: join.position - radius, y: join.start, width: radius * 2, height: join.end - join.start)
        context.clip(to: rect)
        context.drawLinearGradient(gradient, start: point(join, along: join.start, normal: -radius),
            end: point(join, along: join.start, normal: radius), options: [])
        context.restoreGState()
    }

    private static func drawBreak(_ join: StitchJoin, style: StitchStyle, in context: CGContext) {
        let length = join.end - join.start
        // The two marks shrink together on short joins, rather than poking out
        // beyond the seam or changing canvas dimensions.
        let halfHeight = min(max(3, style.wave * 1.5 + 3), length / 8)
        let halfGap = halfHeight * 1.4
        let center = (join.start + join.end) / 2
        let p = CGMutablePath()
        p.move(to: point(join, along: join.start, normal: 0))
        p.addLine(to: point(join, along: center - halfGap, normal: 0))
        p.move(to: point(join, along: center + halfGap, normal: 0))
        p.addLine(to: point(join, along: join.end, normal: 0))
        for offset in [-halfHeight * 0.55, halfHeight * 0.55] {
            p.move(to: point(join, along: center + offset - halfHeight * 0.45, normal: halfHeight))
            p.addLine(to: point(join, along: center + offset + halfHeight * 0.45, normal: -halfHeight))
        }
        stroke(p, color: style.color, in: context)
    }
}
