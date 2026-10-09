import AppKit

/// Finishes fully composited, flat screenshot pixels. Editable history keeps the flat source.
@MainActor
struct ScreenshotPresentation {
    let effects: ImageEffectsConfig
    let beautify: BeautifyConfig?
    let projection: StitchAccordionProjection?
    private let projectionPlanningFailed: Bool

    var hasProjectedOutput: Bool { projection?.hasProjectedOutput == true }

    init(view: OverlayView) {
        effects = view.effectsConfig
        beautify = view.beautifyEnabled ? Self.snapshot(view.beautifyConfig) : nil
        if let document = (view as? ImageEditingView)?.stitchDocument {
            projection = StitchAccordionProjection(document: document)
            projectionPlanningFailed = projection == nil
        } else {
            projection = nil
            projectionPlanningFailed = false
        }
    }

    init(effects: ImageEffectsConfig = ImageEffectsConfig(), beautify: BeautifyConfig? = nil,
         projection: StitchAccordionProjection? = nil) {
        self.effects = effects
        self.beautify = beautify.map { Self.snapshot($0) }
        self.projection = projection
        projectionPlanningFailed = false
    }

    /// Freeze AppKit and SwiftUI drawing on the main actor, then project on a render queue.
    func prepare(_ image: NSImage) -> Prepared? {
        guard !projectionPlanningFailed else { return nil }
        let effected = effects.isIdentity ? image : ImageEffects.apply(to: image, config: effects)
        if !hasProjectedOutput {
            let finished = beautify.map { BeautifyRenderer.render(image: effected, config: $0) } ?? effected
            guard let pixels = finished.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return Prepared(pixels: pixels, sourceSize: finished.size, projection: nil,
                            cornerRadius: 0, paperBackground: nil)
        }
        guard let pixels = effected.cgImage(forProposedRect: nil, context: nil, hints: nil),
              effected.size.width.isFinite, effected.size.height.isFinite,
              effected.size.width > 0, effected.size.height > 0 else { return nil }
        let background: BeautifyRenderer.PaperBackground?
        if let beautify {
            guard let prepared = BeautifyRenderer.preparePaperBackground(
                imageSize: effected.size, pixelWidth: pixels.width, pixelHeight: pixels.height,
                config: beautify) else { return nil }
            background = prepared
        } else {
            background = nil
        }
        return Prepared(pixels: pixels, sourceSize: effected.size, projection: projection,
                        cornerRadius: beautify?.cornerRadius ?? 0, paperBackground: background)
    }

    func render(_ image: NSImage) -> NSImage? {
        guard !projectionPlanningFailed else { return nil }
        // Preserve the established raster and sizing behavior for ordinary screenshots.
        if !hasProjectedOutput {
            let effected = effects.isIdentity ? image : ImageEffects.apply(to: image, config: effects)
            return beautify.map { BeautifyRenderer.render(image: effected, config: $0) } ?? effected
        }
        guard let prepared = prepare(image), let rendered = prepared.renderCGImage() else { return nil }
        return NSImage(cgImage: rendered, size: prepared.imageSize)
    }

    private static func snapshot(_ input: BeautifyConfig) -> BeautifyConfig {
        var config = input
        if config.customBackgroundImage != nil {
            if config.cachedBackgroundCGImage == nil { config.prepareBackgroundCache() }
            if let pixels = config.cachedBackgroundCGImage {
                // NSImage is mutable. The snapshot owns an immutable pixel representation.
                config.customBackgroundImage = NSImage(cgImage: pixels, size: .zero)
            }
        }
        return config
    }

    nonisolated struct Prepared: @unchecked Sendable {
        let pixels: CGImage
        let sourceSize: NSSize
        let projection: StitchAccordionProjection?
        let cornerRadius: CGFloat
        let paperBackground: BeautifyRenderer.PaperBackground?

        var imageSize: NSSize { paperBackground?.imageSize ?? sourceSize }

        nonisolated func renderCGImage() -> CGImage? {
            guard let projection, projection.hasProjectedOutput else { return pixels }
            guard let clipped = Self.clipCorners(pixels, size: sourceSize, radius: cornerRadius),
                  let projected = StitchAccordionWarp.render(clipped, projection: projection),
                  projected.width == pixels.width, projected.height == pixels.height else { return nil }
            if let paperBackground {
                return BeautifyRenderer.renderPaper(image: projected, background: paperBackground)
            }
            return projected
        }

        /// Disposable animation textures contain only the effected, composited flat sheet.
        nonisolated func animationTexture(maxDimension: CGFloat) -> CGImage? {
            guard projection?.hasProjectedOutput == true, maxDimension.isFinite, maxDimension >= 1 else { return nil }
            let limit = min(maxDimension, 1600)
            let factor = min(1, limit / CGFloat(max(pixels.width, pixels.height)))
            if factor == 1 { return Self.clipCorners(pixels, size: sourceSize, radius: cornerRadius) }
            let width = max(1, Int((CGFloat(pixels.width) * factor).rounded(.down)))
            let height = max(1, Int((CGFloat(pixels.height) * factor).rounded(.down)))
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let downsampled = context.makeImage() else { return nil }
            return Self.clipCorners(downsampled, size: sourceSize, radius: cornerRadius)
        }

        private nonisolated static func clipCorners(_ image: CGImage, size: NSSize, radius: CGFloat) -> CGImage? {
            guard radius.isFinite, radius >= 0 else { return nil }
            guard radius > 0 else { return image }
            guard size.width > 0, size.height > 0,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.scaleBy(x: CGFloat(image.width) / size.width, y: CGFloat(image.height) / size.height)
            let rect = CGRect(origin: .zero, size: size)
            let clippedRadius = min(radius, min(size.width, size.height) / 2)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: clippedRadius,
                                   cornerHeight: clippedRadius, transform: nil))
            context.clip()
            context.draw(image, in: rect)
            return context.makeImage()
        }
    }
}
