import AppKit

/// Finishes fully composited, flat screenshot pixels. Editable history keeps the flat source.
@MainActor
struct ScreenshotPresentation {
    nonisolated static let paperPadding: CGFloat = 12

    let effects: ImageEffectsConfig
    let beautify: BeautifyConfig?
    let projection: StitchAccordionProjection?
    private let projectionPlanningFailed: Bool

    var hasProjectedOutput: Bool { projection?.hasProjectedOutput == true }

    init(view: OverlayView) {
        effects = view.effectsConfig
        if let document = (view as? ImageEditingView)?.stitchDocument {
            projection = StitchAccordionProjection(document: document)
            projectionPlanningFailed = projection == nil
        } else {
            projection = nil
            projectionPlanningFailed = false
        }
        // Folded paper always needs a backdrop. Beautify's separate frame toggle
        // only controls ordinary screenshot decoration.
        if projection?.hasProjectedOutput == true {
            beautify = Self.paperBackgroundConfig(view.beautifyConfig)
        } else {
            beautify = view.beautifyEnabled ? Self.snapshot(view.beautifyConfig) : nil
        }
    }

    init(effects: ImageEffectsConfig? = nil, beautify: BeautifyConfig? = nil,
         projection: StitchAccordionProjection? = nil) {
        self.effects = effects ?? ImageEffectsConfig()
        self.beautify = beautify.map {
            projection?.hasProjectedOutput == true ? Self.paperBackgroundConfig($0) : Self.snapshot($0)
        }
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
        return prepareProjected(pixels: pixels, sourceSize: effected.size)
    }

    /// The source texture stays compact. Inserted paper and camera rotation determine
    /// a separate output extent at the same native pixel density.
    private func prepareProjected(pixels: CGImage, sourceSize: NSSize,
                                  previous: Prepared? = nil) -> Prepared? {
        guard let projection, let extent = Prepared.projectedExtent(
            pixels: pixels, sourceSize: sourceSize, projection: projection) else { return nil }
        let background: BeautifyRenderer.PaperBackground?
        if let beautify {
            if let previous, previous.projectedExtent == extent,
               let existing = previous.paperBackground {
                background = existing
            } else {
                guard let prepared = BeautifyRenderer.prepareStitchPaperBackground(
                    imageSize: extent.size, pixelWidth: extent.width, pixelHeight: extent.height,
                    config: beautify) else { return nil }
                background = prepared
            }
        } else {
            background = nil
        }
        return Prepared(pixels: pixels, sourceSize: sourceSize, projection: projection,
            cornerRadius: 0, paperBackground: background, paperBackgroundConfig: beautify)
    }

