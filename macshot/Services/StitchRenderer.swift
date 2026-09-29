import AppKit
import CoreImage

/// One renderer for the workspace preview, clipboard, PNG, and handoff to the annotation editor.
enum StitchRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func path(for join: StitchJoin, style: StitchStyle) -> CGPath {
        let path = CGMutablePath()
        let length = join.end - join.start
        let steps = max(2, Int(ceil(length / 2)))
        for i in 0...steps {
            let along = join.start + length * CGFloat(i) / CGFloat(steps)
            let envelope = min(1, min(along - join.start, join.end - along) / 12)
            let wave = sin((along - join.start) * .pi * 2 / 28) * style.wave * envelope
            let point = join.axis == .horizontal
                ? CGPoint(x: along, y: join.position + wave)
                : CGPoint(x: join.position + wave, y: along)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    static func render(_ document: StitchDocument, maximumPreviewDimension: CGFloat? = nil) -> CGImage? {
        guard document.canRender else { return nil }
        let bounds = document.bounds.integral
        let scale = maximumPreviewDimension.map { min(1, $0 / max(bounds.width, bounds.height)) } ?? 1
        let width = max(1, Int(ceil(bounds.width * scale))), height = max(1, Int(ceil(bounds.height * scale)))
        func makeContext() -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        func applyCoordinates(_ ctx: CGContext) {
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        }
        guard let base = makeContext() else { return nil }
        applyCoordinates(base)
        for piece in document.pieces {
            guard let image = piece.image.cropping(to: piece.source) else { continue }
            base.saveGState()
            base.translateBy(x: piece.origin.x, y: piece.origin.y + piece.frame.height)
            base.scaleBy(x: 1, y: -1)
            base.draw(image, in: CGRect(origin: .zero, size: piece.frame.size))
            base.restoreGState()
        }
        guard let original = base.makeImage() else { return nil }
        let style = document.style
        let joins = document.joins
        guard style.visible && !joins.isEmpty else { return original }
        var blended = original
        if style.blur > 0 && style.feather > 0, let mask = makeContext() {
            mask.setFillColor(CGColor(gray: 0, alpha: 1))
            mask.fill(CGRect(x: 0, y: 0, width: width, height: height))
            applyCoordinates(mask)
            mask.setStrokeColor(CGColor(gray: 1, alpha: 1))
            mask.setLineWidth(max(1, style.feather * 0.7))
            mask.setLineCap(.round)
            for join in joins { mask.addPath(path(for: join, style: style)); mask.strokePath() }
            if let maskImage = mask.makeImage() {
                let source = CIImage(cgImage: original)
                let blurred = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: style.blur * scale]).cropped(to: source.extent)
                let fade = CIImage(cgImage: maskImage).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5, style.feather * scale * 0.4)])
                let output = blurred.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: source, kCIInputMaskImageKey: fade])
                blended = context.createCGImage(output, from: source.extent) ?? original
            }
        }
        guard let final = makeContext() else { return blended }
        final.draw(blended, in: CGRect(x: 0, y: 0, width: width, height: height))
        applyCoordinates(final)
        final.setLineCap(.round)
        final.setLineJoin(.round)
        for join in joins where style.lineWidth > 0 {
            let path = path(for: join, style: style)
            final.addPath(path)
            final.setStrokeColor(NSColor.white.withAlphaComponent(0.65).cgColor)
            final.setLineWidth(style.lineWidth + 2)
            final.strokePath()
            final.addPath(path)
            final.setStrokeColor(style.color.cgColor)
            final.setLineWidth(style.lineWidth)
            final.strokePath()
        }
        return final.makeImage()
    }
}
