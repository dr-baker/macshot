import AppKit

/// Capture instruction text above the shared material, with no input interception.
final class ScreenshotTextPanelView: ScreenshotPanelView {
    struct TextRun: Equatable {
        var text: String
        var origin: NSPoint
        var font: NSFont
        var alpha: CGFloat = 1
        var color: NSColor?
    }

    var textRuns: [TextRun] {
        get { artwork.textRuns }
        set {
            if artwork.textRuns != newValue {
                artwork.textRuns = newValue
                artwork.needsDisplay = true
            }
        }
    }
    /// Sibling controls can share this panel's cached foreground without moving
    /// their hit-testing or layout into the noninteractive text surface.
    var onForegroundChange: ((NSColor) -> Void)? {
        didSet { onForegroundChange?(panelForegroundColor) }
    }
    private let artwork = TextArtworkView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        artwork.panel = self
        artwork.frame = bounds
        artwork.autoresizingMask = [.width, .height]
        artwork.setAccessibilityElement(false)
        addSubview(artwork)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        artwork.frame = bounds
    }
    override func refreshPanelAppearance() {
        super.refreshPanelAppearance()
        artwork.needsDisplay = true
        onForegroundChange?(panelForegroundColor)
    }
}

private final class TextArtworkView: NSView {
    weak var panel: ScreenshotTextPanelView?
    var textRuns: [ScreenshotTextPanelView.TextRun] = []

    override func draw(_ dirtyRect: NSRect) {
        let foreground = panel?.panelForegroundColor ?? ToolbarLayout.iconColor
        for run in textRuns {
            (run.text as NSString).draw(at: run.origin, withAttributes: [
                .font: run.font,
                .foregroundColor: (run.color ?? foreground).withAlphaComponent(run.alpha),
            ])
        }
    }
}