    /// Reuse only Beautify's background choice. The sheet keeps its own silhouette.
    static func paperBackgroundConfig(_ input: BeautifyConfig) -> BeautifyConfig {
        snapshot(BeautifyConfig(mode: .rounded, styleIndex: input.styleIndex,
            padding: paperPadding, cornerRadius: 0, shadowRadius: BeautifyRenderer.stitchPaperShadow.radius, bgRadius: 0,
            isWindowSnap: false, customBackgroundImage: input.customBackgroundImage,
            backgroundBlur: input.backgroundBlur, cachedBackgroundCGImage: input.cachedBackgroundCGImage))
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

    /// One editor owns one native-resolution presentation. The key retains the
    /// immutable composite, so replacing a CGImage cannot reuse an old pointer.
    final class Cache {
        static let defaultMaximumRetainedBytes = 128 * 1024 * 1024
        let maximumRetainedBytes: Int
        private var entry: Entry?

        var retainedEntryCount: Int { entry == nil ? 0 : 1 }
        var retainedByteCount: Int { entry?.byteCount ?? 0 }

        init(maximumRetainedBytes: Int = defaultMaximumRetainedBytes) {
            self.maximumRetainedBytes = max(0, maximumRetainedBytes)
        }

        func clear() { entry = nil }

        func prepare(_ presentation: ScreenshotPresentation, image: NSImage,
                     document: StitchDocument? = nil) -> Prepared? {
            // A previously valid entry must never conceal an invalid current plan.
            guard presentation.isValidForReuse, document?.canRender != false,
                  image.size.width.isFinite, image.size.height.isFinite,
                  image.size.width > 0, image.size.height > 0,
                  let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                clear()
                return nil
            }
            let key = Key(presentation: presentation, pixels: pixels, size: image.size)
            if let entry, entry.key.matches(key) { return entry.prepared }

            let previous = entry
            entry = nil
            let prepared: Prepared
            if let previous, presentation.hasProjectedOutput,
               previous.key.matchesInput(key) {
                // Camera and pleat edits reuse effected pixels. A new projected
                // extent needs a freshly prepared background at its own size.
                guard let result = presentation.prepareProjected(pixels: previous.prepared.pixels,
                    sourceSize: previous.prepared.sourceSize, previous: previous.prepared) else { return nil }
                prepared = result
            } else {
                let frozen = NSImage(cgImage: pixels, size: image.size)
                guard let result = presentation.prepare(frozen) else { return nil }
                prepared = result
            }

            guard let cost = Self.retentionCost(key: key, prepared: prepared),
                  cost.total <= maximumRetainedBytes else { return prepared }
            let cached = prepared.cachingRenderedPixels(maximumRetainedBytes: cost.rendered)
            entry = Entry(key: key, prepared: cached, byteCount: cost.total)
            return cached
        }

        func render(_ presentation: ScreenshotPresentation, image: NSImage,
                    document: StitchDocument? = nil) -> NSImage? {
            guard let prepared = prepare(presentation, image: image, document: document),
                  let pixels = prepared.renderCGImage() else { return nil }
            return NSImage(cgImage: pixels, size: prepared.imageSize)
        }

        private struct Entry {
            let key: Key
            let prepared: Prepared
            let byteCount: Int
        }

        private struct Key {
            let pixels: CGImage
            let size: NSSize
            let effects: ImageEffectsConfig
            let beautify: BeautifyKey?
            let projection: StitchAccordionProjection?

            init(presentation: ScreenshotPresentation, pixels: CGImage, size: NSSize) {
                self.pixels = pixels
                self.size = size
                effects = presentation.effects
                beautify = presentation.beautify.map { BeautifyKey($0, projected: presentation.hasProjectedOutput) }
                projection = presentation.projection
            }

            func matchesInput(_ other: Self) -> Bool {
                pixels === other.pixels && size == other.size && beautify == other.beautify
                    && effects.preset == other.effects.preset && effects.brightness == other.effects.brightness
                    && effects.contrast == other.effects.contrast && effects.saturation == other.effects.saturation
                    && effects.sharpness == other.effects.sharpness
                    && (projection?.hasProjectedOutput == true) == (other.projection?.hasProjectedOutput == true)
            }

            func matches(_ other: Self) -> Bool {
                guard matchesInput(other) else { return false }
                switch (projection, other.projection) {
                case (nil, nil): return true
                case (.some(let a), .some(let b)):
                    guard a.documentBounds == b.documentBounds, a.outputBounds == b.outputBounds,
                          a.source.camera == b.source.camera,
                          a.hasProjectedOutput == b.hasProjectedOutput, a.faces.count == b.faces.count,
                          a.drawingOrder == b.drawingOrder else { return false }
                    return zip(a.faces, b.faces).allSatisfy { a, b in
                        Self.matches(a.a, b.a) && Self.matches(a.b, b.b) && Self.matches(a.c, b.c)
                            && a.shade == b.shade && a.isFrontFacing == b.isFrontFacing
                            && a.boundaryEdges == b.boundaryEdges && a.paperSample == b.paperSample
                    }
                default: return false
                }
            }

            private static func matches(_ a: StitchAccordionProjection.Vertex,
                                        _ b: StitchAccordionProjection.Vertex) -> Bool {
                a.source == b.source && a.rest == b.rest && a.projected == b.projected && a.depth == b.depth
            }
        }

        private struct BeautifyKey: Equatable {
            let mode: BeautifyMode
            let styleIndex: Int
            let padding: CGFloat
            let cornerRadius: CGFloat
            let shadowRadius: CGFloat
            let bgRadius: CGFloat
            let isWindowSnap: Bool
            let backgroundBlur: CGFloat
            let customBackground: Bool
            let background: CGImage?

            init(_ config: BeautifyConfig, projected: Bool) {
                mode = projected ? .rounded : config.mode
                styleIndex = projected && config.isCustomBackground ? 0 : config.styleIndex
                padding = projected ? 0 : config.padding
                cornerRadius = projected ? 0 : config.cornerRadius
                shadowRadius = projected ? 0 : config.shadowRadius
                bgRadius = projected ? 0 : config.bgRadius
                isWindowSnap = !projected && config.isWindowSnap
                backgroundBlur = projected && !config.isCustomBackground ? 0 : config.backgroundBlur
                customBackground = config.isCustomBackground
                background = config.isCustomBackground ? config.cachedBackgroundCGImage : nil
            }

            static func == (a: Self, b: Self) -> Bool {
                a.mode == b.mode && a.styleIndex == b.styleIndex && a.padding == b.padding
                    && a.cornerRadius == b.cornerRadius && a.shadowRadius == b.shadowRadius
                    && a.bgRadius == b.bgRadius && a.isWindowSnap == b.isWindowSnap
                    && a.backgroundBlur == b.backgroundBlur && a.customBackground == b.customBackground
                    && a.background === b.background
            }
        }

        private static func retentionCost(key: Key, prepared: Prepared) -> (total: Int, rendered: Int)? {
            var images = [key.pixels, prepared.pixels]
            if let background = key.beautify?.background { images.append(background) }
            if let background = prepared.paperBackground { images.append(background.pixels) }
            var retained: [CGImage] = []
            var total = 0
            for image in images where !retained.contains(where: { $0 === image }) {
                guard let bytes = pixelByteCount(image) else { return nil }
                let sum = total.addingReportingOverflow(bytes)
                guard !sum.overflow else { return nil }
                total = sum.partialValue
                retained.append(image)
            }
            var rendered = 0
            if prepared.projection?.hasProjectedOutput == true {
                guard let extent = prepared.projectedExtent else { return nil }
                let width = prepared.paperBackground?.pixels.width ?? extent.width
                let height = prepared.paperBackground?.pixels.height ?? extent.height
                let row = width.multipliedReportingOverflow(by: 4)
                let bytes = row.partialValue.multipliedReportingOverflow(by: height)
                guard !row.overflow, !bytes.overflow else { return nil }
                rendered = bytes.partialValue
                let sum = total.addingReportingOverflow(rendered)
                guard !sum.overflow else { return nil }
                total = sum.partialValue
            }
            return (total, rendered)
        }
    }

