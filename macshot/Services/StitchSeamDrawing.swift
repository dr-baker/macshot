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

    static func draw(_ join: StitchJoin, style: StitchStyle, foldPaper: [NSColor] = [], in context: CGContext) {
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
            drawFold(join, style: style, paper: foldPaper, in: context)
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

    private static func drawFold(_ join: StitchJoin, style: StitchStyle, paper: [NSColor], in context: CGContext) {
        let length = join.end - join.start
        let depth = min(style.foldDepth, length / 6)
        let strength = style.foldStrength
        guard depth > 0, strength > 0 else { return }
        let inset = depth * 0.6
        let valley = -depth * 0.72, tuck = depth * 0.12, lip = depth * 0.17
        func ends(_ normal: CGFloat, inset: CGFloat) -> [CGPoint] {
            [point(join, along: join.start + inset, normal: normal),
             point(join, along: join.end - inset, normal: normal)]
        }
        let anchors = ends(0, inset: 0)
        let a = ends(valley, inset: inset), b = ends(0, inset: inset * 1.25)
        let c = ends(tuck, inset: inset * 0.85), d = ends(lip, inset: inset * 0.6)
        func polygon(_ points: [CGPoint]) -> CGPath {
            let result = CGMutablePath()
            result.addLines(between: points)
            result.closeSubpath()
            return result
        }
        let colors = paper.count >= 2 ? paper : [NSColor(white: 0.95, alpha: 1), NSColor(white: 0.95, alpha: 1)]
        func tint(_ color: NSColor, light: CGFloat = 0, shade: CGFloat = 0) -> NSColor {
            let rgb = color.usingColorSpace(.sRGB) ?? color
            func channel(_ value: CGFloat) -> CGFloat { (value + (1 - value) * light) * (1 - shade) }
            return NSColor(srgbRed: channel(rgb.redComponent), green: channel(rgb.greenComponent),
                           blue: channel(rgb.blueComponent), alpha: 1)
        }
        let front = colors.map { color -> NSColor in
            let rgb = color.usingColorSpace(.sRGB) ?? color
            let luminance = rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722
            return tint(rgb, light: max(0, 0.6 - luminance) * 0.11, shade: max(0, luminance - 0.5) * 0.1)
        }
        func fill(_ path: CGPath, light: CGFloat = 0, shade: CGFloat = 0, material: [NSColor]? = nil) {
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: (material ?? colors).map { tint($0, light: light, shade: shade).cgColor } as CFArray,
                locations: nil) else { return }
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.drawLinearGradient(gradient, start: point(join, along: join.start, normal: 0),
                end: point(join, along: join.end, normal: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            context.restoreGState()
        }
        func line(_ points: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: points)
            return path
        }

        func face(_ upper: [CGPoint], _ lower: [CGPoint]) -> CGPath {
            polygon([anchors[0], upper[0], upper[1], anchors[1], lower[1], lower[0]])
        }
        // A shallow accordion fold has a broad front, a tucked return, and a
        // narrow paper lip. Its crease fans meet the original sheet at each end.
        let silhouette = face(a, d)
        let opacity = 1 - pow(1 - strength, 4)
        let hairline = min(0.6, depth * 0.2)
        let shadowDepth = min(4, depth * 0.2)
        if let shadow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [NSColor(white: 0, alpha: 0.22 * opacity).cgColor, NSColor.clear.cgColor] as CFArray,
            locations: [0, 1]) {
            context.saveGState()
            context.addPath(face(d, ends(lip + shadowDepth, inset: inset * 0.6)))
            context.clip()
            context.drawLinearGradient(shadow, start: point(join, along: join.start, normal: lip),
                end: point(join, along: join.start, normal: lip + shadowDepth), options: [])
            context.restoreGState()
        }

        // Composite the paper once. Filling its silhouette first prevents cracks
        // between antialiased facets from exposing text through the crease.
        context.setAlpha(opacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        fill(silhouette)
        fill(face(a, b), material: front)
        // A restrained ambient shade describes the broad plane's slope. It
        // never lifts the crease to white or puts a glossy highlight on it.
        if let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [NSColor(white: 0, alpha: 0.07).cgColor, NSColor.clear.cgColor] as CFArray, locations: [0, 1]) {
            context.saveGState()
            context.addPath(face(a, b))
            context.clip()
            context.drawLinearGradient(shade, start: point(join, along: join.start, normal: valley),
                end: point(join, along: join.start, normal: 0), options: [])
            context.restoreGState()
        }
        fill(face(b, c), shade: 0.3)
        fill(face(c, d), light: 0.035)
        for end in 0...1 {
            fill(polygon([anchors[end], a[end], b[end]]), shade: 0.035, material: front)
        }
        context.setLineWidth(hairline)
        stroke(line([anchors[0], b[0], b[1], anchors[1]]), color: NSColor(white: 0, alpha: 0.2), in: context)
        stroke(line([anchors[0], c[0], c[1], anchors[1]]), color: NSColor(white: 0, alpha: 0.23), in: context)
        context.endTransparencyLayer()
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
