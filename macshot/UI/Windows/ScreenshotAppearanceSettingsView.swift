import AppKit

/// The production appearance controls, backed by the same panels used during capture.
final class ScreenshotAppearanceSettingsView: NSView {
    private let material = NSSegmentedControl(labels: ScreenshotPanelStyle.Material.allCases.map { L($0.title) },
        trackingMode: .selectOne, target: nil, action: nil)
    private let colorMode = NSSegmentedControl(labels: [L("System"), L("Light"), L("Dark")],
        trackingMode: .selectOne, target: nil, action: nil)
    private let systemAccent = SettingsAccentStyle.checkbox(title: L("Use macOS accent color"), target: nil, action: nil)
    private let tintSource = NSPopUpButton()
    private let tintColor = NSColorWell()
    private let tintAmount = NSSlider()
    private let tintValue = NSTextField(labelWithString: "")
    private let materialNote = NSTextField(wrappingLabelWithString: "")
    private let preview = ScreenshotAppearancePreviewView(frame: .zero)

    private enum TintSource: Int { case theme, custom, none }

    init(themeControls: NSView) {
        super.init(frame: .zero)
        buildControls(themeControls: themeControls)
        refreshControls()
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
            name: ScreenshotPanelStyle.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
            name: .toolbarColorsDidChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appearanceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func buildControls(themeControls: NSView) {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let stack = AppearanceSettingsStack()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
        ])

        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.identifier = .init("screenshot.appearance.preview")
        stack.addArrangedSubview(preview)
        stack.setCustomSpacing(18, after: preview)

        let heading = Self.sectionHeading(L("Screenshot controls"))
        let reset = NSButton(title: L("Reset"), target: self, action: #selector(resetAppearance))
        reset.bezelStyle = .inline
        reset.controlSize = .small
        reset.identifier = .init("screenshot.appearance.reset")
        reset.toolTip = L("Restore Clear glass with your theme background tint")
        let headingRow = Self.horizontal([heading, Self.spacer(), reset])
        stack.addArrangedSubview(headingRow)
        stack.setCustomSpacing(8, after: headingRow)

        colorMode.segmentStyle = .rounded
        colorMode.identifier = .init("screenshot.appearance.colorMode")
        colorMode.target = self
        colorMode.action = #selector(colorModeChanged)
        colorMode.setAccessibilityLabel(L("Appearance"))
        for index in 0..<3 { colorMode.setWidth(72, forSegment: index) }
        stack.addArrangedSubview(Self.settingsRow(L("Appearance"), controls: [colorMode]))

        material.segmentStyle = .rounded
        material.identifier = .init("screenshot.appearance.material")
        material.target = self
        material.action = #selector(materialChanged)
        material.setAccessibilityLabel(L("Screenshot panel style"))
        for index in 0..<3 { material.setWidth(85, forSegment: index) }
        stack.addArrangedSubview(Self.settingsRow(L("Style"), controls: [material]))
        stack.setCustomSpacing(4, after: stack.arrangedSubviews.last!)

        materialNote.font = .systemFont(ofSize: 11)
        materialNote.identifier = .init("screenshot.appearance.note")
        materialNote.textColor = .secondaryLabelColor
        materialNote.translatesAutoresizingMaskIntoConstraints = false
        let noteRow = Self.settingsRow("", controls: [materialNote])
        stack.addArrangedSubview(noteRow)

        tintSource.addItems(withTitles: [L("Theme"), L("Custom"), L("None")])
        tintSource.identifier = .init("screenshot.appearance.tint.source")
        tintSource.target = self
        tintSource.action = #selector(tintSourceChanged)
        tintSource.setAccessibilityLabel(L("Panel tint"))
        tintSource.widthAnchor.constraint(equalToConstant: 116).isActive = true
        tintColor.colorWellStyle = .minimal
        tintColor.identifier = .init("screenshot.appearance.tint.color")
        tintColor.isContinuous = true
        tintColor.target = self
        tintColor.action = #selector(tintColorChanged)
        tintColor.translatesAutoresizingMaskIntoConstraints = false
        tintColor.widthAnchor.constraint(equalToConstant: 30).isActive = true
        tintColor.heightAnchor.constraint(equalToConstant: 28).isActive = true
        tintColor.setAccessibilityLabel(L("Custom panel tint color"))
        stack.addArrangedSubview(Self.settingsRow(L("Tint"), controls: [tintSource, tintColor]))

        tintAmount.minValue = 0
        tintAmount.identifier = .init("screenshot.appearance.tint.strength")
        tintAmount.maxValue = 1
        tintAmount.isContinuous = true
        tintAmount.target = self
        tintAmount.action = #selector(tintAmountChanged)
        tintAmount.setAccessibilityLabel(L("Tint strength"))
        tintAmount.translatesAutoresizingMaskIntoConstraints = false
        tintAmount.widthAnchor.constraint(equalToConstant: 230).isActive = true
        tintValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tintValue.alignment = .right
        tintValue.translatesAutoresizingMaskIntoConstraints = false
        tintValue.widthAnchor.constraint(equalToConstant: 40).isActive = true
        stack.addArrangedSubview(Self.settingsRow(L("Strength"), controls: [tintAmount, tintValue]))
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last!)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        stack.setCustomSpacing(18, after: separator)