    private var isValidForReuse: Bool {
        guard !projectionPlanningFailed,
              [effects.brightness, effects.contrast, effects.saturation, effects.sharpness].allSatisfy(\.isFinite) else {
            return false
        }
        if let beautify {
            guard beautify.backgroundBlur.isFinite, (0...50).contains(beautify.backgroundBlur),
                  !beautify.isCustomBackground || beautify.cachedBackgroundCGImage != nil else { return false }
            if !hasProjectedOutput {
                guard [beautify.padding, beautify.cornerRadius, beautify.shadowRadius, beautify.bgRadius]
                    .allSatisfy({ $0.isFinite && $0 >= 0 }) else { return false }
            }
        }
        return true
    }

    private nonisolated static func pixelByteCount(_ image: CGImage) -> Int? {
        let bytes = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        return bytes.overflow ? nil : bytes.partialValue
    }

    /// The lock only protects state. Main-actor lookup never waits for a warm
    /// render; workers share its result instead of projecting the sheet twice.
    nonisolated final class RenderedPixels: @unchecked Sendable {
        private let condition = NSCondition()
        private let maximumRetainedBytes: Int
        private var rendering = false
        private var pixels: CGImage?

        init(maximumRetainedBytes: Int) { self.maximumRetainedBytes = maximumRetainedBytes }

        var image: CGImage? {
            condition.lock()
            defer { condition.unlock() }
            return pixels
        }

        func render(_ body: () -> CGImage?) -> CGImage? {
            condition.lock()
            while rendering && pixels == nil {
                if Thread.isMainThread {
                    condition.unlock()
                    return body()
                }
                condition.wait()
            }
            if let pixels {
                condition.unlock()
                return pixels
            }
            rendering = true
            condition.unlock()
            let rendered = body()
            condition.lock()
            if let rendered, let bytes = ScreenshotPresentation.pixelByteCount(rendered),
               bytes <= maximumRetainedBytes { pixels = rendered }
            rendering = false
            condition.broadcast()
            condition.unlock()
            return rendered
        }
    }

