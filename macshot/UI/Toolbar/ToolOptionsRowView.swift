import Cocoa

/// Real NSView-based tool options row, replacing the custom-drawn drawToolOptionsRow().
/// Dynamically rebuilds its content when the selected tool changes.
class ToolOptionsRowView: ScreenshotPanelView {
    override var joinsAdjacentGlass: Bool { true }

    weak var overlayView: OverlayView?
    override var isHidden: Bool {
        willSet {
            if newValue, !isHidden, let overlayView {
                ScreenshotKeyboardFocus.moveIfOwned(by: self, to: overlayView)
            }
        }
    }
    private(set) var currentTool: AnnotationTool?
    /// When set, the options row edits this annotation's properties instead of global tool state.
    private(set) var editingAnnotation: Annotation?
    /// Snapshot taken before the first property edit, for undo.
    private var editingSnapshot: Annotation?
    private let rowHeight: CGFloat = 34
    private let padding: CGFloat = 8
    /// The natural content width calculated during rebuild, before any external resizing.
    private(set) var contentWidth: CGFloat = 200
    private var panelSeparatorViews: [NSView] = []
    private var foregroundButtonAlphas: [ObjectIdentifier: CGFloat] = [:]
    private enum BeautifyProperty: String { case padding, radius, shadow, blur }
    private enum ControlRole: Hashable {
        case strokeTitle, strokeSlider, strokeValue
        case loupeSizeTitle, loupeSizeSlider, loupeSizeValue
        case loupeZoomTitle, loupeZoomSlider, loupeZoomValue
        case highlightDimTitle, highlightDimSlider, highlightDimValue, highlightBorder
        case lineStyle, arrowStyle, shapeFill, censorMode
        case cornerRadiusTitle, cornerRadiusSlider, cornerRadiusValue
        case arrowFlip, pencilSmooth, pencilPressure, markerSmart
        case stitchMode, stitchPlacement, stitchSeams, stitchPieces, stitchCanvas
        case numberFormat, numberStartTitle, numberStartStepper, numberStartValue
        case fontFamily, textBold, textItalic, textUnderline, textStrikethrough
        case alignmentLeft, alignmentCenter, alignmentRight
        case fontSizeDecrease, fontSizeValue, fontSizeIncrease
        case textFillToggle, textFillSwatch, textOutlineToggle, textOutlineSwatch
        case textStrokeToggle, textStrokeSwatch, textCancel, textConfirm
        case measureUnits, measureLimit, measureHint
        case stampSizeTitle, stampSizeSlider, stampSizeValue, stampQuickChoices, stampMore, stampLoad
        case stampEmoji(String)
        case censorDrawTitle, censorDrawMode, censorAutoTitle
        case redactText, redactPII, redactFaces, redactPeople
        case beautifyToggle, beautifyMode, beautifySwatch, beautifyDisclosure
        case beautifyTitle(BeautifyProperty), beautifySlider(BeautifyProperty)
        case annotationOutlineToggle, annotationOutlineSwatch
        case loupeOutlineToggle, loupeOutlineSwatch
        case separator(String)

        var identifier: String {
            switch self {
            case .stampEmoji(let emoji): return "options.stamp.emoji.\(emoji)"
            case .beautifyTitle(let property): return "options.beautify.\(property.rawValue).title"
            case .beautifySlider(let property): return "options.beautify.\(property.rawValue).slider"
            case .separator(let nextControl): return "options.separator.\(nextControl)"
            default: return "options.\(String(describing: self))"
            }
        }
    }
    private var mountedViews: [ControlRole: NSView] = [:]
    private var usedRoles: Set<ControlRole> = []
    private var toggleHandlers: [ControlRole: ToggleHandler] = [:]
    // Consume clicks on gaps between controls so they don't fall through to OverlayView.
    // In editor mode, let gap clicks pass through so drawing works over the options area.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if let result = super.hitTest(point), result !== self { return result }
        if overlayView?.isEditorMode == true { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    /// Auto-tint controls to match toolbar accent color.
    /// Buttons with tag 990+ are excluded (they have custom colors like red/green/white).
    override func addSubview(_ view: NSView) {
        if view.superview !== self { super.addSubview(view) }
        if let btn = view as? NSButton, btn.tag < 990 { btn.contentTintColor = ToolbarLayout.accentColor }
        if let slider = view as? NSSlider { slider.trackFillColor = ToolbarLayout.accentColor }
        if let seg = view as? NSSegmentedControl { seg.selectedSegmentBezelColor = ToolbarLayout.accentColor }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        glassUnionIdentity = "drawing-controls"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func refreshPanelAppearance() {
        super.refreshPanelAppearance()
        let foreground = panelForegroundColor
        for view in subviews {
            if let label = view as? NSTextField {
                label.textColor = foreground.withAlphaComponent(label.isEnabled ? 1 : 0.35)
            }
            if let button = view as? NSButton {
                if foregroundButtonAlphas[ObjectIdentifier(button)] != nil {
                    button.contentTintColor = foreground.withAlphaComponent(button.isEnabled ? 1 : 0.35)
                } else if button.tag < 990 {
                    button.contentTintColor = ToolbarLayout.accentColor
                }
                if button.tag < 990 {
                    refreshAttributedTitle(in: button)
                }
                if (975...978).contains(button.tag) {
                    button.layer?.borderColor = foreground.withAlphaComponent(0.4).cgColor
                }
                if (980...983).contains(button.tag), button.layer?.backgroundColor != nil {
                    button.layer?.backgroundColor = ToolbarLayout.accentColor.withAlphaComponent(0.85).cgColor
                }
            }
            if let slider = view as? NSSlider {
                slider.trackFillColor = ToolbarLayout.accentColor
            }
            if let segments = view as? NSSegmentedControl {
                segments.selectedSegmentBezelColor = ToolbarLayout.accentColor
                refreshSegmentImages(in: segments)
            }
        }
        for separator in panelSeparatorViews {
            separator.layer?.backgroundColor = foreground.withAlphaComponent(0.1).cgColor
        }
        if let swatch = viewWithTag(995) as? NSButton, let ov = overlayView {
            swatch.image = Self.gradientSwatchImage(
                styleIndex: ov.beautifyStyleIndex, size: 22, color: foreground)
        }
    }

    private func setForegroundTint(on button: NSButton, alpha: CGFloat = 1) {
        foregroundButtonAlphas[ObjectIdentifier(button)] = alpha
        button.contentTintColor = panelForegroundColor.withAlphaComponent(alpha)
    }

    private func refreshAttributedTitle(in button: NSButton) {
        let title = button.attributedTitle
        guard title.length > 0 else { return }
        var ranges: [NSRange] = []
        title.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: title.length)) { value, range, _ in
            if value is NSColor { ranges.append(range) }
        }
        guard !ranges.isEmpty else { return }
        let updated = NSMutableAttributedString(attributedString: title)
        for range in ranges {
            updated.addAttribute(.foregroundColor, value: panelForegroundColor.withAlphaComponent(button.isEnabled ? 1 : 0.35), range: range)
        }
        button.attributedTitle = updated
    }

