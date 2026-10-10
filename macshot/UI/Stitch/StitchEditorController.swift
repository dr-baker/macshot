import AppKit

private final class StitchPiecesStack: NSStackView {
    override var isFlipped: Bool { true }
}

private final class StitchSlider: NSSlider {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onBegin?(); super.mouseDown(with: event); onEnd?() }
    override func keyDown(with event: NSEvent) { onBegin?(); super.keyDown(with: event); onEnd?() }
}

private enum StitchSeamParameter: Int, CaseIterable {
    case blur, feather, lineWidth, shape, tearWidth, foldDepth, foldStrength, accordionWidth, accordionPleats

    func keyPath(for transition: StitchTransition) -> WritableKeyPath<StitchStyle, CGFloat> {
        switch self {
        case .blur: return \.blur
        case .feather: return \.feather
        case .lineWidth: return \.lineWidth
        case .shape:
            switch transition {
            case .torn: return \.tearRoughness
            case .breakLine: return \.breakSize
            default: return \.wave
            }
        case .tearWidth: return \.tearWidth
        case .foldDepth: return \.foldDepth
        case .foldStrength: return \.foldStrength
        case .accordionWidth: return \.accordionWidth
        case .accordionPleats: return \.accordionPleats
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .blur: return 0...30
        case .feather: return 0...100
        case .lineWidth: return 0...8
        case .shape: return 0...14
        case .tearWidth: return 2...32
        case .foldDepth: return 0...80
        case .foldStrength: return 0...Double(StitchStyle.maximumFoldStrength)
        case .accordionWidth: return 4...64
        case .accordionPleats: return 2...6
        }
    }

    func title(for transition: StitchTransition) -> String {
        switch self {
        case .blur: return L("Blur")
        case .feather: return L("Fade width")
        case .lineWidth: return L("Line width")
        case .shape:
            switch transition {
            case .torn: return L("Roughness")
            case .breakLine: return L("Break size")
            default: return L("Wave height")
            }
        case .tearWidth: return L("Paper width")
        case .foldDepth: return L("Fold depth")
        case .foldStrength: return L("Strength")
        case .accordionWidth: return L("Fold width")
        case .accordionPleats: return L("Pleats")
        }
    }

    func formattedValue(_ value: CGFloat) -> String {
        if self == .accordionPleats { return String(Int(value.rounded())) }
        return self == .foldStrength ? String(format: "%.0f%%", Double(value / StitchStyle.maximumFoldStrength) * 100)
            : String(format: "%.1f px", Double(value))
    }

    static func visible(for transition: StitchTransition, hasUnmeasuredAccordionJoins: Bool) -> [Self] {
        switch transition {
        case .wave, .breakLine: return [.blur, .feather, .lineWidth, .shape]
        case .blend: return [.blur, .feather]
        case .torn: return [.tearWidth, .shape]
        case .fold: return [.foldDepth, .foldStrength]
        case .accordion: return hasUnmeasuredAccordionJoins ? [.accordionWidth, .accordionPleats] : [.accordionPleats]
        }
    }
}

enum StitchOptionsAction { case seams, pieces, canvas, background, animation }

