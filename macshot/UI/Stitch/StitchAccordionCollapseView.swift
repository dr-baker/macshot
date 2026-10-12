import AppKit
import CoreImage
import QuartzCore

/// A bounded, disposable animation of the same textured faces used by the export renderer.
@MainActor
final class StitchAccordionCollapseView: NSView {
    static let duration: CFTimeInterval = StitchAccordionAnimation.editorDuration
    static let maximumTextureDimension: CGFloat = 1600
    private let texture: CGImage
    private var plans: [StitchAccordionProjection]
    private var outputBounds: CGRect
    private var faceLayers: [Int: CALayer] = [:]
    private var guardedTextures: [ObjectIdentifier: StitchPaperGuardedTexture] = [:]
    private struct PaperSampleKey: Hashable {
        let x: CGFloat
        let y: CGFloat
        init(_ point: CGPoint) { x = point.x; y = point.y }
    }
    private var paperColors: [PaperSampleKey: CGColor] = [:]
    private let interactive: Bool
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init?(texture: CGImage, document: StitchDocument, frame: CGRect,
          preparedSource: StitchAccordionProjection.Source? = nil) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              texture.width <= Int(Self.maximumTextureDimension), texture.height <= Int(Self.maximumTextureDimension),
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return nil }
        guard let rawSource = preparedSource ?? StitchAccordionProjection.Source(document: document),
              let source = rawSource.resizingPaperTextures(maxDimension: Int(Self.maximumTextureDimension)),
              let final = source.expandingProjection(progress: 1), final.hasProjectedOutput,
              final.faces.count <= 512,
              let guarded = Self.prepareTextures(texture: texture, projection: final) else { return nil }
        let progress = StitchAccordionAnimation.editorProgresses
        let plans = progress.dropLast().compactMap { source.expandingProjection(progress: $0) } + [final]
        guard plans.count == progress.count, plans.allSatisfy({ $0.faces.count == final.faces.count }) else { return nil }
        self.texture = texture
        guardedTextures = guarded
        self.plans = plans
        let envelope = plans.reduce(CGRect.null) { $0.union($1.outputBounds) }
        outputBounds = envelope
        interactive = false
        let finalBounds = final.outputBounds
        let sx = frame.width / finalBounds.width, sy = frame.height / finalBounds.height
        super.init(frame: CGRect(x: frame.minX + (envelope.minX - finalBounds.minX) * sx,
            y: frame.minY + (finalBounds.maxY - envelope.maxY) * sy,
            width: envelope.width * sx, height: envelope.height * sy))
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateDisplayScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDisplayScale()
    }

    private func updateDisplayScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        layer?.contentsScale = scale
        for sheet in faceLayers.values {
            sheet.contentsScale = scale
            sheet.mask?.contentsScale = scale
            sheet.sublayers?.forEach { $0.contentsScale = scale }
        }
    }

    /// Orbiting updates only textured face transforms and lighting. Reduce Motion
    /// removes the folding animation, while direct manipulation remains available.
    init?(interactiveTexture texture: CGImage, projection: StitchAccordionProjection, frame: CGRect) {
        guard texture.width <= Int(Self.maximumTextureDimension),
              texture.height <= Int(Self.maximumTextureDimension),
              projection.hasProjectedOutput, projection.faces.count <= 512,
              frame.width > 0, frame.height > 0,
              let projection = projection.resizingPaperTextures(maxDimension: Int(Self.maximumTextureDimension)),
              let guarded = Self.prepareTextures(texture: texture, projection: projection) else { return nil }
        self.texture = texture
        guardedTextures = guarded
        plans = [projection]
        outputBounds = projection.outputBounds
        interactive = true
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
        renderFaces(animated: false)
    }

    func uses(texture: CGImage) -> Bool { self.texture === texture }

    @discardableResult
    func updateInteractive(projection: StitchAccordionProjection, frame: CGRect) -> Bool {
        guard interactive, projection.hasProjectedOutput, projection.faces.count <= 512,
              frame.width > 0, frame.height > 0,
              let guarded = Self.prepareTextures(texture: texture, projection: projection,
                reusing: guardedTextures) else { return false }
        guardedTextures = guarded
        self.frame = frame
        plans = [projection]
        outputBounds = projection.outputBounds
        renderFaces(animated: false)
        return true
    }

    private static func prepareTextures(texture: CGImage, projection: StitchAccordionProjection,
                                        reusing existing: [ObjectIdentifier: StitchPaperGuardedTexture] = [:])
        -> [ObjectIdentifier: StitchPaperGuardedTexture]? {
        var prepared: [ObjectIdentifier: StitchPaperGuardedTexture] = [:]
        for image in [texture] + projection.faces.compactMap({ $0.paperTexture?.image }) {
            let identity = ObjectIdentifier(image)
            if prepared[identity] != nil { continue }
            guard let material = existing[identity] ?? StitchPaperGuardedTexture(image) else { return nil }
            prepared[identity] = material
        }
        return prepared
    }

    func play(completion: @escaping () -> Void) {
        guard !interactive, layer != nil, !plans.isEmpty else { completion(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        renderFaces(animated: true)
        CATransaction.commit()
    }

    private func renderFaces(animated: Bool) {
        guard let layer, let final = plans.last, let first = plans.first,
              bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if faceLayers.count != final.faces.count {
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            faceLayers.removeAll()
        }
        let documentBounds = final.documentBounds
        let outputBounds = self.outputBounds
        let scaleX = bounds.width / outputBounds.width, scaleY = bounds.height / outputBounds.height
        let referenceDepth = first.faces.first?.a.depth ?? 1
        let displayScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        var usedTextures: Set<ObjectIdentifier> = []
        let depthRanks = plans.map { plan -> [CGFloat] in
            var ranks = Array(repeating: CGFloat.zero, count: plan.faces.count)
            for (rank, index) in plan.drawingOrder.enumerated() { ranks[index] = CGFloat(rank) }
            return ranks
        }
        for index in final.drawingOrder {
            let face = final.faces[index]
            // Inserted paper has a degenerate UV triangle at the cut. Its full
            // rest coordinates provide the nondegenerate local material plane.
            let localPoints = face.vertices.map { vertex in
                let point = face.paperSample == nil ? vertex.source : vertex.rest
                return CGPoint(x: point.x * scaleX, y: point.y * scaleY)
            }
            let faceRect = Self.envelope(localPoints)
            guard faceRect.width > 0, faceRect.height > 0 else { continue }
            let printedImage: CGImage?
            let crop: CGRect
            if let paper = face.paperTexture {
                let uv = Self.envelope(face.vertices.compactMap(\.paperUV))
                let u = paper.horizontalFlipped ? 1 - uv.maxX : uv.minX
                let v = paper.verticalFlipped ? 1 - uv.maxY : uv.minY
                printedImage = paper.image
                crop = CGRect(x: paper.source.minX + u * paper.source.width,
                    y: paper.source.minY + v * paper.source.height,
                    width: uv.width * paper.source.width, height: uv.height * paper.source.height)
            } else if face.paperSample == nil {
                let uv = Self.envelope(face.vertices.map(\.source))
                printedImage = texture
                crop = CGRect(x: (uv.minX - documentBounds.minX) / documentBounds.width * CGFloat(texture.width),
                    y: (uv.minY - documentBounds.minY) / documentBounds.height * CGFloat(texture.height),
                    width: uv.width / documentBounds.width * CGFloat(texture.width),
                    height: uv.height / documentBounds.height * CGFloat(texture.height))
            } else {
                printedImage = nil
                crop = .zero
            }
            let guarded: StitchPaperGuardedTexture?
            let marginX: CGFloat, marginY: CGFloat
            if let printedImage {
                let identity = ObjectIdentifier(printedImage)
                usedTextures.insert(identity)
                guard let material = guardedTextures[identity], crop.width > 0, crop.height > 0 else { continue }
                guarded = material
                // Overscan the texture plane beneath the triangle mask. The
                // replicated image border supplies opaque samples at exterior edges.
                let pixelX = faceRect.width / crop.width, pixelY = faceRect.height / crop.height
                marginX = min(CGFloat(StitchPaperGuardedTexture.padding) * pixelX, max(pixelX, 1 / displayScale))
                marginY = min(CGFloat(StitchPaperGuardedTexture.padding) * pixelY, max(pixelY, 1 / displayScale))
            } else {
                guarded = nil
                marginX = 1 / displayScale; marginY = marginX
            }
            let sourceRect = faceRect.insetBy(dx: -marginX, dy: -marginY)
            let guardedCrop = guarded.map { $0.contentsRect(for: crop.insetBy(
                dx: -marginX / faceRect.width * crop.width,
                dy: -marginY / faceRect.height * crop.height)) }
            let sheet: CALayer
            if let existing = faceLayers[index] {
                sheet = existing
            } else {
                sheet = CALayer()
                sheet.name = "accordion.face.\(index)"
                sheet.anchorPoint = .zero
                sheet.position = .zero
                sheet.contentsGravity = .resize
                let mask = CAShapeLayer()
                mask.fillColor = NSColor.black.cgColor
                // Cover shared triangle antialiasing pixels so flat faces never show diagonal mesh cracks.
                mask.strokeColor = NSColor.black.cgColor
                mask.lineWidth = 0.8
                sheet.mask = mask
                faceLayers[index] = sheet
            }
            sheet.bounds = CGRect(origin: .zero, size: sourceRect.size)
            if let paper = face.paperTexture {
                // The material plane stays in physical rest coordinates while
                // its printed pixels come from the captured, composited cut.
                sheet.contents = nil
                sheet.backgroundColor = nil
                let printed: CALayer
                if let existing = sheet.sublayers?.first { printed = existing }
                else {
                    printed = CALayer()
                    printed.name = "accordion.print"
                    printed.contentsGravity = .resize
                    sheet.addSublayer(printed)
                }
                printed.frame = sheet.bounds
                printed.contents = guarded?.image
                printed.contentsRect = guardedCrop ?? .zero
                printed.transform = CATransform3DMakeScale(paper.horizontalFlipped ? -1 : 1,
                    paper.verticalFlipped ? -1 : 1, 1)
            } else if let sample = face.paperSample {
                sheet.sublayers?.forEach { $0.removeFromSuperlayer() }
                let key = PaperSampleKey(sample)
                let color: CGColor?
                if let cached = paperColors[key] { color = cached }
                else {
                    color = StitchAccordionWarp.paperColor(image: texture, sample: sample,
                        documentBounds: documentBounds)?.cgColor
                    if let color { paperColors[key] = color }
                }
                sheet.contents = nil
                sheet.backgroundColor = color
            } else {
                sheet.sublayers?.forEach { $0.removeFromSuperlayer() }
                sheet.backgroundColor = nil
                sheet.contents = guarded?.image
                sheet.contentsRect = guardedCrop ?? .zero
            }
            if let mask = sheet.mask as? CAShapeLayer {
                mask.frame = sheet.bounds
                let path = CGMutablePath()
                path.addLines(between: localPoints.map { CGPoint(x: $0.x - sourceRect.minX, y: $0.y - sourceRect.minY) })
                path.closeSubpath()
                mask.path = path
            }
            sheet.removeAllAnimations()
            let transforms = plans.map {
                Self.transform(face: $0.faces[index], sourceRect: sourceRect,
                    outputBounds: outputBounds, size: bounds.size, referenceDepth: referenceDepth)
            }
            sheet.transform = transforms.last!
            sheet.opacity = face.isFrontFacing || face.paperSample != nil ? 1 : 0
            sheet.zPosition = depthRanks.last![index]
            if animated {
                animate("transform", values: transforms.map { NSValue(caTransform3D: $0) }, on: sheet)
                animate("zPosition", values: depthRanks.map { NSNumber(value: Double($0[index])) }, on: sheet)
                animate("opacity", values: plans.map {
                    NSNumber(value: $0.faces[index].isFrontFacing || $0.faces[index].paperSample != nil ? 1 : 0)
                }, on: sheet)
            }
            // Multiply printed RGB, including highlights, while leaving source alpha unchanged.
            // A color overlay would brighten dark paper differently and fill transparent holes.
            if let lighting = (sheet.filters?.first as? CIFilter) ?? CIFilter(name: "CIColorMatrix") {
                lighting.setDefaults()
                lighting.name = "paperLighting"
                let parameters = ["inputRVector", "inputGVector", "inputBVector"].enumerated().map { channel, key in
                    let values = plans.map { plan -> CIVector in
                        var components: [CGFloat] = [0, 0, 0, 0]
                        components[channel] = plan.faces[index].shade
                        return CIVector(values: components, count: components.count)
                    }
                    return (key: key, values: values)
                }
                for parameter in parameters { lighting.setValue(parameter.values.last, forKey: parameter.key) }
                sheet.filters = [lighting]
                if animated {
                    for parameter in parameters {
                        animate("filters.paperLighting.\(parameter.key)", values: parameter.values, on: sheet)
                    }
                }
            }
        }
        layer.sublayers = final.drawingOrder.compactMap { faceLayers[$0] }
        guardedTextures = guardedTextures.filter { usedTextures.contains($0.key) }
        updateDisplayScale()
        if interactive {
            let shadow = BeautifyRenderer.stitchPaperShadow
            var mapping = CGAffineTransform(translationX: -outputBounds.minX, y: -outputBounds.minY)
                .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            layer.shadowPath = final.paperPath.copy(using: &mapping)
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = Float(shadow.alpha)
            layer.shadowRadius = shadow.radius
            layer.shadowOffset = CGSize(width: 0, height: shadow.offset)
        }
        CATransaction.commit()
    }

    private static func envelope(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func animate(_ key: String, values: [Any], on layer: CALayer) {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values
        animation.keyTimes = StitchAccordionAnimation.editorKeyTimes.map { NSNumber(value: Double($0)) }
        // Core Animation must display one connected mesh sample at a time.
        // Interpolating independently decomposed face transforms can separate
        // their shared vertices between the mathematically exact keyframes.
        animation.calculationMode = .discrete
        animation.duration = Self.duration
        layer.add(animation, forKey: key)
    }

    /// A plane's homogeneous coordinates form a linear function of its source triangle.
    /// Discrete animation samples preserve the shared camera denominator and
    /// projected vertices; Core Animation does not interpolate separate planes.
    static func transform(face: StitchAccordionProjection.Face, sourceRect: CGRect,
                          outputBounds: CGRect, size: CGSize, referenceDepth: CGFloat) -> CATransform3D {
        let sx = size.width / outputBounds.width, sy = size.height / outputBounds.height
        let points = face.vertices.map { vertex in
            let point = face.paperSample == nil ? vertex.source : vertex.rest
            return CGPoint(x: point.x * sx - sourceRect.minX, y: point.y * sy - sourceRect.minY)
        }
        let q = face.vertices.map { $0.depth / referenceDepth }
        func coefficients(_ values: [CGFloat]) -> (CGFloat, CGFloat, CGFloat) {
            let a = points[0], b = points[1], c = points[2]
            let dx = b.x - a.x, dy = b.y - a.y, ex = c.x - a.x, ey = c.y - a.y
            let determinant = dx * ey - dy * ex
            let u = ((values[1] - values[0]) * ey - (values[2] - values[0]) * dy) / determinant
            let v = (dx * (values[2] - values[0]) - ex * (values[1] - values[0])) / determinant
            return (u, v, values[0] - u * a.x - v * a.y)
        }
        let x = coefficients(zip(face.vertices, q).map { ($0.0.projected.x - outputBounds.minX) * sx * $0.1 })
        let y = coefficients(zip(face.vertices, q).map { ($0.0.projected.y - outputBounds.minY) * sy * $0.1 })
        let w = coefficients(q)
        var result = CATransform3DIdentity
        result.m11 = x.0; result.m21 = x.1; result.m41 = x.2
        result.m12 = y.0; result.m22 = y.1; result.m42 = y.2
        result.m14 = w.0; result.m24 = w.1; result.m44 = w.2
        return result
    }
}
