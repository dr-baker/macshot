import AppKit
import UniformTypeIdentifiers

private final class StitchPiecesStack: NSStackView {
    override var isFlipped: Bool { true }
}

private final class StitchSlider: NSSlider {
    var onBegin: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onBegin?(); super.mouseDown(with: event) }
    override func keyDown(with event: NSEvent) { onBegin?(); super.keyDown(with: event) }
}

@MainActor
final class StitchEditorWindowController: NSObject, NSWindowDelegate {
    private static var controllers: [StitchEditorWindowController] = []
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
    private let canvas = StitchCanvasView(frame: .zero)
    private let scroll = NSScrollView()
    private let history = UndoManager()
    private var document: StitchDocument
    private var dragSnapshot: StitchDocument?
    private let status = NSTextField(labelWithString: "")
    private let topBar = StitchEditorTopBar(frame: .zero)
    private let toolStrip = ToolbarStripView(orientation: .horizontal)
    private let actionStrip = ToolbarStripView(orientation: .vertical)
    private var seamOptions: NSView!
    private let pieceScroll = NSScrollView()
    private var zoomObservation: NSKeyValueObservation?
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
    private var lastOutput: StitchDocument?
    private var hasOutput: Bool {
        guard let saved = lastOutput else { return false }
        guard saved.pieces.count == document.pieces.count,
              zip(saved.pieces, document.pieces).allSatisfy({
                  $0.image === $1.image && $0.source == $1.source && $0.origin == $1.origin
              }) else { return false }
        let a = saved.style, b = document.style
        guard a.visible == b.visible, a.blur == b.blur, a.feather == b.feather,
              a.lineWidth == b.lineWidth, a.wave == b.wave, a.color.isEqual(b.color) else { return false }
        switch (saved.background, document.background) {
        case (.automatic, .automatic), (.transparent, .transparent): return true
        case (.color(let a), .color(let b)): return a.isEqual(b)
        default: return false
        }
    }
    private enum Options { case seams, pieces, canvas }
    private var activeOptions: Options?
    private let canvasColor = NSColorWell()
    private let backgroundChoice = NSPopUpButton()
    private var pieceActions: [NSButton] = []
    private var feedbackGeneration = UUID()
    private var exporting = false
    private var outputFeedbackGeneration = UUID()
    private let tooltip = StitchTooltipView()
    private let outputQueue = DispatchQueue(label: "macshot.stitch-output", qos: .userInitiated)

    static func open(image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        open(document: StitchDocument(pieces: [StitchPiece(image: cg)]))
    }
    static func open(document: StitchDocument) {
        guard document.canRender else { return }
        let controller = StitchEditorWindowController(document: document)
        controllers.append(controller)
        controller.show()
    }
    private init(document: StitchDocument) { self.document = document; super.init() }

