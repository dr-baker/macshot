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
                displacement = tearDisplacement(along) * style.tearRoughness
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
        guard style.visible else { return 0 }
        switch style.transition {
        case .wave: return style.lineWidth > 0 ? style.wave + style.lineWidth / 2 : 0
        case .blend: return 0
        case .torn: return style.tearWidth > 0 && style.paperColor.alphaComponent > 0 ? style.tearRoughness + style.tearWidth / 2
            + min(style.tearRoughness * 0.4, style.tearWidth * 0.25) + 2 : 0
        case .fold: return style.foldStrength > 0 ? style.foldDepth + 1 : 0
        case .breakLine: return style.lineWidth > 0 ? max(3, style.breakSize * 1.5 + 3) + style.lineWidth / 2 : 0
        }
    }

    static func draw(_ join: StitchJoin, style: StitchStyle, in context: CGContext) {
        guard join.end > join.start, style.transition != .blend else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(style.lineWidth)
        let spine = path(for: join, style: style)
        switch style.transition {
        case .wave:
            guard style.lineWidth > 0 else { return }
            stroke(spine, color: style.color, in: context)
        case .blend:
            break
        case .torn:
            drawTear(join, style: style, in: context)
        case .fold:
            drawFold(join, style: style, in: context)
        case .breakLine:
            guard style.lineWidth > 0 else { return }
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

    /// Stable value noise gives the paper edge corners at several scales without
    /// a repeating wave. Sampling in source pixels keeps every output consistent.
    private static func noise(_ index: Int, salt: UInt64) -> CGFloat {
        var value = UInt64(bitPattern: Int64(index)) &+ salt
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        value ^= value >> 31
        return CGFloat(value & 0xffff) / 32767.5 - 1
    }

    private static func valueNoise(_ along: CGFloat, step: CGFloat, salt: UInt64) -> CGFloat {
        let position = along / step
        let index = Int(floor(position))
        let fraction = position - CGFloat(index)
        return noise(index, salt: salt) * (1 - fraction) + noise(index + 1, salt: salt) * fraction
    }

    private static func tearDisplacement(_ along: CGFloat) -> CGFloat {
        valueNoise(along, step: 17, salt: 41) * 0.52
            + valueNoise(along, step: 5, salt: 137) * 0.31
            + valueNoise(along, step: 1.3, salt: 751) * 0.17
    }

    private static func drawTear(_ join: StitchJoin, style: StitchStyle, in context: CGContext) {
        let opacity = style.paperColor.alphaComponent
        guard style.tearWidth > 0, opacity > 0 else { return }
        let length = join.end - join.start
        let steps = max(2, Int(ceil(length / 0.9)))
        let edgeRoughness = min(style.tearRoughness * 0.4, style.tearWidth * 0.25)
        func edge(_ along: CGFloat, upper: Bool) -> CGFloat {
            let envelope = min(1, min(along, length - along) / min(12, length / 3))
            let center = tearDisplacement(along) * style.tearRoughness
            let jagged = valueNoise(along, step: 1.8, salt: upper ? 293 : 467) * edgeRoughness
            return (center + (upper ? -style.tearWidth / 2 : style.tearWidth / 2) + jagged) * envelope
        }
        var upper: [CGPoint] = [], lower: [CGPoint] = []
        for index in 0...steps {
            let along = length * CGFloat(index) / CGFloat(steps)
            upper.append(point(join, along: join.start + along, normal: edge(along, upper: true)))
            lower.append(point(join, along: join.start + along, normal: edge(along, upper: false)))
        }
        func line(_ points: [CGPoint]) -> CGPath {
            let result = CGMutablePath()
            result.addLines(between: points)
            return result
        }
        let paper = CGMutablePath()
        paper.addLines(between: upper + lower.reversed())
        paper.closeSubpath()

        // The exposed paper has two separate edges. A narrow cast shadow sits
        // under the lower lip; the source pixels never receive a Gaussian blur.
        var shift = CGAffineTransform(translationX: join.axis == .vertical ? 1.2 : 0,
                                      y: join.axis == .horizontal ? 1.2 : 0)
        if let shadow = line(lower).copy(using: &shift) {
            context.setLineWidth(1.6)
            stroke(shadow, color: NSColor(white: 0, alpha: 0.25 * opacity), in: context)
        }
        context.setFillColor(style.paperColor.cgColor)
        context.addPath(paper)
        context.fillPath()
        context.setLineWidth(0.65)
        stroke(line(upper), color: NSColor(white: 0, alpha: 0.13 * opacity), in: context)
        stroke(line(lower), color: NSColor(white: 1, alpha: 0.48 * opacity), in: context)

        context.saveGState()
        context.addPath(paper)
        context.clip()
        context.setLineWidth(0.55)
        let fibers = CGMutablePath()
        for index in 0..<Int(length / 3) {
            let along = CGFloat(index) * 3 + 1.5
            guard along > 4, along < length - 4, noise(index, salt: 941) > -0.3 else { continue }
            let upper = index % 2 == 0
            let normal = edge(along, upper: upper)
            let fiberLength = min(style.tearWidth * 0.3, 0.8 + abs(noise(index, salt: 653)) * 1.4)
            fibers.move(to: point(join, along: join.start + along, normal: normal))
            fibers.addLine(to: point(join, along: join.start + along + noise(index, salt: 821),
                                    normal: normal + (upper ? fiberLength : -fiberLength)))
        }
        stroke(fibers, color: NSColor(white: 1, alpha: 0.55 * opacity), in: context)
        context.restoreGState()
    }

    private static func drawFold(_ join: StitchJoin, style: StitchStyle, in context: CGContext) {
        let depth = style.foldDepth
        let strength = style.foldStrength
        guard depth > 0, strength > 0 else { return }
        let length = join.end - join.start
        let bevel = min(depth * 1.25, length / 3)
        func face(_ normal: CGFloat) -> CGPath {
            let result = CGMutablePath()
            result.addLines(between: [point(join, along: join.start, normal: 0),
                point(join, along: join.start + bevel, normal: normal),
                point(join, along: join.end - bevel, normal: normal),
                point(join, along: join.end, normal: 0)])
            result.closeSubpath()
            return result
        }
        func shade(_ path: CGPath, from: CGFloat, to: CGFloat, colors: [NSColor], locations: [CGFloat]) {
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: colors.map(\.cgColor) as CFArray, locations: locations) else { return }
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.drawLinearGradient(gradient, start: point(join, along: join.start, normal: from),
                end: point(join, along: join.start, normal: to), options: [])
            context.restoreGState()
        }
        // Two planar facets meet at a sharp ridge. Beveled ends and outer
        // creases make the pleat readable even against a flat background.
        shade(face(-depth), from: -depth, to: 0,
            colors: [NSColor(white: 0, alpha: 0.14 * strength),
                     NSColor(white: 1, alpha: 0.1 * strength),
                     NSColor(white: 1, alpha: 0.66 * strength)], locations: [0, 0.12, 1])
        shade(face(depth), from: 0, to: depth,
            colors: [NSColor(white: 0, alpha: 0.56 * strength),
                     NSColor(white: 0, alpha: 0.12 * strength),
                     NSColor(white: 1, alpha: 0.12 * strength)], locations: [0, 0.85, 1])
        context.saveGState()
        context.addPath(face(-depth)); context.addPath(face(depth)); context.clip()
        let ridge = CGMutablePath()
        ridge.move(to: point(join, along: join.start, normal: -0.5))
        ridge.addLine(to: point(join, along: join.end, normal: -0.5))
        context.setLineWidth(0.75)
        stroke(ridge, color: NSColor(white: 1, alpha: 0.7 * strength), in: context)
        for normal in [-depth, depth] {
            let crease = CGMutablePath()
            crease.move(to: point(join, along: join.start, normal: 0))
            crease.addLine(to: point(join, along: join.start + bevel, normal: normal))
            crease.addLine(to: point(join, along: join.end - bevel, normal: normal))
            crease.addLine(to: point(join, along: join.end, normal: 0))
            context.setLineWidth(0.65)
            stroke(crease, color: NSColor(white: 0, alpha: 0.18 * strength), in: context)
        }
        context.restoreGState()
    }

    private static func drawBreak(_ join: StitchJoin, style: StitchStyle, in context: CGContext) {
        let length = join.end - join.start
        // The two marks shrink together on short joins, rather than poking out
        // beyond the seam or changing canvas dimensions.
        let halfHeight = min(max(3, style.breakSize * 1.5 + 3), length / 8)
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
