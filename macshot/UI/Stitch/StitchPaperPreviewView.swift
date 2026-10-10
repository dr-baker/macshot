import AppKit
import QuartzCore

/// Presentation stays separate from the flat editing canvas and native annotation tools.
@MainActor
final class StitchPaperPreviewView: NSView {
    var onEdit: (() -> Void)?
    var onCameraBegin: (() -> Void)?
    var onCameraChanged: ((StitchPaperCamera) -> Void)?
    var onCameraEnd: ((Bool) -> Void)?
    var onReset: (() -> Void)?
    var camera = StitchPaperCamera()
    var projection: StitchAccordionProjection?
    var paperFrame: CGRect?
    var isShowingInteractivePaper: Bool { interactivePaper != nil }
    var image: NSImage? {
        didSet {
            // A nil image clears stale pixels during annotation/redaction changes.
            // A replacement image also retires the live mesh after the final raster finishes.
            clearInteractivePaper()
            if image == nil { cancelAnimation() }
            if image == nil { progress.startAnimation(nil) }
            else { progress.stopAnimation(nil) }
            progress.isHidden = image != nil
            needsDisplay = true
        }
    }
    private let progress = NSProgressIndicator()
    private var animation: StitchAccordionCollapseView?
    private var animationBackground: NSImage?
    private var animationBackdrop: CALayer?
    private var interactivePaper: StitchAccordionCollapseView?
    private var interactiveBackground: NSImage?
    private var mouseOrigin: CGPoint?
    private var gestureCamera: StitchPaperCamera?
    private var isOrbiting = false
    private var hasCameraChanges = false
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        addSubview(progress)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L("Folded screenshot preview"))
        setAccessibilityHelp(L("Drag the paper to change the view angle. Double-click to reset."))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func isAccessibilityElement() -> Bool { !isHiddenOrHasHiddenAncestor }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { L("Folded screenshot preview") }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard onReset != nil else { return [] }
        return [NSAccessibilityCustomAction(name: L("Reset view angle")) { [weak self] in
            guard let self, !self.isHiddenOrHasHiddenAncestor,
                  self.image != nil || self.interactivePaper != nil, let reset = self.onReset else { return false }
            reset()
            return true
        }]
    }

    override func layout() {
        super.layout()
        progress.frame = CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        // An opaque editor backdrop also keeps a pending redaction from revealing an older raw image.
        NSColor(white: 0.15, alpha: 1).setFill()
        bounds.fill()
        let visibleImage = interactivePaper != nil ? interactiveBackground : (animation == nil ? image : animationBackground)
        visibleImage?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }
    func animate(texture: CGImage, document: StitchDocument, frame: CGRect, background: CGImage?, viewport: CGRect? = nil,
                 preparedSource: StitchAccordionProjection.Source? = nil) {
        cancelAnimation()
        clearInteractivePaper()
        guard let effect = StitchAccordionCollapseView(texture: texture, document: document, frame: frame,
            preparedSource: preparedSource) else { return }
        let available = viewport ?? animationViewport
        let backgroundFrame = effect.frame.insetBy(dx: -ScreenshotPresentation.paperPadding,
            dy: -ScreenshotPresentation.paperPadding)
        guard available?.contains(backgroundFrame) != false else { return }
        // The opening sheet can be much wider than its final screenshot. Extend
        // only this disposable animation surface, leaving editor geometry fixed.
        wantsLayer = true
        layer?.masksToBounds = false
        if #available(macOS 14.0, *) { clipsToBounds = false }
        animation = effect
        animationBackground = background.map { NSImage(cgImage: $0, size: bounds.size) }
        let backdrop = CALayer()
        backdrop.name = "stitch.accordion.backdrop"
        backdrop.frame = backgroundFrame
        backdrop.masksToBounds = true
        backdrop.contents = background
        backdrop.contentsGravity = .resizeAspectFill
        backdrop.backgroundColor = NSColor(white: 0.15, alpha: 1).cgColor
        animationBackdrop = backdrop
        layer?.addSublayer(backdrop)
        addSubview(effect)
        needsDisplay = true
        effect.play { [weak self, weak effect] in
            guard self?.animation === effect else { return }
            self?.cancelAnimation()
        }
    }

    private var animationViewport: CGRect? {
        if let clip = enclosingScrollView?.contentView { return convert(clip.bounds, from: clip) }
        if let content = window?.contentView { return convert(content.bounds, from: content) }
        return nil
    }

    /// The host caches an effected, fully composited texture before starting an orbit.
    /// Updating the camera reuses its face layers and immutable background.
    @discardableResult
    func showInteractivePaper(texture: CGImage, document: StitchDocument, frame: CGRect, background: CGImage?) -> Bool {
        guard let projection = StitchAccordionProjection(document: document) else { return false }
        return showInteractivePaper(texture: texture, projection: projection, frame: frame, background: background)
    }

    @discardableResult
    func showInteractivePaper(texture: CGImage, projection: StitchAccordionProjection, frame: CGRect, background: CGImage?) -> Bool {
        cancelAnimation()
        if let current = interactivePaper, current.uses(texture: texture),
           current.updateInteractive(projection: projection, frame: frame) {
            self.projection = projection
            paperFrame = frame
            return true
        }
        guard let effect = StitchAccordionCollapseView(interactiveTexture: texture, projection: projection, frame: frame) else { return false }
        clearInteractivePaper()
        self.projection = projection
        paperFrame = frame
        interactivePaper = effect
        interactiveBackground = background.map { NSImage(cgImage: $0, size: bounds.size) }
        progress.stopAnimation(nil)
        progress.isHidden = true
        addSubview(effect)
        needsDisplay = true
        return true
    }

    private func clearInteractivePaper() {
        interactivePaper?.removeFromSuperview()
        interactivePaper = nil
        interactiveBackground = nil
    }

    func cancelAnimation() {
        let old = animation
        animation = nil
        old?.layer?.sublayers?.forEach { $0.removeAllAnimations() }
        old?.removeFromSuperview()
        animationBackdrop?.removeFromSuperlayer()
        animationBackdrop = nil
        animationBackground = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard containsPaper(at: point) else { return }
        if event.clickCount > 1 {
            cancelCameraGesture()
            onReset?()
            return
        }
        mouseOrigin = point
        gestureCamera = camera
        isOrbiting = false
        hasCameraChanges = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseOrigin, let initial = gestureCamera else { return }
        let point = convert(event.locationInWindow, from: nil)
        let delta = CGPoint(x: point.x - origin.x, y: isFlipped ? point.y - origin.y : origin.y - point.y)
        guard isOrbiting || hypot(delta.x, delta.y) >= 3 else { return }
        if !isOrbiting {
            isOrbiting = true
            onCameraBegin?()
            NSCursor.closedHand.set()
        }
        let next = initial.dragged(by: delta, precision: event.modifierFlags.contains(.option),
                                   axisLock: event.modifierFlags.contains(.shift))
        guard next != camera else { return }
        camera = next
        hasCameraChanges = next != initial
        onCameraChanged?(next)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseOrigin != nil else { return }
        let wasOrbiting = isOrbiting
        let changed = hasCameraChanges
        resetGesture()
        if wasOrbiting { onCameraEnd?(changed) }
        window?.invalidateCursorRects(for: self)
    }

    /// Called by the editor command owner when Escape cancels an active orbit.
    @discardableResult
    func cancelCameraGesture() -> Bool {
        guard mouseOrigin != nil else { return false }
        let initial = gestureCamera
        let wasOrbiting = isOrbiting
        resetGesture()
        if wasOrbiting {
            if let initial, initial != camera {
                camera = initial
                onCameraChanged?(initial)
            }
            onCameraEnd?(false)
        }
        window?.invalidateCursorRects(for: self)
        return true
    }

    private func resetGesture() {
        mouseOrigin = nil
        gestureCamera = nil
        isOrbiting = false
        hasCameraChanges = false
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { _ = cancelCameraGesture() }
        super.viewWillMove(toWindow: newWindow)
    }

    func containsPaper(at point: CGPoint) -> Bool {
        guard image != nil || interactivePaper != nil, let frame = paperFrame,
              frame.width > 0, frame.height > 0, frame.contains(point), let projection else { return false }
        let bounds = projection.outputBounds
        let mapped = CGPoint(x: bounds.minX + (point.x - frame.minX) * bounds.width / frame.width,
            y: bounds.minY + (isFlipped ? point.y - frame.minY : frame.maxY - point.y) * bounds.height / frame.height)
        return projection.unproject(mapped) != nil
    }

    override func resetCursorRects() {
        if let paperFrame { addCursorRect(paperFrame.intersection(bounds), cursor: isOrbiting ? .closedHand : .openHand) }
    }
}