        stack.addArrangedSubview(Self.sectionHeading(L("Theme colors")))
        stack.setCustomSpacing(8, after: stack.arrangedSubviews.last!)
        systemAccent.identifier = .init("screenshot.appearance.systemAccent")
        systemAccent.target = self
        systemAccent.action = #selector(systemAccentChanged)
        systemAccent.toolTip = L("Match the macOS accent with a subtle matching background")
        stack.addArrangedSubview(Self.settingsRow("", controls: [systemAccent]))
        stack.addArrangedSubview(themeControls)

        // Cross-view constraints require every arranged view to be attached first.
        NSLayoutConstraint.activate([
            preview.heightAnchor.constraint(equalToConstant: 160),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            headingRow.widthAnchor.constraint(equalTo: preview.widthAnchor),
            noteRow.widthAnchor.constraint(equalTo: preview.widthAnchor),
            separator.widthAnchor.constraint(equalTo: preview.widthAnchor),
        ])
    }

    func refreshControls() {
        let style = ScreenshotPanelStyle.load()
        colorMode.selectedSegment = ToolbarLayout.ColorMode.allCases.firstIndex(of: ToolbarLayout.colorMode) ?? 0
        systemAccent.state = ToolbarLayout.usesSystemAccent ? .on : .off
        material.selectedSegment = ScreenshotPanelStyle.Material.allCases.firstIndex(of: style.material) ?? 0
        let source: TintSource = style.tintUsesTheme ? .theme : style.tint == nil ? .none : .custom
        tintSource.selectItem(at: source.rawValue)
        let color = style.resolvedTint(themeColor: ToolbarLayout.bgColor)?.nsColor ?? .black
        if !tintColor.color.isEqual(color) { tintColor.color = color }
        tintColor.isEnabled = source == .custom
        tintColor.isHidden = source == .none
        tintColor.toolTip = source == .theme ? L("Uses your theme's background color") : L("Choose a custom panel tint")
        tintAmount.doubleValue = style.tintOpacity
        let adjustsTint = source != .none && !(style.material == .classic && source == .theme)
        tintAmount.isEnabled = adjustsTint
        tintValue.stringValue = !adjustsTint ? "—" : "\(Int((style.tintOpacity * 100).rounded()))%"
        if style.material == .classic {
            materialNote.stringValue = L("Solid panels use your theme background. Custom tint adds a color wash.")
        } else if ScreenshotGlassAvailability.isAvailable {
            materialNote.stringValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                ? L("Reduce Transparency is on. Glass uses a solid panel.")
                : L("Connected glass for capture and editor controls.")
        } else if #available(macOS 26.0, *) {
            materialNote.stringValue = L("Glass is unavailable on this Mac. Classic is shown.")
        } else {
            materialNote.stringValue = L("Glass requires macOS 26. Classic is shown on this Mac.")
        }
        preview.refreshContent()
    }

    @objc private func appearanceChanged() { refreshControls() }

    @objc private func colorModeChanged() {
        guard ToolbarLayout.ColorMode.allCases.indices.contains(colorMode.selectedSegment) else { return }
        ToolbarLayout.colorMode = ToolbarLayout.ColorMode.allCases[colorMode.selectedSegment]
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
    }

    @objc private func systemAccentChanged() {
        ToolbarLayout.usesSystemAccent = systemAccent.state == .on
        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
    }

    @objc private func materialChanged() {
        var style = ScreenshotPanelStyle.load()
        guard ScreenshotPanelStyle.Material.allCases.indices.contains(material.selectedSegment) else { return }
        style.material = ScreenshotPanelStyle.Material.allCases[material.selectedSegment]
        style.save()
    }

    @objc private func tintSourceChanged() {
        guard let source = TintSource(rawValue: tintSource.indexOfSelectedItem) else { return }
        var style = ScreenshotPanelStyle.load()
        style.tintUsesTheme = source == .theme
        switch source {
        case .theme: break
        case .custom:
            if style.tint == nil { style.tint = ScreenshotPanelStyle.Tint(color: tintColor.color) }
        case .none: style.tint = nil
        }
        style.save()
    }

    @objc private func tintColorChanged() {
        guard let tint = ScreenshotPanelStyle.Tint(color: tintColor.color) else { return }
        var style = ScreenshotPanelStyle.load()
        style.tintUsesTheme = false
        style.tint = tint
        style.save()
    }

    @objc private func tintAmountChanged() {
        var style = ScreenshotPanelStyle.load()
        style.tintOpacity = tintAmount.doubleValue
        style.save()
    }

    @objc private func resetAppearance() { ScreenshotPanelStyle().save() }

    static func settingsRow(_ title: String, controls: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 100).isActive = true
        return horizontal([label] + controls, spacing: 12)
    }

    private static func sectionHeading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private static func horizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
}

