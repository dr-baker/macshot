import AppKit

/// Immediate hover label, sharing the same material as its toolbar.
class ScreenshotTooltipView: ScreenshotPanelView {
    private let label = NSTextField(labelWithString: "")
    var text: String {
        get { label.stringValue }
        set { if label.stringValue != newValue { label.stringValue = newValue } }
    }

    var preferredSize: NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: ceil(size.width) + 12, height: ceil(size.height) + 6)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        panelCornerRadius = 4
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        refreshPanelAppearance()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func refreshPanelAppearance() {
        super.refreshPanelAppearance()
        label.textColor = panelForegroundColor
    }
}
