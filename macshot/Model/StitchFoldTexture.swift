import AppKit

/// Top-left image pixels covering the matched contact's tangent interval and
/// complete omitted depth. Consumers sample normalized UVs within this rectangle.
nonisolated struct StitchJoinTexture: Sendable {
    let image: CGImage
    let source: CGRect
    let horizontalFlipped: Bool
    let verticalFlipped: Bool

    var isValid: Bool {
        image.width > 0 && image.height > 0
            && CGFloat(image.width) <= StitchDocument.maximumDimension
            && CGFloat(image.height) <= StitchDocument.maximumDimension
            && image.width * image.height <= StitchDocument.maximumFoldTexturePixels
            && [source.minX, source.minY, source.width, source.height].allSatisfy(\.isFinite)
            && source.width > 0 && source.height > 0
            && CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(source)
    }

    func restricted(from start: CGFloat, to end: CGFloat, within join: StitchJoin) -> Self? {
        guard isValid, start >= join.start, end <= join.end, end > start, join.end > join.start else { return nil }
        let horizontal = join.axis == .horizontal
        let reversed = horizontal ? horizontalFlipped : verticalFlipped
        let lo = reversed ? join.end - end : start - join.start
        let length = (end - start) / (join.end - join.start)
        let offset = lo / (join.end - join.start)
        var rect = source
        if horizontal {
            rect.origin.x += rect.width * offset
            rect.size.width *= length
        } else {
            rect.origin.y += rect.height * offset
            rect.size.height *= length
        }
        rect = rect.intersection(source)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        return Self(image: image, source: rect, horizontalFlipped: horizontalFlipped,
                    verticalFlipped: verticalFlipped)
    }
}

/// One immutable composited cut strip. Cut coordinates survive source slicing,
/// movement and mirrors, and never require rereading the removed original pixels.
struct StitchFoldTexture {
    let image: CGImage
    let axis: StitchAxis
    let start: CGFloat
    let end: CGFloat
    let removedLength: CGFloat

    var isValid: Bool {
        guard start.isFinite, end.isFinite, end > start, removedLength.isFinite,
              removedLength > 0, removedLength <= StitchDocument.maximumDimension,
              end - start <= StitchDocument.maximumDimension,
              abs(start) <= SavedCaptureValidation.maximumCoordinate,
              abs(end) <= SavedCaptureValidation.maximumCoordinate else { return false }
        let width = axis == .horizontal ? end - start : removedLength
        let height = axis == .horizontal ? removedLength : end - start
        return image.width == Int(ceil(width)) && image.height == Int(ceil(height))
    }

    func mapping(stamp: StitchTrimStamp, sourceOffset: CGFloat,
                 from lo: CGFloat, to hi: CGFloat) -> StitchJoinTexture? {
        let a = stamp.cutCoordinate(at: lo - sourceOffset)
        let b = stamp.cutCoordinate(at: hi - sourceOffset)
        let rawLow = min(a, b), rawHigh = max(a, b)
        guard stamp.removedLength == removedLength, rawLow >= start - 0.000001,
              rawHigh <= end + 0.000001, rawHigh > rawLow else { return nil }
        let low = max(start, rawLow), high = min(end, rawHigh)
        let horizontal = axis == .horizontal
        let tangentPixels = CGFloat(horizontal ? image.width : image.height)
        let offset = (low - start) / (end - start) * tangentPixels
        let length = (high - low) / (end - start) * tangentPixels
        let rect = horizontal
            ? CGRect(x: offset, y: 0, width: length, height: CGFloat(image.height))
            : CGRect(x: 0, y: offset, width: CGFloat(image.width), height: length)
        return StitchJoinTexture(image: image, source: rect,
            horizontalFlipped: horizontal ? stamp.tangentReversed : stamp.normalReversed,
            verticalFlipped: horizontal ? stamp.normalReversed : stamp.tangentReversed)
    }
}