/// Edits source pieces on the main editor canvas; the host owns all chrome and output actions.
@MainActor
final class StitchEditorController: NSObject {
    private weak var window: NSWindow?
    private weak var editorView: ImageEditingView?
    /// The host validates, renders, and records undo before committing a change.
    var onDocumentChanged: ((StitchDocument, Bool) -> Bool)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var canUndo: (() -> Bool)?
    var canRedo: (() -> Bool)?
    var onAction: ((ToolbarButtonAction, NSView?) -> Void)?
    var annotationLayers: [UUID: StitchAnnotationLayer] = [:] { didSet { canvas.annotationLayers = annotationLayers } }
    var unattachedAnnotationPreview: CGImage? { didSet { canvas.unattachedAnnotationPreview = unattachedAnnotationPreview } }
    var annotationPreview: CGImage? {
        didSet {
            canvas.annotationPreview = annotationPreview
            if cameraSnapshot != nil {
                _ = paperPreview.cancelCameraGesture()
                _ = angleControl.cancelCameraGesture()
                endCameraGesture(commit: false)
            }
            schedulePaperPreview()
        }
    }
    private var restoring = false
    private var adjustingStyle = false
    private let canvas = StitchCanvasView(frame: .zero)
    private let paperPreview = StitchPaperPreviewView(frame: .zero)
    private var paperGeneration = UUID()
    private var pendingPaperPreview: DispatchWorkItem?
    private var paperRenderCancellation: StitchPreviewCancellation?
    private let paperPresentationCache = ScreenshotPresentation.Cache()
    private var paperTexture: (source: CGImage, size: NSSize, pixels: CGImage)?
    private var pendingNativePaperWarm: DispatchWorkItem?
    private let nativePaperWarmQueue = DispatchQueue(label: "macshot.stitch-output-warm", qos: .utility)
    private weak var previewScrollView: NSScrollView?
    private var savedPreviewInsets: NSEdgeInsets?
    private var savedPreviewClipping: Bool?
    private var animatesNextPaperPreview = false
    private var cameraSnapshot: StitchDocument?
    private var committingCamera = false
    private weak var cameraScopeOwner: NSView?
    private var interactiveTexture: CGImage?
    private var interactivePaperSource: StitchAccordionProjection.Source?
    private var interactiveBackground: CGImage?
    private var interactivePaperFrame: CGRect?
    private let angleControl = StitchPaperAngleControl(frame: .zero)
    private let angleHint = NSTextField(wrappingLabelWithString: L("Drag the paper to tilt it. Hold ⌥ for precision or ⇧ to stay on one axis."))
    private lazy var animationButton = button("film", title: L("Save Animation"), action: #selector(saveAnimation))
    private var animationSavePanel: StitchAnimationSavePanel?
    var isAttached: Bool { canvas.superview != nil }
    private var document: StitchDocument
    private var dragSnapshot: StitchDocument?
    private var seamOptions: NSView!
    private let pieceScroll = NSScrollView()
    private let piecesStack = StitchPiecesStack()
    private let pieceCountLabel = NSTextField(labelWithString: "")
    private var sliders: [StitchSlider] = []
    private var values: [NSTextField] = []
    private var seamLabels: [NSTextField] = []
    private let seamStylePicker = StitchSeamStylePicker(frame: .zero)
    private let color = NSColorWell()
    private let seamToggle = NSButton(checkboxWithTitle: L("Show stitch seams"), target: nil, action: nil)
    private let renderQueue = DispatchQueue(label: "macshot.stitch-preview", qos: .userInitiated)
    private var renderGeneration = UUID()
    private var renderCancellation: StitchPreviewCancellation?
    private var pendingRender: DispatchWorkItem?
    private let guideQueue = DispatchQueue(label: "macshot.stitch-band-guides", qos: .userInitiated)
    private var guideGeneration = UUID()
    private var guideCancellation: StitchPreviewCancellation?
    private var cachedGuideLayout: StitchDocument?
    private var cachedBandGuides: StitchBandGuides.Result?
    private var pendingGuideLayout: StitchDocument?
    private let canvasColor = NSColorWell()
    private let backgroundChoice = NSPopUpButton()
    private var pieceActions: [NSButton] = []
    private var feedbackGeneration = UUID()
    private let feedback = StitchTooltipView()

    init(document: StitchDocument, window: NSWindow) {
        self.document = document
        self.window = window
        super.init()
    }

    func attach(to editor: ImageEditingView) {
        editorView = editor
        canvas.inlineEditor = editor
        if canvas.superview !== editor {
            editor.addSubview(canvas, positioned: .below, relativeTo: editor.subviews.first)
        }
        if paperPreview.superview !== editor {
            editor.addSubview(paperPreview, positioned: .below, relativeTo: editor.subviews.first)
        }
        paperPreview.isHidden = true
        paperPreview.onEdit = { [weak self, weak editor] in
            editor?.stitchPreviewEnabled = false
            self?.focus()
        }
        paperPreview.onCameraBegin = { [weak self] in
            guard let self else { return }
            self.beginCameraGesture(owner: self.paperPreview)
        }
        paperPreview.onCameraChanged = { [weak self] camera in self?.changeCamera(camera) }
        paperPreview.onCameraEnd = { [weak self] commit in self?.endCameraGesture(commit: commit) }
        paperPreview.onReset = { [weak self] in self?.resetCamera() }
        angleControl.onCameraBegin = { [weak self] in
            guard let self else { return }
            self.beginCameraGesture(owner: self.angleControl)
        }
        angleControl.onCameraChanged = { [weak self] camera in self?.changeCamera(camera) }
        angleControl.onCameraEnd = { [weak self] commit in self?.endCameraGesture(commit: commit) }
        angleControl.onReset = { [weak self] in self?.resetCamera() }
        editor.onStitchPreviewChanged = { [weak self] in
            self?.updatePaperVisibility()
            self?.schedulePaperPreview()
        }
        canvas.mode = editor.stitchMode
        if seamOptions == nil { seamOptions = makeSeamOptions() }
        piecesStack.orientation = .vertical
        piecesStack.alignment = .leading
        piecesStack.spacing = 4
        pieceScroll.hasVerticalScroller = true
        pieceScroll.autohidesScrollers = true
        pieceScroll.drawsBackground = false
        pieceScroll.documentView = piecesStack
        editor.onStitchSeamColorPreview = { [weak self] color in self?.previewSeamColor(color) }
        canvas.onSelect = { [weak self] _ in self?.refreshPieces() }
        canvas.onCut = { [weak self] axis, from, to in
            guard let self else { return }
            // Freeze the visible pixels before slicing annotations. The folded
            // strip must keep censors and other edits that disappear in the cut.
            guard let composite = self.editorView?.captureSelectedRegion(),
                  let texture = composite.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.showFeedback(L("Unable to render this canvas. Reduce its size and try again."))
                return
            }
            var next = self.document
            if next.collapse(axis: axis, from: from, to: to, texture: texture) {
                guard self.commitDocument(next) else { return }
                self.canvas.selectedID = nil
                self.refresh(); self.showFeedback(L("Space collapsed. Undo restores the original pieces."))
                if next.hasAccordionFolds {
                    self.animatesNextPaperPreview = true
                    self.editorView?.stitchPreviewEnabled = true
                    self.schedulePaperPreview()
                }
            } else {
                self.showFeedback(L("Select a band inside the canvas and leave some content on either side."))
            }
        }
        canvas.onMove = { [weak self] id, origin, final in self?.move(id: id, origin: origin, final: final) }
        canvas.onCancelMove = { [weak self] in
            guard let self, let snapshot = self.dragSnapshot else { return }
            self.document = snapshot
            self.dragSnapshot = nil
            self.refresh()
        }
        canvas.onDelete = { [weak self] in self?.deletePiece() }
        canvas.onImages = { [weak self] images in self?.append(images) }
        canvas.onCopy = { [weak self] in self?.onAction?(.copy, nil) }
        canvas.canUndo = { [weak self] in self?.canUndo?() ?? false }
        canvas.canRedo = { [weak self] in self?.canRedo?() ?? false }
        canvas.onUndo = { [weak self] in self?.undoAction() }
        canvas.onRedo = { [weak self] in self?.redoAction() }
        canvas.onSave = { [weak self] in self?.onAction?(.save, nil) }
        canvas.onMode = { [weak self] mode in self?.setMode(mode) }
        if editor.canPreviewStitchPaper { editor.stitchPreviewEnabled = true }
        refresh()
    }

    func showOptions(_ action: StitchOptionsAction, at anchor: NSView) {
        switch action {
        case .seams: showSeams(at: anchor)
        case .pieces: showPieces(at: anchor)
        case .canvas: showCanvasOptions(at: anchor)
        case .background:
            editorView?.showBeautifyGradientPopover(anchorView: anchor, backgroundOnly: true)
        case .animation: saveAnimation()
        }
    }

    func setPlacement(_ placement: StitchPlacement) {
        guard document.placement != placement else { return }
        var next = document
        guard next.setPlacement(placement), next.canRender else { return }
        guard commitDocument(next) else { return }
        refresh()
    }

    func focus() {
        window?.makeFirstResponder(paperPreview.isHidden ? canvas : editorView)
    }

    func restore(_ value: StitchDocument) {
        restoring = true
        _ = paperPreview.cancelCameraGesture()
        _ = angleControl.cancelCameraGesture()
        endCameraGesture(commit: false)
        canvas.cancelEditingGesture()
        dragSnapshot = nil
        document = value
        refresh()
        restoring = false
    }

    func suspend() {
        _ = paperPreview.cancelCameraGesture()
        _ = angleControl.cancelCameraGesture()
        endCameraGesture(commit: false)
        restorePreviewInsets()
        canvas.cancelEditingGesture()
        PopoverHelper.dismiss()
        feedback.removeFromSuperview()
        canvas.removeFromSuperview()
        paperPreview.removeFromSuperview()
        paperPreview.cancelAnimation()
        paperPreview.image = nil
        paperPreview.onEdit = nil
        paperPreview.onCameraBegin = nil
        paperPreview.onCameraChanged = nil
        paperPreview.onCameraEnd = nil
        paperPreview.onReset = nil
        editorView?.stitchPaperPresentationFrame = nil
        interactiveTexture = nil
        interactivePaperSource = nil
        interactiveBackground = nil
        interactivePaperFrame = nil
        paperTexture = nil
        paperPresentationCache.clear()
        pendingNativePaperWarm?.cancel()
        pendingNativePaperWarm = nil
        cameraSnapshot = nil
        pendingPaperPreview?.cancel()
        paperRenderCancellation?.cancel()
        paperGeneration = UUID()
        editorView?.onStitchPreviewChanged = nil
        canvas.inlineEditor = nil
        editorView?.previewStitchSeamColor(nil)
        editorView?.onStitchSeamColorPreview = nil
        cancelPreview()
        guideGeneration = UUID()
        guideCancellation?.cancel()
        pendingGuideLayout = nil
    }

    func updateUndoState() { editorView?.refreshStitchOptions() }

