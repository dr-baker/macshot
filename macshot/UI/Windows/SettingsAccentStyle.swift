import AppKit

/// Apply the Settings accent through public AppKit color hooks. AppKit retains
/// its native control artwork, keyboard handling and disabled presentation.
@MainActor
enum SettingsAccentStyle {
    private static let checkboxes = NSHashTable<NSButton>.weakObjects()

    static func checkbox(title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: target, action: action)
        checkboxes.add(button)
        return button
    }

    private static let originals = NSMapTable<NSView, OriginalColors>.weakToStrongObjects()

    static func apply(to view: NSView) {
        apply(to: view, accentColor: ToolbarLayout.usesSystemAccent ? nil : ToolbarLayout.accentColor)
    }

    /// Nil restores native styling. The explicit color also supports isolated tests.
    static func apply(to view: NSView, accentColor: NSColor?) {
        // Screenshot previews own their contrast and accent treatment.
        guard !(view is ScreenshotPanelView) else { return }
        if let slider = view as? NSSlider {
            update(slider, accentColor: accentColor) { _ in
                slider.trackFillColor = accentColor
            }
            return
        }
        if let segments = view as? NSSegmentedControl {
            update(segments, accentColor: accentColor) { _ in
                segments.selectedSegmentBezelColor = accentColor
            }
            return
        }
        if let button = view as? NSButton {
            update(button, accentColor: accentColor) { colors in
                if button.isBordered || checkboxes.contains(button) {
                    // AppKit decides which button appearances support bezel tint.
                    button.bezelColor = accentColor
                } else {
                    // Explicit tints may identify links or semantic actions.
                    button.contentTintColor = colors.buttonContent ?? accentColor
                }
            }
            return
        }
        // Avoid traversing private control implementation views such as NSSwitch.
        guard !(view is NSControl) else { return }
        for child in view.subviews { apply(to: child, accentColor: accentColor) }
    }

    private static func update(_ view: NSView, accentColor: NSColor?,
                               applyCustom: (OriginalColors) -> Void) {
        guard accentColor != nil else {
            guard let colors = originals.object(forKey: view) else { return }
            if let slider = view as? NSSlider { slider.trackFillColor = colors.sliderFill }
            if let segments = view as? NSSegmentedControl { segments.selectedSegmentBezelColor = colors.segmentFill }
            if let button = view as? NSButton {
                button.bezelColor = colors.buttonBezel
                button.contentTintColor = colors.buttonContent
            }
            originals.removeObject(forKey: view)
            return
        }
        let colors: OriginalColors
        if let saved = originals.object(forKey: view) {
            colors = saved
        } else {
            colors = OriginalColors(view)
            originals.setObject(colors, forKey: view)
        }
        applyCustom(colors)
    }

    private final class OriginalColors: NSObject {
        let sliderFill: NSColor?
        let segmentFill: NSColor?
        let buttonBezel: NSColor?
        let buttonContent: NSColor?

        init(_ view: NSView) {
            sliderFill = (view as? NSSlider)?.trackFillColor
            segmentFill = (view as? NSSegmentedControl)?.selectedSegmentBezelColor
            buttonBezel = (view as? NSButton)?.bezelColor
            buttonContent = (view as? NSButton)?.contentTintColor
            super.init()
        }
    }
}
