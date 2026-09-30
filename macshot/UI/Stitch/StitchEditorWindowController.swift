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
    private var hasOutput = false

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
            for button in strip.buttonViews {
                button.toolTip = button.tooltipText
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
                self.refresh(); self.status.stringValue = L("Space collapsed. Undo restores the original pieces.")
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
        canvas.selectedID = document.pieces.first?.id
        refresh()
        status.stringValue = L("Select rows or columns to collapse space, or drag pieces to arrange them.")
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
        if PopoverHelper.toggleClosedIfOpen() { return }
        PopoverHelper.show(seamOptions, size: seamOptions.frame.size,
                           relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    private func showPieces(at anchor: NSView) {
        if PopoverHelper.toggleClosedIfOpen() { return }
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
        for (index, button) in actions.enumerated() {
            button.frame = NSRect(x: 12 + index * 36, y: 8, width: 30, height: 26)
            button.bezelStyle = .recessed
            button.isBordered = false
            button.contentTintColor = ToolbarLayout.iconColor
            button.toolTip = labels[index]
            button.setAccessibilityLabel(labels[index])
            view.addSubview(button)
        }
        PopoverHelper.show(view, size: view.frame.size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
    private func checkpoint(_ title: String) { registerUndo(document, title: title); hasOutput = false }
    private func registerUndo(_ snapshot: StitchDocument, title: String) {
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.registerUndo(target.document, title: title)
                target.document = snapshot; target.canvas.selectedID = nil; target.hasOutput = false; target.refresh()
            }
        }
        history.setActionName(title)
        DispatchQueue.main.async { [weak self] in self?.updateTools() }
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { history }
    private func refresh() {
        canvas.refresh(document, preview: nil)
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
        cancelPreview()
        let snapshot = document
        let generation = renderGeneration
        let cancellation = StitchPreviewCancellation()
        renderCancellation = cancellation
        let work = DispatchWorkItem { [weak self] in
            guard !cancellation.isCancelled else { return }
            let bounds = snapshot.bounds
            let scale = min(1, sqrt(16_000_000 / max(1, bounds.width * bounds.height)))
            let preview = autoreleasepool {
                StitchRenderer.render(snapshot, maximumPreviewDimension: max(bounds.width, bounds.height) * scale)
            }
            guard !cancellation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.renderGeneration == generation,
                      !cancellation.isCancelled, self.window.isVisible else { return }
                self.canvas.refresh(snapshot, preview: preview)
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
    }
    private func move(id: UUID, origin: CGPoint, final: Bool) {
        guard let index = document.pieces.firstIndex(where: { $0.id == id }) else { return }
        if dragSnapshot == nil { cancelPreview(); dragSnapshot = document }
        let old = document.pieces[index].origin
        document.pieces[index].origin = origin
        if !document.canRender { document.pieces[index].origin = old; status.stringValue = L("Canvas limit reached. Move pieces closer together.") }
        canvas.document = document; canvas.needsDisplay = true
        if final {
            if let snapshot = dragSnapshot { registerUndo(snapshot, title: L("Move piece")) }
            dragSnapshot = nil; hasOutput = false; refresh()
        }
    }
    private func setMode(_ mode: StitchCanvasView.Mode) {
        canvas.mode = mode
        status.stringValue = mode == .move
            ? L("Drag a piece. Edges snap together; Option disables snapping.")
            : L("Drag across the band to remove. Release to join the remaining edges.")
        updateTools()
        window.makeFirstResponder(canvas)
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
        hasOutput = false; scheduleRender()
    }
    @objc private func changeColor() { checkpoint(L("Change seam color")); document.style.color = color.color; scheduleRender() }
    @objc private func toggleSeams() { checkpoint(L("Toggle seams")); document.style.visible = seamToggle.state == .on; scheduleRender() }
    @objc private func selectPiece(_ sender: NSButton) { canvas.selectedID = document.pieces[sender.tag].id; refreshPieces(); window.makeFirstResponder(canvas) }
    @objc private func deletePiece() {
        guard let id = canvas.selectedID, document.pieces.count > 1 else { return }
        checkpoint(L("Delete piece")); document.pieces.removeAll { $0.id == id }; canvas.selectedID = nil; refresh()
    }
    private func reorderPiece(to index: Int) {
        guard let id = canvas.selectedID else { return }
        var next = document
        guard StitchPieceOrder.move(id, in: &next.pieces, to: index) else { return }
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
        setZoom(min(1, min((area.width - 50) / size.width, (area.height - 84) / size.height)))
    }
    private func setZoom(_ value: CGFloat) {
        let zoom = min(scroll.maxMagnification, max(scroll.minMagnification, value))
        scroll.setMagnification(zoom, centeredAt: NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
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
        checkpoint(L("Add images")); document = next; refresh(); fitCanvas()
    }
    private func output() -> NSImage? {
        guard let cg = StitchRenderer.render(document) else { status.stringValue = L("Unable to render this canvas. Reduce its size and try again."); return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    @objc private func copyImage() {
        guard let image = output() else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]); hasOutput = true; status.stringValue = L("Copied stitched image.")
    }
    @objc private func saveImage() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Stitch.png"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url, let image = self.output(), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
            do { try data.write(to: url, options: .atomic); self.hasOutput = true; self.status.stringValue = L("Saved stitched image.") }
            catch { self.status.stringValue = error.localizedDescription }
        }
    }
    @objc private func annotate() {
        guard let image = output() else { return }
        DetachedEditorWindowController.open(image: image, fromCapture: true, disableBeautify: true)
        hasOutput = true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !hasOutput else { return true }
        let alert = NSAlert(); alert.messageText = L("Close this stitch?")
        alert.informativeText = L("Its editable pieces will be discarded. Copy or save the image first to keep the result.")
        alert.addButton(withTitle: L("Keep Editing")); alert.addButton(withTitle: L("Discard"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowWillClose(_ notification: Notification) {
        PopoverHelper.dismiss()
        zoomObservation = nil
        cancelPreview(); Self.controllers.removeAll { $0 === self }
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}