    nonisolated struct Prepared: @unchecked Sendable {
        let pixels: CGImage
        let sourceSize: NSSize
        let projection: StitchAccordionProjection?
        let cornerRadius: CGFloat
        let paperBackground: BeautifyRenderer.PaperBackground?
        private let paperBackgroundConfig: BeautifyConfig?
        private let renderedPixels: RenderedPixels?

        init(pixels: CGImage, sourceSize: NSSize, projection: StitchAccordionProjection?,
             cornerRadius: CGFloat, paperBackground: BeautifyRenderer.PaperBackground?,
             paperBackgroundConfig: BeautifyConfig? = nil) {
            self.init(pixels: pixels, sourceSize: sourceSize, projection: projection,
                cornerRadius: cornerRadius, paperBackground: paperBackground,
                paperBackgroundConfig: paperBackgroundConfig, renderedPixels: nil)
        }

        private init(pixels: CGImage, sourceSize: NSSize, projection: StitchAccordionProjection?,
                     cornerRadius: CGFloat, paperBackground: BeautifyRenderer.PaperBackground?,
                     paperBackgroundConfig: BeautifyConfig?,
                     renderedPixels: RenderedPixels?) {
            self.pixels = pixels
            self.sourceSize = sourceSize
            self.projection = projection
            self.cornerRadius = cornerRadius
            self.paperBackground = paperBackground
            self.paperBackgroundConfig = paperBackgroundConfig
            self.renderedPixels = renderedPixels
        }

        /// Point dimensions of the full projected sheet, before background padding.
        var projectedSize: NSSize { projectedExtent?.size ?? sourceSize }
        var imageSize: NSSize { paperBackground?.imageSize ?? projectedSize }
        var isRenderCacheEnabled: Bool { renderedPixels != nil }
        var renderedCGImage: CGImage? {
            projection?.hasProjectedOutput == true ? renderedPixels?.image : pixels
        }

        fileprivate func cachingRenderedPixels(maximumRetainedBytes: Int) -> Self {
            Self(pixels: pixels, sourceSize: sourceSize, projection: projection,
                cornerRadius: cornerRadius, paperBackground: paperBackground,
                paperBackgroundConfig: paperBackgroundConfig,
                renderedPixels: RenderedPixels(maximumRetainedBytes: maximumRetainedBytes))
        }

        /// Animation uses one envelope for all frames. Prepare the original background
        /// choice at that size rather than stretching the final folded backdrop.
        @MainActor
        func animationBackground(contentSize: NSSize, pixelWidth: Int,
                                 pixelHeight: Int) -> BeautifyRenderer.PaperBackground? {
            guard let paperBackgroundConfig else { return nil }
            return BeautifyRenderer.prepareStitchPaperBackground(imageSize: contentSize,
                pixelWidth: pixelWidth, pixelHeight: pixelHeight, config: paperBackgroundConfig)
        }

        fileprivate nonisolated struct ProjectedExtent: Sendable, Equatable {
            let size: NSSize
            let width: Int
            let height: Int
        }

        fileprivate var projectedExtent: ProjectedExtent? {
            guard let projection, projection.hasProjectedOutput else { return nil }
            return Self.projectedExtent(pixels: pixels, sourceSize: sourceSize, projection: projection)
        }

        fileprivate static func projectedExtent(pixels: CGImage, sourceSize: NSSize,
                                               projection: StitchAccordionProjection) -> ProjectedExtent? {
            guard sourceSize.width.isFinite, sourceSize.height.isFinite,
                  sourceSize.width > 0, sourceSize.height > 0,
                  let dimensions = projection.outputPixelDimensions(pixelWidth: pixels.width,
                      pixelHeight: pixels.height) else { return nil }
            let size = NSSize(width: projection.outputBounds.width * sourceSize.width / projection.documentBounds.width,
                              height: projection.outputBounds.height * sourceSize.height / projection.documentBounds.height)
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
            return ProjectedExtent(size: size, width: dimensions.width, height: dimensions.height)
        }

        nonisolated func renderCGImage() -> CGImage? {
            if let renderedPixels { return renderedPixels.render { renderUncached() } }
            return renderUncached()
        }

        private nonisolated func renderUncached() -> CGImage? {
            guard let projection, projection.hasProjectedOutput else { return pixels }
            guard let extent = projectedExtent,
                  let clipped = Self.clipCorners(pixels, size: sourceSize, radius: cornerRadius),
                  let projected = StitchAccordionWarp.render(clipped, projection: projection),
                  projected.width == extent.width, projected.height == extent.height else { return nil }
            if let paperBackground {
                guard paperBackground.contentSize == extent.size else { return nil }
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
