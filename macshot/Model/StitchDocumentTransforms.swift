import AppKit

extension StitchDocument {
    /// Cheap in-memory equality. Original capture pixels are immutable, so
    /// pointer identity suffices without encoding or comparing large images.
    func isIdentical(to other: StitchDocument) -> Bool {
        guard pieces.count == other.pieces.count, placement == other.placement,
            savedPackingState.horizontal == other.savedPackingState.horizontal,
            savedPackingState.length == other.savedPackingState.length,
            style.transition == other.style.transition,
            style.color == other.style.color, style.lineWidth == other.style.lineWidth,
            style.wave == other.style.wave, style.blur == other.style.blur,
            style.feather == other.style.feather, style.tearWidth == other.style.tearWidth,
            style.tearRoughness == other.style.tearRoughness, style.breakSize == other.style.breakSize,
            style.foldDepth == other.style.foldDepth,
            style.foldStrength == other.style.foldStrength,
            style.accordionWidth == other.style.accordionWidth,
            style.accordionPleats == other.style.accordionPleats,
            style.accordionPerspective == other.style.accordionPerspective,
            style.accordionYaw == other.style.accordionYaw, style.visible == other.style.visible else { return false }
        switch (background, other.background) {
        case (.automatic, .automatic), (.transparent, .transparent): break
        case (.color(let a), .color(let b)): guard a == b else { return false }
        default: return false
        }
        return zip(pieces, other.pieces).allSatisfy { a, b in
            a.id == b.id && a.lineageID == b.lineageID && a.image === b.image && a.source == b.source
                && a.origin == b.origin && a.label == b.label && a.trimStamps == b.trimStamps
        }
    }

    func flipped(horizontal: Bool) -> StitchDocument? {
        guard canRender else { return nil }
        var next = self
        let rasterBounds = bounds.integral
        var images: [(original: CGImage, flipped: CGImage)] = []
        for index in next.pieces.indices {
            let piece = pieces[index]
            let flipped: CGImage
            if let existing = images.first(where: { $0.original === piece.image }) { flipped = existing.flipped }
            else {
                let image = piece.image
                guard let context = CGContext(data: nil, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.translateBy(x: horizontal ? CGFloat(image.width) : 0, y: horizontal ? 0 : CGFloat(image.height))
                context.scaleBy(x: horizontal ? -1 : 1, y: horizontal ? 1 : -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let result = context.makeImage() else { return nil }
                flipped = result
                images.append((image, result))
            }
            var replacement = StitchPiece(image: flipped, origin: piece.origin, label: piece.label)
            replacement.id = piece.id
            replacement.lineageID = piece.lineageID
            replacement.source = piece.source
            replacement.trimStamps = piece.trimStamps.map {
                $0.mirrored(horizontal: horizontal,
                            imageSize: CGSize(width: piece.image.width, height: piece.image.height))
            }
            if horizontal {
                replacement.origin.x = rasterBounds.minX + rasterBounds.maxX - piece.frame.maxX
                replacement.source.origin.x = CGFloat(piece.image.width) - piece.source.maxX
            } else {
                replacement.origin.y = rasterBounds.minY + rasterBounds.maxY - piece.frame.maxY
                replacement.source.origin.y = CGFloat(piece.image.height) - piece.source.maxY
            }
            next.pieces[index] = replacement
        }
        // A mirrored Packed arrangement has reversed slots. Infer its stable
        // order when it is rearranged again without changing this exact image.
        if next.placement == .packed {
            next.pieces.sort { a, b in
                if savedPackingState.horizontal {
                    return a.frame.minY == b.frame.minY ? a.frame.minX < b.frame.minX : a.frame.minY < b.frame.minY
                }
                return a.frame.minX == b.frame.minX ? a.frame.minY < b.frame.minY : a.frame.minX < b.frame.minX
            }
        }
        return next.canRender ? next : nil
    }

    /// Cropping keeps source slices editable when their union matches the
    /// raster's rectangle. A crop entirely in empty canvas remains raster-only.
    func cropped(to rect: CGRect) -> StitchDocument? {
        guard canRender, !rect.isEmpty, rect == rect.integral, bounds.contains(rect) else { return nil }
        var next = self
        next.pieces = pieces.compactMap { piece in
            let intersection = piece.frame.intersection(rect)
            guard !intersection.isNull, intersection.width >= 1, intersection.height >= 1 else { return nil }
            var sliced = piece.slice(intersection, shift: CGPoint(x: -rect.minX, y: -rect.minY))
            sliced.id = piece.id
            return sliced
        }
        guard next.canRender, next.bounds == CGRect(origin: .zero, size: rect.size) else { return nil }
        next.restorePackingState(packed: placement == .packed, horizontal: savedPackingState.horizontal,
            length: min(savedPackingState.length, savedPackingState.horizontal ? rect.width : rect.height))
        return next
    }
}
