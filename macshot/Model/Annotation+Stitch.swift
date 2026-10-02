import AppKit

extension Annotation {
    var isStitchRedaction: Bool { tool == .filledRectangle || tool == .pixelate || tool == .blur }

    private var stitchUnclippedBounds: CGRect {
        var rect = boundingRect
        if tool == .filledRectangle, outlineColor != nil {
            rect = rect.insetBy(dx: -(strokeWidth + 6) / 2, dy: -(strokeWidth + 6) / 2)
        }
        if rotation != 0 && supportsRotation {
            let center = CGPoint(x: boundingRect.midX, y: boundingRect.midY)
            let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)].map { point in
                let x = point.x - center.x, y = point.y - center.y
                return CGPoint(x: center.x + x * cos(rotation) - y * sin(rotation),
                    y: center.y + x * sin(rotation) + y * cos(rotation))
            }
            rect = CGRect(x: corners.map(\.x).min()!, y: corners.map(\.y).min()!,
                width: corners.map(\.x).max()! - corners.map(\.x).min()!,
                height: corners.map(\.y).max()! - corners.map(\.y).min()!)
        }
        return rect
    }

    /// Bounds of pixels drawn by a redaction, after rotation and source clipping.
    var stitchVisibleBounds: CGRect {
        guard let attachment = stitchAttachment else { return stitchUnclippedBounds }
        return stitchUnclippedBounds.intersection(attachment.clipRect)
    }

    /// A deliberate resize or rotation defines new coverage. Rebind it to the
    /// captures under the edited mark on the next Stitch operation.
    func updateStitchClipForGeometryEdit() {
        guard stitchAttachment != nil else { return }
        let rect = stitchUnclippedBounds
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return }
        stitchAttachment = StitchAnnotationAttachment(pieceID: nil, lineageID: nil, clipRect: rect)
    }

    /// The image and its covering annotation move together. Keep the baked
    /// censor pixels, and move both circles of a rooted magnifier.
    func moveWithSource(dx: CGFloat, dy: CGFloat) {
        let baked = bakedBlurNSImage
        let attachment = stitchAttachment
        move(dx: dx, dy: dy)
        bakedBlurNSImage = baked
        if var attachment {
            attachment.clipRect = attachment.clipRect.offsetBy(dx: dx, dy: dy)
            stitchAttachment = attachment
        }
        if let source = loupeSourceRect { loupeSourceRect = source.offsetBy(dx: dx, dy: dy) }
    }

    /// Square censors become independently editable rectangles. Rounded and
    /// rotated shapes retain their geometry and are clipped in canvas space.
    func trimStitchRedaction(to rect: CGRect) -> Bool {
        let old = boundingRect
        guard rotation == 0, rectCornerRadius == 0, !isRounded, outlineColor == nil else { return true }
        guard old.contains(rect), rect.width > 0, rect.height > 0 else { return false }
        if tool == .pixelate || tool == .blur, rect != old {
            guard let baked = bakedBlurNSImage,
                  let image = baked.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            let width = max(1, Int(ceil(rect.width * CGFloat(image.width) / old.width)))
            let height = max(1, Int(ceil(rect.height * CGFloat(image.height) / old.height)))
            guard width <= Int(StitchDocument.maximumDimension), height <= Int(StitchDocument.maximumDimension),
                  CGFloat(width) * CGFloat(height) <= StitchDocument.maximumPixels,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.scaleBy(x: CGFloat(width) / rect.width, y: CGFloat(height) / rect.height)
            context.translateBy(x: -rect.minX, y: -rect.minY)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            graphics.imageInterpolation = .none
            baked.draw(in: old, from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let result = context.makeImage() else { return false }
            bakedBlurNSImage = NSImage(cgImage: result, size: rect.size)
        }
        startPoint = rect.origin
        endPoint = CGPoint(x: rect.maxX, y: rect.maxY)
        return true
    }

    func mirrorStitchPixels(horizontal: Bool, in bounds: CGRect) {
        if var attachment = stitchAttachment {
            if horizontal { attachment.clipRect.origin.x = bounds.minX + bounds.maxX - attachment.clipRect.maxX }
            else { attachment.clipRect.origin.y = bounds.minY + bounds.maxY - attachment.clipRect.maxY }
            stitchAttachment = attachment
        }
        guard let baked = bakedBlurNSImage,
              let image = baked.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.translateBy(x: horizontal ? CGFloat(image.width) : 0, y: horizontal ? 0 : CGFloat(image.height))
        context.scaleBy(x: horizontal ? -1 : 1, y: horizontal ? 1 : -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if let result = context.makeImage() { bakedBlurNSImage = NSImage(cgImage: result, size: baked.size) }
    }
}