private final class AppearanceSettingsStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// A read-only sample of the real screenshot controls over light and dark content.
private final class ScreenshotAppearancePreviewView: NSView {
    private let sampleToolbar = ToolbarStripView(orientation: .horizontal)
    private let sampleResolution = ResolutionBoxView()
    private let sampleOptions = ToolOptionsRowView(frame: .zero)
    private let sampleCanvas = OverlayView(frame: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        sampleToolbar.setButtons([
            ToolbarButton(action: .tool(.select), sfSymbol: "cursorarrow", tooltip: L("Move")),
            ToolbarButton(action: .tool(.line), sfSymbol: "line.diagonal", tooltip: L("Line"), isSelected: true),
            ToolbarButton(action: .tool(.arrow), sfSymbol: "arrow.up.right", tooltip: L("Arrow")),
            ToolbarButton(action: .tool(.rectangle), sfSymbol: "rectangle", tooltip: L("Rectangle")),
            ToolbarButton(action: .tool(.text), sfSymbol: "textformat", tooltip: L("Text")),
            ToolbarButton(action: .tool(.stitch), sfSymbol: "scissors", tooltip: L("Stitch")),
            ToolbarButton(action: .color, sfSymbol: nil, tooltip: L("Color"), bgColor: ToolbarLayout.accentColor),
            ToolbarButton(action: .undo, sfSymbol: "arrow.uturn.backward", tooltip: L("Undo")),
            ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy")),
            ToolbarButton(action: .save, sfSymbol: "square.and.arrow.down", tooltip: L("Save")),
        ])
        sampleToolbar.onClick = { _ in }
        sampleResolution.setDimensions(w: 1280, h: 720)
        sampleResolution.setEditable(false)
        sampleOptions.overlayView = sampleCanvas
        sampleOptions.rebuild(for: .line)
        for view in [sampleResolution, sampleOptions, sampleToolbar] { addSubview(view) }
        preventControlFocus(in: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func preventControlFocus(in view: NSView) {
        // Keep actions intact: the options row uses them to refresh its icon artwork.
        // Pointer and accessibility input are rejected by the preview itself.
        if let control = view as? NSControl { control.refusesFirstResponder = true }
        for child in view.subviews { preventControlFocus(in: child) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }
    override func accessibilityLabel() -> String? { L("Screenshot controls appearance preview") }

    func refreshContent() {
        for panel in [sampleToolbar, sampleResolution, sampleOptions] as [ScreenshotPanelView] {
            panel.refreshPanelAppearance()
        }
        sampleToolbar.buttonViews.first(where: { $0.action == .color })?.swatchColor = ToolbarLayout.accentColor
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        sampleToolbar.frame.origin = NSPoint(x: (bounds.width - sampleToolbar.frame.width) / 2, y: 12)
        sampleOptions.frame.origin = NSPoint(x: (bounds.width - sampleOptions.frame.width) / 2,
            y: sampleToolbar.frame.maxY + 6)
        sampleResolution.frame.origin = NSPoint(x: (bounds.width - sampleResolution.frame.width) / 2,
            y: bounds.height - sampleResolution.frame.height - 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.96, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: 0.10, alpha: 1).setFill()
        NSRect(x: bounds.midX, y: 0, width: bounds.width / 2, height: bounds.height).fill()
        for (index, color) in [NSColor.black, .white].enumerated() {
            let x = CGFloat(index) * bounds.width / 2 + 18
            (L("Project notes") as NSString).draw(at: NSPoint(x: x, y: bounds.height - 30), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: color.withAlphaComponent(0.75),
            ])
            color.withAlphaComponent(0.08).setFill()
            for row in 0..<3 {
                NSBezierPath(roundedRect: NSRect(x: x, y: bounds.height - 48 - CGFloat(row) * 14,
                    width: bounds.width / 2 - 36 - CGFloat(row % 2) * 32, height: 4),
                    xRadius: 2, yRadius: 2).fill()
            }
        }
    }
}