extension StitchDocument {
    /// Interleave flat pixels with the immutable strips from seams absorbed by
    /// this cut. Only the supplied composited snapshot supplies newly cut pixels.
    func retainedTextures(axis: StitchAxis, band: RemovalBand, segments: [TrimSegment],
                                  snapshot: CGImage, remainingPixels: Int) -> [StitchFoldTexture]? {
        let rasterBounds = bounds.integral
        guard snapshot.width == Int(rasterBounds.width), snapshot.height == Int(rasterBounds.height),
              remainingPixels >= 0, segments.count <= Self.maximumFoldTextures else { return nil }
        let horizontal = axis == .horizontal
        let crossed = joins.filter {
            $0.axis == axis && $0.position >= band.range.lowerBound - 0.001
                && $0.position <= band.range.upperBound + 0.001
        }.sorted { $0.position < $1.position }
        var groups: [[StitchJoin]] = []
        for join in crossed {
            if let first = groups.last?.first, abs(first.position - join.position) < 0.001 {
                groups[groups.count - 1].append(join)
            } else { groups.append([join]) }
        }
        struct DrawSlice {
            let image: CGImage
            let source: CGRect
            let destination: CGRect
            var horizontalFlipped = false
            var verticalFlipped = false
        }
        var retained: [StitchFoldTexture] = []
        var usedPixels = 0
        for segment in segments {
            let width = horizontal ? segment.end - segment.start : segment.removedLength
            let height = horizontal ? segment.removedLength : segment.end - segment.start
            guard width > 0, height > 0, width <= Self.maximumDimension, height <= Self.maximumDimension else { return nil }
            let pixelWidth = Int(ceil(width)), pixelHeight = Int(ceil(height))
            var slices: [DrawSlice] = []
            var compact = band.range.lowerBound
            var restored: CGFloat = 0
            func appendFlat(to end: CGFloat) {
                let depth = end - compact
                guard depth > 0 else { return }
                let world = horizontal
                    ? CGRect(x: segment.start, y: compact, width: width, height: depth)
                    : CGRect(x: compact, y: segment.start, width: depth, height: height)
                let destination = horizontal
                    ? CGRect(x: 0, y: restored, width: width, height: depth)
                    : CGRect(x: restored, y: 0, width: depth, height: height)
                slices.append(DrawSlice(image: snapshot,
                    source: world.offsetBy(dx: -rasterBounds.minX, dy: -rasterBounds.minY),
                    destination: destination))
                restored += depth
                compact = end
            }
            let middle = (segment.start + segment.end) / 2
            var complete = true
            for group in groups {
                let candidates = group.filter {
                    $0.start < middle && $0.end > middle
                        && ($0.trimmedLength.map { $0 > 0 && $0.isFinite } ?? false)
                }
                guard let join = candidates.max(by: { ($0.trimmedLength ?? 0) < ($1.trimmedLength ?? 0) }),
                      let depth = join.trimmedLength else { continue }
                appendFlat(to: min(band.range.upperBound, max(compact, join.position)))
                // Old history has no composited strip. Preserve its safe material
                // fallback, rather than rebuilding omitted pixels from originals.
                guard let texture = join.texture?.restricted(from: segment.start, to: segment.end, within: join) else {
                    complete = false
                    break
                }
                let destination = horizontal
                    ? CGRect(x: 0, y: restored, width: width, height: depth)
                    : CGRect(x: restored, y: 0, width: depth, height: height)
                slices.append(DrawSlice(image: texture.image, source: texture.source, destination: destination,
                    horizontalFlipped: texture.horizontalFlipped, verticalFlipped: texture.verticalFlipped))
                restored += depth
            }
            guard complete else { continue }
            appendFlat(to: band.range.upperBound)
            guard abs(restored - segment.removedLength) < 0.001,
                  pixelWidth * pixelHeight <= remainingPixels - usedPixels,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                    bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .none
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: CGFloat(pixelWidth) / width, y: -CGFloat(pixelHeight) / height)
            for slice in slices {
                guard let pixels = slice.image.cropping(to: slice.source) else { return nil }
                let destination = slice.destination
                context.saveGState()
                context.translateBy(x: destination.minX + (slice.horizontalFlipped ? destination.width : 0),
                    y: destination.minY + (slice.verticalFlipped ? 0 : destination.height))
                context.scaleBy(x: slice.horizontalFlipped ? -1 : 1, y: slice.verticalFlipped ? 1 : -1)
                context.draw(pixels, in: CGRect(origin: .zero, size: destination.size))
                context.restoreGState()
            }
            guard let pixels = context.makeImage() else { return nil }
            retained.append(StitchFoldTexture(image: pixels, axis: axis, start: segment.start,
                                              end: segment.end, removedLength: segment.removedLength))
            usedPixels += pixelWidth * pixelHeight
        }
        return retained
    }

}
