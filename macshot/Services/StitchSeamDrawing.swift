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
        case .torn: return style.tearWidth > 0 ? style.tearRoughness + style.tearWidth / 2
            + min(style.tearRoughness * 0.4, style.tearWidth * 0.25) + 2 : 0
        case .fold: return StitchFoldGeometry.extent(style: style)
        case .breakLine: return style.lineWidth > 0 ? max(3, style.breakSize * 1.5 + 3) + style.lineWidth / 2 : 0
        }
    }

    static func draw(_ join: StitchJoin, style: StitchStyle, paper: StitchPaperPalette = .neutral, in context: CGContext) {
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
            drawTear(join, style: style, palette: paper, in: context)
        case .fold:
            drawFold(join, style: style, paper: paper, in: context)
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

    private static func drawTear(_ join: StitchJoin, style: StitchStyle, palette: StitchPaperPalette, in context: CGContext) {
        guard style.tearWidth > 0, palette.hasVisiblePaper else { return }
        context.setBlendMode(.sourceAtop)
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
            stroke(shadow, color: NSColor(white: 0, alpha: 0.25), in: context)
        }
        context.saveGState()
        context.addPath(paper)
        context.clip()
        if let image = paperImage(palette, axis: join.axis, lift: 0) {
            let extent = style.tearWidth / 2 + style.tearRoughness + edgeRoughness + 1
            // Palette stops lie at the join endpoints. Extend by half a pixel
            // so image pixel centers land at those same document positions.
            let count = min(palette.negative.count, palette.positive.count)
            let spacing = count > 1 ? length / CGFloat(count - 1) : 0
            let rect = join.axis == .horizontal
                ? CGRect(x: join.start - spacing / 2, y: join.position - extent,
                         width: length + spacing, height: extent * 2)
                : CGRect(x: join.position - extent, y: join.start - spacing / 2,
                         width: extent * 2, height: length + spacing)
            context.interpolationQuality = .high
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        }
        context.restoreGState()

        // Keep the paper equal to the sampled background. Only its narrow lips
        // and fibers contrast, following each sheet's own local section colors.
        func contrasting(_ color: NSColor, amount: CGFloat) -> NSColor {
            let rgb = color.usingColorSpace(.sRGB)!
            let brightness = rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722
            let toward: CGFloat = brightness < 0.52 ? 1 : 0
            func channel(_ value: CGFloat) -> CGFloat { value + (toward - value) * amount }
            return NSColor(srgbRed: channel(rgb.redComponent), green: channel(rgb.greenComponent),
                blue: channel(rgb.blueComponent), alpha: rgb.alphaComponent)
        }
        func edgeStroke(_ path: CGPath, colors: [NSColor], width: CGFloat, contrast: CGFloat) {
            guard !colors.isEmpty else { return }
            let stops = colors.count == 1 ? [colors[0], colors[0]] : colors
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: stops.map { contrasting($0, amount: contrast).cgColor } as CFArray, locations: nil) else { return }
            context.saveGState()
            defer { context.restoreGState() }
            context.setLineWidth(width)
            context.addPath(path)
            context.replacePathWithStrokedPath()
            context.clip()
            context.drawLinearGradient(gradient, start: point(join, along: join.start, normal: 0),
                end: point(join, along: join.end, normal: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        edgeStroke(line(upper), colors: palette.negative, width: 0.65, contrast: 0.16)
        edgeStroke(line(lower), colors: palette.positive, width: 0.65, contrast: 0.24)

        context.saveGState()
        context.addPath(paper)
        context.clip()
        let upperFibers = CGMutablePath(), lowerFibers = CGMutablePath()
        for index in 0..<Int(length / 3) {
            let along = CGFloat(index) * 3 + 1.5
            guard along > 4, along < length - 4, noise(index, salt: 941) > -0.3 else { continue }
            let upper = index % 2 == 0
            let normal = edge(along, upper: upper)
            let fiberLength = min(style.tearWidth * 0.3, 0.8 + abs(noise(index, salt: 653)) * 1.4)
            let fibers = upper ? upperFibers : lowerFibers
            fibers.move(to: point(join, along: join.start + along, normal: normal))
            fibers.addLine(to: point(join, along: join.start + along + noise(index, salt: 821),
                                    normal: normal + (upper ? fiberLength : -fiberLength)))
        }
        edgeStroke(upperFibers, colors: palette.negative, width: 0.55, contrast: 0.34)
        edgeStroke(lowerFibers, colors: palette.positive, width: 0.55, contrast: 0.34)
        context.restoreGState()
    }

    /// Two sampled edges form a small color field. It follows section colors
    /// along the seam and fades between different backgrounds across its width.
    private static func paperImage(_ palette: StitchPaperPalette, axis: StitchAxis, lift: CGFloat) -> CGImage? {
        let count = min(palette.negative.count, palette.positive.count)
        guard count > 0 else { return nil }
        let width = axis == .horizontal ? count : 2, height = axis == .horizontal ? 2 : count
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for side in 0..<2 {
            let colors = side == 0 ? palette.negative : palette.positive
            for index in 0..<count {
                let rgb = colors[index].usingColorSpace(.sRGB)!
                let alpha = rgb.alphaComponent
                let x = axis == .horizontal ? index : side, y = axis == .horizontal ? side : index
                let offset = (y * width + x) * 4
                for (channel, value) in [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].enumerated() {
                    bytes[offset + channel] = UInt8(((value + (1 - value) * lift) * alpha * 255).rounded())
                }
                bytes[offset + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func drawFold(_ join: StitchJoin, style: StitchStyle, paper: StitchPaperPalette, in context: CGContext) {
        guard let fold = StitchFoldGeometry(join: join, style: style), paper.hasVisiblePaper else { return }
        // Source-atop changes the captured surface without increasing its alpha
        // or painting into clear source pixels. The upper bend keeps real detail.
        context.setBlendMode(.sourceAtop)
        context.setAlpha(min(1, fold.strength))
        let shading = max(1, fold.strength)
        if let shadow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [NSColor(white: 0, alpha: 0.2 * shading).cgColor, NSColor.clear.cgColor] as CFArray,
            locations: [0, 1]) {
            context.saveGState()
            context.addPath(fold.band(from: fold.lowerLanding, to: fold.lowerLanding + fold.shadowWidth))
            context.clip()
            context.drawLinearGradient(shadow,
                start: fold.point(along: join.start, normal: fold.lowerLanding),
                end: fold.point(along: join.start, normal: fold.lowerLanding + fold.shadowWidth),
                options: [.drawsBeforeStartLocation])
            context.restoreGState()
        }

        func shade(_ color: NSColor, by amount: CGFloat) -> NSColor {
            let rgb = color.usingColorSpace(.sRGB)!
            return NSColor(srgbRed: rgb.redComponent * (1 - amount), green: rgb.greenComponent * (1 - amount),
                blue: rgb.blueComponent * (1 - amount), alpha: rgb.alphaComponent)
        }
        let material = StitchPaperPalette(negative: paper.negative.map { shade($0, by: 0.06 * shading) },
                                         positive: paper.positive.map { shade($0, by: 0.015 * shading) })
        guard let image = paperImage(material, axis: join.axis, lift: 0) else { return }
        context.addPath(fold.band(from: fold.upperTurn, to: fold.lowerLanding))
        context.clip()
        let length = join.end - join.start
        let count = min(material.negative.count, material.positive.count)
        let spacing = count > 1 ? length / CGFloat(count - 1) : 0
        // Match pixel centers to both the along-seam palette stops and the two
        // sheet edges across the return. The tapered path clips the extension.
        let rect = join.axis == .horizontal
            ? CGRect(x: join.start - spacing / 2, y: join.position + fold.upperTurn - fold.returnWidth / 2,
                width: length + spacing, height: fold.returnWidth * 2)
            : CGRect(x: join.position + fold.upperTurn - fold.returnWidth / 2, y: join.start - spacing / 2,
                width: fold.returnWidth * 2, height: length + spacing)
        context.interpolationQuality = .high
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
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
