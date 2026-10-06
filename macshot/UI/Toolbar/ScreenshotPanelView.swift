import AppKit

/// Move focus before removing or hiding the view that currently owns it.
@MainActor
enum ScreenshotKeyboardFocus {
    static func editingView(in window: NSWindow) -> NSView? {
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            return editor.delegate as? NSView
        }
        return window.firstResponder as? NSView
    }

    @discardableResult
    static func moveIfOwned(by owner: NSView, to fallback: NSResponder) -> Bool {
        guard let window = owner.window,
              editingView(in: window)?.isDescendant(of: owner) == true else { return false }
        if let view = fallback as? NSView, view.window !== window { return false }
        return window.makeFirstResponder(fallback)
    }
}

/// A shared background inside the existing screenshot control hierarchy.
/// Changing appearance never recreates a control or adds a window.
class ScreenshotPanelView: NSView {
    var panelCornerRadius: CGFloat = ToolbarLayout.cornerRadius {
        didSet { if oldValue != panelCornerRadius { applyPanelBackground() } }
    }

    /// A local override for the material preview; ordinary panels use the toolbar theme.
    var panelAppearanceOverride: NSAppearance? {
        didSet { refreshPanelAppearance() }
    }

    private var cachedForeground = ToolbarLayout.iconColor
    var panelForegroundColor: NSColor { cachedForeground }
    var panelSelectedForegroundColor: NSColor {
        ScreenshotPanelContrast.foregroundColor(on: ToolbarLayout.accentColor)
    }

    let glassIdentity = UUID().uuidString
    /// Only the drawing controls and their submenus participate in native joins.
    /// Hover labels, image chrome, and status panels remain separate surfaces.
    var joinsAdjacentGlass: Bool { false }
    var glassUnionIdentity: String?
    private(set) var renderedGlassConfiguration: ScreenshotGlassConfiguration?
    private(set) var materialAppearanceName: NSAppearance.Name?
    private weak var glassGroup: ScreenshotGlassGroupView?
    private var glassContainer: NSView? { window?.contentView === self ? self : superview }
    /// Submenus request insertion/removal morphs; ordinary layout follows the pointer.
    var animatesGlassPresentation = false