    private func refreshSegmentImages(in segments: NSSegmentedControl) {
        let foreground = panelForegroundColor
        if segments.action == #selector(highlightBorderChanged(_:)) {
            for (index, style) in [LineStyle.solid, .dashed].enumerated() where index < segments.segmentCount {
                segments.setImage(Self.lineStyleImage(style, color: foreground), forSegment: index)
            }
        } else if segments.action == #selector(lineStyleChanged(_:)) {
            for (index, style) in LineStyle.allCases.enumerated() where index < segments.segmentCount {
                segments.setImage(Self.lineStyleImage(style, color: foreground), forSegment: index)
            }
        } else if segments.action == #selector(arrowStyleChanged(_:)) {
            for (index, style) in ArrowStyle.allCases.enumerated() where index < segments.segmentCount {
                segments.setImage(Self.arrowStyleImage(style, color: foreground), forSegment: index)
            }
        } else if segments.action == #selector(shapeFillChanged(_:)) {
            for (index, style) in RectFillStyle.allCases.enumerated() where index < segments.segmentCount {
                segments.setImage(Self.shapeFillImage(style, oval: currentTool == .ellipse, color: foreground), forSegment: index)
            }
        }
    }

    /// Rebuild the options row for a selected annotation's tool, reading values from the annotation.
    func rebuild(forAnnotation ann: Annotation) {
        editingAnnotation = ann
        editingSnapshot = nil  // snapshot taken on first edit
        rebuild(for: ann.tool)
    }

    /// Clear editing state so future rebuilds use global tool defaults.
    /// Update color swatches in-place without rebuilding the entire row.
    func updateSwatchColors() {
        guard let ov = overlayView else { return }
        // Text background swatch (tag 975)
        if let swatch = viewWithTag(975) {
            swatch.layer?.backgroundColor = ov.textEditor.bgColor.cgColor
        }
        // Text outline swatch (tag 976)
        if let swatch = viewWithTag(976) {
            swatch.layer?.backgroundColor = ov.textEditor.outlineColor.cgColor
        }
        // Text glyph-stroke swatch (tag 977)
        if let swatch = viewWithTag(977) {
            swatch.layer?.backgroundColor = ov.textEditor.glyphStrokeColor.cgColor
        }
        // Annotation outline swatch (tag 978)
        if let swatch = viewWithTag(978) {
            let col = editingAnnotation?.outlineColor ?? Self.savedOutlineColor
            swatch.layer?.backgroundColor = col.cgColor
        }
    }

    func clearEditingAnnotation() {
        commitEditingSnapshot()
        editingAnnotation = nil
        editingSnapshot = nil
    }

    /// Push the undo entry if we have a snapshot (i.e., at least one property was changed).
    private func commitEditingSnapshot() {
        guard let ann = editingAnnotation, let snapshot = editingSnapshot else { return }
        overlayView?.pushPropertyChangeUndo(annotation: ann, snapshot: snapshot)
        editingSnapshot = nil
    }

    /// Take a snapshot before the first edit so we can undo.
    private func ensureSnapshot() {
        guard let ann = editingAnnotation, editingSnapshot == nil else { return }
        editingSnapshot = ann.clone()
    }

    /// Rebuild the options row for the given tool. Call when tool or state changes.
    func rebuild(for tool: AnnotationTool) {
        usedRoles.removeAll(keepingCapacity: true)
        panelSeparatorViews.removeAll()
        foregroundButtonAlphas.removeAll()
        defer { unmountUnusedControls() }
        guard let ov = overlayView else { return }

        currentTool = tool
        var curX: CGFloat = padding

        // ── Beautify options (overrides tool options when active) ──
        if ov.showBeautifyInOptionsRow {
            curX = addBeautifyOptions(at: curX, ov: ov)
            let totalW = max(curX + padding, 200)
            contentWidth = totalW
            frame.size = NSSize(width: totalW, height: rowHeight)
            return
        }

        if tool == .stitch, let editor = ov as? ImageEditingView {
            curX = addStitchOptions(at: curX, editor: editor)
            contentWidth = max(curX + padding, 200)
            frame.size = NSSize(width: contentWidth, height: rowHeight)
            return
        }

        // ── Stroke width slider (most drawing tools) ──
        let hasStroke = [.pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe].contains(tool)
        if hasStroke {
            curX = addStrokeSlider(at: curX, tool: tool, ov: ov)
        }
        if tool == .loupe {
            curX = addSeparator(at: curX, before: .loupeZoomTitle)
            curX = addLoupeMagnificationSlider(at: curX, ov: ov)
            curX = addSeparator(at: curX, before: .loupeOutlineToggle)
            curX = addLoupeOutlineControls(at: curX, ov: ov)
        }
        if tool == .highlight {
            curX = addHighlightDimSlider(at: curX, ov: ov)
            curX = addSeparator(at: curX, before: .highlightBorder)
            curX = addHighlightBorderSegment(at: curX, ov: ov)
            let totalW = max(curX + padding, 200)
            contentWidth = totalW
            frame.size = NSSize(width: totalW, height: rowHeight)
            return
        }

        // ── Line style (line, pencil, rectangle) ──
        let hasLineStyle = [.line, .pencil, .rectangle, .arrow, .ellipse].contains(tool)
        if hasLineStyle {
            if hasStroke { curX = addSeparator(at: curX, before: .lineStyle) }
            curX = addLineStyleSegment(at: curX, ov: ov)
        }

        // ── Arrow style + outline + reverse toggle ──
        if tool == .arrow {
            curX = addSeparator(at: curX, before: .arrowStyle)
            curX = addArrowStyleSegment(at: curX, ov: ov)
            curX = addSeparator(at: curX, before: .annotationOutlineToggle)
            curX = addOutlineControls(at: curX, ov: ov)
            curX = addSeparator(at: curX, before: .arrowFlip)
            let flipIsOn = editingAnnotation?.arrowReversed ?? ov.arrowReversed
            curX = addToggle(.arrowFlip, at: curX, title: L("Flip"), isOn: flipIsOn) { [weak self, weak ov] isOn in
                if let ann = self?.editingAnnotation {
                    self?.ensureSnapshot()
                    ann.arrowReversed = isOn
                    ov?.cachedCompositedImage = nil
                }
                ov?.arrowReversed = isOn
                UserDefaults.standard.set(isOn, forKey: "arrowReversed")
                ov?.needsDisplay = true
            }
        }

        // ── Shape fill style (rectangle, ellipse) ──
        if tool == .rectangle || tool == .ellipse {
            curX = addSeparator(at: curX, before: .shapeFill)
            curX = addShapeFillSegment(at: curX, tool: tool, ov: ov)
        }

        // ── Corner radius slider (rectangle) ──
        if tool == .rectangle {
            curX = addSeparator(at: curX, before: .cornerRadiusTitle)
            curX = addCornerRadiusSlider(at: curX, ov: ov)
        }



        // ── Pencil smooth mode selector ──
        if tool == .pencil {
            curX = addSeparator(at: curX, before: .pencilSmooth)
            let seg = makeSegments(.pencilSmooth, labels: [L("None"), L("Smooth"), L("Refined")],
                                   action: #selector(pencilSmoothModeChanged(_:)))
            seg.selectedSegment = ov.pencilSmoothMode
            seg.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
            seg.sizeToFit()
            seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: seg.frame.width, height: 22)
            addSubview(seg)
            curX += seg.frame.width + 4

            // ── Pressure sensitivity toggle ──
            curX = addSeparator(at: curX, before: .pencilPressure)
            curX = addToggle(.pencilPressure, at: curX, title: L("Pressure"), isOn: ov.pencilPressureEnabled) { [weak ov] isOn in
                ov?.pencilPressureEnabled = isOn
                UserDefaults.standard.set(isOn, forKey: "pencilPressureEnabled")
            }
        }

        // ── Smart marker toggle ──
        if tool == .marker {
            curX = addSeparator(at: curX, before: .markerSmart)
            curX = addToggle(.markerSmart, at: curX, title: L("Smart"), isOn: ov.smartMarkerEnabled) { [weak ov, weak self] isOn in
                ov?.smartMarkerEnabled = isOn
                UserDefaults.standard.set(isOn, forKey: "smartMarkerEnabled")
                ov?.updateCursorForCurrentTool()
                ov?.needsDisplay = true
                // Rebuild to update stroke slider enabled state
                self?.rebuild(for: .marker)
            }
        }

        // ── Number format + start-at ──
        if tool == .number {
            curX = addSeparator(at: curX, before: .numberFormat)
            curX = addNumberOptions(at: curX, ov: ov)
        }

        // ── Text formatting ──
        if tool == .text {
            curX = addTextOptions(at: curX, ov: ov)
        }

        // ── Measure px/pt toggle ──
        if tool == .measure {
            curX = addMeasureToggle(at: curX, ov: ov)
        }

        // ── Stamp/emoji row ──
        if tool == .stamp {
            curX = addStampOptions(at: curX, ov: ov)
        }

        // ── Censor tool: mode selector + redact buttons ──
        if tool == .pixelate {
            curX = addCensorModeSegment(at: curX, ov: ov)
            curX = addSeparator(at: curX, before: .censorDrawTitle)
            curX = addRedactOptions(at: curX, ov: ov)
        }

        // ── Outline toggle + color swatch (line, rectangle, ellipse, number — arrow handled above) ──
        let hasOutlineGeneric: [AnnotationTool] = [.line, .rectangle, .ellipse, .number]
        if hasOutlineGeneric.contains(tool) {
            curX = addSeparator(at: curX, before: .annotationOutlineToggle)
            curX = addOutlineControls(at: curX, ov: ov)
        }

        // Size the row
        let totalW = max(curX + padding, 200)
        contentWidth = totalW
        frame.size = NSSize(width: totalW, height: rowHeight)

        // Right-align cancel/confirm buttons for text tool
        if usedRoles.contains(.textConfirm), let confirmBtn = mountedViews[.textConfirm] {
            confirmBtn.frame.origin.x = totalW - padding - 28
        }
        if usedRoles.contains(.textCancel), let cancelBtn = mountedViews[.textCancel] {
            cancelBtn.frame.origin.x = totalW - padding - 28 - 4 - 28
        }
    }

    // MARK: - Section builders

    /// A semantic role owns one native view for as long as that option is present.
    /// Builders configure retained views on every pass; controls and their cells
    /// stay attached while values, annotations, and panel appearance change.
    private func mounted<View: NSView>(_ role: ControlRole, make: () -> View) -> View {
        precondition(usedRoles.insert(role).inserted, "An option role must be rendered only once")
        let view: View
        if let existing = mountedViews[role] {
            guard let matching = existing as? View else {
                preconditionFailure("An option role cannot change its native view type")
            }
            view = matching
        } else {
            view = make()
            view.identifier = NSUserInterfaceItemIdentifier(role.identifier)
            mountedViews[role] = view
        }
        if view.isHidden { view.isHidden = false }
        return view
    }

    private func applyControlState(_ control: NSControl, isEnabled: Bool = true, alpha: CGFloat = 1) {
        if control.isEnabled != isEnabled { control.isEnabled = isEnabled }
        if control.alphaValue != alpha { control.alphaValue = alpha }
    }

    private func makeLabel(_ role: ControlRole, text: String, isEnabled: Bool = true,
                           alpha: CGFloat = 1) -> NSTextField {
        let field = mounted(role) { NSTextField(labelWithString: text) }
        applyControlState(field, isEnabled: isEnabled, alpha: alpha)
        if field.stringValue != text { field.stringValue = text }
        field.alignment = .left
        field.tag = 0
        return field
    }

    private func makeButton(_ role: ControlRole, title: String = "", action: Selector? = nil,
                            type: NSButton.ButtonType = .momentaryPushIn, isEnabled: Bool = true) -> NSButton {
        let control: NSButton = mounted(role) {
            let button = NSButton()
            button.setButtonType(type)
            return button
        }
        applyControlState(control, isEnabled: isEnabled)
        if control.title != title { control.title = title }
        control.target = self
        control.action = action
        return control
    }

    private func makeSlider(_ role: ControlRole, value: Double, min: Double, max: Double,
                            action: Selector, isEnabled: Bool = true, alpha: CGFloat = 1) -> NSSlider {
        let control = mounted(role) { NSSlider() }
        applyControlState(control, isEnabled: isEnabled, alpha: alpha)
        control.minValue = min
        control.maxValue = max
        control.doubleValue = value
        control.target = self
        control.action = action
        return control
    }

    private func makeSegments(_ role: ControlRole, labels: [String]? = nil,
                              action: Selector, tracking: NSSegmentedControl.SwitchTracking = .selectOne,
                              isEnabled: Bool = true) -> NSSegmentedControl {
        let control = mounted(role) { NSSegmentedControl() }
        applyControlState(control, isEnabled: isEnabled)
        if control.trackingMode != tracking { control.trackingMode = tracking }
        control.target = self
        control.action = action
        if let labels {
            if control.segmentCount != labels.count { control.segmentCount = labels.count }
            for (index, title) in labels.enumerated() {
                if control.label(forSegment: index) != title { control.setLabel(title, forSegment: index) }
            }
        }
        for index in 0..<control.segmentCount { control.setEnabled(true, forSegment: index) }
        return control
    }

    private func makePopup(_ role: ControlRole, titles: [String], action: Selector) -> NSPopUpButton {
        let control = mounted(role) { NSPopUpButton(frame: .zero, pullsDown: false) }
        applyControlState(control)
        if control.itemTitles != titles {
            control.removeAllItems()
            control.addItems(withTitles: titles)
        }
        control.target = self
        control.action = action
        return control
    }

    private func makeStepper(_ role: ControlRole, value: Int, min: Double, max: Double,
                             action: Selector) -> NSStepper {
        let control = mounted(role) { NSStepper() }
        applyControlState(control)
        control.minValue = min
        control.maxValue = max
        control.integerValue = value
        control.target = self
        control.action = action
        return control
    }

    private func unmountUnusedControls() {
        let unusedRoles = mountedViews.keys.filter { !usedRoles.contains($0) }
        for role in unusedRoles {
            guard let view = mountedViews.removeValue(forKey: role) else { continue }
            if let overlayView { ScreenshotKeyboardFocus.moveIfOwned(by: view, to: overlayView) }
            view.removeFromSuperview()
            toggleHandlers.removeValue(forKey: role)
        }
    }

    private func addSeparator(at x: CGFloat, before role: ControlRole) -> CGFloat {
        let sep = mounted(.separator(role.identifier)) { NSView() }
        sep.frame = NSRect(x: x + 6, y: 8, width: 1, height: rowHeight - 16)
        sep.wantsLayer = true
        sep.layer?.backgroundColor = panelForegroundColor.withAlphaComponent(0.1).cgColor
        addSubview(sep)
        panelSeparatorViews.append(sep)
        return x + 13
    }

    /// Keep popover anchors alive while document changes refresh native chrome.
    func refreshStitchState() {
        guard currentTool == .stitch, let editor = overlayView as? ImageEditingView else { return }
        if let modes = subviews.first(where: { $0.identifier?.rawValue == "stitch.mode" }) as? NSSegmentedControl {
            switch editor.stitchMode {
            case .removeSpace: modes.selectedSegment = 0
            case .move: modes.selectedSegment = 1
            }
        }
        if let placement = subviews.first(where: { $0.identifier?.rawValue == "stitch.placement" }) as? NSPopUpButton {
            placement.selectItem(at: editor.stitchDocument?.placement == .packed ? 1 : 0)
        }
    }

    private func addStitchOptions(at x: CGFloat, editor: ImageEditingView) -> CGFloat {
        var curX = x
        let modes = makeSegments(.stitchMode, labels: [L("Remove Space"), L("Move")],
            action: #selector(stitchModeChanged(_:)))
        modes.identifier = NSUserInterfaceItemIdentifier("stitch.mode")
        switch editor.stitchMode {
        case .removeSpace: modes.selectedSegment = 0
        case .move: modes.selectedSegment = 1
        }
        modes.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        (modes.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        modes.sizeToFit()
        modes.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: modes.frame.width, height: 22)
        modes.setToolTip(L("Drag up or down to remove rows, or left or right to remove columns. Hold ⌥ to ignore guides."), forSegment: 0)
        modes.setToolTip(L("Drag pieces to move or reorder them. Hold ⌥ to ignore Free Move snapping."), forSegment: 1)
        addSubview(modes)
        curX += modes.frame.width + 4
        curX = addSeparator(at: curX, before: .stitchPlacement)

        let placement = makePopup(.stitchPlacement, titles: [L("Free Move"), L("Packed")],
                                  action: #selector(stitchPlacementChanged(_:)))
        placement.identifier = NSUserInterfaceItemIdentifier("stitch.placement")
        placement.toolTip = L("Free Move keeps overlaps. Packed closes gaps and snaps pieces into rows or columns.")
        placement.item(at: 0)?.toolTip = L("Place pieces independently and keep precise overlaps.")
        placement.item(at: 1)?.toolTip = L("Arrange pieces tightly and drag to reorder them.")
        placement.selectItem(at: editor.stitchDocument?.placement == .packed ? 1 : 0)
        placement.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        placement.sizeToFit()
        placement.frame = NSRect(x: curX, y: (rowHeight - 22) / 2,
            width: max(placement.frame.width, 96), height: 22)
        addSubview(placement)
        curX += placement.frame.width + 4
        curX = addSeparator(at: curX, before: .stitchSeams)

        let options: [(String, String, Int, ControlRole)] = [
            (L("Seams"), "stitch.seams", 0, .stitchSeams),
            (L("Pieces"), "stitch.pieces", 1, .stitchPieces),
            (L("Canvas"), "stitch.canvas", 2, .stitchCanvas),
        ]
        for (label, identifier, tag, role) in options {
            let button = makeButton(role, title: label, action: #selector(stitchOptionsClicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            button.tag = tag
            button.bezelStyle = .rounded
            button.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            button.sizeToFit()
            button.frame = NSRect(x: curX, y: (rowHeight - 22) / 2,
                width: max(46, button.frame.width), height: 22)
            addSubview(button)
            curX += button.frame.width + 4
        }
        return curX
    }

    @objc private func stitchModeChanged(_ sender: NSSegmentedControl) {
        guard let editor = overlayView as? ImageEditingView else { return }
        switch sender.selectedSegment {
        case 0: editor.stitchMode = .removeSpace
        case 1: editor.stitchMode = .move
        default: break
        }
    }

    @objc private func stitchPlacementChanged(_ sender: NSPopUpButton) {
        (overlayView as? ImageEditingView)?.onStitchPlacementChanged?(sender.indexOfSelectedItem == 1 ? .packed : .free)
    }

    @objc private func stitchOptionsClicked(_ sender: NSButton) {
        guard let editor = overlayView as? ImageEditingView else { return }
        let option: StitchOptionsAction
        switch sender.tag {
        case 0: option = .seams
        case 1: option = .pieces
        default: option = .canvas
        }
        editor.onStitchOptions?(option, sender)
    }

    private func addStrokeSlider(at x: CGFloat, tool: AnnotationTool, ov: OverlayView) -> CGFloat {
        var curX = x
        // Smart marker supplies its own width; retain and dim the manual controls.
        let usesSmartWidth = tool == .marker && ov.smartMarkerEnabled
        let controlAlpha: CGFloat = usesSmartWidth ? 0.35 : 1

        let nameLabel = makeLabel(tool == .loupe ? .loupeSizeTitle : .strokeTitle,
            text: tool == .loupe ? L("Size") : L("Stroke"), alpha: controlAlpha)
        nameLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        nameLabel.textColor = panelForegroundColor
        nameLabel.sizeToFit()
        nameLabel.frame.origin = NSPoint(x: curX, y: (rowHeight - nameLabel.frame.height) / 2)
        addSubview(nameLabel)
        curX += nameLabel.frame.width + 4

        let currentVal: CGFloat
        if tool == .loupe, let ann = editingAnnotation {
            currentVal = min(ann.boundingRect.width, ann.boundingRect.height)
        } else {
            currentVal = editingAnnotation?.strokeWidth ?? ov.activeStrokeWidthForTool(tool)
        }
        let sliderW: CGFloat = 100
        let slider = makeSlider(tool == .loupe ? .loupeSizeSlider : .strokeSlider, value: Double(currentVal),
                                min: tool == .loupe ? 40 : 1, max: tool == .loupe ? 320 : 30,
                                action: #selector(strokeSliderChanged(_:)),
                                isEnabled: !usesSmartWidth, alpha: controlAlpha)
        slider.frame = NSRect(x: curX, y: (rowHeight - 20) / 2, width: sliderW, height: 20)
        slider.isContinuous = true
        slider.tag = tool.rawValue
        addSubview(slider)
        curX += sliderW + 4

        let val = Int(currentVal)
        let valStr = tool == .loupe ? "\(val)" : "\(val)px"
        let labelW: CGFloat = tool == .loupe ? 32 : 28
        let label = makeLabel(tool == .loupe ? .loupeSizeValue : .strokeValue, text: valStr, alpha: controlAlpha)
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        label.textColor = panelForegroundColor
        label.alignment = .right
        label.frame = NSRect(x: curX, y: (rowHeight - 14) / 2, width: labelW, height: 14)
        label.tag = 997  // stroke value label
        addSubview(label)
        curX += labelW

        return curX
    }

    private func addLoupeMagnificationSlider(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x

        let nameLabel = makeLabel(.loupeZoomTitle, text: L("Zoom"))
        nameLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        nameLabel.textColor = panelForegroundColor
        nameLabel.sizeToFit()
        nameLabel.frame.origin = NSPoint(x: curX, y: (rowHeight - nameLabel.frame.height) / 2)
        addSubview(nameLabel)
        curX += nameLabel.frame.width + 4

        let currentVal = editingAnnotation?.loupeMagnification ?? ov.currentLoupeMagnification
        let sliderW: CGFloat = 84
        let slider = makeSlider(.loupeZoomSlider, value: Double(currentVal), min: 1.1, max: 6.0,
                                action: #selector(loupeMagnificationChanged(_:)))
        slider.frame = NSRect(x: curX, y: (rowHeight - 20) / 2, width: sliderW, height: 20)
        slider.isContinuous = true
        addSubview(slider)
        curX += sliderW + 4

        let label = makeLabel(.loupeZoomValue, text: String(format: "%.1fx", currentVal))
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        label.textColor = panelForegroundColor
        label.alignment = .right
        label.frame = NSRect(x: curX, y: (rowHeight - 14) / 2, width: 38, height: 14)
        label.tag = 994
        addSubview(label)
        curX += 38

        return curX
    }

    private func addHighlightDimSlider(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x

        let nameLabel = makeLabel(.highlightDimTitle, text: L("Dim"))
        nameLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        nameLabel.textColor = panelForegroundColor
        nameLabel.sizeToFit()
        nameLabel.frame.origin = NSPoint(x: curX, y: (rowHeight - nameLabel.frame.height) / 2)
        addSubview(nameLabel)
        curX += nameLabel.frame.width + 4

        let stored = UserDefaults.standard.object(forKey: HighlightToolHandler.dimOpacityKey) as? Double
        let currentVal = editingAnnotation?.dimOpacity ?? CGFloat(stored ?? 0.55)
        let sliderW: CGFloat = 84
        let slider = makeSlider(.highlightDimSlider, value: Double(currentVal), min: 0.1, max: 0.95,
                                action: #selector(highlightDimChanged(_:)))
        slider.frame = NSRect(x: curX, y: (rowHeight - 20) / 2, width: sliderW, height: 20)
        slider.isContinuous = true
        addSubview(slider)
        curX += sliderW + 4

        let label = makeLabel(.highlightDimValue, text: "\(Int((currentVal * 100).rounded()))%")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        label.textColor = panelForegroundColor
        label.alignment = .right
        label.frame = NSRect(x: curX, y: (rowHeight - 14) / 2, width: 38, height: 14)
        label.tag = 993
        addSubview(label)
        curX += 38

        return curX
    }

    /// Solid | Dashed border-style toggle for the highlight rect.
    private func addHighlightBorderSegment(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let seg = makeSegments(.highlightBorder, action: #selector(highlightBorderChanged(_:)))
        if seg.segmentCount != 2 { seg.segmentCount = 2 }
        seg.tag = 992
        seg.setImage(Self.lineStyleImage(.solid, color: panelForegroundColor), forSegment: 0)
        seg.setImage(Self.lineStyleImage(.dashed, color: panelForegroundColor), forSegment: 1)
        seg.setWidth(36, forSegment: 0)
        seg.setWidth(36, forSegment: 1)
        let dashed: Bool
        if let ann = editingAnnotation, ann.tool == .highlight {
            dashed = ann.lineStyle == .dashed
        } else {
            dashed = UserDefaults.standard.object(forKey: HighlightToolHandler.dashedBorderKey) as? Bool ?? true
        }
        seg.selectedSegment = dashed ? 1 : 0
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 72, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += 72
        return curX
    }

    private func addLineStyleSegment(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let seg = makeSegments(.lineStyle, action: #selector(lineStyleChanged(_:)))
        if seg.segmentCount != LineStyle.allCases.count { seg.segmentCount = LineStyle.allCases.count }
        seg.tag = 979  // tag for finding this segment to disable dashed/dotted when outline is on
        for (i, style) in LineStyle.allCases.enumerated() {
            seg.setImage(Self.lineStyleImage(style, color: panelForegroundColor), forSegment: i)
            seg.setWidth(36, forSegment: i)
        }
        let currentStyle = editingAnnotation?.lineStyle ?? ov.currentLineStyle
        seg.selectedSegment = currentStyle.rawValue
        let segW = CGFloat(LineStyle.allCases.count) * 36
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: segW, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect

        // Disable dashed/dotted for rect/ellipse when outline is enabled
        let isShapeTool = [AnnotationTool.rectangle, .ellipse].contains(currentTool ?? ov.currentTool)
        let hasOutline = editingAnnotation.map { $0.outlineColor != nil }
            ?? (isShapeTool && UserDefaults.standard.bool(forKey: "annotationOutlineEnabled"))
        if isShapeTool && hasOutline {
            for (i, style) in LineStyle.allCases.enumerated() {
                if style != .solid {
                    seg.setEnabled(false, forSegment: i)
                }
            }
            // Force solid if currently dashed/dotted
            if currentStyle != .solid {
                seg.selectedSegment = LineStyle.solid.rawValue
                if let ann = editingAnnotation {
                    ann.lineStyle = .solid
                    ov.cachedCompositedImage = nil
                } else {
                    ov.currentLineStyle = .solid
                }
            }
        }

        addSubview(seg)
        curX += segW
        return curX
    }

    private func addArrowStyleSegment(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let seg = makeSegments(.arrowStyle, action: #selector(arrowStyleChanged(_:)))
        if seg.segmentCount != ArrowStyle.allCases.count { seg.segmentCount = ArrowStyle.allCases.count }
        for (i, style) in ArrowStyle.allCases.enumerated() {
            seg.setImage(Self.arrowStyleImage(style, color: panelForegroundColor), forSegment: i)
            seg.setWidth(30, forSegment: i)
        }
        seg.selectedSegment = (editingAnnotation?.arrowStyle ?? ov.currentArrowStyle).rawValue
        let segW = CGFloat(ArrowStyle.allCases.count) * 30
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: segW, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += segW
        return curX
    }

    private func addShapeFillSegment(at x: CGFloat, tool: AnnotationTool, ov: OverlayView) -> CGFloat {
        var curX = x
        let isOval = tool == .ellipse
        let seg = makeSegments(.shapeFill, action: #selector(shapeFillChanged(_:)))
        if seg.segmentCount != RectFillStyle.allCases.count { seg.segmentCount = RectFillStyle.allCases.count }
        for (i, style) in RectFillStyle.allCases.enumerated() {
            seg.setImage(Self.shapeFillImage(style, oval: isOval, color: panelForegroundColor), forSegment: i)
            seg.setWidth(30, forSegment: i)
        }
        seg.selectedSegment = (editingAnnotation?.rectFillStyle ?? ov.currentRectFillStyle).rawValue
        let segW = CGFloat(RectFillStyle.allCases.count) * 30
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: segW, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += segW
        return curX
    }

    private func addCensorModeSegment(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let seg = makeSegments(.censorMode, action: #selector(censorModeChanged(_:)))
        if seg.segmentCount != CensorMode.allCases.count { seg.segmentCount = CensorMode.allCases.count }
        seg.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        for (i, mode) in CensorMode.allCases.enumerated() {
            seg.setLabel(mode.label, forSegment: i)
            seg.setWidth(0, forSegment: i)
        }
        let currentMode: CensorMode
        if let ann = editingAnnotation, ann.tool == .pixelate || ann.tool == .blur {
            currentMode = ann.censorMode
        } else {
            currentMode = CensorMode(rawValue: UserDefaults.standard.integer(forKey: "censorMode")) ?? .pixelate
        }
        seg.selectedSegment = currentMode.rawValue
        seg.sizeToFit()
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: seg.frame.width, height: 22)
        addSubview(seg)
        curX += seg.frame.width
        return curX
    }

    /// Add a uniform redact action button using NSSegmentedControl for consistent sizing.
    /// If `dropdownAction` is provided, adds a second narrow segment with a ▾ arrow.
    private func addRedactButton(_ role: ControlRole, at x: CGFloat, title: String, action: Selector,
                                  font: NSFont, height: CGFloat, y: CGFloat,
                                  dropdownAction: Selector? = nil) -> CGFloat {
        var curX = x
        let seg = makeSegments(role, action: action, tracking: .momentary)
        seg.font = font
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect

        if dropdownAction != nil {
            if seg.segmentCount != 2 { seg.segmentCount = 2 }
            seg.setLabel(title, forSegment: 0)
            seg.setLabel("▾", forSegment: 1)
            seg.setWidth(0, forSegment: 0)
            seg.setWidth(18, forSegment: 1)
            seg.target = self
            seg.action = #selector(piiSegmentClicked(_:))
        } else {
            if seg.segmentCount != 1 { seg.segmentCount = 1 }
            seg.setLabel(title, forSegment: 0)
            seg.setWidth(0, forSegment: 0)
            seg.target = self
            seg.action = action
        }

        seg.sizeToFit()
        seg.frame = NSRect(x: curX, y: y, width: seg.frame.width, height: height)
        addSubview(seg)
        curX += seg.frame.width + 4
        return curX
    }

    @objc private func piiSegmentClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            redactPIIClicked()
        } else {
            redactTypesClicked(sender)
        }
    }

    // MARK: - Segment preview images

    private static func lineStyleImage(_ style: LineStyle, color: NSColor) -> NSImage {
        let size = NSSize(width: 28, height: 16)
        return NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            style.apply(to: path)
            color.setStroke()
            path.move(to: NSPoint(x: 4, y: size.height / 2))
            path.line(to: NSPoint(x: size.width - 4, y: size.height / 2))
            path.stroke()
            return true
        }
    }

    private static func arrowStyleImage(_ style: ArrowStyle, color: NSColor) -> NSImage {
        let size = NSSize(width: 24, height: 16)
        return NSImage(size: size, flipped: false) { _ in
            let mid = size.height / 2
            let from = NSPoint(x: 3, y: mid)
            let to = NSPoint(x: size.width - 3, y: mid)
            color.setStroke()
            color.setFill()

            switch style {
            case .single:
                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.move(to: from)
                path.line(to: NSPoint(x: to.x - 4, y: mid))
                path.stroke()
                let head = NSBezierPath()
                head.move(to: to)
                head.line(to: NSPoint(x: to.x - 5, y: mid + 3))
                head.line(to: NSPoint(x: to.x - 5, y: mid - 3))
                head.close()
                head.fill()
            case .thick:
                // Thick shaft stops before the head
                let path = NSBezierPath()
                path.lineWidth = 2.5
                path.move(to: from)
                path.line(to: NSPoint(x: to.x - 6, y: mid))
                path.stroke()
                let head = NSBezierPath()
                head.move(to: to)
                head.line(to: NSPoint(x: to.x - 7, y: mid + 5))
                head.line(to: NSPoint(x: to.x - 7, y: mid - 5))
                head.close()
                head.fill()
            case .double:
                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.move(to: NSPoint(x: from.x + 4, y: mid))
                path.line(to: NSPoint(x: to.x - 4, y: mid))
                path.stroke()
                // Left arrowhead (pointing left)
                let headL = NSBezierPath()
                headL.move(to: from)
                headL.line(to: NSPoint(x: from.x + 5, y: mid + 3))
                headL.line(to: NSPoint(x: from.x + 5, y: mid - 3))
                headL.close()
                headL.fill()
                // Right arrowhead (pointing right)
                let headR = NSBezierPath()
                headR.move(to: to)
                headR.line(to: NSPoint(x: to.x - 5, y: mid + 3))
                headR.line(to: NSPoint(x: to.x - 5, y: mid - 3))
                headR.close()
                headR.fill()
            case .open:
                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.move(to: from)
                path.line(to: to)
                path.move(to: NSPoint(x: to.x - 5, y: mid + 3))
                path.line(to: to)
                path.line(to: NSPoint(x: to.x - 5, y: mid - 3))
                path.stroke()
            case .tail:
                // Filled circle at the start matches what the renderer actually draws.
                let tailR: CGFloat = 2.6
                let tailCircle = NSBezierPath(ovalIn: NSRect(
                    x: from.x - tailR, y: mid - tailR,
                    width: tailR * 2, height: tailR * 2))
                tailCircle.fill()
                let path = NSBezierPath()
                path.lineWidth = 1.5
                path.move(to: NSPoint(x: from.x + tailR, y: mid))
                path.line(to: NSPoint(x: to.x - 4, y: mid))
                path.stroke()
                let head = NSBezierPath()
                head.move(to: to)
                head.line(to: NSPoint(x: to.x - 5, y: mid + 3))
                head.line(to: NSPoint(x: to.x - 5, y: mid - 3))
                head.close()
                head.fill()
            case .sketchy:
                // Wobbly shaft + open chevron head with a slight hand-drawn bow.
                let nose = NSPoint(x: to.x - 1, y: mid)
                let shaft = NSBezierPath()
                shaft.lineWidth = 1.6
                shaft.lineCapStyle = .round
                shaft.lineJoinStyle = .round
                shaft.move(to: NSPoint(x: from.x, y: mid - 0.5))
                shaft.curve(
                    to: NSPoint(x: to.x - 6.5, y: mid + 0.3),
                    controlPoint1: NSPoint(x: from.x + 5, y: mid - 1.6),
                    controlPoint2: NSPoint(x: to.x - 11, y: mid + 1.6))
                shaft.stroke()
                // Upper chevron leg with a tiny outward bow.
                let upper = NSBezierPath()
                upper.lineWidth = 1.6
                upper.lineCapStyle = .round
                upper.move(to: nose)
                upper.curve(
                    to: NSPoint(x: to.x - 6.5, y: mid + 3.5),
                    controlPoint1: NSPoint(x: to.x - 3.5, y: mid + 1.4),
                    controlPoint2: NSPoint(x: to.x - 4.6, y: mid + 2.2))
                upper.stroke()
                // Lower chevron leg with a slightly different bow.
                let lower = NSBezierPath()
                lower.lineWidth = 1.6
                lower.lineCapStyle = .round
                lower.move(to: nose)
                lower.curve(
                    to: NSPoint(x: to.x - 6.5, y: mid - 3.5),
                    controlPoint1: NSPoint(x: to.x - 3.5, y: mid - 1.6),
                    controlPoint2: NSPoint(x: to.x - 4.4, y: mid - 2.4))
                lower.stroke()
            }
            return true
        }
    }

    private static func shapeFillImage(_ style: RectFillStyle, oval: Bool, color: NSColor) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        return NSImage(size: size, flipped: false) { _ in
            let r = NSRect(x: 3, y: 2, width: size.width - 6, height: size.height - 4)
            let path = oval ? NSBezierPath(ovalIn: r) : NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            path.lineWidth = 1.5
            switch style {
            case .stroke:
                color.setStroke()
                path.stroke()
            case .strokeAndFill:
                color.withAlphaComponent(0.4).setFill()
                path.fill()
                color.setStroke()
                path.stroke()
            case .fill:
                color.setFill()
                path.fill()
            }
            return true
        }
    }

    private static func gradientSwatchImage(styleIndex: Int, size: CGFloat, color: NSColor) -> NSImage {
        // Custom image background swatch
        if styleIndex == -1 {
            if let data = UserDefaults.standard.data(forKey: "beautifyCustomBgImageData"),
               let img = NSImage(data: data) {
                return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
                    let r = NSRect(x: 0, y: 0, width: size, height: size)
                    let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                    NSGraphicsContext.saveGraphicsState()
                    path.addClip()
                    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
                    NSGraphicsContext.restoreGraphicsState()
                    color.withAlphaComponent(0.3).setStroke()
                    path.lineWidth = 0.5
                    path.stroke()
                    return true
                }
            }
            return NSImage(size: NSSize(width: size, height: size))
        }
        let styles = BeautifyRenderer.styles
        guard styleIndex >= 0, styleIndex < styles.count else {
            return NSImage(size: NSSize(width: size, height: size))
        }
        let style = styles[styleIndex]
        // Use mesh rendering on macOS 15+ for mesh styles
        if #available(macOS 15.0, *), let mesh = style.meshDef,
           let meshImg = BeautifyRenderer.renderMeshSwatch(mesh, size: size) {
            return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
                let r = NSRect(x: 0, y: 0, width: size, height: size)
                let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                meshImg.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
                color.withAlphaComponent(0.3).setStroke()
                path.lineWidth = 0.5
                path.stroke()
                return true
            }
        }
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let r = NSRect(x: 0, y: 0, width: size, height: size)
            let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
            if let grad = NSGradient(
                colors: style.stops.map { $0.0 },
                atLocations: style.stops.map { $0.1 },
                colorSpace: .deviceRGB)
            {
                grad.draw(in: path, angle: style.angle - 90)
            }
            color.withAlphaComponent(0.3).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            return true
        }
    }

    private func addCornerRadiusSlider(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let label = makeLabel(.cornerRadiusTitle, text: L("Radius"))
        label.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        label.textColor = panelForegroundColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: curX, y: (rowHeight - label.frame.height) / 2)
        addSubview(label)
        curX += label.frame.width + 4

        let radiusVal = editingAnnotation?.rectCornerRadius ?? ov.currentRectCornerRadius
        let slider = makeSlider(.cornerRadiusSlider, value: Double(radiusVal), min: 0, max: 30,
                                action: #selector(cornerRadiusChanged(_:)))
        slider.frame = NSRect(x: curX, y: (rowHeight - 20) / 2, width: 80, height: 20)
        slider.isContinuous = true
        addSubview(slider)
        curX += 80 + 4

        let valLabel = makeLabel(.cornerRadiusValue, text: "\(Int(radiusVal))px")
        valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        valLabel.textColor = panelForegroundColor
        valLabel.alignment = .right
        valLabel.frame = NSRect(x: curX, y: (rowHeight - 14) / 2, width: 28, height: 14)
        valLabel.tag = 996  // corner radius value label
        addSubview(valLabel)
        curX += 28

        return curX
    }

    private func addToggle(_ role: ControlRole, at x: CGFloat, title: String, isOn: Bool, action: @escaping (Bool) -> Void) -> CGFloat {
        var curX = x
        let btn = makeButton(role, title: title, type: .switch)
        btn.state = isOn ? .on : .off
        btn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        btn.contentTintColor = panelForegroundColor.withAlphaComponent(0.7)
        // Keep checkbox titles aligned with the panel foreground.
        if let cell = btn.cell as? NSButtonCell {
            let attrTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: panelForegroundColor,
                .font: NSFont.systemFont(ofSize: 10, weight: .medium)
            ])
            cell.attributedTitle = attrTitle
        }
        btn.sizeToFit()
        btn.frame.origin = NSPoint(x: curX, y: (rowHeight - btn.frame.height) / 2)
        let handler = toggleHandlers[role] ?? ToggleHandler(action: action)
        handler.action = action
        toggleHandlers[role] = handler
        btn.target = handler
        btn.action = #selector(ToggleHandler.toggled(_:))
        addSubview(btn)
        curX += btn.frame.width + 8
        return curX
    }

    private func addNumberOptions(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let formats = ["1", "I", "A", "a"]
        let seg = makeSegments(.numberFormat, labels: formats, action: #selector(numberFormatChanged(_:)))
        seg.selectedSegment = ov.currentNumberFormat.rawValue
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 100, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += 100

        curX = addSeparator(at: curX, before: .numberStartTitle)

        let startLabel = makeLabel(.numberStartTitle, text: L("Start:"))
        startLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        startLabel.textColor = panelForegroundColor
        startLabel.sizeToFit()
        startLabel.frame.origin = NSPoint(x: curX, y: (rowHeight - startLabel.frame.height) / 2)
        addSubview(startLabel)
        curX += startLabel.frame.width + 4

        let stepper = makeStepper(.numberStartStepper, value: ov.numberStartAt, min: 1, max: 999,
                                  action: #selector(numberStartChanged(_:)))
        stepper.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 19, height: 22)
        addSubview(stepper)

        let valLabel = makeLabel(.numberStartValue, text: ov.currentNumberFormat.format(ov.numberStartAt))
        valLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        valLabel.textColor = panelForegroundColor
        valLabel.tag = 999  // tag for finding later
        valLabel.sizeToFit()
        valLabel.frame.origin = NSPoint(x: curX + 22, y: (rowHeight - valLabel.frame.height) / 2)
        addSubview(valLabel)
        curX += 50

        return curX
    }

    private func addTextOptions(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x

        // Font family dropdown
        let displayName = ov.textEditor.fontFamily == "System" ? "System" : ov.textEditor.fontFamily
        let fontBtn = makeButton(.fontFamily, title: "\(displayName) ▾", action: #selector(fontFamilyClicked(_:)))
        fontBtn.bezelStyle = .recessed
        fontBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        fontBtn.attributedTitle = NSAttributedString(string: "\(displayName) ▾", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .baselineOffset: 0.5,
        ])
        fontBtn.sizeToFit()
        fontBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: max(65, fontBtn.frame.width + 8), height: 22)
        addSubview(fontBtn)
        curX += fontBtn.frame.width + 6

        // Bold / Italic / Underline / Strikethrough
        let textStyles: [(ControlRole, String, Bool, Selector, Int)] = [
            (.textBold, "B", ov.textEditor.bold, #selector(boldToggled), 980),
            (.textItalic, "I", ov.textEditor.italic, #selector(italicToggled), 981),
            (.textUnderline, "U", ov.textEditor.underline, #selector(underlineToggled), 982),
            (.textStrikethrough, "S", ov.textEditor.strikethrough, #selector(strikethroughToggled), 983),
        ]
        for (role, label, isOn, sel, tag) in textStyles {
            let btn = makeButton(role, title: label, action: sel)
            btn.bezelStyle = .smallSquare
            btn.isBordered = false
            btn.wantsLayer = true
            btn.tag = tag
            btn.layer?.cornerRadius = 4
            btn.layer?.backgroundColor = isOn ? ToolbarLayout.accentColor.withAlphaComponent(0.85).cgColor : nil
            btn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            btn.attributedTitle = NSAttributedString(string: label, attributes: [
                .foregroundColor: panelForegroundColor,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            ])
            btn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 26, height: 22)
            addSubview(btn)
            curX += 28
        }

        curX = addSeparator(at: curX, before: .alignmentLeft)

        // Alignment buttons
        let alignments: [(ControlRole, String, NSTextAlignment)] = [
            (.alignmentLeft, "text.alignleft", .left),
            (.alignmentCenter, "text.aligncenter", .center),
            (.alignmentRight, "text.alignright", .right),
        ]
        for (role, symbol, alignment) in alignments {
            let btn = makeButton(role, type: .toggle)
            btn.bezelStyle = .recessed
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
            btn.state = ov.textEditor.alignment == alignment ? .on : .off
            btn.tag = alignment.rawValue
            btn.target = self
            btn.action = #selector(alignmentChanged(_:))
            btn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 26, height: 22)
            addSubview(btn)
            curX += 28
        }

        curX = addSeparator(at: curX, before: .fontSizeDecrease)

        // Font size −/+
        let minusBtn = makeButton(.fontSizeDecrease, title: "−", action: #selector(fontSizeDecreased))
        minusBtn.bezelStyle = .recessed
        minusBtn.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        minusBtn.isContinuous = true
        (minusBtn.cell as? NSButtonCell)?.setPeriodicDelay(0.3, interval: 0.05)
        minusBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 20, height: 22)
        addSubview(minusBtn)
        curX += 20

        let sizeLabel = makeLabel(.fontSizeValue, text: "\(Int(ov.textEditor.fontSize))")
        sizeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        sizeLabel.textColor = panelForegroundColor
        sizeLabel.alignment = .center
        sizeLabel.tag = 998
        sizeLabel.frame = NSRect(x: curX, y: (rowHeight - 14) / 2, width: 26, height: 14)
        addSubview(sizeLabel)
        curX += 26

        let plusBtn = makeButton(.fontSizeIncrease, title: "+", action: #selector(fontSizeIncreased))
        plusBtn.bezelStyle = .recessed
        plusBtn.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        plusBtn.isContinuous = true
        (plusBtn.cell as? NSButtonCell)?.setPeriodicDelay(0.3, interval: 0.05)
        plusBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 20, height: 22)
        addSubview(plusBtn)
        curX += 24

        curX = addSeparator(at: curX, before: .textFillToggle)

        // Fill: clickable label (toggles on/off) + color swatch (opens color picker)
        let fillSwatchSize: CGFloat = 18
        let fillLabelBtn = makeButton(.textFillToggle, title: L("Fill"), action: #selector(textBgToggled(_:)), type: .toggle)
        fillLabelBtn.bezelStyle = .recessed
        fillLabelBtn.state = ov.textEditor.bgEnabled ? .on : .off
        fillLabelBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        fillLabelBtn.attributedTitle = NSAttributedString(string: L("Fill"), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .baselineOffset: 0.5,
        ])
        fillLabelBtn.sizeToFit()
        fillLabelBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: max(30, fillLabelBtn.frame.width), height: 22)
        addSubview(fillLabelBtn)
        curX += fillLabelBtn.frame.width + 2

        let fillSwatch = makeButton(.textFillSwatch)
        fillSwatch.frame = NSRect(x: curX, y: (rowHeight - fillSwatchSize) / 2, width: fillSwatchSize, height: fillSwatchSize)
        fillSwatch.title = ""
        fillSwatch.isBordered = false
        fillSwatch.wantsLayer = true
        fillSwatch.layer?.backgroundColor = ov.textEditor.bgColor.cgColor
        fillSwatch.layer?.cornerRadius = 3
        fillSwatch.layer?.borderWidth = 1.5
        fillSwatch.layer?.borderColor = panelForegroundColor.withAlphaComponent(0.4).cgColor
        fillSwatch.layer?.opacity = ov.textEditor.bgEnabled ? 1.0 : 0.3
        fillSwatch.tag = 975
        fillSwatch.target = self
        fillSwatch.action = #selector(textBgColorClicked(_:))
        addSubview(fillSwatch)
        curX += fillSwatchSize + 6

        // Outline: clickable label (toggles on/off) + color swatch (opens color picker)
        let outlineLabelBtn = makeButton(.textOutlineToggle, title: L("Outline"), action: #selector(textOutlineToggled(_:)), type: .toggle)
        outlineLabelBtn.bezelStyle = .recessed
        outlineLabelBtn.state = ov.textEditor.outlineEnabled ? .on : .off
        outlineLabelBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        outlineLabelBtn.attributedTitle = NSAttributedString(string: L("Outline"), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .baselineOffset: 0.5,
        ])
        outlineLabelBtn.sizeToFit()
        outlineLabelBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: max(50, outlineLabelBtn.frame.width), height: 22)
        addSubview(outlineLabelBtn)
        curX += outlineLabelBtn.frame.width + 2

        let outlineSwatch = makeButton(.textOutlineSwatch)
        outlineSwatch.frame = NSRect(x: curX, y: (rowHeight - fillSwatchSize) / 2, width: fillSwatchSize, height: fillSwatchSize)
        outlineSwatch.title = ""
        outlineSwatch.isBordered = false
        outlineSwatch.wantsLayer = true
        outlineSwatch.layer?.backgroundColor = ov.textEditor.outlineColor.cgColor
        outlineSwatch.layer?.cornerRadius = 3
        outlineSwatch.layer?.borderWidth = 1.5
        outlineSwatch.layer?.borderColor = panelForegroundColor.withAlphaComponent(0.4).cgColor
        outlineSwatch.layer?.opacity = ov.textEditor.outlineEnabled ? 1.0 : 0.3
        outlineSwatch.tag = 976
        outlineSwatch.target = self
        outlineSwatch.action = #selector(textOutlineColorClicked(_:))
        addSubview(outlineSwatch)
        curX += fillSwatchSize + 6

        // Stroke (per-glyph): clickable label (toggles on/off) + color swatch
        let strokeLabelBtn = makeButton(.textStrokeToggle, title: L("Stroke"), action: #selector(textGlyphStrokeToggled(_:)), type: .toggle)
        strokeLabelBtn.bezelStyle = .recessed
        strokeLabelBtn.state = ov.textEditor.glyphStrokeEnabled ? .on : .off
        strokeLabelBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        strokeLabelBtn.attributedTitle = NSAttributedString(string: L("Stroke"), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .baselineOffset: 0.5,
        ])
        strokeLabelBtn.sizeToFit()
        strokeLabelBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: max(46, strokeLabelBtn.frame.width), height: 22)
        addSubview(strokeLabelBtn)
        curX += strokeLabelBtn.frame.width + 2

        let strokeSwatch = makeButton(.textStrokeSwatch)
        strokeSwatch.frame = NSRect(x: curX, y: (rowHeight - fillSwatchSize) / 2, width: fillSwatchSize, height: fillSwatchSize)
        strokeSwatch.title = ""
        strokeSwatch.isBordered = false
        strokeSwatch.wantsLayer = true
        strokeSwatch.layer?.backgroundColor = ov.textEditor.glyphStrokeColor.cgColor
        strokeSwatch.layer?.cornerRadius = 3
        strokeSwatch.layer?.borderWidth = 1.5
        strokeSwatch.layer?.borderColor = panelForegroundColor.withAlphaComponent(0.4).cgColor
        strokeSwatch.layer?.opacity = ov.textEditor.glyphStrokeEnabled ? 1.0 : 0.3
        strokeSwatch.tag = 977
        strokeSwatch.target = self
        strokeSwatch.action = #selector(textGlyphStrokeColorClicked(_:))
        addSubview(strokeSwatch)
        curX += fillSwatchSize

        // Cancel / Confirm — only when actively editing text, right-aligned
        if ov.textEditor.isEditing {
            curX = addSeparator(at: curX, before: .textCancel)
            let cancelBtn = makeButton(.textCancel, title: "✕", action: #selector(textCancelClicked))
            cancelBtn.bezelStyle = .smallSquare
            cancelBtn.isBordered = false
            cancelBtn.wantsLayer = true
            cancelBtn.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
            cancelBtn.layer?.cornerRadius = 4
            cancelBtn.font = NSFont.systemFont(ofSize: 11, weight: .bold)
            cancelBtn.attributedTitle = NSAttributedString(string: "✕", attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11, weight: .bold)])
            cancelBtn.frame = NSRect(x: 0, y: (rowHeight - 22) / 2, width: 28, height: 22)
            cancelBtn.tag = 990
            addSubview(cancelBtn)

            let confirmBtn = makeButton(.textConfirm, title: "✓", action: #selector(textConfirmClicked))
            confirmBtn.bezelStyle = .smallSquare
            confirmBtn.isBordered = false
            confirmBtn.wantsLayer = true
            confirmBtn.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.8).cgColor
            confirmBtn.layer?.cornerRadius = 4
            confirmBtn.font = NSFont.systemFont(ofSize: 12, weight: .bold)
            confirmBtn.attributedTitle = NSAttributedString(string: "✓", attributes: [
                .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 12, weight: .bold)])
            confirmBtn.frame = NSRect(x: 0, y: (rowHeight - 22) / 2, width: 28, height: 22)
            confirmBtn.tag = 991
            addSubview(confirmBtn)

            curX += 68  // reserve space for right-aligned buttons
        }
        return curX
    }

    private func addMeasureToggle(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let seg = makeSegments(.measureUnits, labels: ["px", "pt"], action: #selector(measureUnitChanged(_:)))
        seg.selectedSegment = ov.currentMeasureInPoints ? 1 : 0
        seg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 60, height: 22)
        (seg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        addSubview(seg)
        curX += 72

        curX = addToggle(.measureLimit, at: curX, title: L("Limit to selection"), isOn: ov.currentMeasureClampToSelection) { [weak ov] isOn in
            ov?.currentMeasureClampToSelection = isOn
            UserDefaults.standard.set(isOn, forKey: "measureClampToSelection")
        }

        // Hint
        curX = addHintLabel(.measureHint, at: curX, text: L("Hold 1 auto-vertical  ·  Hold 2 auto-horizontal"))
        return curX
    }

    private func addStampOptions(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x

        // Size slider — sets the default placement size; resizes the selected stamp when
        // editing. Skipped for capture stamps ("Add Capture" images), which are usually far
        // larger than the slider range — those resize via their handles instead.
        if editingAnnotation?.isCaptureStamp != true {
            let sizeLabel = makeLabel(.stampSizeTitle, text: L("Size"))
            sizeLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
            sizeLabel.textColor = panelForegroundColor
            sizeLabel.sizeToFit()
            sizeLabel.frame.origin = NSPoint(x: curX, y: (rowHeight - sizeLabel.frame.height) / 2)
            addSubview(sizeLabel)
            curX += sizeLabel.frame.width + 4

            let currentSize: CGFloat
            if let ann = editingAnnotation, ann.tool == .stamp {
                currentSize = max(ann.boundingRect.width, ann.boundingRect.height)
            } else {
                currentSize = ov.currentStampSize
            }
            let sizeSlider = makeSlider(.stampSizeSlider, value: Double(currentSize), min: 16, max: 256,
                                        action: #selector(stampSizeChanged(_:)))
            sizeSlider.frame = NSRect(x: curX, y: (rowHeight - 20) / 2, width: 80, height: 20)
            sizeSlider.isContinuous = true
            addSubview(sizeSlider)
            curX += 80 + 4

            let sizeValLabel = makeLabel(.stampSizeValue, text: "\(Int(currentSize))px")
            sizeValLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            sizeValLabel.textColor = panelForegroundColor
            sizeValLabel.alignment = .right
            sizeValLabel.frame = NSRect(x: curX, y: (rowHeight - 14) / 2, width: 34, height: 14)
            sizeValLabel.tag = 989  // stamp size value label
            addSubview(sizeValLabel)
            curX += 34

            curX = addSeparator(at: curX, before: .stampQuickChoices)
        }

        // Quick emoji buttons
        for emoji in StampEmojis.common {
            let btn = makeButton(.stampEmoji(emoji), title: emoji, action: #selector(quickEmojiClicked(_:)))
            btn.bezelStyle = .recessed
            btn.isBordered = false
            btn.font = NSFont.systemFont(ofSize: 18)
            btn.frame = NSRect(x: curX, y: (rowHeight - 26) / 2, width: 26, height: 26)
            addSubview(btn)
            curX += 26
        }
        curX += 4

        curX = addSeparator(at: curX, before: .stampMore)

        let moreBtn = makeButton(.stampMore)
        moreBtn.bezelStyle = .recessed
        moreBtn.isBordered = false
        moreBtn.image = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: L("More Emojis"))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        moreBtn.toolTip = L("More Emojis")
        moreBtn.target = self
        moreBtn.action = #selector(moreEmojisClicked(_:))
        moreBtn.frame = NSRect(x: curX, y: (rowHeight - 26) / 2, width: 28, height: 26)
        addSubview(moreBtn)
        setForegroundTint(on: moreBtn)
        curX += 30

        let loadBtn = makeButton(.stampLoad)
        loadBtn.bezelStyle = .recessed
        loadBtn.isBordered = false
        loadBtn.image = NSImage(systemSymbolName: "photo", accessibilityDescription: L("Load Image"))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        loadBtn.toolTip = L("Load Image")
        loadBtn.target = self
        loadBtn.action = #selector(loadImageClicked)
        loadBtn.frame = NSRect(x: curX, y: (rowHeight - 26) / 2, width: 28, height: 26)
        addSubview(loadBtn)
        setForegroundTint(on: loadBtn)
        curX += 30

        return curX
    }

    private func addRedactOptions(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x

        // — Draw mode: All / Text Only segmented control —
        let drawLabel = makeLabel(.censorDrawTitle, text: L("Draw:"))
        drawLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        drawLabel.textColor = panelForegroundColor
        drawLabel.sizeToFit()
        drawLabel.frame.origin = NSPoint(x: curX, y: (rowHeight - drawLabel.frame.height) / 2)
        addSubview(drawLabel)
        curX += drawLabel.frame.width + 4

        let textOnly = UserDefaults.standard.bool(forKey: "censorTextOnly")
        let drawSeg = makeSegments(.censorDrawMode, labels: [L("All"), L("Text Only")],
                                   action: #selector(drawModeChanged(_:)))
        drawSeg.selectedSegment = textOnly ? 1 : 0
        drawSeg.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        (drawSeg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
        drawSeg.sizeToFit()
        drawSeg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: drawSeg.frame.width, height: 22)
        addSubview(drawSeg)
        curX += drawSeg.frame.width + 4

        curX = addSeparator(at: curX, before: .censorAutoTitle)

        // — Auto-detect buttons —
        let autoLabel = makeLabel(.censorAutoTitle, text: L("Auto:"))
        autoLabel.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        autoLabel.textColor = panelForegroundColor
        autoLabel.sizeToFit()
        autoLabel.frame.origin = NSPoint(x: curX, y: (rowHeight - autoLabel.frame.height) / 2)
        addSubview(autoLabel)
        curX += autoLabel.frame.width + 4

        let btnH: CGFloat = 22
        let btnFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let btnY = (rowHeight - btnH) / 2

        curX = addRedactButton(.redactText, at: curX, title: L("All Text"), action: #selector(redactAllTextClicked),
                               font: btnFont, height: btnH, y: btnY)

        // PII button with dropdown arrow for type selection
        curX = addRedactButton(.redactPII, at: curX, title: L("PII"), action: #selector(redactPIIClicked),
                               font: btnFont, height: btnH, y: btnY,
                               dropdownAction: #selector(redactTypesClicked(_:)))

        curX = addRedactButton(.redactFaces, at: curX, title: L("Faces"), action: #selector(redactFacesClicked),
                               font: btnFont, height: btnH, y: btnY)

        curX = addRedactButton(.redactPeople, at: curX, title: L("People"), action: #selector(redactPeopleClicked),
                               font: btnFont, height: btnH, y: btnY)

        return curX
    }

    private func addBeautifyOptions(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let isSnap = ov.selectionIsWindowSnap
        let controlsEnabled = ov.beautifyEnabled

        // Keep the effect switch first so its enabled state and escape hatch are immediately visible.
        let toggleBtn = makeButton(.beautifyToggle, title: L("Beautify"),
                                   action: #selector(beautifyToggleChanged(_:)), type: .switch)
        toggleBtn.state = controlsEnabled ? .on : .off
        toggleBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        if let cell = toggleBtn.cell as? NSButtonCell {
            cell.attributedTitle = NSAttributedString(string: L("Beautify"), attributes: [
                .foregroundColor: panelForegroundColor,
                .font: NSFont.systemFont(ofSize: 10, weight: .medium)
            ])
        }
        toggleBtn.sizeToFit()
        toggleBtn.frame.origin = NSPoint(
            x: curX, y: (rowHeight - toggleBtn.frame.height) / 2)
        addSubview(toggleBtn)
        curX += toggleBtn.frame.width + 4

        curX = addSeparator(at: curX, before: .beautifyMode)

        // Mode toggle: Window / Rounded — hidden for snapped windows (always uses native chrome)
        if !isSnap {
            let modeSeg = makeSegments(.beautifyMode, labels: ["W", "R"],
                                       action: #selector(beautifyModeChanged(_:)), isEnabled: controlsEnabled)
            modeSeg.selectedSegment = ov.beautifyMode == .window ? 0 : 1
            modeSeg.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: 56, height: 22)
            (modeSeg.cell as? NSSegmentedCell)?.segmentStyle = .roundRect
            addSubview(modeSeg)
            curX += 56

            curX = addSeparator(at: curX, before: .beautifyTitle(.padding))
        }

        // Padding slider
        curX = addBeautifySlider(.padding, at: curX, label: L("Padding"), value: ov.beautifyPadding, min: 16, max: 96, isEnabled: controlsEnabled, action: #selector(beautifyPaddingChanged(_:)))

        // Corner radius slider — hidden for snapped windows (native corners are baked in)
        if !isSnap {
            curX = addBeautifySlider(.radius, at: curX, label: L("Radius"), value: ov.beautifyCornerRadius, min: 0, max: 30, isEnabled: controlsEnabled, action: #selector(beautifyCornerChanged(_:)))
        }

        // Shadow slider
        curX = addBeautifySlider(.shadow, at: curX, label: L("Shadow"), value: ov.beautifyShadowRadius, min: 0, max: 100, isEnabled: controlsEnabled, action: #selector(beautifyShadowChanged(_:)))

        // Blur slider — only shown for custom image backgrounds
        if ov.beautifyStyleIndex == -1 {
            curX = addBeautifySlider(.blur, at: curX, label: L("Blur"), value: ov.beautifyBackgroundBlur, min: 0, max: 50, isEnabled: controlsEnabled, action: #selector(beautifyBlurChanged(_:)))
        }

        curX = addSeparator(at: curX, before: .beautifySwatch)

        // Gradient style picker — swatch preview + dropdown arrow
        curX += 2
        let swatchSize: CGFloat = 22
        let swatchBtn = makeButton(.beautifySwatch, isEnabled: controlsEnabled)
        swatchBtn.frame = NSRect(x: curX, y: (rowHeight - swatchSize) / 2, width: swatchSize, height: swatchSize)
        swatchBtn.bezelStyle = .recessed
        swatchBtn.isBordered = false
        swatchBtn.image = Self.gradientSwatchImage(styleIndex: ov.beautifyStyleIndex, size: swatchSize, color: panelForegroundColor)
        swatchBtn.imageScaling = .scaleProportionallyUpOrDown
        swatchBtn.target = self
        swatchBtn.action = #selector(beautifyGradientClicked(_:))
        swatchBtn.toolTip = L("Gradient Style")
        swatchBtn.tag = 995
        addSubview(swatchBtn)
        curX += swatchSize + 2

        let arrowBtn = makeButton(.beautifyDisclosure, isEnabled: controlsEnabled)
        arrowBtn.frame = NSRect(x: curX, y: (rowHeight - 16) / 2, width: 14, height: 16)
        arrowBtn.bezelStyle = .recessed
        arrowBtn.isBordered = false
        arrowBtn.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        arrowBtn.target = self
        arrowBtn.action = #selector(beautifyGradientClicked(_:))
        addSubview(arrowBtn)
        setForegroundTint(on: arrowBtn, alpha: controlsEnabled ? 1 : 0.35)
        curX += 18

        return curX
    }

    private func addBeautifySlider(_ property: BeautifyProperty, at x: CGFloat, label: String, value: CGFloat, min: CGFloat, max: CGFloat, isEnabled: Bool, action: Selector) -> CGFloat {
        var curX = x
        let lbl = makeLabel(.beautifyTitle(property), text: label, isEnabled: isEnabled)
        lbl.font = NSFont.systemFont(ofSize: 9, weight: .medium)
        lbl.textColor = panelForegroundColor.withAlphaComponent(isEnabled ? 1 : 0.35)
        lbl.sizeToFit()
        lbl.frame.origin = NSPoint(x: curX, y: (rowHeight - lbl.frame.height) / 2)
        addSubview(lbl)
        curX += lbl.frame.width + 3

        let slider = makeSlider(.beautifySlider(property), value: Double(value), min: Double(min), max: Double(max),
                                action: action, isEnabled: isEnabled)
        slider.frame = NSRect(x: curX, y: (rowHeight - 18) / 2, width: 60, height: 18)
        slider.isContinuous = true
        addSubview(slider)
        curX += 64

        return curX
    }

    // MARK: - Beautify Actions

    @objc private func beautifyModeChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        ov.beautifyMode = sender.selectedSegment == 0 ? .window : .rounded
        UserDefaults.standard.set(ov.beautifyMode.rawValue, forKey: "beautifyMode")
        ov.needsDisplay = true
        ov.onContentChanged?()
    }

    @objc private func beautifyPaddingChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        ov.beautifyPadding = CGFloat(sender.floatValue)
        UserDefaults.standard.set(sender.doubleValue, forKey: "beautifyPadding")
        ov.needsDisplay = true
        ov.onContentChanged?()
    }

    @objc private func beautifyCornerChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        ov.beautifyCornerRadius = CGFloat(sender.floatValue)
        UserDefaults.standard.set(sender.doubleValue, forKey: "beautifyCornerRadius")
        ov.needsDisplay = true
        ov.onContentChanged?()
    }

    @objc private func beautifyShadowChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        ov.beautifyShadowRadius = CGFloat(sender.floatValue)
        UserDefaults.standard.set(sender.doubleValue, forKey: "beautifyShadowRadius")
        ov.needsDisplay = true
        ov.onContentChanged?()
    }

    @objc private func beautifyBlurChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        ov.beautifyBackgroundBlur = CGFloat(sender.floatValue)
        UserDefaults.standard.set(sender.doubleValue, forKey: "beautifyBgBlur")
        ov.cachedCompositedImage = nil
        ov.needsDisplay = true
        ov.onContentChanged?()
    }

    func updateBeautifySwatch(styleIndex: Int) {
        guard let btn = viewWithTag(995) as? NSButton else { return }
        btn.image = Self.gradientSwatchImage(styleIndex: styleIndex, size: 22, color: panelForegroundColor)
    }

    @objc private func beautifyGradientClicked(_ sender: NSButton) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        guard let ov = overlayView else { return }
        let swatchBtn = viewWithTag(995) as? NSButton ?? sender
        ov.showBeautifyGradientPopover(anchorView: swatchBtn)
    }

    @objc private func beautifyToggleChanged(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        ov.setBeautifyEnabled(sender.state == .on)
        ov.rebuildToolbarLayout()
    }

    private func addHintLabel(_ role: ControlRole, at x: CGFloat, text: String) -> CGFloat {
        let label = makeLabel(role, text: text)
        label.font = NSFont.systemFont(ofSize: 9.5, weight: .medium)
        label.textColor = panelForegroundColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: x, y: (rowHeight - label.frame.height) / 2)
        addSubview(label)
        return x + label.frame.width + 8
    }

    // MARK: - Actions

    @objc private func strokeSliderChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        var val = CGFloat(sender.floatValue)
        if let ann = editingAnnotation {
            ensureSnapshot()
            if ann.tool == .loupe {
                val = max(40, val)
                let rect = ann.boundingRect
                let center = NSPoint(x: rect.midX, y: rect.midY)
                ann.startPoint = NSPoint(x: center.x - val / 2, y: center.y - val / 2)
                ann.endPoint = NSPoint(x: center.x + val / 2, y: center.y + val / 2)
                ann.strokeWidth = val
                ann.bakedBlurNSImage = nil
                ann.bakeLoupe()
            } else {
                ann.strokeWidth = val
            }
            ov.cachedCompositedImage = nil
        }
        // Always update the global default so the last-picked stroke sticks
        // for the next capture, whether or not an annotation was being edited.
        if let tool = currentTool { ov.setActiveStrokeWidth(val, for: tool) }
        if let label = viewWithTag(997) as? NSTextField {
            label.stringValue = currentTool == .loupe ? "\(Int(val))" : "\(Int(val))px"
        }
        ov.needsDisplay = true
    }

    @objc private func stampSizeChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        let val = min(256, max(16, CGFloat(sender.doubleValue)))
        if let ann = editingAnnotation, ann.tool == .stamp, !ann.isCaptureStamp {
            ensureSnapshot()
            // Resize around the center, preserving aspect ratio.
            let rect = ann.boundingRect
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let aspect = rect.width / max(rect.height, 1)
            let w = aspect >= 1 ? val : val * aspect
            let h = aspect >= 1 ? val / aspect : val
            ann.startPoint = NSPoint(x: center.x - w / 2, y: center.y - h / 2)
            ann.endPoint = NSPoint(x: center.x + w / 2, y: center.y + h / 2)
            ov.cachedCompositedImage = nil
        }
        // Always update the default so the next stamp is placed at this size.
        ov.setActiveStampSize(val)
        if let label = viewWithTag(989) as? NSTextField {
            label.stringValue = "\(Int(val))px"
        }
        ov.needsDisplay = true
    }

    @objc private func loupeMagnificationChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        let val = min(6.0, max(1.1, CGFloat(sender.doubleValue)))
        if let ann = editingAnnotation, ann.tool == .loupe {
            ensureSnapshot()
            ann.loupeMagnification = val
            // Keep the source circle framing exactly what the lens shows.
            ann.syncLoupeSourceToMagnification()
            ann.bakedBlurNSImage = nil
            ann.bakeLoupe()
            ov.cachedCompositedImage = nil
        }
        ov.setActiveLoupeMagnification(val)
        if let label = viewWithTag(994) as? NSTextField {
            label.stringValue = String(format: "%.1fx", val)
        }
        ov.needsDisplay = true
    }

    @objc private func highlightDimChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        let val = min(0.95, max(0.1, CGFloat(sender.doubleValue)))
        if let ann = editingAnnotation, ann.tool == .highlight {
            // Editing a specific selected highlight.
            ensureSnapshot()
            ann.dimOpacity = val
            ov.cachedCompositedImage = nil
        } else {
            // Highlight tool active with no specific selection: the dim is a
            // single spotlight level, so apply it to every placed highlight live
            // (not just the next one). Highlight bakes nothing — invalidating the
            // cache re-renders the union dim at the new strength.
            var changed = false
            for ann in ov.annotations where ann.tool == .highlight {
                ann.dimOpacity = val
                changed = true
            }
            if changed { ov.cachedCompositedImage = nil }
        }
        UserDefaults.standard.set(Double(val), forKey: HighlightToolHandler.dimOpacityKey)
        if let label = viewWithTag(993) as? NSTextField {
            label.stringValue = "\(Int((val * 100).rounded()))%"
        }
        ov.needsDisplay = true
    }

    @objc private func highlightBorderChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        let dashed = sender.selectedSegment == 1
        let style: LineStyle = dashed ? .dashed : .solid
        if let ann = editingAnnotation, ann.tool == .highlight {
            ensureSnapshot()
            ann.lineStyle = style
            ov.cachedCompositedImage = nil
        } else {
            var changed = false
            for ann in ov.annotations where ann.tool == .highlight {
                ann.lineStyle = style
                changed = true
            }
            if changed { ov.cachedCompositedImage = nil }
        }
        UserDefaults.standard.set(dashed, forKey: HighlightToolHandler.dashedBorderKey)
        ov.needsDisplay = true
    }

    @objc private func lineStyleChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        if let style = LineStyle(rawValue: sender.selectedSegment) {
            if let ann = editingAnnotation {
                ensureSnapshot()
                ann.lineStyle = style
                ov.cachedCompositedImage = nil
            }
            ov.currentLineStyle = style
            UserDefaults.standard.set(style.rawValue, forKey: "currentLineStyle")
            ov.needsDisplay = true
        }
    }

    @objc private func arrowStyleChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        if let style = ArrowStyle(rawValue: sender.selectedSegment) {
            if let ann = editingAnnotation {
                ensureSnapshot()
                ann.arrowStyle = style
                ov.cachedCompositedImage = nil
            }
            ov.currentArrowStyle = style
            UserDefaults.standard.set(style.rawValue, forKey: "currentArrowStyle")
            ov.needsDisplay = true
        }
    }

    @objc private func shapeFillChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        if let style = RectFillStyle(rawValue: sender.selectedSegment) {
            if let ann = editingAnnotation {
                ensureSnapshot()
                ann.rectFillStyle = style
                ov.cachedCompositedImage = nil
            }
            ov.currentRectFillStyle = style
            UserDefaults.standard.set(style.rawValue, forKey: "currentRectFillStyle")
            ov.needsDisplay = true
        }
    }

    @objc private func cornerRadiusChanged(_ sender: NSSlider) {
        guard let ov = overlayView else { return }
        let val = CGFloat(sender.floatValue)
        if let ann = editingAnnotation {
            ensureSnapshot()
            ann.rectCornerRadius = val
            ov.cachedCompositedImage = nil
        }
        ov.currentRectCornerRadius = val
        UserDefaults.standard.set(sender.doubleValue, forKey: "currentRectCornerRadius")
        if let label = viewWithTag(996) as? NSTextField {
            label.stringValue = "\(Int(val))px"
        }
        ov.needsDisplay = true
    }

    @objc private func censorModeChanged(_ sender: NSSegmentedControl) {
        guard let mode = CensorMode(rawValue: sender.selectedSegment) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: "censorMode")
        if let ann = editingAnnotation, ann.tool == .pixelate || ann.tool == .blur {
            ensureSnapshot()
            ann.censorMode = mode
            // Clear the baked image so bakePixelate re-runs with the new mode.
            ann.bakedBlurNSImage = nil
            ann.bakePixelate()
            overlayView?.cachedCompositedImage = nil
            overlayView?.needsDisplay = true
        }
    }

    @objc private func numberFormatChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        if let fmt = NumberFormat(rawValue: sender.selectedSegment) {
            ov.currentNumberFormat = fmt
            UserDefaults.standard.set(fmt.rawValue, forKey: "numberFormat")
            // Update start value preview to match new format
            if let label = viewWithTag(999) as? NSTextField {
                label.stringValue = fmt.format(ov.numberStartAt)
                label.sizeToFit()
            }
            ov.needsDisplay = true
        }
    }

    @objc private func numberStartChanged(_ sender: NSStepper) {
        guard let ov = overlayView else { return }
        ov.numberStartAt = sender.integerValue
        UserDefaults.standard.set(sender.integerValue, forKey: "numberStartAt")
        // Update value label
        if let label = viewWithTag(999) as? NSTextField {
            label.stringValue = ov.currentNumberFormat.format(sender.integerValue)
            label.sizeToFit()
        }
        ov.needsDisplay = true
    }



    @objc private func boldToggled() { overlayView?.textEditor.toggleBold(); overlayView.map { $0.applyTextFormattingToSelectedAnnotations(); $0.needsDisplay = true; rebuild(for: $0.currentTool) } }
    @objc private func italicToggled() { overlayView?.textEditor.toggleItalic(); overlayView.map { $0.applyTextFormattingToSelectedAnnotations(); $0.needsDisplay = true; rebuild(for: $0.currentTool) } }
    @objc private func underlineToggled() { overlayView?.textEditor.toggleUnderline(); overlayView.map { $0.applyTextFormattingToSelectedAnnotations(); $0.needsDisplay = true; rebuild(for: $0.currentTool) } }
    @objc private func strikethroughToggled() { overlayView?.textEditor.toggleStrikethrough(); overlayView.map { $0.applyTextFormattingToSelectedAnnotations(); $0.needsDisplay = true; rebuild(for: $0.currentTool) } }

    @objc private func measureUnitChanged(_ sender: NSSegmentedControl) {
        guard let ov = overlayView else { return }
        ov.currentMeasureInPoints = sender.selectedSegment == 1
        UserDefaults.standard.set(ov.currentMeasureInPoints, forKey: "measureInPoints")
        ov.needsDisplay = true
    }

    @objc private func quickEmojiClicked(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        ov.currentStampImage = StampEmojis.renderEmoji(sender.title)
        ov.currentStampEmoji = sender.title
        ov.needsDisplay = true
    }

    @objc private func moreEmojisClicked(_ sender: NSButton) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        guard let ov = overlayView else { return }
        ov.showEmojiPopover(anchorView: sender)
    }

    @objc private func loadImageClicked() {
        guard let ov = overlayView else { return }
        StampEmojis.loadStampImage { [weak ov] image in
            ov?.currentStampImage = image
            ov?.currentStampEmoji = nil
            ov?.needsDisplay = true
        }
    }

    @objc private func drawModeChanged(_ sender: NSSegmentedControl) {
        UserDefaults.standard.set(sender.selectedSegment == 1, forKey: "censorTextOnly")
    }

    @objc private func pencilSmoothModeChanged(_ sender: NSSegmentedControl) {
        let mode = sender.selectedSegment
        overlayView?.pencilSmoothMode = mode
        UserDefaults.standard.set(mode, forKey: "pencilSmoothMode")
    }

    @objc private func redactAllTextClicked() {
        overlayView?.performRedactAllText()
    }

    @objc private func redactPIIClicked() {
        overlayView?.performAutoRedact()
    }

    @objc private func redactFacesClicked() {
        overlayView?.performRedactFaces()
    }

    @objc private func redactPeopleClicked() {
        overlayView?.performRedactPeople()
    }

    @objc private func redactTypesClicked(_ sender: NSView) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        guard let ov = overlayView else { return }
        ov.showRedactTypePopover(anchorRect: .zero, anchorView: sender)
    }

    @objc private func fontFamilyClicked(_ sender: NSButton) {
        // Toggle: close if already open
        if PopoverHelper.toggleClosedIfOpen() { return }
        guard let ov = overlayView else { return }
        let picker = FontPickerView(selectedFamily: ov.textEditor.fontFamily)
        picker.onSelect = { [weak ov] family in
            guard let ov = ov else { return }
            ov.textEditor.fontFamily = family
            UserDefaults.standard.set(family, forKey: "textFontFamily")
            ov.textEditor.applyFontSizeChange()
            ov.applyTextFormattingToSelectedAnnotations()
            ov.rebuildToolbarLayout()
            ov.needsDisplay = true
            PopoverHelper.dismiss()
        }
        PopoverHelper.show(picker, size: picker.preferredSize, relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        DispatchQueue.main.async {
            picker.scrollToTop()
        }
    }

    @objc private func alignmentChanged(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        if let align = NSTextAlignment(rawValue: sender.tag) {
            ov.textEditor.alignment = align
            ov.textEditor.applyAlignment()
            ov.applyTextFormattingToSelectedAnnotations()
            // Update all alignment buttons — only the selected one should be on
            for case let btn as NSButton in subviews where
                btn.tag == NSTextAlignment.left.rawValue ||
                btn.tag == NSTextAlignment.center.rawValue ||
                btn.tag == NSTextAlignment.right.rawValue {
                btn.state = btn.tag == align.rawValue ? .on : .off
            }
            ov.needsDisplay = true
        }
    }

    @objc private func fontSizeDecreased() {
        guard let ov = overlayView else { return }
        ov.textEditor.fontSize = max(8, ov.textEditor.fontSize - 1)
        UserDefaults.standard.set(Double(ov.textEditor.fontSize), forKey: "textFontSize")
        ov.textEditor.applyFontSizeChange()
        ov.textEditor.resizeToFit()
        ov.applyTextFormattingToSelectedAnnotations()
        if let label = viewWithTag(998) as? NSTextField { label.stringValue = "\(Int(ov.textEditor.fontSize))" }
        ov.needsDisplay = true
    }

    @objc private func fontSizeIncreased() {
        guard let ov = overlayView else { return }
        ov.textEditor.fontSize = min(200, ov.textEditor.fontSize + 1)
        UserDefaults.standard.set(Double(ov.textEditor.fontSize), forKey: "textFontSize")
        ov.textEditor.applyFontSizeChange()
        ov.textEditor.resizeToFit()
        ov.applyTextFormattingToSelectedAnnotations()
        if let label = viewWithTag(998) as? NSTextField { label.stringValue = "\(Int(ov.textEditor.fontSize))" }
        ov.needsDisplay = true
    }

    @objc private func textBgToggled(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        ov.textEditor.bgEnabled = sender.state == .on
        UserDefaults.standard.set(ov.textEditor.bgEnabled, forKey: "textBgEnabled")
        // Update swatch opacity
        if let swatch = viewWithTag(975) { swatch.layer?.opacity = ov.textEditor.bgEnabled ? 1.0 : 0.3 }
        ov.applyTextBgOutlineToSelectedAnnotations()
        ov.needsDisplay = true
    }

    @objc private func textOutlineToggled(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        ov.textEditor.outlineEnabled = sender.state == .on
        UserDefaults.standard.set(ov.textEditor.outlineEnabled, forKey: "textOutlineEnabled")
        if let swatch = viewWithTag(976) { swatch.layer?.opacity = ov.textEditor.outlineEnabled ? 1.0 : 0.3 }
        ov.applyTextBgOutlineToSelectedAnnotations()
        ov.needsDisplay = true
    }

    @objc private func textBgColorClicked(_ sender: NSButton) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        guard let ov = overlayView else { return }
        ov.showColorPickerPopover(target: .textBg, anchorView: sender)
    }

    @objc private func textOutlineColorClicked(_ sender: NSButton) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        guard let ov = overlayView else { return }
        ov.showColorPickerPopover(target: .textOutline, anchorView: sender)
    }

    @objc private func textGlyphStrokeToggled(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        ov.textEditor.glyphStrokeEnabled = sender.state == .on
        UserDefaults.standard.set(ov.textEditor.glyphStrokeEnabled, forKey: "textGlyphStrokeEnabled")
        if let swatch = viewWithTag(977) { swatch.layer?.opacity = ov.textEditor.glyphStrokeEnabled ? 1.0 : 0.3 }
        ov.applyGlyphStrokeToLiveTextView()
        ov.applyTextBgOutlineToSelectedAnnotations()
        ov.needsDisplay = true
    }

    @objc private func textGlyphStrokeColorClicked(_ sender: NSButton) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        guard let ov = overlayView else { return }
        ov.showColorPickerPopover(target: .textGlyphStroke, anchorView: sender)
    }

    // MARK: - Annotation outline

    private func addOutlineControls(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let outlineEnabled: Bool
        let outlineCol: NSColor
        if let ann = editingAnnotation {
            outlineEnabled = ann.outlineColor != nil
            outlineCol = ann.outlineColor ?? Self.savedOutlineColor
        } else {
            outlineEnabled = UserDefaults.standard.bool(forKey: "annotationOutlineEnabled")
            outlineCol = Self.savedOutlineColor
        }
        let outlineBtn = makeButton(.annotationOutlineToggle, title: L("Outline"), action: #selector(annotationOutlineToggled(_:)), type: .toggle)
        outlineBtn.bezelStyle = .recessed
        outlineBtn.state = outlineEnabled ? .on : .off
        outlineBtn.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        outlineBtn.attributedTitle = NSAttributedString(string: L("Outline"), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .baselineOffset: 0.5,
        ])
        outlineBtn.sizeToFit()
        let rowHeight: CGFloat = frame.height > 0 ? frame.height : 30
        outlineBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: max(50, outlineBtn.frame.width), height: 22)
        addSubview(outlineBtn)
        curX += outlineBtn.frame.width + 2

        let swatchSize: CGFloat = 18
        let swatch = makeButton(.annotationOutlineSwatch)
        swatch.frame = NSRect(x: curX, y: (rowHeight - swatchSize) / 2, width: swatchSize, height: swatchSize)
        swatch.title = ""
        swatch.isBordered = false
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = outlineCol.cgColor
        swatch.layer?.cornerRadius = 3
        swatch.layer?.borderWidth = 1.5
        swatch.layer?.borderColor = panelForegroundColor.withAlphaComponent(0.4).cgColor
        swatch.layer?.opacity = outlineEnabled ? 1.0 : 0.3
        swatch.tag = 978
        swatch.target = self
        swatch.action = #selector(annotationOutlineColorClicked(_:))
        addSubview(swatch)
        curX += swatchSize
        return curX
    }

    static var savedOutlineColor: NSColor {
        if let data = UserDefaults.standard.data(forKey: "annotationOutlineColor"),
           let c = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) { return c }
        return .white
    }

    @objc private func annotationOutlineToggled(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        let isOn = sender.state == .on
        UserDefaults.standard.set(isOn, forKey: "annotationOutlineEnabled")
        if let swatch = viewWithTag(978) { swatch.layer?.opacity = isOn ? 1.0 : 0.3 }
        if let ann = editingAnnotation {
            ensureSnapshot()
            ann.outlineColor = isOn ? Self.savedOutlineColor : nil
            ov.cachedCompositedImage = nil
        }
        // Rebuild to update line style segment enabled state (rect/ellipse disable dashed/dotted with outline)
        let tool = editingAnnotation?.tool ?? ov.currentTool
        if tool == .rectangle || tool == .ellipse {
            if let ann = editingAnnotation {
                rebuild(forAnnotation: ann)
            } else {
                rebuild(for: tool)
            }
        }
        ov.needsDisplay = true
    }

    @objc private func annotationOutlineColorClicked(_ sender: NSButton) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        guard let ov = overlayView else { return }
        ov.showColorPickerPopover(target: .annotationOutline, anchorView: sender)
    }

    // MARK: - Loupe outline color

    private func addLoupeOutlineControls(at x: CGFloat, ov: OverlayView) -> CGFloat {
        var curX = x
        let enabled: Bool
        let col: NSColor
        if let ann = editingAnnotation, ann.tool == .loupe {
            enabled = ann.loupeOutlineEnabled
            col = ann.outlineColor ?? ov.currentLoupeOutlineColor
        } else {
            enabled = ov.currentLoupeOutlineEnabled
            col = ov.currentLoupeOutlineColor
        }

        let outlineBtn = makeButton(.loupeOutlineToggle, title: L("Outline"), action: #selector(loupeOutlineToggled(_:)), type: .toggle)
        outlineBtn.bezelStyle = .recessed
        outlineBtn.state = enabled ? .on : .off
        outlineBtn.attributedTitle = NSAttributedString(string: L("Outline"), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .baselineOffset: 0.5,
        ])
        outlineBtn.sizeToFit()
        let rowHeight: CGFloat = frame.height > 0 ? frame.height : 30
        outlineBtn.frame = NSRect(x: curX, y: (rowHeight - 22) / 2, width: max(50, outlineBtn.frame.width), height: 22)
        addSubview(outlineBtn)
        curX += outlineBtn.frame.width + 2

        let swatchSize: CGFloat = 18
        let swatch = makeButton(.loupeOutlineSwatch)
        swatch.frame = NSRect(x: curX, y: (rowHeight - swatchSize) / 2, width: swatchSize, height: swatchSize)
        swatch.title = ""
        swatch.isBordered = false
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = col.cgColor
        swatch.layer?.cornerRadius = 3
        swatch.layer?.borderWidth = 1.5
        swatch.layer?.borderColor = panelForegroundColor.withAlphaComponent(0.4).cgColor
        swatch.layer?.opacity = enabled ? 1.0 : 0.3
        swatch.tag = 976
        swatch.target = self
        swatch.action = #selector(loupeOutlineColorClicked(_:))
        addSubview(swatch)
        curX += swatchSize
        return curX
    }

    @objc private func loupeOutlineToggled(_ sender: NSButton) {
        guard let ov = overlayView else { return }
        let isOn = sender.state == .on
        ov.currentLoupeOutlineEnabled = isOn
        UserDefaults.standard.set(isOn, forKey: "loupeOutlineEnabled")
        if let swatch = viewWithTag(976) { swatch.layer?.opacity = isOn ? 1.0 : 0.3 }
        if let ann = editingAnnotation, ann.tool == .loupe {
            ensureSnapshot()
            ann.loupeOutlineEnabled = isOn
            if isOn, ann.outlineColor == nil { ann.outlineColor = ov.currentLoupeOutlineColor }
            ov.invalidateLoupeCaches()
        }
        ov.needsDisplay = true
    }

    @objc private func loupeOutlineColorClicked(_ sender: NSButton) {
        if PopoverHelper.toggleClosedIfOpen() { return }
        guard let ov = overlayView else { return }
        ov.showColorPickerPopover(target: .loupeOutline, anchorView: sender)
    }

    @objc private func textCancelClicked() {
        overlayView?.cancelTextEditing()
    }

    @objc private func textConfirmClicked() {
        overlayView?.commitTextFieldIfNeeded()
    }
}

// Helper for toggle closures
private class ToggleHandler: NSObject {
    var action: (Bool) -> Void
    init(action: @escaping (Bool) -> Void) { self.action = action }
    @objc func toggled(_ sender: NSButton) { action(sender.state == .on) }
}
