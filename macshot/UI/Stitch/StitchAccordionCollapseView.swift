import AppKit
import CoreImage
import QuartzCore

/// A bounded, disposable animation of the same textured faces used by the export renderer.
@MainActor
final class StitchAccordionCollapseView: NSView {
    static let duration: CFTimeInterval = 0.48
    static let maximumTextureDimension: CGFloat = 1600
    private let texture: CGImage
    private var plans: [StitchAccordionProjection]
    private var outputBounds: CGRect
    private var faceLayers: [Int: CALayer] = [:]
    private struct PaperSampleKey: Hashable {
        let x: CGFloat
        let y: CGFloat
        init(_ point: CGPoint) { x = point.x; y = point.y }
    }
    private var paperColors: [PaperSampleKey: CGColor] = [:]
    private let interactive: Bool
    private static let fractions: [CGFloat] = [0, 0.2, 0.45, 0.72, 1]
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init?(texture: CGImage, document: StitchDocument, frame: CGRect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              texture.width <= Int(Self.maximumTextureDimension), texture.height <= Int(Self.maximumTextureDimension) else { return nil }
        guard let source = StitchAccordionProjection.Source(document: document) else { return nil }
        let plans = Self.fractions.compactMap { StitchAccordionProjection(source: source, progress: $0) }
        guard plans.count == Self.fractions.count, let final = plans.last, final.hasProjectedOutput,
              final.faces.count <= 512, plans.allSatisfy({ $0.faces.count == final.faces.count }) else { return nil }
        self.texture = texture
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

    /// Orbiting updates only textured face transforms and lighting. Reduce Motion
    /// removes the folding animation, while direct manipulation remains available.
    init?(interactiveTexture texture: CGImage, projection: StitchAccordionProjection, frame: CGRect) {
        guard texture.width <= Int(Self.maximumTextureDimension),
              texture.height <= Int(Self.maximumTextureDimension),
              projection.hasProjectedOutput, projection.faces.count <= 512,
              frame.width > 0, frame.height > 0 else { return nil }
        self.texture = texture
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
              frame.width > 0, frame.height > 0 else { return false }
        self.frame = frame
        plans = [projection]
        outputBounds = projection.outputBounds
        renderFaces(animated: false)
        return true
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
        for index in final.drawingOrder {
            let face = final.faces[index]
            // Inserted paper has a degenerate UV triangle at the cut. Its full
            // rest coordinates provide the nondegenerate local material plane.
            let localPoints = face.vertices.map { vertex in
                let point = face.paperSample == nil ? vertex.source : vertex.rest
                return CGPoint(x: point.x * scaleX, y: point.y * scaleY)
            }
            let sourceRect = Self.envelope(localPoints)
            guard sourceRect.width > 0, sourceRect.height > 0 else { continue }
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
            if let sample = face.paperSample {
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
                let uvRect = Self.envelope(face.vertices.map(\.source))
                sheet.backgroundColor = nil
                sheet.contents = texture
                sheet.contentsRect = CGRect(x: (uvRect.minX - documentBounds.minX) / documentBounds.width,
                    y: (uvRect.minY - documentBounds.minY) / documentBounds.height,
                    width: uvRect.width / documentBounds.width, height: uvRect.height / documentBounds.height)
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
            if animated {
                animate("transform", values: transforms.map { NSValue(caTransform3D: $0) }, on: sheet)
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
        animation.keyTimes = Self.fractions.map { NSNumber(value: Double($0)) }
        animation.timingFunctions = (1..<values.count).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
        animation.duration = Self.duration
        layer.add(animation, forKey: key)
    }

    /// A plane's homogeneous coordinates form a linear function of its source triangle.
    /// The shared camera denominator keeps neighbouring layers joined throughout interpolation.
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