    private var style: ScreenshotPanelStyle { ScreenshotPanelAppearance.shared.style }
    private var isApplyingBackground = false
    private var didInitializePanel = false
    private let decorationView = ScreenshotPanelBackgroundView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Keep foreground drawing above the sibling SwiftUI backdrop. An
        // unbacked view can otherwise flatten its text into the sampled canvas.
        wantsLayer = true
        decorationView.setAccessibilityElement(false)
        decorationView.autoresizingMask = [.width, .height]
        addSubview(decorationView, positioned: .below, relativeTo: nil)
        applyPanelBackground()
        didInitializePanel = true
        ScreenshotPanelAppearance.shared.register(self)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        decorationView.frame = bounds
        glassGroup?.invalidate()
    }

    override var frame: NSRect {
        didSet {
            if oldValue != frame { glassGroup?.invalidate() }
        }
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let changed = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        if changed { glassGroup?.invalidate() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { glassGroup?.invalidate() }
    }

    override var isHidden: Bool {
        didSet {
            if oldValue != isHidden { glassGroup?.invalidate() }
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        glassGroup?.remove(self)
        glassGroup = renderedGlassConfiguration == nil ? nil : glassContainer.map { ScreenshotGlassGroupView.attach(self, to: $0) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if didInitializePanel { refreshPanelAppearance() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if didInitializePanel && !isApplyingBackground { refreshPanelAppearance() }
    }

    /// Subclasses refresh their existing foreground controls after calling super.
    func refreshPanelAppearance() {
        applyPanelBackground()
        needsDisplay = true
    }

    /// Tool changes replace only content, keeping one mounted material view.
    func removePanelContentSubviews() {
        for view in subviews where view !== decorationView {
            if view is ScreenshotGlassGroupView { continue }
            view.removeFromSuperview()
        }
    }

    private func refreshNeutralContentColors(in view: NSView) {
        for child in view.subviews where child !== decorationView {
            if child is ScreenshotPanelView { continue }
            if let field = child as? NSTextField, let color = field.textColor?.usingColorSpace(.sRGB),
               abs(color.redComponent - color.greenComponent) < 0.05,
               abs(color.greenComponent - color.blueComponent) < 0.05 {
                field.textColor = cachedForeground.withAlphaComponent(field.isEnabled ? 1 : 0.35)
            }
            if let button = child as? NSButton {
                if let color = button.contentTintColor?.usingColorSpace(.sRGB) {
                    if abs(color.redComponent - color.greenComponent) < 0.05,
                       abs(color.greenComponent - color.blueComponent) < 0.05 {
                        button.contentTintColor = cachedForeground.withAlphaComponent(button.isEnabled ? 1 : 0.35)
                    }
                } else { button.contentTintColor = cachedForeground }
            }
            child.needsDisplay = true
            refreshNeutralContentColors(in: child)
        }
    }

    private func applyPanelBackground() {
        guard !isApplyingBackground else { return }
        isApplyingBackground = true
        defer { isApplyingBackground = false }
        var configuration = style.glassConfiguration
        let supportedWindow = window == nil || window is ScreenshotGlassWindow || window is ScreenshotGlassPanel
        if !supportedWindow || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            configuration = nil
        }
        let materialAppearance = panelAppearanceOverride ?? ToolbarLayout.appearance
        decorationView.frame = bounds
        decorationView.cornerRadius = panelCornerRadius
        materialAppearanceName = materialAppearance?.name
        // Classic and accessibility fallbacks have an exact opaque color. Clear
        // estimates contrast from the same tint without sampling the screenshot.
        let palette = ToolbarLayout.palette(for: materialAppearance ?? NSApp.effectiveAppearance)
        let contrast = ScreenshotPanelContrast.resolve(style: style, baseColor: palette.bg, themeColor: palette.bg)
        configuration?.tint = style.resolvedTint(themeColor: palette.bg)
        cachedForeground = contrast.foregroundColor
        // Native control colors follow the chosen foreground; material appearance
        // remains independent so a light tint does not change the selected recipe.
        let foregroundAppearance = NSAppearance(named: contrast.appearanceName)
        if appearance?.name != foregroundAppearance?.name { appearance = foregroundAppearance }
        refreshNeutralContentColors(in: self)
        decorationView.backgroundColor = contrast.backgroundColor
        configuration?.cornerRadius = max(0, panelCornerRadius)
        renderedGlassConfiguration = configuration
        if configuration != nil, let parent = glassContainer, glassGroup?.superview !== parent {
            glassGroup?.remove(self)
            glassGroup = ScreenshotGlassGroupView.attach(self, to: parent)
        }
        decorationView.isHidden = configuration != nil
        decorationView.needsDisplay = true
        glassGroup?.invalidate()
        if let window = window as? ScreenshotGlassWindow { window.glassAlwaysActive = configuration != nil }
        else if let panel = window as? ScreenshotGlassPanel { panel.glassAlwaysActive = configuration != nil }
    }
}

/// One runtime snapshot reads the app-owned preference and updates live panels.
/// Weak registration lets transient capture controls disappear normally.
@MainActor
private final class ScreenshotPanelAppearance: NSObject {
    static let shared = ScreenshotPanelAppearance()
    private(set) var style = ScreenshotPanelStyle.load()
    private let panels = NSHashTable<ScreenshotPanelView>.weakObjects()
    private var systemAppearanceObservation: NSKeyValueObservation?

    private override init() {
        super.init()
        systemAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            // The system source stays independent of each panel's explicit glyph appearance.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(systemColorsChanged),
            name: NSColor.systemColorsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(materialChanged),
            name: ScreenshotPanelStyle.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
            name: .toolbarColorsDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(themeChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    func register(_ panel: ScreenshotPanelView) { panels.add(panel) }

    @objc private func materialChanged() {
        style = ScreenshotPanelStyle.load()
        // Every view reads the same snapshot when a window appearance refresh
        // traverses its children.
        for panel in panels.allObjects { panel.refreshPanelAppearance() }
    }

    @objc private func systemColorsChanged() {
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
    }

    @objc private func themeChanged() {
        for panel in panels.allObjects { panel.refreshPanelAppearance() }
    }
}

private final class ScreenshotPanelBackgroundView: NSView {
    var cornerRadius: CGFloat = ToolbarLayout.cornerRadius
    var backgroundColor = ToolbarLayout.bgColor
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
}

extension NSView {
    /// Custom picker drawing inherits the panel's cached neutral foreground.
    var screenshotForegroundColor: NSColor {
        var ancestor: NSView? = self
        while let view = ancestor {
            if let panel = view as? ScreenshotPanelView { return panel.panelForegroundColor }
            ancestor = view.superview
        }
        // Native popovers use their own material rather than the toolbar background.
        var color = NSColor.labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance { color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor }
        return color.withAlphaComponent(1)
    }
}
