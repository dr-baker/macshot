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

enum StitchOptionsAction { case seams, pieces, canvas }

/// Edits source pieces on the main editor canvas; the host owns all chrome and output actions.
@MainActor
final class StitchEditorController: NSObject {
    private weak var window: NSWindow?
    private weak var editorView: EditorView?
    var onCheckpoint: (() -> Void)?
    var onDocumentChanged: ((StitchDocument) -> Bool)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var canUndo: (() -> Bool)?
    var canRedo: (() -> Bool)?
    var onAction: ((ToolbarButtonAction, NSView?) -> Void)?
    var annotationLayers: [UUID: StitchAnnotationLayer] = [:] { didSet { canvas.annotationLayers = annotationLayers } }
    var unattachedAnnotationPreview: CGImage? { didSet { canvas.unattachedAnnotationPreview = unattachedAnnotationPreview } }
    var annotationPreview: CGImage? { didSet { canvas.annotationPreview = annotationPreview } }
    private var restoring = false
    private var adjustingStyle = false
    private let canvas = StitchCanvasView(frame: .zero)
    var isAttached: Bool { canvas.superview != nil }
    private var document: StitchDocument
    private var dragSnapshot: StitchDocument?
    private var seamOptions: NSView!
    private let pieceScroll = NSScrollView()
    private let piecesStack = StitchPiecesStack()
    private let pieceCountLabel = NSTextField(labelWithString: "")
    private var sliders: [StitchSlider] = []
    private var values: [NSTextField] = []
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
    private enum Options { case seams, pieces, canvas }
    private var activeOptions: Options?
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

