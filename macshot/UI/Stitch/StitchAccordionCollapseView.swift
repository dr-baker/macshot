import AppKit
import QuartzCore

/// A disposable presentation of an already committed cut. The document, undo,
/// clipboard, and saved pixels never depend on animation progress.
@MainActor
final class StitchAccordionCollapseView: NSView {
    struct Snapshot {
        let image: CGImage
        let frame: CGRect
        let documentBounds: CGRect
        let band: StitchDocument.RemovalBand
        let axis: StitchAxis
        let style: StitchStyle
    }

    static let duration: CFTimeInterval = 0.5
    static let maximumTextureDimension: CGFloat = 1600
    private let before: Snapshot
    private let afterImage: CGImage
    private let afterFrame: CGRect
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(before: Snapshot, afterImage: CGImage, afterFrame: CGRect) {
        self.before = before
        self.afterImage = afterImage
        self.afterFrame = afterFrame
        super.init(frame: before.frame.union(afterFrame))
        wantsLayer = true
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func play(completion: @escaping () -> Void) {
        guard let layer, let parent = superview else { completion(); return }
        let from = convert(before.frame, from: parent)
        let to = convert(afterFrame, from: parent)
        let horizontal = before.axis == .horizontal
        let origin = horizontal ? before.documentBounds.minY : before.documentBounds.minX
        let length = horizontal ? before.documentBounds.height : before.documentBounds.width
        let lo = (before.band.range.lowerBound - origin) / length
        let hi = (before.band.range.upperBound - origin) / length
        let fromLength = horizontal ? from.height : from.width
        let toLength = horizontal ? to.height : to.width
        let bandLength = (hi - lo) * fromLength
        guard bandLength > 0 else { completion(); return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        let settled = texture(afterImage, source: CGRect(x: 0, y: 0, width: 1, height: 1), frame: to)
        layer.addSublayer(settled)
        for side in 0..<2 {
            let start = side == 0 ? CGFloat(0) : hi
            let end = side == 0 ? lo : CGFloat(1)
            guard end > start else { continue }
            let source = rectangle(horizontal: horizontal, along: 0, normal: start, alongLength: 1, normalLength: end - start)
            let initial = segment(from, horizontal: horizontal, start: start * fromLength, length: (end - start) * fromLength)
            let finalStart = side == 0 ? CGFloat(0) : lo * fromLength
            let finalLength = side == 0 ? lo * fromLength : toLength - finalStart
            guard finalLength > 0 else { continue }
            let final = segment(to, horizontal: horizontal, start: finalStart, length: finalLength)
            let sheet = texture(before.image, source: source, frame: final)
            layer.addSublayer(sheet)
            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(point: CGPoint(x: initial.midX, y: initial.midY))
            position.toValue = NSValue(point: sheet.position)
            position.duration = Self.duration
            position.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sheet.add(position, forKey: "collapse")
        }

        let stage = CALayer()
        stage.frame = bounds
        stage.name = "accordion.pleats"
        // The flipped NSView already flips its backing layer. Flipping this
        // child again would reflect horizontal pleats across the canvas.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / max(700, bandLength * 4)
        stage.sublayerTransform = perspective
        layer.addSublayer(stage)
        let count = Int(max(2, min(6, before.style.accordionPleats.rounded()))) * 2
        let faceLength = bandLength / CGFloat(count)
        let pixelScale = toLength / (length - before.band.length)
        let targetWidth = min(before.style.accordionWidth * pixelScale, bandLength * 0.22)
        let fractions: [CGFloat] = [0, 0.18, 0.42, 0.70, 1]
        let keyTimes: [NSNumber] = fractions.map { NSNumber(value: Double($0)) }
        let easing: (CGFloat) -> CGFloat = { $0 * $0 * (3 - 2 * $0) }
        for index in 0..<count {
            let initialStart = lo * fromLength + CGFloat(index) * faceLength
            let initial = segment(from, horizontal: horizontal, start: initialStart, length: faceLength)
            let source = rectangle(horizontal: horizontal, along: 0,
                normal: lo + CGFloat(index) * (hi - lo) / CGFloat(count),
                alongLength: 1, normalLength: (hi - lo) / CGFloat(count))
            let face = texture(before.image, source: source, frame: initial)
            face.anchorPoint = horizontal ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
            face.isDoubleSided = false
            let isReturn = index % 2 != 0
            var positions: [NSValue] = [], transforms: [NSValue] = [], heights: [NSNumber] = []
            for fraction in fractions {
                let progress = easing(fraction)
                let ratio = 1 + (targetWidth / bandLength - 1) * progress
                let angle = acos(max(0, min(1, ratio))) * (isReturn ? -1 : 1)
                let initialBase = horizontal ? from.minY + lo * fromLength : from.minX + lo * fromLength
                let finalBase = (horizontal ? to.minY : to.minX) + lo * fromLength - targetWidth / 2
                let normal = initialBase + (finalBase - initialBase) * progress + CGFloat(index) * faceLength * ratio
                let along = (horizontal ? from.midX : from.midY)
                    + ((horizontal ? to.midX : to.midY) - (horizontal ? from.midX : from.midY)) * progress
                positions.append(NSValue(point: horizontal ? CGPoint(x: along, y: normal) : CGPoint(x: normal, y: along)))
                transforms.append(NSValue(caTransform3D: CATransform3DMakeRotation(angle,
                    horizontal ? 1 : 0, horizontal ? 0 : -1, 0)))
                heights.append(NSNumber(value: Double(isReturn ? abs(sin(angle)) * faceLength : 0)))
            }
            face.position = positions.last!.pointValue
            face.transform = transforms.last!.caTransform3DValue
            face.zPosition = CGFloat(heights.last!.doubleValue)
            stage.addSublayer(face)
            for (key, values) in [("position", positions as [Any]), ("transform", transforms as [Any]), ("zPosition", heights as [Any])] {
                let animation = CAKeyframeAnimation(keyPath: key)
                animation.values = values
                animation.keyTimes = keyTimes
                animation.duration = Self.duration
                face.add(animation, forKey: key)
            }
            let light = CAGradientLayer()
            light.frame = face.bounds
            light.startPoint = horizontal ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5)
            light.endPoint = horizontal ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
            light.colors = isReturn
                ? [NSColor.black.withAlphaComponent(0.4).cgColor, NSColor.black.withAlphaComponent(0.08).cgColor]
                : [NSColor.white.withAlphaComponent(0.15).cgColor, NSColor.black.withAlphaComponent(0.2).cgColor]
            face.addSublayer(light)
            let illumination = CABasicAnimation(keyPath: "opacity")
            illumination.fromValue = 0; illumination.toValue = 1
            illumination.duration = Self.duration * 0.7
            light.add(illumination, forKey: "illumination")
        }
        // The folded transient pixels dissolve into the real, sampled seam.
        // No excluded source content survives in the document or output pixels.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.72, 1]
        fade.duration = Self.duration
        stage.opacity = 0
        stage.add(fade, forKey: "settle")
        let reveal = CAKeyframeAnimation(keyPath: "opacity")
        reveal.values = [1, 1, 0]
        reveal.keyTimes = [0, 0.76, 1]
        reveal.duration = Self.duration
        layer.opacity = 0
        layer.add(reveal, forKey: "reveal")
        CATransaction.commit()
    }

    private func texture(_ image: CGImage, source: CGRect, frame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.frame = frame
        layer.contents = image
        layer.contentsRect = source
        layer.contentsGravity = .resize
        layer.masksToBounds = true
        return layer
    }

    private func segment(_ rect: CGRect, horizontal: Bool, start: CGFloat, length: CGFloat) -> CGRect {
        horizontal ? CGRect(x: rect.minX, y: rect.minY + start, width: rect.width, height: length)
            : CGRect(x: rect.minX + start, y: rect.minY, width: length, height: rect.height)
    }

    private func rectangle(horizontal: Bool, along: CGFloat, normal: CGFloat, alongLength: CGFloat, normalLength: CGFloat) -> CGRect {
        horizontal ? CGRect(x: along, y: normal, width: alongLength, height: normalLength)
            : CGRect(x: normal, y: along, width: normalLength, height: alongLength)
    }
}