    private func button(_ symbol: String, title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.bezelStyle = .rounded; button.controlSize = .small
        return button
    }
    func makeSeamOptions() -> NSView {
        if let seamOptions { return seamOptions }
        let view = StitchOptionsView(frame: NSRect(x: 0, y: 0, width: 368, height: 322))
        seamToggle.target = self
        seamToggle.action = #selector(toggleSeams)
        seamToggle.contentTintColor = ToolbarLayout.accentColor
        seamToggle.identifier = NSUserInterfaceItemIdentifier("stitch.seam.visibility")
        view.addSubview(seamToggle)
        seamStylePicker.onSelectionChanged = { [weak self] transition in self?.selectSeamTransition(transition) }
        view.addSubview(seamStylePicker)
        angleControl.identifier = NSUserInterfaceItemIdentifier("stitch.seam.angle")
        angleControl.foregroundColor = view.screenshotForegroundColor
        animationButton.identifier = NSUserInterfaceItemIdentifier("stitch.seam.animation")
        animationButton.setAccessibilityLabel(L("Save Animation"))
        angleHint.font = .systemFont(ofSize: 11)
        angleHint.textColor = view.screenshotForegroundColor
        for child in [angleControl, angleHint, animationButton] { view.addSubview(child) }
        let colorLabel = NSTextField(labelWithString: L("Line color"))
        colorLabel.identifier = NSUserInterfaceItemIdentifier("stitch.seam.color.label")
        colorLabel.font = .systemFont(ofSize: 11)
        colorLabel.textColor = view.screenshotForegroundColor
        color.identifier = NSUserInterfaceItemIdentifier("stitch.seam.color")
        color.setAccessibilityLabel(L("Seam line color"))
        color.target = self
        color.action = #selector(changeColor)
        view.addSubview(colorLabel)
        view.addSubview(color)
        seamLabels.append(colorLabel)
        for parameter in StitchSeamParameter.allCases {
            let label = NSTextField(labelWithString: parameter.title(for: document.style.transition))
            label.font = .systemFont(ofSize: 11)
            label.textColor = view.screenshotForegroundColor
            label.identifier = NSUserInterfaceItemIdentifier("stitch.seam.\(parameter).label")
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            value.textColor = view.screenshotForegroundColor
            value.alignment = .right
            value.identifier = NSUserInterfaceItemIdentifier("stitch.seam.\(parameter).value")
            let slider = StitchSlider(value: 0, minValue: parameter.range.lowerBound, maxValue: parameter.range.upperBound,
                                      target: self, action: #selector(changeStyle(_:)))
            slider.identifier = NSUserInterfaceItemIdentifier("stitch.seam.\(parameter)")
            slider.tag = parameter.rawValue
            slider.isContinuous = true
            if parameter == .accordionPleats {
                slider.numberOfTickMarks = 5
                slider.allowsTickMarkValuesOnly = true
            }
            slider.controlSize = .small
            slider.trackFillColor = ToolbarLayout.accentColor
            slider.setAccessibilityLabel(label.stringValue)
            slider.onBegin = { [weak self] in
                self?.adjustingStyle = true
            }
            slider.onEnd = { [weak self] in
                guard let self else { return }
                self.adjustingStyle = false
                if !self.commitDocument(self.document), let current = self.editorView?.stitchDocument { self.document = current }
                self.refresh()
            }
            view.addSubview(label); view.addSubview(value); view.addSubview(slider)
            sliders.append(slider); values.append(value); seamLabels.append(label)
        }
        seamOptions = view
        syncSeamControls()
        return view
    }
    private func showSeams(at anchor: NSView) {
        feedback.removeFromSuperview()
        if PopoverHelper.toggleClosedIfOpen(anchorView: anchor) { return }
        showTray(seamOptions, at: anchor)
    }
    private func showTray(_ content: NSView, at anchor: NSView) {
        guard let editor = editorView else { return }
        PopoverHelper.showToolbarTray(content, size: content.frame.size,
            relativeTo: anchor.bounds, of: anchor, avoiding: editor.screenshotPresentationRect, in: editor)
    }
    private func showPieces(at anchor: NSView) {
        feedback.removeFromSuperview()
        if PopoverHelper.toggleClosedIfOpen(anchorView: anchor) { return }
        let view = makePieceOptions()
        showTray(view, at: anchor)
    }

    func makePieceOptions() -> NSView {
        refreshPieces()
        let listHeight = min(CGFloat(288), max(36, CGFloat(document.pieces.count) * 36))
        let view = StitchOptionsView(frame: NSRect(x: 0, y: 0, width: 264, height: listHeight + 76))
        let title = pieceCountLabel
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = view.screenshotForegroundColor
        title.frame = NSRect(x: 12, y: listHeight + 50, width: 240, height: 16)
        pieceScroll.frame = NSRect(x: 12, y: 42, width: 240, height: listHeight)
        view.addSubview(title)
        view.addSubview(pieceScroll)
        let selectors = [#selector(movePieceUp), #selector(movePieceDown), #selector(bringForward), #selector(deletePiece)]
        let actions = zip(pieceActionPresentation, selectors).map { info, selector in
            button(info.symbol, title: "", action: selector)
        }
        pieceActions = actions
        for (index, button) in actions.enumerated() {
            button.frame = NSRect(x: 12 + index * 36, y: 8, width: 30, height: 26)
            button.bezelStyle = .recessed
            button.isBordered = false
            button.contentTintColor = view.screenshotForegroundColor
            view.addSubview(button)
        }
        updatePieceActions()
        return view
    }
    private func showCanvasOptions(at anchor: NSView) {
        feedback.removeFromSuperview()
        if PopoverHelper.toggleClosedIfOpen(anchorView: anchor) { return }
        let view = StitchOptionsView(frame: NSRect(x: 0, y: 0, width: 264, height: 100))
        let title = NSTextField(labelWithString: L("Canvas background"))
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = view.screenshotForegroundColor
        title.frame = NSRect(x: 12, y: 72, width: 240, height: 16)
        backgroundChoice.removeAllItems()
        backgroundChoice.addItems(withTitles: [L("Adjacent edge colors"), L("Solid color"), L("Transparent")])
        backgroundChoice.frame = NSRect(x: 10, y: 37, width: 198, height: 26)
        backgroundChoice.target = self; backgroundChoice.action = #selector(changeBackground)
        backgroundChoice.setAccessibilityLabel(L("Canvas background"))
        canvasColor.frame = NSRect(x: 217, y: 39, width: 34, height: 24)
        canvasColor.setAccessibilityLabel(L("Canvas background color"))
        canvasColor.target = self; canvasColor.action = #selector(changeCanvasColor)
        switch document.background {
        case .automatic: backgroundChoice.selectItem(at: 0)
        case .color(let value): backgroundChoice.selectItem(at: 1); canvasColor.color = value
        case .transparent: backgroundChoice.selectItem(at: 2)
        }
        if backgroundChoice.indexOfSelectedItem != 1 { PopoverHelper.moveFocusBeforeChanging(canvasColor) }
        canvasColor.isHidden = backgroundChoice.indexOfSelectedItem != 1
        let hint = NSTextField(labelWithString: L("Fills space between captured pieces."))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = view.screenshotForegroundColor
        hint.frame = NSRect(x: 12, y: 13, width: 240, height: 16)
        for child in [title, backgroundChoice, canvasColor, hint] { view.addSubview(child) }
        showTray(view, at: anchor)
    }
    @objc private func changeBackground() {
        var next = document
        switch backgroundChoice.indexOfSelectedItem {
        case 1: next.background = .color(canvasColor.color)
        case 2: next.background = .transparent
        default: next.background = .automatic
        }
        guard commitDocument(next) else { return }
        if backgroundChoice.indexOfSelectedItem != 1 { PopoverHelper.moveFocusBeforeChanging(canvasColor) }
        canvasColor.isHidden = backgroundChoice.indexOfSelectedItem != 1
        refresh()
    }
    @objc private func changeCanvasColor() {
        var next = document
        next.background = .color(canvasColor.color)
        guard commitDocument(next) else { return }
        refresh()
    }
    private func showFeedback(_ text: String) {
        guard let editor = editorView, let parent = editor.chromeParentView ?? editor.superview else { return }
        let token = UUID(); feedbackGeneration = token
        feedback.text = text
        let size = feedback.preferredSize
        feedback.frame = CGRect(x: max(8, parent.bounds.midX - size.width / 2),
                                y: 108, width: min(parent.bounds.width - 16, size.width), height: size.height)
        parent.addSubview(feedback)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.feedbackGeneration == token else { return }
            self.feedback.removeFromSuperview()
        }
    }
    private func commitDocument(_ next: StitchDocument) -> Bool {
        guard onDocumentChanged?(next, true) != false else {
            showFeedback(editorView?.stitchChangeFailureMessage
                ?? L("Unable to render this canvas. Reduce its size and try again."))
            return false
        }
        document = next
        return true
    }
    private func publish() {
        guard !restoring else { return }
        if onDocumentChanged?(document, false) == false {
            showFeedback(L("Unable to render this canvas. Reduce its size and try again."))
        }
    }
    private func refresh() {
        if !document.pieces.contains(where: { $0.id == canvas.selectedID }) { canvas.selectedID = nil }
        canvas.refresh(document, preview: nil)
        updateBandGuides()
        canvas.packed = document.placement == .packed
        syncSeamControls()
        editorView?.refreshStitchOptions()
        updatePaperVisibility()
        refreshPieces(); scheduleRender()
    }
    private func syncSeamControls() {
        let s = document.style
        let parameters = visibleSeamParameters
        let hasColor = s.transition.hasEditableColor
        if !s.visible { PopoverHelper.moveFocusBeforeChanging(seamStylePicker) }
        if !hasColor || !s.visible { PopoverHelper.moveFocusBeforeChanging(color) }
        for parameter in StitchSeamParameter.allCases where !s.visible || !parameters.contains(parameter) {
            PopoverHelper.moveFocusBeforeChanging(sliders[parameter.rawValue])
        }
        let showsAngle = s.transition == .accordion
        if !showsAngle || !s.visible { PopoverHelper.moveFocusBeforeChanging(angleControl) }
        if !showsAngle || editorView?.canPreviewStitchPaper != true {
            PopoverHelper.moveFocusBeforeChanging(animationButton)
        }
        let height = 58 + StitchSeamStylePicker.preferredHeight + (hasColor ? 34 : 0)
            + CGFloat(parameters.count) * 38 + (showsAngle ? 110 : 0)
        let size = NSSize(width: 368, height: height)
        seamOptions.setFrameSize(size)
        seamToggle.frame = NSRect(x: 12, y: height - 36, width: 344, height: 24)
        seamStylePicker.frame = NSRect(x: 12, y: height - 40 - StitchSeamStylePicker.preferredHeight,
            width: 344, height: StitchSeamStylePicker.preferredHeight)
        seamStylePicker.selection = s.transition
        seamStylePicker.isEnabled = s.visible
        seamToggle.state = s.visible ? .on : .off
        color.color = s.color
        if color.isActive && (!hasColor || !s.visible) { color.deactivate() }
        color.isHidden = !hasColor
        color.isEnabled = s.visible && hasColor
        color.alphaValue = s.visible ? 1 : 0.35
        let parametersTop = seamStylePicker.frame.minY - 26
        color.frame = NSRect(x: 308, y: parametersTop - 4, width: 46, height: 24)
        let colorLabel = seamLabels[0]
        colorLabel.isHidden = !hasColor
        colorLabel.alphaValue = s.visible ? 1 : 0.35
        colorLabel.frame = NSRect(x: 12, y: parametersTop, width: 258, height: 18)
        for parameter in StitchSeamParameter.allCases {
            let index = parameter.rawValue
            let slider = sliders[index]
            let label = seamLabels[index + 1]
            let value = values[index]
            let visibleIndex = parameters.firstIndex(of: parameter)
            let enabled = s.visible && visibleIndex != nil
            let keyPath = parameter.keyPath(for: s.transition)
            slider.doubleValue = Double(s[keyPath: keyPath])
            value.stringValue = parameter.formattedValue(s[keyPath: keyPath])
            label.stringValue = parameter.title(for: s.transition)
            slider.setAccessibilityLabel(label.stringValue)
            slider.isHidden = visibleIndex == nil
            label.isHidden = visibleIndex == nil
            value.isHidden = visibleIndex == nil
            slider.isEnabled = enabled
            slider.alphaValue = s.visible ? 1 : 0.35
            label.alphaValue = s.visible ? 1 : 0.35
            value.alphaValue = s.visible ? 1 : 0.35
            if let visibleIndex {
                let y = parametersTop - (hasColor ? 34 : 0) - CGFloat(visibleIndex) * 38
                label.frame = NSRect(x: 12, y: y, width: 260, height: 16)
                value.frame = NSRect(x: 289, y: y, width: 65, height: 16)
                slider.frame = NSRect(x: 10, y: y - 19, width: 346, height: 20)
            }
        }
        angleControl.camera = StitchPaperCamera(perspective: s.accordionPerspective, yaw: s.accordionYaw)
        angleControl.isHidden = !showsAngle
        angleControl.isEnabled = s.visible
        angleControl.alphaValue = s.visible ? 1 : 0.35
        angleControl.frame = NSRect(x: 12, y: 12, width: 176, height: 92)
        angleHint.isHidden = !showsAngle
        angleHint.alphaValue = s.visible ? 1 : 0.35
        angleHint.frame = NSRect(x: 202, y: 48, width: 150, height: 56)
        animationButton.isHidden = !showsAngle
        animationButton.isEnabled = editorView?.canPreviewStitchPaper == true
        animationButton.frame = NSRect(x: 202, y: 14, width: 150, height: 28)
        PopoverHelper.resize(seamOptions, to: size)
    }
    private func previewSeamColor(_ color: NSColor?) {
        guard let style = editorView?.stitchDocument?.style else { return }
        guard color == nil || (style.visible && style.transition.hasEditableColor) else { return }
        document.style = style
        if let color { document.style.color = color }
        adjustingStyle = color != nil
        syncSeamControls()
        scheduleRender(publishDocument: false)
    }
    private func sameGuideLayout(_ first: StitchDocument, _ second: StitchDocument) -> Bool {
        StitchBandGuides.contentPadding(document: first) == StitchBandGuides.contentPadding(document: second)
            && first.joins.count == second.joins.count
            && zip(first.joins, second.joins).allSatisfy { $0.axis == $1.axis && $0.position == $1.position }
            && first.pieces.count == second.pieces.count && zip(first.pieces, second.pieces).allSatisfy {
            $0.image === $1.image && $0.source == $1.source && $0.origin == $1.origin
        }
    }
    private func installBandGuides(_ guides: StitchBandGuides.Result) {
        canvas.bandGuideRows = guides.rows
        canvas.bandGuideColumns = guides.columns
    }
    private func updateBandGuides() {
        if let cachedGuideLayout, let cachedBandGuides, sameGuideLayout(document, cachedGuideLayout) {
            guideGeneration = UUID()
            guideCancellation?.cancel()
            pendingGuideLayout = nil
            installBandGuides(cachedBandGuides)
            return
        }
        if let pendingGuideLayout, sameGuideLayout(document, pendingGuideLayout) { return }
        guideCancellation?.cancel()
        let snapshot = document
        pendingGuideLayout = snapshot
        installBandGuides(StitchBandGuides.geometry(document: snapshot))
        let token = UUID(); guideGeneration = token
        let cancellation = StitchPreviewCancellation(); guideCancellation = cancellation
        guideQueue.async { [weak self] in
            guard !cancellation.isCancelled else { return }
            let result = StitchBandGuides.analyze(document: snapshot, isCancelled: { cancellation.isCancelled })
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.guideGeneration == token,
                      !cancellation.isCancelled else { return }
                self.pendingGuideLayout = nil
                guard self.sameGuideLayout(self.document, snapshot) else { return }
                self.cachedGuideLayout = snapshot
                self.cachedBandGuides = result
                self.pendingGuideLayout = nil
                self.installBandGuides(result)
            }
        }
    }
    private func cancelPreview() {
        pendingNativePaperWarm?.cancel()
        pendingNativePaperWarm = nil
        renderGeneration = UUID()
        renderCancellation?.cancel()
        pendingRender?.cancel()
        pendingRender = nil
        pendingPaperPreview?.cancel()
        paperRenderCancellation?.cancel()
        pendingPaperPreview = nil
        paperGeneration = UUID()
    }

