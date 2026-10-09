import AppKit

/// Presentation stays separate from the flat editing canvas and native annotation tools.
@MainActor
final class StitchPaperPreviewView: NSView {
    var onEdit: (() -> Void)?
    var image: NSImage? {
        didSet {
            if image == nil { progress.startAnimation(nil) }
            else { progress.stopAnimation(nil) }
            progress.isHidden = image != nil
            needsDisplay = true
        }
    }
    private let progress = NSProgressIndicator()
    private var animation: StitchAccordionCollapseView?
    private var animationBackground: NSImage?
    override var acceptsFirstResponder: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        addSubview(progress)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L("Folded screenshot preview"))
        setAccessibilityHelp(L("Click the paper to unfold and edit."))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        progress.frame = CGRect(x: bounds.midX - 8, y: bounds.midY - 8, width: 16, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        // An opaque editor backdrop also keeps a pending redaction from revealing an older raw image.
        NSColor(white: 0.15, alpha: 1).setFill()
        bounds.fill()
        let visibleImage = animation == nil ? image : animationBackground
        visibleImage?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }
    func animate(texture: CGImage, document: StitchDocument, frame: CGRect, background: CGImage?) {
        cancelAnimation()
        guard let effect = StitchAccordionCollapseView(texture: texture, document: document, frame: frame) else { return }
        animation = effect
        animationBackground = background.map { NSImage(cgImage: $0, size: bounds.size) }
        addSubview(effect)
        needsDisplay = true
        effect.play { [weak self, weak effect] in
            guard self?.animation === effect else { return }
            self?.cancelAnimation()
        }
    }
    func cancelAnimation() {
        let old = animation
        animation = nil
        old?.layer?.sublayers?.forEach { $0.removeAllAnimations() }
        old?.removeFromSuperview()
        animationBackground = nil
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) { onEdit?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