    func attach(to editor: EditorView) {
        editorView = editor
        canvas.inlineEditor = editor
        if canvas.superview !== editor { editor.addSubview(canvas) }
        canvas.mode = editor.stitchMode
        if seamOptions == nil {
            seamOptions = makeSeamOptions()
            piecesStack.orientation = .vertical
            piecesStack.alignment = .leading
            piecesStack.spacing = 4
            pieceScroll.hasVerticalScroller = true
            pieceScroll.autohidesScrollers = true
            pieceScroll.drawsBackground = false
            pieceScroll.documentView = piecesStack
        }
        canvas.onSelect = { [weak self] _ in self?.refreshPieces() }
        canvas.onCut = { [weak self] axis, from, to in
            guard let self else { return }
            var next = self.document
            if next.collapse(axis: axis, from: from, to: to) {
                self.checkpoint(L("Collapse space")); self.document = next; self.canvas.selectedID = nil
                self.refresh(); self.showFeedback(L("Space collapsed. Undo restores the original pieces."))
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
        canvas.selectedID = nil
        refresh()
    }

    func showOptions(_ action: StitchOptionsAction, at anchor: NSView) {
        switch action {
        case .seams: showSeams(at: anchor)
        case .pieces: showPieces(at: anchor)
        case .canvas: showCanvasOptions(at: anchor)
        }
    }

    func setPlacement(_ placement: StitchPlacement) {
        guard document.placement != placement else { return }
        var next = document
        guard next.setPlacement(placement), next.canRender else { return }
        checkpoint(L("Change arrangement")); document = next; refresh()
    }

    func focus() {
        window?.makeFirstResponder(canvas)
    }

    func restore(_ value: StitchDocument) {
        restoring = true
        canvas.cancelEditingGesture()
        dragSnapshot = nil
        document = value
        canvas.selectedID = nil
        refresh()
        restoring = false
    }

    func suspend() {
        canvas.cancelEditingGesture()
        PopoverHelper.dismiss()
        feedback.removeFromSuperview()
        canvas.removeFromSuperview()
        canvas.inlineEditor = nil
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
    private func makeSeamOptions() -> NSView {
        let view = StitchOptionsView(frame: NSRect(x: 0, y: 0, width: 280, height: 242))
        seamToggle.target = self
        seamToggle.action = #selector(toggleSeams)
        seamToggle.contentTintColor = ToolbarLayout.accentColor
        seamToggle.frame = NSRect(x: 12, y: 207, width: 250, height: 24)
        view.addSubview(seamToggle)
        let colorLabel = NSTextField(labelWithString: L("Line color"))
        colorLabel.font = .systemFont(ofSize: 11)
        colorLabel.textColor = ToolbarLayout.iconColor
        colorLabel.frame = NSRect(x: 12, y: 177, width: 170, height: 18)
        color.frame = NSRect(x: 220, y: 173, width: 46, height: 24)
        color.target = self
        color.action = #selector(changeColor)
        view.addSubview(colorLabel)
        view.addSubview(color)
        for (index, spec) in [("Blur", 0.0, 30.0), ("Fade width", 0.0, 100.0), ("Line width", 0.0, 8.0), ("Wave height", 0.0, 14.0)].enumerated() {
            let y = CGFloat(137 - index * 38)
            let label = NSTextField(labelWithString: L(spec.0))
            label.font = .systemFont(ofSize: 11)
            label.textColor = ToolbarLayout.iconColor
            label.frame = NSRect(x: 12, y: y + 10, width: 180, height: 16)
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            value.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.55)
            value.alignment = .right
            value.frame = NSRect(x: 201, y: y + 10, width: 65, height: 16)
            let slider = StitchSlider(value: 0, minValue: spec.1, maxValue: spec.2,
                                      target: self, action: #selector(changeStyle(_:)))
            slider.frame = NSRect(x: 10, y: y - 9, width: 258, height: 20)
            slider.tag = index
            slider.isContinuous = true
            slider.controlSize = .small
            slider.trackFillColor = ToolbarLayout.accentColor
            slider.setAccessibilityLabel(L(spec.0))
            slider.onBegin = { [weak self] in
                self?.checkpoint(L("Change seam")); self?.adjustingStyle = true
            }
            slider.onEnd = { [weak self] in self?.adjustingStyle = false; self?.updateBandGuides(); self?.publish() }
            view.addSubview(label); view.addSubview(value); view.addSubview(slider)
            sliders.append(slider); values.append(value)
        }
        return view
    }
    private func showSeams(at anchor: NSView) {
        feedback.removeFromSuperview()
        if activeOptions == .seams, PopoverHelper.toggleClosedIfOpen() { return }
        activeOptions = .seams
        PopoverHelper.show(seamOptions, size: seamOptions.frame.size,
                           relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    private func showPieces(at anchor: NSView) {
        feedback.removeFromSuperview()
        if activeOptions == .pieces, PopoverHelper.toggleClosedIfOpen() { return }
        activeOptions = .pieces
        refreshPieces()
        let listHeight = min(CGFloat(288), max(36, CGFloat(document.pieces.count) * 36))
        let view = StitchOptionsView(frame: NSRect(x: 0, y: 0, width: 264, height: listHeight + 76))
        let title = pieceCountLabel
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.6)
        title.frame = NSRect(x: 12, y: listHeight + 50, width: 240, height: 16)
        pieceScroll.frame = NSRect(x: 12, y: 42, width: 240, height: listHeight)
        view.addSubview(title)
        view.addSubview(pieceScroll)
        let actions = [
            button("arrow.up", title: "", action: #selector(movePieceUp)),
            button("arrow.down", title: "", action: #selector(movePieceDown)),
            button("square.3.layers.3d.top.filled", title: "", action: #selector(bringForward)),
            button("trash", title: "", action: #selector(deletePiece)),
        ]
        let labels = [L("Move up"), L("Move down"), L("Bring Forward"), L("Delete piece")]
        pieceActions = actions
        for (index, button) in actions.enumerated() {
            button.frame = NSRect(x: 12 + index * 36, y: 8, width: 30, height: 26)
            button.bezelStyle = .recessed
            button.isBordered = false
            button.contentTintColor = ToolbarLayout.iconColor
            button.toolTip = labels[index]
            button.setAccessibilityLabel(labels[index])
            view.addSubview(button)
        }
        updatePieceActions()
        PopoverHelper.show(view, size: view.frame.size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
    private func showCanvasOptions(at anchor: NSView) {
        feedback.removeFromSuperview()
        if activeOptions == .canvas, PopoverHelper.toggleClosedIfOpen() { return }
        activeOptions = .canvas
        let view = StitchOptionsView(frame: NSRect(x: 0, y: 0, width: 264, height: 100))
        let title = NSTextField(labelWithString: L("Canvas background"))
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = ToolbarLayout.iconColor
        title.frame = NSRect(x: 12, y: 72, width: 240, height: 16)
        backgroundChoice.removeAllItems()
        backgroundChoice.addItems(withTitles: [L("Adjacent edge colors"), L("Solid color"), L("Transparent")])
        backgroundChoice.frame = NSRect(x: 10, y: 37, width: 198, height: 26)
        backgroundChoice.target = self; backgroundChoice.action = #selector(changeBackground)
        backgroundChoice.setAccessibilityLabel(L("Canvas background"))
        canvasColor.frame = NSRect(x: 217, y: 39, width: 34, height: 24)
        canvasColor.target = self; canvasColor.action = #selector(changeCanvasColor)
        switch document.background {
        case .automatic: backgroundChoice.selectItem(at: 0)
        case .color(let value): backgroundChoice.selectItem(at: 1); canvasColor.color = value
        case .transparent: backgroundChoice.selectItem(at: 2)
        }
        canvasColor.isHidden = backgroundChoice.indexOfSelectedItem != 1
        let hint = NSTextField(labelWithString: L("Fills space between captured pieces."))
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.55)
        hint.frame = NSRect(x: 12, y: 13, width: 240, height: 16)
        for child in [title, backgroundChoice, canvasColor, hint] { view.addSubview(child) }
        PopoverHelper.show(view, size: view.frame.size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
    @objc private func changeBackground() {
        checkpoint(L("Change canvas background"))
        switch backgroundChoice.indexOfSelectedItem {
        case 1: document.background = .color(canvasColor.color)
        case 2: document.background = .transparent
        default: document.background = .automatic
        }
        canvasColor.isHidden = backgroundChoice.indexOfSelectedItem != 1
        refresh()
    }
    @objc private func changeCanvasColor() {
        checkpoint(L("Change canvas background")); document.background = .color(canvasColor.color); refresh()
    }
    private func showFeedback(_ text: String) {
        guard let editor = editorView, let parent = editor.chromeParentView ?? editor.superview else { return }
        let token = UUID(); feedbackGeneration = token
        let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        feedback.text = text
        feedback.frame = CGRect(x: max(8, parent.bounds.midX - (size.width + 12) / 2),
                                y: 108, width: min(parent.bounds.width - 16, size.width + 12), height: size.height + 6)
        parent.addSubview(feedback)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.feedbackGeneration == token else { return }
            self.feedback.removeFromSuperview()
        }
    }
    private func checkpoint(_ title: String) { onCheckpoint?() }
    private func publish() {
        guard !restoring else { return }
        if onDocumentChanged?(document) == false {
            showFeedback(L("Unable to render this canvas. Reduce its size and try again."))
        }
    }
    private func refresh() {
        canvas.refresh(document, preview: nil)
        updateBandGuides()
        canvas.packed = document.placement == .packed
        let s = document.style
        for (index, value) in [s.blur, s.feather, s.lineWidth, s.wave].enumerated() {
            sliders[index].doubleValue = Double(value); values[index].stringValue = String(format: "%.1f px", Double(value))
        }
        color.color = s.color; seamToggle.state = s.visible ? .on : .off
        editorView?.refreshStitchOptions()
        refreshPieces(); scheduleRender()
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
        renderGeneration = UUID()
        renderCancellation?.cancel()
        pendingRender?.cancel()
        pendingRender = nil
    }
    private func scheduleRender() {
        if !adjustingStyle { publish() }
        canvas.syncInlineGeometry()
        cancelPreview()
        let snapshot = document
        let generation = renderGeneration
        let cancellation = StitchPreviewCancellation()
        renderCancellation = cancellation
        let work = DispatchWorkItem { [weak self] in
            guard !cancellation.isCancelled else { return }
            let bounds = snapshot.bounds
            let scale = min(1, sqrt(16_000_000 / max(1, bounds.width * bounds.height)))
            let result = autoreleasepool {
                (StitchRenderer.render(snapshot, maximumPreviewDimension: max(bounds.width, bounds.height) * scale),
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
    }
    private func refreshPieces() {
        pieceCountLabel.stringValue = "\(document.pieces.count) \(L("pieces"))"
        for view in piecesStack.arrangedSubviews { piecesStack.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, piece) in document.pieces.enumerated().reversed() {
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
            button.contentTintColor = canvas.selectedID == piece.id ? ToolbarLayout.accentColor : ToolbarLayout.iconColor
            button.toolTip = piece.label
            piecesStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 236).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        }
        piecesStack.frame = CGRect(x: 0, y: 0, width: 240, height: max(36, document.pieces.count * 36))
        updatePieceActions()
    }
    private func updatePieceActions() {
        guard pieceActions.count == 4 else { return }
        let index = document.pieces.firstIndex(where: { $0.id == canvas.selectedID })
        let enabled = [index.map { $0 < document.pieces.count - 1 } ?? false,
                       index.map { $0 > 0 } ?? false,
                       index.map { $0 < document.pieces.count - 1 } ?? false,
                       index != nil && document.pieces.count > 1]
        for (button, available) in zip(pieceActions, enabled) { button.isEnabled = available; button.alphaValue = available ? 1 : 0.35 }
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
            checkpoint(L("Move piece")); document = next; refresh()
            return
        }
        if dragSnapshot == nil { cancelPreview(); dragSnapshot = document }
        let old = document.pieces[index].origin
        document.pieces[index].origin = origin
        if !document.canRender { document.pieces[index].origin = old; showFeedback(L("Canvas limit reached. Move pieces closer together.")) }
        canvas.document = document; canvas.needsDisplay = true
        if final {
            if let snapshot = dragSnapshot, zip(snapshot.pieces, document.pieces).contains(where: { $0.origin != $1.origin }) { checkpoint(L("Move piece")) }
            dragSnapshot = nil; refresh()
        }
    }
    func setMode(_ mode: StitchCanvasView.Mode, focusCanvas: Bool = true) {
        canvas.mode = mode
        feedback.removeFromSuperview()
        if editorView?.stitchMode != mode { editorView?.stitchMode = mode }
        editorView?.refreshStitchOptions()
        if focusCanvas { window?.makeFirstResponder(canvas) }
    }
    @objc private func changeStyle(_ sender: NSSlider) {
        switch sender.tag { case 0: document.style.blur = sender.doubleValue; case 1: document.style.feather = sender.doubleValue; case 2: document.style.lineWidth = sender.doubleValue; default: document.style.wave = sender.doubleValue }
        values[sender.tag].stringValue = String(format: "%.1f px", sender.doubleValue)
        scheduleRender()
    }
    @objc private func changeColor() { checkpoint(L("Change seam color")); document.style.color = color.color; scheduleRender() }
    @objc private func toggleSeams() { checkpoint(L("Toggle seams")); document.style.visible = seamToggle.state == .on; updateBandGuides(); scheduleRender() }
    @objc private func selectPiece(_ sender: NSButton) {
        let piece = document.pieces[sender.tag]
        setMode(.move, focusCanvas: false); canvas.selectedID = piece.id
        refreshPieces()
        let rect = piece.frame.offsetBy(dx: -document.bounds.minX, dy: -document.bounds.minY)
        canvas.scrollToVisible(rect.insetBy(dx: -12, dy: -12))
        if !PopoverHelper.isVisible { window?.makeFirstResponder(canvas) }
    }
    @objc private func deletePiece() {
        guard let id = canvas.selectedID, document.pieces.count > 1 else { return }
        var next = document
        next.pieces.removeAll { $0.id == id }
        guard next.placement != .packed || next.reflowPacked() else { showFeedback(L("Canvas limit reached. Move pieces closer together.")); return }
        checkpoint(L("Delete piece")); document = next; canvas.selectedID = nil; refresh()
    }
    private func reorderPiece(to index: Int) {
        guard let id = canvas.selectedID else { return }
        var next = document
        guard StitchPieceOrder.move(id, in: &next.pieces, to: index) else { return }
        guard next.placement != .packed || next.reflowPacked() else { showFeedback(L("Canvas limit reached. Move pieces closer together.")); return }
        checkpoint(L("Bring piece forward"))
        document = next
        refresh()
    }
    @objc private func bringForward() { reorderPiece(to: document.pieces.count - 1) }
    @objc private func movePieceUp() {
        guard let index = document.pieces.firstIndex(where: { $0.id == canvas.selectedID }) else { return }
        reorderPiece(to: index + 1)
    }
    @objc private func movePieceDown() {
        guard let index = document.pieces.firstIndex(where: { $0.id == canvas.selectedID }) else { return }
        reorderPiece(to: index - 1)
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
        checkpoint(L("Add images")); document = next
        setMode(.move)
        canvas.selectedID = next.pieces.last?.id
        refresh()
    }
    deinit { pendingRender?.cancel(); renderCancellation?.cancel(); guideCancellation?.cancel() }
}