    private func updatePaperVisibility() {
        guard let editor = editorView else { return }
        let showsPaper = editor.stitchPreviewEnabled && editor.canPreviewStitchPaper
        let wasShowingPaper = !paperPreview.isHidden
        if showsPaper {
            canvas.cancelEditingGesture()
            // Move keyboard ownership before hiding the editable canvas.
            ScreenshotKeyboardFocus.moveIfOwned(by: canvas, to: editor)
        }
        canvas.isHidden = showsPaper
        paperPreview.isHidden = !showsPaper
        if showsPaper { updatePreviewInsets() }
        else {
            editor.stitchPaperPresentationFrame = nil
            restorePreviewInsets()
        }
        if !showsPaper {
            pendingNativePaperWarm?.cancel()
            pendingNativePaperWarm = nil
            paperPreview.cancelAnimation()
            animatesNextPaperPreview = false
            pendingPaperPreview?.cancel()
            paperRenderCancellation?.cancel()
            pendingPaperPreview = nil
            paperGeneration = UUID()
            if wasShowingPaper { ScreenshotKeyboardFocus.moveIfOwned(by: editor, to: canvas) }
        }
        editor.refreshStitchOptions()
    }

    /// Convert projected, top-down paper pixels to the editor's point coordinate
    /// system without stretching the sheet or moving annotation coordinates.
    static func paperOutputFrame(projection: StitchAccordionProjection, selection: CGRect,
                                 isFlipped: Bool) -> CGRect {
        let source = projection.documentBounds, output = projection.outputBounds
        let scaleX = selection.width / source.width, scaleY = selection.height / source.height
        return CGRect(x: selection.minX + (output.minX - source.minX) * scaleX,
            y: selection.minY + (isFlipped ? output.minY - source.minY : source.maxY - output.maxY) * scaleY,
            width: output.width * scaleX, height: output.height * scaleY)
    }

