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
    private let summary = NSTextField(labelWithString: "")
    private let piecesStack = StitchPiecesStack()
    private var sliders: [StitchSlider] = []
    private var values: [NSTextField] = []
    private let color = NSColorWell()
    private let seamToggle = NSButton(checkboxWithTitle: L("Show stitch seams"), target: nil, action: nil)
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
        window.minSize = NSSize(width: 850, height: 680)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        let root = NSView()
        window.contentView = root
        let toolbar = NSStackView()
        toolbar.orientation = .horizontal; toolbar.spacing = 10
        let modes = NSSegmentedControl(labels: [L("Move"), L("Remove Rows"), L("Remove Columns")], trackingMode: .selectOne, target: self, action: #selector(changeMode(_:)))
        modes.selectedSegment = 0
        modes.toolTip = L("Drag across the space to remove. Its edges reconnect with a soft stitch seam.")
        toolbar.addArrangedSubview(modes)
        toolbar.addArrangedSubview(button("arrow.uturn.backward", title: L("Undo"), action: #selector(undoAction)))
        toolbar.addArrangedSubview(button("arrow.uturn.forward", title: L("Redo"), action: #selector(redoAction)))
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.addArrangedSubview(spacer)
        toolbar.addArrangedSubview(button("plus", title: L("Add Images"), action: #selector(addImages)))
        toolbar.addArrangedSubview(button("doc.on.doc", title: L("Copy"), action: #selector(copyImage)))
        toolbar.addArrangedSubview(button("square.and.arrow.down", title: L("Save PNG"), action: #selector(saveImage)))
        let edit = button("pencil.tip", title: L("Annotate"), action: #selector(annotate))
        edit.toolTip = L("Open the rendered stitch in the annotation editor. This workspace keeps its editable pieces.")
        toolbar.addArrangedSubview(edit)

        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.allowsMagnification = true
        scroll.minMagnification = 0.025; scroll.maxMagnification = 4
        scroll.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1)
        let inspector = NSStackView(); inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing = 7
        inspector.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 16, right: 16)
        let heading = NSTextField(labelWithString: L("STITCH")); heading.font = .systemFont(ofSize: 11, weight: .bold); heading.textColor = .secondaryLabelColor
        inspector.addArrangedSubview(heading)
        seamToggle.target = self; seamToggle.action = #selector(toggleSeams)
        inspector.addArrangedSubview(seamToggle)
        let colorRow = NSStackView(views: [NSTextField(labelWithString: L("Line color")), color]); colorRow.spacing = 12
        color.target = self; color.action = #selector(changeColor)
        inspector.addArrangedSubview(colorRow)
        for (index, spec) in [("Blur", 0.0, 30.0), ("Fade width", 0.0, 100.0), ("Line width", 0.0, 8.0), ("Wave height", 0.0, 14.0)].enumerated() {
            let label = NSTextField(labelWithString: L(spec.0))
            let value = NSTextField(labelWithString: ""); value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); value.textColor = .secondaryLabelColor
            let row = NSStackView(views: [label, value]); row.distribution = .fillEqually
            let slider = StitchSlider(value: 0, minValue: spec.1, maxValue: spec.2, target: self, action: #selector(changeStyle(_:)))
            slider.tag = index; slider.isContinuous = true
            slider.setAccessibilityLabel(L(spec.0))
            slider.onBegin = { [weak self] in self?.checkpoint(L("Change seam")) }
            inspector.addArrangedSubview(row); inspector.addArrangedSubview(slider)
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
            sliders.append(slider); values.append(value)
        }
        let piecesTitle = NSTextField(labelWithString: L("PIECES")); piecesTitle.font = .systemFont(ofSize: 11, weight: .bold); piecesTitle.textColor = .secondaryLabelColor
        inspector.addArrangedSubview(piecesTitle)
        let pieceScroll = NSScrollView(); pieceScroll.hasVerticalScroller = true; pieceScroll.drawsBackground = false
        piecesStack.orientation = .vertical; piecesStack.alignment = .leading; piecesStack.spacing = 6
        pieceScroll.documentView = piecesStack
        inspector.addArrangedSubview(pieceScroll)
        pieceScroll.widthAnchor.constraint(equalToConstant: 200).isActive = true
        pieceScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        let pieceActions = NSStackView(views: [button("square.3.layers.3d.top.filled", title: L("Bring Forward"), action: #selector(bringForward)), button("trash", title: "", action: #selector(deletePiece))])
        inspector.addArrangedSubview(pieceActions)
        let fit = button("arrow.up.left.and.arrow.down.right", title: L("Fit Canvas"), action: #selector(fitCanvas))
        inspector.addArrangedSubview(fit)
        let hint = NSTextField(wrappingLabelWithString: L("Drag pieces to align their edges. Hold Option to move freely. Arrow keys nudge; Shift moves 10 px."))
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        inspector.addArrangedSubview(hint)
        hint.widthAnchor.constraint(equalToConstant: 200).isActive = true
        summary.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); summary.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let footer = NSStackView(views: [status, summary]); footer.distribution = .fill; footer.spacing = 16
        for view in [toolbar, scroll, inspector, footer] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12), toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14), toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), toolbar.heightAnchor.constraint(equalToConstant: 32),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10), scroll.trailingAnchor.constraint(equalTo: inspector.leadingAnchor),
            inspector.topAnchor.constraint(equalTo: scroll.topAnchor), inspector.trailingAnchor.constraint(equalTo: root.trailingAnchor), inspector.bottomAnchor.constraint(equalTo: scroll.bottomAnchor), inspector.widthAnchor.constraint(equalToConstant: 232),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16), footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16), footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -9), footer.heightAnchor.constraint(equalToConstant: 18)
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
        canvas.onDelete = { [weak self] in self?.deletePiece() }
        canvas.onImages = { [weak self] images in self?.append(images) }
        canvas.onCopy = { [weak self] in self?.copyImage() }
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
    private func checkpoint(_ title: String) { registerUndo(document, title: title); hasOutput = false }
    private func registerUndo(_ snapshot: StitchDocument, title: String) {
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.registerUndo(target.document, title: title)
                target.document = snapshot; target.canvas.selectedID = nil; target.hasOutput = false; target.refresh()
            }
        }
        history.setActionName(title)
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
        summary.stringValue = "\(document.pieces.count) \(L("pieces")) · \(Int(b.width)) × \(Int(b.height)) px"
        refreshPieces(); scheduleRender()
    }
    private func scheduleRender() {
        pendingRender?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let bounds = self.document.bounds
            let scale = min(1, sqrt(16_000_000 / max(1, bounds.width * bounds.height)))
            self.canvas.refresh(self.document, preview: StitchRenderer.render(self.document, maximumPreviewDimension: max(bounds.width, bounds.height) * scale))
        }
        pendingRender = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }
    private func refreshPieces() {
        for view in piecesStack.arrangedSubviews { piecesStack.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, piece) in document.pieces.enumerated() {
            let button = NSButton(title: "\(index + 1)   \(piece.label)", target: self, action: #selector(selectPiece(_:)))
            button.tag = index; button.bezelStyle = .recessed; button.setButtonType(.pushOnPushOff)
            button.state = canvas.selectedID == piece.id ? .on : .off
            if let cg = piece.image.cropping(to: piece.source) {
                let image = NSImage(cgImage: cg, size: NSSize(width: 30, height: 24)); button.image = image; button.imagePosition = .imageLeading
            }
            button.alignment = .left
            piecesStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 196).isActive = true
        }
        piecesStack.frame = CGRect(x: 0, y: 0, width: 200, height: max(30, document.pieces.count * 32))
    }
    private func move(id: UUID, origin: CGPoint, final: Bool) {
        guard let index = document.pieces.firstIndex(where: { $0.id == id }) else { return }
        if dragSnapshot == nil { dragSnapshot = document }
        let old = document.pieces[index].origin
        document.pieces[index].origin = origin
        if !document.canRender { document.pieces[index].origin = old; status.stringValue = L("Canvas limit reached. Move pieces closer together.") }
        canvas.document = document; canvas.needsDisplay = true
        if final {
            if let snapshot = dragSnapshot { registerUndo(snapshot, title: L("Move piece")) }
            dragSnapshot = nil; hasOutput = false; refresh()
        }
    }
    @objc private func changeMode(_ sender: NSSegmentedControl) {
        canvas.mode = StitchCanvasView.Mode(rawValue: sender.selectedSegment) ?? .move
        status.stringValue = canvas.mode == .move ? L("Drag a piece. Edges snap together; Option disables snapping.") : L("Drag across the band to remove. Release to join the remaining edges.")
        window.makeFirstResponder(canvas)
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
    @objc private func bringForward() {
        guard let id = canvas.selectedID, let index = document.pieces.firstIndex(where: { $0.id == id }) else { return }
        checkpoint(L("Bring piece forward")); let piece = document.pieces.remove(at: index); document.pieces.append(piece); refresh()
    }
    @objc private func undoAction() { history.undo() }
    @objc private func redoAction() { history.redo() }
    @objc private func fitCanvas() {
        let area = scroll.contentSize
        scroll.magnification = max(scroll.minMagnification, min(1, min(area.width / canvas.frame.width, area.height / canvas.frame.height)))
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
        pendingRender?.cancel(); Self.controllers.removeAll { $0 === self }
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}