    private func show() {
        window.title = L("macshot · Stitch")
        window.minSize = NSSize(width: 760, height: 500)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.center()
        let root = NSView()
        window.contentView = root

        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.025
        scroll.maxMagnification = 8
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.backgroundColor = NSColor(white: 0.15, alpha: 1)
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 84, right: 50)
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: -84, right: -50)

        topBar.onAdd = { [weak self] in self?.addImages() }
        topBar.onPieces = { [weak self] anchor in self?.showPieces(at: anchor) }
        topBar.onFit = { [weak self] in self?.fitCanvas() }
        topBar.onZoom = { [weak self] value in self?.setZoom(value) }
        topBar.onCanvas = { [weak self] anchor in self?.showCanvasOptions(at: anchor) }
        topBar.onPlacement = { [weak self] placement in
            guard let self, self.document.placement != placement else { return }
            var next = self.document
            guard next.setPlacement(placement), next.canRender else { return }
            self.checkpoint(L("Change arrangement")); self.document = next
            self.refresh(); self.fitCanvas()
            self.showFeedback(placement == .packed ? L("Packed · drag pieces to rearrange") : L("Free Move · drag pieces anywhere"))
        }
        zoomObservation = scroll.observe(\.magnification, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            MainActor.assumeIsolated { self?.topBar.updateZoom(value) }
        }
        toolStrip.setButtons(toolButtons())
        toolStrip.onClick = { [weak self] action in self?.handleTool(action) }
        toolStrip.onRightClick = { [weak self] action, anchor in
            switch action {
            case .adjustSelection, .scrollCapture, .effects: self?.showSeams(at: anchor)
            default: break
            }
        }
        actionStrip.setButtons([
            ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy")),
            ToolbarButton(action: .save, sfSymbol: "square.and.arrow.down", tooltip: L("Save PNG")),
            ToolbarButton(action: .detach, sfSymbol: "pencil.tip", tooltip: L("Annotate")),
        ])
        actionStrip.onClick = { [weak self] action in
            switch action {
            case .copy: self?.copyImage()
            case .save: self?.saveImage()
            case .detach: self?.annotate()
            default: break
            }
        }
        for strip in [toolStrip, actionStrip] {
            strip.onHover = { [weak self, weak strip] action, hovered in
                guard let self, let strip else { return }
                self.showTooltip(action, strip: strip, hovered: hovered)
            }
            for button in strip.buttonViews {
                button.toolTip = nil
                button.setAccessibilityLabel(button.tooltipText)
            }
        }
        seamOptions = makeSeamOptions()
        piecesStack.orientation = .vertical
        piecesStack.alignment = .leading
        piecesStack.spacing = 4
        pieceScroll.hasVerticalScroller = true
        pieceScroll.autohidesScrollers = true
        pieceScroll.drawsBackground = false
        pieceScroll.documentView = piecesStack

        status.font = .systemFont(ofSize: 11)
        status.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.7)
        status.lineBreakMode = .byTruncatingTail
        let statusBar = StitchOptionsView(frame: .zero)
        status.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(status)
        for view in [scroll, topBar, toolStrip, actionStrip, statusBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 32),
            scroll.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toolStrip.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toolStrip.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            toolStrip.widthAnchor.constraint(equalToConstant: toolStrip.frame.width),
            toolStrip.heightAnchor.constraint(equalToConstant: toolStrip.frame.height),
            actionStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            actionStrip.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            actionStrip.widthAnchor.constraint(equalToConstant: actionStrip.frame.width),
            actionStrip.heightAnchor.constraint(equalToConstant: actionStrip.frame.height),
            statusBar.centerXAnchor.constraint(equalTo: toolStrip.centerXAnchor),
            statusBar.bottomAnchor.constraint(equalTo: toolStrip.topAnchor, constant: -6),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
            statusBar.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -130),
            status.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
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
        canvas.onCopy = { [weak self] in self?.copyImage() }
        canvas.onMode = { [weak self] mode in self?.setMode(mode) }
        canvas.onZoom = { [weak self] value in self?.setZoom(value) }
        canvas.onFit = { [weak self] in self?.fitCanvas() }
        canvas.selectedID = nil
        refresh()
        status.stringValue = toolHint
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(canvas)
        DispatchQueue.main.async { [weak self] in self?.fitCanvas() }
    }
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
            slider.onBegin = { [weak self] in self?.checkpoint(L("Change seam")) }
            view.addSubview(label); view.addSubview(value); view.addSubview(slider)
            sliders.append(slider); values.append(value)
        }
        return view
    }
    private func showSeams(at anchor: NSView) {
        tooltip.removeFromSuperview()
        if activeOptions == .seams, PopoverHelper.toggleClosedIfOpen() { return }
        activeOptions = .seams
        PopoverHelper.show(seamOptions, size: seamOptions.frame.size,
                           relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    private func showPieces(at anchor: NSView) {
        tooltip.removeFromSuperview()
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
        tooltip.removeFromSuperview()
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
    private var toolHint: String {
        switch canvas.mode {
        case .move: return document.placement == .packed ? L("Packed · drag pieces to rearrange") : L("Drag a piece. Edges snap together; Option disables snapping.")
        case .rows, .columns: return L("Drag across the band to remove. Release to join the remaining edges.")
        }
    }
    private func showTooltip(_ action: ToolbarButtonAction, strip: ToolbarStripView, hovered: Bool) {
        tooltip.removeFromSuperview()
        guard hovered, !PopoverHelper.isVisible, let root = window.contentView,
              let button = toolbarButton(action, in: strip) else { return }
        let text = button.tooltipText
        let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        let frame = button.convert(button.bounds, to: root)
        let width = size.width + 12, height = size.height + 6
        let x = strip === toolStrip ? frame.midX - width / 2 : frame.minX - width - 6
        let y = strip === toolStrip ? toolStrip.frame.maxY + 4 : frame.midY - height / 2
        tooltip.frame = NSRect(x: max(2, min(x, root.bounds.maxX - width - 2)),
                               y: max(2, min(y, root.bounds.maxY - height - 2)), width: width, height: height)
        tooltip.text = text; root.addSubview(tooltip)
    }
    private func toolbarButton(_ action: ToolbarButtonAction, in strip: ToolbarStripView) -> ToolbarButtonView? {
        let index: Int
        switch action {
        case .moveSelection, .copy: index = 0
        case .adjustSelection, .save: index = 1
        case .scrollCapture, .detach: index = 2
        case .effects: index = 3
        case .undo: index = 4
        case .redo: index = 5
        default: return nil
        }
        return strip.buttonViews.indices.contains(index) ? strip.buttonViews[index] : nil
    }
    private func showFeedback(_ text: String) {
        let token = UUID(); feedbackGeneration = token
        status.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.feedbackGeneration == token, !self.exporting else { return }
            self.status.stringValue = self.toolHint
        }
    }
    private func checkpoint(_ title: String) { registerUndo(document, title: title) }
    private func registerUndo(_ snapshot: StitchDocument, title: String) {
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.registerUndo(target.document, title: title)
                target.document = snapshot; target.canvas.selectedID = nil; target.refresh()
            }
        }
        history.setActionName(title)
        DispatchQueue.main.async { [weak self] in self?.updateTools() }
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { history }
    private func refresh() {
        window.isDocumentEdited = !hasOutput
        canvas.refresh(document, preview: nil)
        canvas.packed = document.placement == .packed
        topBar.updatePlacement(document.placement)
        let s = document.style
        for (index, value) in [s.blur, s.feather, s.lineWidth, s.wave].enumerated() {
            sliders[index].doubleValue = Double(value); values[index].stringValue = String(format: "%.1f px", Double(value))
        }
        color.color = s.color; seamToggle.state = s.visible ? .on : .off
        let b = document.bounds
        topBar.update(width: Int(b.width), height: Int(b.height), pieces: document.pieces.count)
        updateTools()
        refreshPieces(); scheduleRender()
    }
    private func cancelPreview() {
        renderGeneration = UUID()
        renderCancellation?.cancel()
        pendingRender?.cancel()
        pendingRender = nil
    }
    private func scheduleRender() {
        window.isDocumentEdited = !hasOutput
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
                      !cancellation.isCancelled, self.window.isVisible else { return }
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
        if !document.canRender { document.pieces[index].origin = old; status.stringValue = L("Canvas limit reached. Move pieces closer together.") }
        canvas.document = document; canvas.needsDisplay = true
        if final {
            if let snapshot = dragSnapshot { registerUndo(snapshot, title: L("Move piece")) }
            dragSnapshot = nil; refresh()
        }
    }
    private func setMode(_ mode: StitchCanvasView.Mode, focusCanvas: Bool = true) {
        canvas.mode = mode
        feedbackGeneration = UUID(); status.stringValue = toolHint
        updateTools()
        if focusCanvas { window.makeFirstResponder(canvas) }
    }
    private func toolButtons() -> [ToolbarButton] {
        [
            ToolbarButton(action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right", tooltip: L("Move") + " (V)", isSelected: canvas.mode == .move),
            ToolbarButton(action: .adjustSelection, sfSymbol: "rectangle.split.1x2", tooltip: L("Remove Rows") + " (R)", isSelected: canvas.mode == .rows, hasContextMenu: true),
            ToolbarButton(action: .scrollCapture, sfSymbol: "rectangle.split.2x1", tooltip: L("Remove Columns") + " (C)", isSelected: canvas.mode == .columns, hasContextMenu: true),
            ToolbarButton(action: .effects, sfSymbol: "slider.horizontal.3", tooltip: L("Change seam")),
            ToolbarButton(action: .undo, sfSymbol: "arrow.uturn.backward", tooltip: L("Undo"), tintColor: ToolbarLayout.iconColor.withAlphaComponent(history.canUndo ? 1 : 0.3)),
            ToolbarButton(action: .redo, sfSymbol: "arrow.uturn.forward", tooltip: L("Redo"), tintColor: ToolbarLayout.iconColor.withAlphaComponent(history.canRedo ? 1 : 0.3)),
        ]
    }
    private func updateTools() { toolStrip.updateState(from: toolButtons()) }
    private func handleTool(_ action: ToolbarButtonAction) {
        switch action {
        case .moveSelection: setMode(.move)
        case .adjustSelection: setMode(.rows)
        case .scrollCapture: setMode(.columns)
        case .effects:
            if let anchor = toolStrip.buttonViews.dropFirst(3).first { showSeams(at: anchor) }
        case .undo: undoAction()
        case .redo: redoAction()
        default: break
        }
    }
    @objc private func changeStyle(_ sender: NSSlider) {
        switch sender.tag { case 0: document.style.blur = sender.doubleValue; case 1: document.style.feather = sender.doubleValue; case 2: document.style.lineWidth = sender.doubleValue; default: document.style.wave = sender.doubleValue }
        values[sender.tag].stringValue = String(format: "%.1f px", sender.doubleValue)
        window.isDocumentEdited = !hasOutput; scheduleRender()
    }
    @objc private func changeColor() { checkpoint(L("Change seam color")); document.style.color = color.color; scheduleRender() }
    @objc private func toggleSeams() { checkpoint(L("Toggle seams")); document.style.visible = seamToggle.state == .on; scheduleRender() }
    @objc private func selectPiece(_ sender: NSButton) {
        let piece = document.pieces[sender.tag]
        setMode(.move, focusCanvas: false); canvas.selectedID = piece.id
        refreshPieces()
        let rect = piece.frame.offsetBy(dx: 80 - document.bounds.minX, dy: 80 - document.bounds.minY)
        canvas.scrollToVisible(rect.insetBy(dx: -12, dy: -12))
        if !PopoverHelper.isVisible { window.makeFirstResponder(canvas) }
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
    @objc private func undoAction() { history.undo(); updateTools() }
    @objc private func redoAction() { history.redo(); updateTools() }
    @objc private func fitCanvas() {
        let area = scroll.contentSize
        let size = canvas.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        setZoom(min(1, min((area.width - 50) / size.width, (area.height - 84) / size.height)), fit: true)
    }
    private func setZoom(_ value: CGFloat, fit: Bool = false) {
        let zoom = min(scroll.maxMagnification, max(scroll.minMagnification, value))
        let visible = scroll.documentVisibleRect
        let center = fit ? NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY) : NSPoint(x: visible.midX, y: visible.midY)
        scroll.setMagnification(zoom, centeredAt: center)
        topBar.updateZoom(zoom)
    }
    @objc private func addImages() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK else { return }
            self?.append(panel.urls.compactMap { NSImage(contentsOf: $0) })
        }
    }
    private func append(_ images: [NSImage]) {
        var next = document
        for image in images {
            guard next.pieces.count < 48, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let b = next.bounds
            next.pieces.append(StitchPiece(image: cg, origin: CGPoint(x: b.minX, y: b.maxY), label: L("Added image")))
            if !next.canRender { next.pieces.removeLast(); status.stringValue = L("Image exceeds the canvas limit."); break }
        }
        guard next.pieces.count != document.pieces.count else { return }
        guard next.placement != .packed || next.reflowPacked() else { showFeedback(L("Image exceeds the canvas limit.")); return }
        checkpoint(L("Add images")); document = next; refresh(); fitCanvas()
    }
    /// Rendering and PNG encoding own an immutable snapshot while the editor remains responsive.
    private func output(action: ToolbarButtonAction, writeTo url: URL? = nil, completion: @escaping (NSImage, Bool) -> Void) {
        guard !exporting else { return }
        exporting = true
        outputFeedbackGeneration = UUID()
        let snapshot = document
        showFeedback(L("Preparing image…"))
        setOutputFeedback(action: action, symbol: "hourglass")
        outputQueue.async { [weak self] in
            let result: Result<CGImage, Error> = autoreleasepool {
                guard let pixels = StitchRenderer.render(snapshot) else {
                    return .failure(NSError(domain: "Stitch", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Unable to render this canvas. Reduce its size and try again.")]))
                }
                if let url {
                    guard let data = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]) else {
                        return .failure(NSError(domain: "Stitch", code: 2, userInfo: [NSLocalizedDescriptionKey: L("Unable to save this image.")]))
                    }
                    do { try data.write(to: url, options: .atomic) }
                    catch { return .failure(error) }
                }
                return .success(pixels)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.exporting = false
                self.resetOutputFeedback()
                switch result {
                case .failure(let error): self.showFeedback(error.localizedDescription)
                case .success(let pixels):
                    self.lastOutput = snapshot
                    let unchanged = self.hasOutput
                    self.window.isDocumentEdited = !unchanged
                    completion(NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height)), unchanged)
                }
            }
        }
    }
    private func resetOutputFeedback() {
        actionStrip.updateState(from: [
            ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy")),
            ToolbarButton(action: .save, sfSymbol: "square.and.arrow.down", tooltip: L("Save PNG")),
            ToolbarButton(action: .detach, sfSymbol: "pencil.tip", tooltip: L("Annotate")),
        ])
    }
    private func setOutputFeedback(action: ToolbarButtonAction, symbol: String) {
        guard let button = toolbarButton(action, in: actionStrip) else { return }
        button.configure(with: ToolbarButton(action: action, sfSymbol: symbol, tooltip: button.tooltipText, tintColor: ToolbarLayout.accentColor))
    }
    private func outputFinished(action: ToolbarButtonAction, message: String) {
        showFeedback(message)
        if UserDefaults.standard.object(forKey: "playCopySound") as? Bool ?? true {
            AppDelegate.captureSound?.stop(); AppDelegate.captureSound?.play()
        }
        setOutputFeedback(action: action, symbol: "checkmark")
        let token = UUID(); outputFeedbackGeneration = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.outputFeedbackGeneration == token, !self.exporting else { return }
            self.resetOutputFeedback()
        }
    }
    @objc private func copyImage() {
        output(action: .copy) { [weak self] image, _ in
            ImageEncoder.copyToClipboard(image)
            self?.outputFinished(action: .copy, message: L("Copied stitched image."))
        }
    }
    @objc private func saveImage() { saveImage(closeAfterSave: false) }
    private func saveImage(closeAfterSave: Bool) {
        guard !exporting else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Stitch.png"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { return }
            self.output(action: .save, writeTo: url) { [weak self] _, unchanged in
                guard let self else { return }
                self.outputFinished(action: .save, message: L("Saved stitched image."))
                if closeAfterSave, unchanged { self.window.close() }
            }
        }
    }
    @objc private func annotate() {
        output(action: .detach) { [weak self] image, _ in
            DetachedEditorWindowController.open(image: image, fromCapture: true, disableBeautify: true)
            self?.outputFinished(action: .detach, message: L("Opened in editor"))
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if exporting { showFeedback(L("Preparing image…")); return false }
        guard !hasOutput else { return true }
        let alert = NSAlert(); alert.messageText = L("Close this stitch?")
        alert.informativeText = L("Its editable pieces will be discarded. Copy or save the image first to keep the result.")
        alert.addButton(withTitle: L("Save PNG")); alert.addButton(withTitle: L("Discard")); alert.addButton(withTitle: L("Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.saveImage(closeAfterSave: true) }
            else if response == .alertSecondButtonReturn { self.window.close() }
        }
        return false
    }
    func windowWillClose(_ notification: Notification) {
        PopoverHelper.dismiss()
        zoomObservation = nil
        cancelPreview(); Self.controllers.removeAll { $0 === self }
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}
