import AppKit
import CoreImage
import QuartzCore

/// A bounded, disposable animation of the same textured faces used by the export renderer.
@MainActor
final class StitchAccordionCollapseView: NSView {
    static let duration: CFTimeInterval = 0.48
    static let maximumTextureDimension: CGFloat = 1600
    private let texture: CGImage
    private let plans: [StitchAccordionProjection]
    private static let fractions: [CGFloat] = [0, 0.2, 0.45, 0.72, 1]
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init?(texture: CGImage, document: StitchDocument, frame: CGRect) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              texture.width <= Int(Self.maximumTextureDimension), texture.height <= Int(Self.maximumTextureDimension) else { return nil }
        let plans = Self.fractions.compactMap { StitchAccordionProjection(document: document, progress: $0) }
        guard plans.count == Self.fractions.count, let final = plans.last, final.hasProjectedOutput,
              final.faces.count <= 512, plans.allSatisfy({ $0.faces.count == final.faces.count }) else { return nil }
        self.texture = texture
        self.plans = plans
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func play(completion: @escaping () -> Void) {
        guard let layer, let final = plans.last, let first = plans.first else { completion(); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        let documentBounds = final.documentBounds
        let scaleX = bounds.width / documentBounds.width, scaleY = bounds.height / documentBounds.height
        let referenceDepth = first.faces.first?.a.depth ?? 1
        for index in final.drawingOrder {
            let face = final.faces[index]
            let source = face.vertices.map {
                CGPoint(x: ($0.source.x - documentBounds.minX) * scaleX,
                        y: ($0.source.y - documentBounds.minY) * scaleY)
            }
            let sourceRect = CGRect(x: source.map(\.x).min()!, y: source.map(\.y).min()!,
                width: source.map(\.x).max()! - source.map(\.x).min()!,
                height: source.map(\.y).max()! - source.map(\.y).min()!)
            guard sourceRect.width > 0, sourceRect.height > 0 else { continue }
            let sheet = CALayer()
            sheet.name = "accordion.face.\(index)"
            sheet.bounds = CGRect(origin: .zero, size: sourceRect.size)
            sheet.anchorPoint = .zero
            sheet.position = .zero
            sheet.contents = texture
            sheet.contentsRect = CGRect(x: sourceRect.minX / bounds.width, y: sourceRect.minY / bounds.height,
                width: sourceRect.width / bounds.width, height: sourceRect.height / bounds.height)
            sheet.contentsGravity = .resize
            let mask = CAShapeLayer()
            mask.frame = sheet.bounds
            let path = CGMutablePath()
            path.addLines(between: source.map { CGPoint(x: $0.x - sourceRect.minX, y: $0.y - sourceRect.minY) })
            path.closeSubpath()
            mask.path = path
            mask.fillColor = NSColor.black.cgColor
            // Cover shared triangle antialiasing pixels so flat faces never show diagonal mesh cracks.
            mask.strokeColor = NSColor.black.cgColor
            mask.lineWidth = 0.8
            sheet.mask = mask
            let transforms = plans.map {
                Self.transform(face: $0.faces[index], sourceRect: sourceRect,
                    documentBounds: documentBounds, size: bounds.size, referenceDepth: referenceDepth)
            }
            sheet.transform = transforms.last!
            sheet.opacity = face.isFrontFacing ? 1 : 0
            layer.addSublayer(sheet)
            animate("transform", values: transforms.map { NSValue(caTransform3D: $0) }, on: sheet)
            animate("opacity", values: plans.map { NSNumber(value: $0.faces[index].isFrontFacing ? 1 : 0) }, on: sheet)
            // Multiply printed RGB, including highlights, while leaving source alpha unchanged.
            // A color overlay would brighten dark paper differently and fill transparent holes.
            if let lighting = CIFilter(name: "CIColorMatrix") {
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
                for parameter in parameters {
                    animate("filters.paperLighting.\(parameter.key)", values: parameter.values, on: sheet)
                }
            }
        }
        CATransaction.commit()
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
                          documentBounds: CGRect, size: CGSize, referenceDepth: CGFloat) -> CATransform3D {
        let sx = size.width / documentBounds.width, sy = size.height / documentBounds.height
        let points = face.vertices.map {
            CGPoint(x: ($0.source.x - documentBounds.minX) * sx - sourceRect.minX,
                    y: ($0.source.y - documentBounds.minY) * sy - sourceRect.minY)
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
        let x = coefficients(zip(face.vertices, q).map { ($0.0.projected.x - documentBounds.minX) * sx * $0.1 })
        let y = coefficients(zip(face.vertices, q).map { ($0.0.projected.y - documentBounds.minY) * sy * $0.1 })
        let w = coefficients(q)
        var result = CATransform3DIdentity
        result.m11 = x.0; result.m21 = x.1; result.m41 = x.2
        result.m12 = y.0; result.m22 = y.1; result.m42 = y.2
        result.m14 = w.0; result.m24 = w.1; result.m44 = w.2
        return result
    }
}
