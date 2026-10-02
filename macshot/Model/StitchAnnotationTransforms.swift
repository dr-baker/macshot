import AppKit

enum StitchAnnotationTransforms {
    typealias Change = (object: Annotation, properties: Annotation)
    static let maximumFragments = 10_000

    /// Build all fragments before changing the live canvas or its undo stack.
    /// Every intersection follows source coordinates, including marks whose
    /// center disappears and marks covering several independent captures.
    static func prepare(_ annotations: [Annotation], from old: StitchDocument, to next: StitchDocument,
        scale: CGFloat, sourceImage: NSImage?, sourceBounds: CGRect) -> [Change]? {
        let unchanged = old.pieces.count == next.pieces.count && zip(old.pieces, next.pieces).allSatisfy {
            $0.id == $1.id && $0.lineageID == $1.lineageID && $0.image === $1.image && $0.source == $1.source && $0.origin == $1.origin
        }
        var changes: [Change] = []
        for annotation in annotations {
            let saved = annotation.clone()
            if saved.isStitchRedaction {
                let rect = saved.boundingRect
                guard [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite),
                      saved.stitchAttachment?.isValid != false else { return nil }
            }
            if saved.tool == .pixelate || saved.tool == .blur {
                if saved.bakedBlurNSImage == nil {
                    saved.sourceImage = sourceImage
                    saved.sourceImageBounds = sourceBounds
                    saved.bakePixelate()
                }
                guard saved.bakedBlurNSImage != nil else { return nil }
            }
            if unchanged {
                changes.append((annotation, saved))
            } else if saved.isStitchRedaction {
                guard let fragments = redactionFragments(saved, from: old, to: next, scale: scale) else { return nil }
                for (index, fragment) in fragments.enumerated() {
                    changes.append((index == 0 ? annotation : fragment, fragment))
                }
            } else {
                let center = CGPoint(x: saved.boundingRect.midX, y: saved.boundingRect.midY)
                guard let destination = movedPoint(center, from: old, to: next, scale: scale) else { continue }
                let source = saved.loupeSourceRect.flatMap { rect -> CGRect? in
                    guard let point = movedPoint(CGPoint(x: rect.midX, y: rect.midY), from: old, to: next, scale: scale) else { return nil }
                    return CGRect(x: point.x - rect.width / 2, y: point.y - rect.height / 2, width: rect.width, height: rect.height)
                }
                saved.moveWithSource(dx: destination.x - center.x, dy: destination.y - center.y)
                saved.loupeSourceRect = source
                changes.append((annotation, saved))
            }
            guard changes.count <= maximumFragments else { return nil }
        }
        return changes
    }

    private static func redactionFragments(_ annotation: Annotation, from old: StitchDocument,
        to next: StitchDocument, scale: CGFloat) -> [Annotation]? {
        let coverage = annotation.stitchPixelCoverage(in: old.bounds, scale: scale)
        guard !coverage.isNull, coverage.width > 0, coverage.height > 0 else { return [] }
        let attached = old.pieces.filter { $0.id == annotation.stitchAttachment?.pieceID }
        // An ordinary edit clears the attachment so its new coverage can span
        // captures again. Missing attachment IDs also recover from raster edits.
        let pieces = attached.isEmpty ? old.pieces : attached
        var fragments: [Annotation] = []
        var intersectedSource = false
        for piece in pieces {
            let covered = coverage.intersection(piece.frame)
            guard !covered.isNull, covered.width > 0, covered.height > 0 else { continue }
            intersectedSource = true
            let source = covered.offsetBy(dx: piece.source.minX - piece.origin.x,
                dy: piece.source.minY - piece.origin.y)
            // Replacing a source image needs its own pixel transform. A generic
            // piece operation must not silently remove a still-present mask.
            guard !next.pieces.contains(where: {
                ($0.id == piece.id || $0.lineageID == piece.lineageID) && $0.image !== piece.image
            }) else { return nil }
            for target in next.pieces where (target.id == piece.id || target.lineageID == piece.lineageID) && target.image === piece.image {
                let retained = source.intersection(target.source)
                guard !retained.isNull, retained.width > 0, retained.height > 0 else { continue }
                let before = canvas(retained.offsetBy(dx: piece.origin.x - piece.source.minX,
                    dy: piece.origin.y - piece.source.minY), in: old.bounds, scale: scale)
                let after = canvas(retained.offsetBy(dx: target.origin.x - target.source.minX,
                    dy: target.origin.y - target.source.minY), in: next.bounds, scale: scale)
                let fragment = annotation.clone()
                let trimmed = before.intersection(fragment.boundingRect)
                guard fragment.trimStitchRedaction(to: trimmed) else { return nil }
                fragment.moveWithSource(dx: after.minX - before.minX, dy: after.minY - before.minY)
                fragment.stitchAttachment = StitchAnnotationAttachment(pieceID: target.id,
                    lineageID: target.lineageID, clipRect: after)
                fragments.append(fragment)
            }
        }
        if !intersectedSource {
            let fragment = annotation.clone()
            fragment.moveWithSource(dx: (old.bounds.minX - next.bounds.minX) / scale,
                dy: (next.bounds.maxY - old.bounds.maxY) / scale)
            fragments.append(fragment)
        }
        return fragments
    }

    private static func movedPoint(_ point: CGPoint, from old: StitchDocument, to next: StitchDocument,
        scale: CGFloat) -> CGPoint? {
        let global = CGPoint(x: old.bounds.minX + point.x * scale, y: old.bounds.maxY - point.y * scale)
        var destination = global
        if let piece = old.pieces.reversed().first(where: { $0.frame.contains(global) }) {
            let source = CGPoint(x: piece.source.minX + global.x - piece.origin.x,
                y: piece.source.minY + global.y - piece.origin.y)
            guard let target = next.pieces.first(where: { $0.id == piece.id && $0.source.contains(source) })
                ?? next.pieces.reversed().first(where: { $0.lineageID == piece.lineageID && $0.image === piece.image && $0.source.contains(source) }) else { return nil }
            destination = CGPoint(x: target.origin.x + source.x - target.source.minX,
                y: target.origin.y + source.y - target.source.minY)
        }
        return CGPoint(x: (destination.x - next.bounds.minX) / scale,
            y: (next.bounds.maxY - destination.y) / scale)
    }

    private static func canvas(_ rect: CGRect, in bounds: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: (rect.minX - bounds.minX) / scale, y: (bounds.maxY - rect.maxY) / scale,
            width: rect.width / scale, height: rect.height / scale)
    }
}