    /// A small compact screenshot can unfold into a large sheet. Budget the
    /// preview by both its input texture and its projected, padded output.
    static func paperPreviewTextureSize(pixels: CGImage, sourceSize: CGSize,
                                        projection: StitchAccordionProjection) -> CGSize? {
        let maximum: CGFloat = 2000
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let source = projection.documentBounds, output = projection.outputBounds
        let padding = ScreenshotPresentation.paperPadding * 2
        let outputWidth = output.width / source.width * CGFloat(pixels.width)
            + padding * CGFloat(pixels.width) / sourceSize.width
        let outputHeight = output.height / source.height * CGFloat(pixels.height)
            + padding * CGFloat(pixels.height) / sourceSize.height
        let scale = min(1, maximum / max(CGFloat(pixels.width), CGFloat(pixels.height), outputWidth, outputHeight))
        let width = max(1, floor(CGFloat(pixels.width) * scale))
        let height = max(1, floor(CGFloat(pixels.height) * scale))
        // A single source pixel is the lowest representable texture density.
        guard (output.width / source.width + padding / sourceSize.width) * width <= maximum,
              (output.height / source.height + padding / sourceSize.height) * height <= maximum else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Make the entire projected paper and wallpaper reachable while the compact
    /// document remains the editing and annotation coordinate system.
    private func updatePreviewInsets(projection: StitchAccordionProjection? = nil) {
        guard let editor = editorView,
              let projection = projection ?? StitchAccordionProjection(document: document) else { return }
        let outputFrame = Self.paperOutputFrame(projection: projection, selection: editor.selectionRect,
            isFlipped: editor.isFlipped)
        let presentationFrame = outputFrame.insetBy(dx: -ScreenshotPresentation.paperPadding,
            dy: -ScreenshotPresentation.paperPadding)
        editor.stitchPaperPresentationFrame = presentationFrame
        paperPreview.frame = presentationFrame
        editor.needsDisplay = true
        guard let scroll = editor.enclosingScrollView else { return }
        if savedPreviewInsets == nil {
            previewScrollView = scroll
            savedPreviewInsets = scroll.contentInsets
            if #available(macOS 14.0, *) {
                savedPreviewClipping = editor.clipsToBounds
                editor.clipsToBounds = false
            }
        }
        guard let original = savedPreviewInsets else { return }
        let compact = editor.selectionRect
        let lowY = max(0, compact.minY - presentationFrame.minY)
        let highY = max(0, presentationFrame.maxY - compact.maxY)
        scroll.contentInsets = NSEdgeInsets(top: original.top + (editor.isFlipped ? lowY : highY),
            left: original.left + max(0, compact.minX - presentationFrame.minX),
            bottom: original.bottom + (editor.isFlipped ? highY : lowY),
            right: original.right + max(0, presentationFrame.maxX - compact.maxX))
    }

    private func restorePreviewInsets() {
        if let original = savedPreviewInsets { previewScrollView?.contentInsets = original }
        if #available(macOS 14.0, *), let original = savedPreviewClipping { editorView?.clipsToBounds = original }
        savedPreviewInsets = nil
        savedPreviewClipping = nil
        previewScrollView = nil
    }

    private func failPaperPreview() {
        pendingPaperPreview = nil
        showFeedback(L("Unable to render this canvas. Reduce its size and try again."))
        editorView?.stitchPreviewEnabled = false
    }

