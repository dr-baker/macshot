import AppKit

/// Native preference-tab input with app-owned icon and label colors.
final class SettingsToolbarButton: NSButton {
    let itemIdentifier: NSToolbarItem.Identifier
    var isSelectedTab = false {
        didSet { refreshAppearance() }
    }

    init(itemIdentifier: NSToolbarItem.Identifier, title: String, image: NSImage?,
         target: AnyObject?, action: Selector?) {
        self.itemIdentifier = itemIdentifier
        super.init(frame: .zero)
        self.title = title
        self.image = image
        self.target = target
        self.action = action
        font = .systemFont(ofSize: 11)
        imagePosition = .imageAbove
        imageScaling = .scaleProportionallyDown
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 21, weight: .regular)
        setButtonType(.momentaryChange)
        isBordered = false
        focusRingType = .exterior
        setAccessibilityLabel(title)
        setAccessibilitySubrole(.tabButtonSubrole)
        toolTip = title
        setFrameSize(intrinsicContentSize)
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("Use init(itemIdentifier:title:image:target:action:)") }

    func makeToolbarItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = title
        item.paletteLabel = title
        item.view = self
        // Setting an item's action after its view would replace the button's action.
        let overflow = NSMenuItem(title: title, action: #selector(activateFromOverflow(_:)), keyEquivalent: "")
        overflow.target = self
        overflow.image = image
        item.menuFormRepresentation = overflow
        return item
    }

    @objc private func activateFromOverflow(_ sender: NSMenuItem) { performClick(nil) }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11)]).width
        return NSSize(width: max(58, ceil(width) + 16), height: 54)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    func refreshAppearance() {
        var background = NSColor.windowBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor
        }
        if isSelectedTab, let accent = ScreenshotThemeRGB(color: ToolbarLayout.accentColor),
           let surface = ScreenshotThemeRGB(color: background) {
            contentTintColor = ScreenshotThemeForeground.readableAccent(accent, on: surface).nsColor
        } else {
            contentTintColor = .secondaryLabelColor
        }
        setAccessibilityValue(isSelectedTab ? 1 : 0)
        setAccessibilitySelected(isSelectedTab)
        needsDisplay = true
    }

}