    private func schedulePaperPreview(keepsCurrentPaper: Bool = false) {
        guard cameraSnapshot == nil else { return }
        pendingNativePaperWarm?.cancel()
        pendingNativePaperWarm = nil
        pendingPaperPreview?.cancel()
        paperRenderCancellation?.cancel()
        let generation = UUID(); paperGeneration = generation
        guard let editor = editorView, editor.stitchPreviewEnabled, editor.canPreviewStitchPaper,
              paperPreview.superview != nil else { return }
        paperPreview.cancelAnimation()
        if !keepsCurrentPaper && !committingCamera {
            paperPreview.image = nil
            interactiveTexture = nil
            interactivePaperSource = nil
            interactiveBackground = nil
            interactivePaperFrame = nil
        }
        updatePreviewInsets()
        let cancellation = StitchPreviewCancellation()
        paperRenderCancellation = cancellation
        let snapshot = document
        let work = DispatchWorkItem { [weak self, weak editor] in
            guard let self, let editor, self.paperGeneration == generation,
                  !self.paperPreview.isHidden else { return }
            guard let composite = editor.captureSelectedRegion(),
                  let pixels = composite.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let projection = StitchAccordionProjection(document: snapshot) else {
                self.failPaperPreview(); return
            }
            // Keep native point geometry, and bound only the texture used for the live preview.
            guard let previewSize = Self.paperPreviewTextureSize(pixels: pixels,
                sourceSize: composite.size, projection: projection) else {
                self.failPaperPreview(); return
            }
            let width = Int(previewSize.width), height = Int(previewSize.height)
            let texture: CGImage
            if width == pixels.width && height == pixels.height {
                texture = pixels
            } else if let cached = self.paperTexture, cached.source === pixels, cached.size == composite.size,
                      cached.pixels.width == width, cached.pixels.height == height {
                texture = cached.pixels
            } else {
                guard let bitmap = CGContext(data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    self.failPaperPreview(); return
                }
                bitmap.interpolationQuality = .high
                bitmap.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height))
                guard let scaled = bitmap.makeImage() else { self.failPaperPreview(); return }
                texture = scaled
                self.paperTexture = pixels.bytesPerRow <= 32 * 1024 * 1024 / max(1, pixels.height)
                    ? (pixels, composite.size, scaled) : nil
            }
            let presentation = ScreenshotPresentation(effects: editor.effectsConfig,
                beautify: editor.beautifyConfig, projection: projection)
            // Native-sized previews share their finished pixels with Copy.
            // Larger previews keep a separate bounded texture and output cache.
            let nativeSize = texture === pixels
            let cache = nativeSize ? editor.presentationCache : self.paperPresentationCache
            guard let prepared = cache.prepare(presentation,
                image: NSImage(cgImage: texture, size: composite.size), document: snapshot) else {
                self.failPaperPreview(); return
            }
            self.updatePreviewInsets(projection: projection)
            self.renderQueue.async { [weak self] in
                guard !cancellation.isCancelled else { return }
                let (rendered, animationTexture, layerProjection) = autoreleasepool {
                    let rendered = prepared.renderCGImage()
                    return (rendered, !cancellation.isCancelled ? prepared.animationTexture(maxDimension: 1600) : nil,
                        !cancellation.isCancelled ? prepared.projection?.resizingPaperTextures(maxDimension: 1600) : nil)
                }
                guard !cancellation.isCancelled else { return }
                DispatchQueue.main.async { [weak self, weak editor] in
                    guard let self, let editor, self.paperGeneration == generation,
                          !self.paperPreview.isHidden, self.paperPreview.window != nil else { return }
                    self.pendingPaperPreview = nil
                    guard let rendered else {
                        self.failPaperPreview()
                        return
                    }
                    self.paperPreview.image = NSImage(cgImage: rendered, size: prepared.imageSize)
                    let outputFrame = Self.paperOutputFrame(projection: projection, selection: editor.selectionRect,
                        isFlipped: editor.isFlipped)
                    let paperFrame = self.paperPreview.convert(outputFrame, from: editor)
                    self.interactiveTexture = animationTexture
                    self.interactivePaperSource = layerProjection?.source
                    self.interactiveBackground = prepared.paperBackground?.pixels
                    self.interactivePaperFrame = paperFrame
                    self.paperPreview.paperFrame = paperFrame
                    self.paperPreview.projection = layerProjection ?? prepared.projection
                    self.paperPreview.camera = StitchPaperCamera(perspective: snapshot.style.accordionPerspective,
                        yaw: snapshot.style.accordionYaw)
                    if !nativeSize {
                        self.scheduleNativePaperWarm(presentation, image: composite,
                            document: snapshot, generation: generation, cancellation: cancellation)
                    }
                    if self.animatesNextPaperPreview, let animationTexture, let layerProjection {
                        self.animatesNextPaperPreview = false
                        self.paperPreview.animate(texture: animationTexture, document: snapshot,
                            frame: paperFrame, background: prepared.paperBackground?.pixels,
                            preparedSource: layerProjection.source)
                    }
                }
            }
        }
        pendingPaperPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Warm one native frame after interaction settles. A bounded preview is
    /// never promoted to clipboard or file output.
    private func scheduleNativePaperWarm(_ presentation: ScreenshotPresentation, image: NSImage,
                                        document: StitchDocument, generation: UUID,
                                        cancellation: StitchPreviewCancellation) {
        pendingNativePaperWarm?.cancel()
        guard let nativePixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              nativePixels.bytesPerRow <= 32 * 1024 * 1024 / max(1, nativePixels.height) else { return }
        let work = DispatchWorkItem { [weak self, weak editor = editorView] in
            guard let self, let editor, !cancellation.isCancelled,
                  self.paperGeneration == generation, self.cameraSnapshot == nil,
                  editor.stitchPreviewEnabled, !self.paperPreview.isHidden,
                  let prepared = editor.presentationCache.prepare(presentation, image: image, document: document),
                  prepared.isRenderCacheEnabled, prepared.renderedCGImage == nil else { return }
            self.pendingNativePaperWarm = nil
            self.nativePaperWarmQueue.async {
                guard !cancellation.isCancelled else { return }
                autoreleasepool { _ = prepared.renderCGImage() }
            }
        }
        pendingNativePaperWarm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    private func scheduleRender(publishDocument: Bool = true) {
        if publishDocument && !adjustingStyle { publish() }
        guard editorView?.refreshFoldProtection() != false else { return }
        canvas.syncInlineGeometry()
        cancelPreview()
        updatePaperVisibility()
        let snapshot = document
        let sourceScale = editorView?.screenshotImage.map { snapshot.bounds.integral.width / $0.size.width } ?? 1
        let protection = StitchAnnotationTransforms.protectedRegions(editorView?.localStitchAnnotations ?? [],
            in: snapshot, scale: sourceScale)
        let generation = renderGeneration
        let cancellation = StitchPreviewCancellation()
        renderCancellation = cancellation
        let work = DispatchWorkItem { [weak self] in
            guard !cancellation.isCancelled else { return }
            let bounds = snapshot.bounds
            let scale = min(1, sqrt(16_000_000 / max(1, bounds.width * bounds.height)))
            let result = autoreleasepool {
                (StitchRenderer.render(snapshot, maximumPreviewDimension: max(bounds.width, bounds.height) * scale,
                    protectedRegions: protection),
                 StitchRenderer.renderBackground(snapshot, maximumPreviewDimension: max(bounds.width, bounds.height) * scale))
            }
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.renderGeneration == generation,
                      !cancellation.isCancelled, self.canvas.window != nil else { return }
                self.canvas.backgroundPreview = result.1
                self.canvas.refresh(snapshot, preview: result.0)
                self.pendingRender = nil
            }
        }
        pendingRender = work
        renderQueue.asyncAfter(deadline: .now() + 0.05, execute: work)
        schedulePaperPreview()
    }
    private func refreshPieces() {
        pieceCountLabel.stringValue = "\(document.pieces.count) \(L("pieces"))"
        PopoverHelper.moveFocusBeforeChanging(piecesStack)
        for view in piecesStack.arrangedSubviews { piecesStack.removeArrangedSubview(view); view.removeFromSuperview() }
        // Packed order matches the canvas reading direction; free placement shows frontmost layers first.
        let indices = document.placement == .packed ? Array(document.pieces.indices) : Array(document.pieces.indices.reversed())
        for index in indices {
            let piece = document.pieces[index]
            let button = NSButton(title: "\(index + 1)   \(piece.label)", target: self, action: #selector(selectPiece(_:)))
            button.tag = index; button.bezelStyle = .recessed; button.setButtonType(.pushOnPushOff)
            button.state = canvas.selectedID == piece.id ? .on : .off
            if let cg = piece.image.cropping(to: piece.source) {
                let original = NSImage(cgImage: cg, size: piece.source.size)
                button.image = NSImage(size: NSSize(width: 36, height: 28), flipped: false) { bounds in
                    let scale = min(bounds.width / original.size.width, bounds.height / original.size.height)
                    let size = NSSize(width: original.size.width * scale, height: original.size.height * scale)
                    original.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                             width: size.width, height: size.height))
                    return true
                }
                button.imagePosition = .imageLeading
            }
            button.alignment = .left
            button.font = .systemFont(ofSize: 11)
            button.contentTintColor = canvas.selectedID == piece.id ? ToolbarLayout.accentColor : piecesStack.screenshotForegroundColor
            button.toolTip = piece.label
            piecesStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 236).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        piecesStack.frame = CGRect(x: 0, y: 0, width: 240, height: max(36, document.pieces.count * 36))
        updatePieceActions()
    }
    private var pieceActionPresentation: [(symbol: String, label: String)] {
        guard document.placement == .packed else {
            return [("arrow.up", L("Bring forward one layer")), ("arrow.down", L("Send backward one layer")),
                    ("square.3.layers.3d.top.filled", L("Bring to front")), ("trash", L("Delete piece"))]
        }
        let horizontal = document.savedPackingState.horizontal
        return [(horizontal ? "arrow.left" : "arrow.up", L("Move earlier")),
                (horizontal ? "arrow.right" : "arrow.down", L("Move later")),
                (horizontal ? "arrow.right.to.line" : "arrow.down.to.line", L("Move to end")),
                ("trash", L("Delete piece"))]
    }

    private func updatePieceActions() {
        guard pieceActions.count == 4 else { return }
        let index = document.pieces.firstIndex(where: { $0.id == canvas.selectedID })
        let packed = document.placement == .packed
        let enabled = [index.map { packed ? $0 > 0 : $0 < document.pieces.count - 1 } ?? false,
                       index.map { packed ? $0 < document.pieces.count - 1 : $0 > 0 } ?? false,
                       index.map { $0 < document.pieces.count - 1 } ?? false,
                       index != nil && document.pieces.count > 1]
        for (index, button) in pieceActions.enumerated() {
            let info = pieceActionPresentation[index]
            button.image = NSImage(systemSymbolName: info.symbol, accessibilityDescription: info.label)
            button.toolTip = info.label
            button.setAccessibilityLabel(info.label)
            if !enabled[index] { PopoverHelper.moveFocusBeforeChanging(button) }
            button.isEnabled = enabled[index]
            button.alphaValue = enabled[index] ? 1 : 0.35
        }
    }
    private func move(id: UUID, origin: CGPoint, final: Bool) {
        guard let index = document.pieces.firstIndex(where: { $0.id == id }) else { return }
        if document.placement == .packed {
            var next = document
            guard next.movePacked(id: id, proposed: origin), next.canRender else { return }
            guard final else {
                canvas.packedPreview = next
                canvas.needsDisplay = true
                return
            }
            guard zip(next.pieces, document.pieces).contains(where: { $0.id != $1.id || $0.origin != $1.origin }) else { return }
            guard commitDocument(next) else { canvas.packedPreview = nil; canvas.needsDisplay = true; return }
            refresh()
            return
        }
        if dragSnapshot == nil { cancelPreview(); dragSnapshot = document }
        let old = document.pieces[index].origin
        document.pieces[index].origin = origin
        if !document.canRender { document.pieces[index].origin = old; showFeedback(L("Canvas limit reached. Move pieces closer together.")) }
        canvas.document = document; canvas.needsDisplay = true
        if final {
            let next = document
            if let snapshot = dragSnapshot { document = snapshot }
            dragSnapshot = nil
            _ = commitDocument(next)
            refresh()
        }
    }
    func setMode(_ mode: StitchCanvasView.Mode, focusCanvas: Bool = true) {
        editorView?.stitchPreviewEnabled = false
        canvas.mode = mode
        feedback.removeFromSuperview()
        if editorView?.stitchMode != mode { editorView?.stitchMode = mode }
        editorView?.refreshStitchOptions()
        if focusCanvas { window?.makeFirstResponder(canvas) }
    }
    private func beginCameraGesture(owner: NSView? = nil) {
        guard cameraSnapshot == nil, let editor = editorView,
              document.style.visible, document.style.transition == .accordion else { return }
        cameraSnapshot = document
        pendingNativePaperWarm?.cancel()
        pendingNativePaperWarm = nil
        if let owner {
            cameraScopeOwner = owner
            ScreenshotCommandResponder.forWindow(window)?.setTransientScope(owner: owner) { [weak self] in
                guard let self else { return }
                _ = self.paperPreview.cancelCameraGesture()
                _ = self.angleControl.cancelCameraGesture()
                self.endCameraGesture(commit: false)
            }
        }
        pendingPaperPreview?.cancel()
        paperRenderCancellation?.cancel()
        paperGeneration = UUID()
        paperPreview.cancelAnimation()
        if editor.canPreviewStitchPaper { editor.stitchPreviewEnabled = true }
    }
    private func changeCamera(_ camera: StitchPaperCamera) {
        guard cameraSnapshot != nil else { return }
        document.style.accordionPerspective = camera.perspective
        document.style.accordionYaw = camera.yaw
        angleControl.camera = camera
        paperPreview.camera = camera
        guard let texture = interactiveTexture, let editor = editorView,
              let projection = interactivePaperSource?.withCamera(camera).projection()
            else { return }
        updatePreviewInsets(projection: projection)
        let outputFrame = Self.paperOutputFrame(projection: projection, selection: editor.selectionRect,
            isFlipped: editor.isFlipped)
        let frame = paperPreview.convert(outputFrame, from: editor)
        interactivePaperFrame = frame
        _ = paperPreview.showInteractivePaper(texture: texture, projection: projection,
            frame: frame, background: interactiveBackground)
    }
    private func endCameraGesture(commit: Bool) {
        if let owner = cameraScopeOwner {
            ScreenshotCommandResponder.forWindow(window)?.removeTransientScope(owner: owner)
        }
        cameraScopeOwner = nil
        guard let original = cameraSnapshot else { return }
        let next = document
        cameraSnapshot = nil
        document = original
        committingCamera = true
        if commit && !original.isIdentical(to: next) { _ = commitDocument(next) }
        committingCamera = false
        syncSeamControls()
        paperPreview.camera = StitchPaperCamera(perspective: document.style.accordionPerspective,
            yaw: document.style.accordionYaw)
        schedulePaperPreview(keepsCurrentPaper: true)
    }
    private func resetCamera() {
        guard document.style.visible, document.style.transition == .accordion else { return }
        beginCameraGesture()
        changeCamera(StitchPaperCamera())
        endCameraGesture(commit: true)
    }
    @objc private func saveAnimation() {
        guard animationSavePanel == nil, let editor = editorView,
              editor.canPreviewStitchPaper, let window,
              let composite = editor.captureSelectedRegion() else { return }
        do {
            guard let prepared = ScreenshotPresentation(view: editor).prepare(composite) else {
                throw StitchAnimationExporter.ExportError.invalidSnapshot
            }
            let plan = try StitchAnimationExporter.prepare(document: document, presentation: prepared)
            PopoverHelper.dismiss()
            let savePanel = StitchAnimationSavePanel()
            animationSavePanel = savePanel
            savePanel.present(in: window) { [weak self] choice in
                self?.animationSavePanel = nil
                guard let choice else { return }
                let accessing = choice.url.startAccessingSecurityScopedResource()
                let access = SaveDirectoryLease(alreadyAccessing: accessing ? choice.url : nil)
                let job = MediaExportCoordinator.shared.start(title: choice.url.lastPathComponent,
                    status: L("Saving animation…"), operation: { cancellation, progress in
                        defer { withExtendedLifetime(access) {} }
                        try await StitchAnimationExporter.export(plan, to: choice.url, format: choice.format,
                            cancellation: cancellation, progress: progress)
                    }, completion: { [weak self] result in
                        switch result {
                        case .success: self?.showFeedback(L("Animation saved."))
                        case .failure(let error) where error is CancellationError:
                            self?.showFeedback(L("Cancelled"))
                        case .failure(let error):
                            let message = L("Unable to save animation.") + " " + error.localizedDescription
                            if let self, self.editorView?.window != nil { self.showFeedback(message) }
                            else { ImageSaveService.onFailure?(message) }
                        }
                    })
                MediaExportProgressController.show(for: job)
            }
        } catch {
            editor.showOverlayError(L("Unable to save animation.") + " " + error.localizedDescription)
        }
    }
    @objc private func changeStyle(_ sender: NSSlider) {
        guard document.style.visible, let parameter = StitchSeamParameter(rawValue: sender.tag),
              visibleSeamParameters.contains(parameter) else { return }
        let keyPath = parameter.keyPath(for: document.style.transition)
        let value = parameter == .accordionPleats ? sender.doubleValue.rounded() : sender.doubleValue
        if adjustingStyle {
            document.style[keyPath: keyPath] = value
        } else {
            var next = document
            next.style[keyPath: keyPath] = value
            guard commitDocument(next) else { syncSeamControls(); return }
        }
        values[sender.tag].stringValue = parameter.formattedValue(value)
        scheduleRender()
    }

    private var visibleSeamParameters: [StitchSeamParameter] {
        StitchSeamParameter.visible(for: document.style.transition,
            hasUnmeasuredAccordionJoins: document.style.transition == .accordion
                && document.joins.contains { $0.trimmedLength == nil })
    }

    private func selectSeamTransition(_ transition: StitchTransition) {
        guard document.style.visible, document.style.transition != transition else { return }
        editorView?.previewStitchSeamColor(nil)
        var next = document
        next.style.transition = transition
        guard commitDocument(next) else { syncSeamControls(); return }
        if transition == .accordion {
            editorView?.stitchPreviewEnabled = editorView?.canPreviewStitchPaper == true
            animatesNextPaperPreview = true
        } else { editorView?.stitchPreviewEnabled = false }
        updatePaperVisibility()
        syncSeamControls()
        updateBandGuides()
        scheduleRender(publishDocument: false)
    }
    @objc private func changeColor() {
        guard document.style.visible, document.style.transition.hasEditableColor else { return }
        var next = document
        next.style.color = color.color
        guard commitDocument(next) else { return }
        scheduleRender()
    }
    @objc private func toggleSeams() {
        let visible = seamToggle.state == .on
        editorView?.previewStitchSeamColor(nil)
        var next = document
        next.style.visible = visible
        guard commitDocument(next) else { return }
        syncSeamControls(); updateBandGuides(); scheduleRender()
    }
    @objc private func selectPiece(_ sender: NSButton) {
        let sourceWindow = sender.window
        let piece = document.pieces[sender.tag]
        setMode(.move, focusCanvas: false); canvas.selectedID = piece.id
        refreshPieces()
        let rect = piece.frame.offsetBy(dx: -document.bounds.minX, dy: -document.bounds.minY)
        canvas.scrollToVisible(rect.insetBy(dx: -12, dy: -12))
        if !PopoverHelper.isVisible, sourceWindow === window { window?.makeFirstResponder(canvas) }
    }
    @objc private func deletePiece() {
        guard let id = canvas.selectedID, document.pieces.count > 1 else { return }
        var next = document
        next.pieces.removeAll { $0.id == id }
        next.pruneFoldTextures()
        guard next.placement != .packed || next.reflowPacked() else { showFeedback(L("Canvas limit reached. Move pieces closer together.")); return }
        guard commitDocument(next) else { return }
        canvas.selectedID = nil; refresh()
    }
    private func reorderPiece(to index: Int) {
        guard let id = canvas.selectedID else { return }
        var next = document
        guard StitchPieceOrder.move(id, in: &next.pieces, to: index) else { return }
        guard next.placement != .packed || next.reflowPacked() else { showFeedback(L("Canvas limit reached. Move pieces closer together.")); return }
        guard commitDocument(next) else { return }
        refresh()
    }
    @objc private func bringForward() { reorderPiece(to: document.pieces.count - 1) }
    @objc private func movePieceUp() {
        guard let index = document.pieces.firstIndex(where: { $0.id == canvas.selectedID }) else { return }
        reorderPiece(to: index + (document.placement == .packed ? -1 : 1))
    }
    @objc private func movePieceDown() {
        guard let index = document.pieces.firstIndex(where: { $0.id == canvas.selectedID }) else { return }
        reorderPiece(to: index + (document.placement == .packed ? 1 : -1))
    }
    @objc private func undoAction() { onUndo?() }
    @objc private func redoAction() { onRedo?() }
    func append(_ images: [NSImage]) {
        canvas.cancelEditingGesture()
        var next = document
        for image in images {
            guard next.pieces.count < 48, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let b = next.bounds
            next.pieces.append(StitchPiece(image: cg, origin: CGPoint(x: b.minX, y: b.maxY), label: L("Added image")))
            if !next.canRender { next.pieces.removeLast(); showFeedback(L("Image exceeds the canvas limit.")); break }
        }
        guard next.pieces.count != document.pieces.count else { return }
        guard next.placement != .packed || next.reflowPacked() else { showFeedback(L("Image exceeds the canvas limit.")); return }
        guard commitDocument(next) else { return }
        setMode(.move)
        canvas.selectedID = next.pieces.last?.id
        refresh()
    }
    deinit { pendingRender?.cancel(); renderCancellation?.cancel(); guideCancellation?.cancel() }
}
