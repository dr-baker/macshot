import Cocoa

/// Standalone editor view — subclass of OverlayView for the editor window.
/// When inside an NSScrollView, coordinate transforms are identity (view coords = canvas coords).
/// NSScrollView handles zoom, pan, centering, momentum — no manual math needed.
struct StitchEditorSnapshot {
    let image: NSImage?
    let document: StitchDocument?
    let annotations: [(object: Annotation, properties: Annotation)]
    let numberCounter: Int
}

struct StitchAnnotationLayer {
    /// A missing raster requires an opaque piece placeholder during movement.
    let image: CGImage?
    /// Global top-down document pixels, including marks crossing piece edges.
    let frame: CGRect
}

class EditorView: OverlayView, NSMenuItemValidation {
    override var toolbarColor: NSColor {
        currentTool == .stitch ? stitchSeamColorPreview ?? stitchDocument?.style.color ?? currentColor : currentColor
    }

    private(set) var stitchSeamColorPreview: NSColor?
    var onStitchSeamColorPreview: ((NSColor?) -> Void)?

    func previewStitchSeamColor(_ color: NSColor?) {
        guard stitchSeamColorPreview != color else { return }
        stitchSeamColorPreview = color
        updateToolbarColorSwatch()
        onStitchSeamColorPreview?(color)
    }

    var stitchMode: StitchCanvasView.Mode = .removeSpace {
        didSet {
            guard stitchMode != oldValue else { return }
            onStitchModeChanged?(stitchMode)
            refreshStitchOptions()
        }
    }
    var onStitchModeChanged: ((StitchCanvasView.Mode) -> Void)?
    var onStitchToolChanged: ((Bool) -> Void)?
    var onStitchOptions: ((StitchOptionsAction, NSView) -> Void)?
    var onStitchPlacementChanged: ((StitchPlacement) -> Void)?
    var onStitchImages: (([NSImage]) -> Void)?

    override var currentTool: AnnotationTool {
        didSet {
            guard currentTool != oldValue else { return }
            if currentTool == .stitch || oldValue == .stitch {
                clearStitchAnnotationSelection()
                onStitchToolChanged?(currentTool == .stitch)
            }
        }
    }

    override func handleToolbarAction(_ action: ToolbarButtonAction, mousePoint: NSPoint = .zero) {
        if currentTool == .stitch {
            switch action {
            case .beautify, .beautifyStyle, .effects, .invertColors, .removeBackground, .translate, .autoRedact:
                currentTool = .select
            default: break
            }
        }
        super.handleToolbarAction(action, mousePoint: mousePoint)
    }

    func refreshStitchOptions() {
        guard currentTool == .stitch else { return }
        rebuildToolbarLayout()
    }

    override func pasteImageFromClipboard() -> Bool {
        guard currentTool == .stitch, let onStitchImages else { return super.pasteImageFromClipboard() }
        guard let image = NSImage(pasteboard: .general), image.size.width > 0, image.size.height > 0 else { return false }
        onStitchImages([image])
        return true
    }

    private(set) var stitchDocument: StitchDocument? {
        didSet { cachedSavedStitchDocument = nil }
    }
    private var cachedSavedStitchDocument: SavedStitchDocument?
    private var savedStitchImages: [(image: CGImage, data: Data)] = []
    var savedStitchDocument: SavedStitchDocument? {
        if let cachedSavedStitchDocument { return cachedSavedStitchDocument }
        guard let stitchDocument else { return nil }
        let saved = SavedStitchDocument(stitchDocument, imageData: &savedStitchImages)
        cachedSavedStitchDocument = saved
        return saved
    }
    var onStitchDocumentChanged: (() -> Void)?
    private(set) var stitchChangeFailureMessage: String?
    private var installingStitchImage = false

    override var screenshotImage: NSImage? {
        didSet {
            guard !installingStitchImage else { return }
            stitchDocument = nil
            previewStitchSeamColor(nil)
            onStitchDocumentChanged?()
        }
    }

    /// History already supplies the correct raw composite; restore its editable
    /// pieces without replacing that image or adding an undo entry.
    func installStitchDocument(_ document: StitchDocument) {
        guard document.canRender else { return }
        stitchDocument = document
        updateAnnotationSourceImages(annotations)
        onStitchDocumentChanged?()
    }

    func checkpointStitchDocument() {
        undoStack.append(.stitchDocument(stitchSnapshot()))
        redoStack.removeAll()
    }

    @discardableResult
    func applyStitchDocument(_ next: StitchDocument, registerUndo: Bool = true) -> Bool {
        stitchChangeFailureMessage = nil
        if let current = stitchDocument, current.isIdentical(to: next) { return true }
        guard next.canRender, let rendered = StitchRenderer.render(next) else { return false }
        let previous = stitchDocument
        let scale: CGFloat = screenshotImage.flatMap { image in
            image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { CGFloat($0.width) / image.size.width }
        } ?? 1
        guard scale.isFinite, scale > 0 else { return false }
        let changes: [StitchAnnotationTransforms.Change]
        if let previous {
            guard let prepared = StitchAnnotationTransforms.prepare(annotations, from: previous, to: next,
                scale: scale, sourceImage: screenshotImage, sourceBounds: captureDrawRect) else {
                stitchChangeFailureMessage = L("Unable to preserve these redactions. Move or resize them and try again.")
                return false
            }
            changes = prepared
        } else { changes = annotations.map { ($0, $0.clone()) } }
        if registerUndo { checkpointStitchDocument() }
        for change in changes { change.object.copyProperties(from: change.properties) }
        annotations = changes.map(\.object)
        installingStitchImage = true
        screenshotImage = NSImage(cgImage: rendered,
            size: NSSize(width: CGFloat(rendered.width) / scale, height: CGFloat(rendered.height) / scale))
        installingStitchImage = false
        stitchDocument = next
        applySelection(NSRect(origin: .zero, size: screenshotImage!.size))
        frame.size = selectionRect.size
        updateAnnotationSourceImages(annotations)
        // Reassigning invalidates the annotation layer after moving in place.
        annotations = Array(annotations)
        cachedCompositedImage = nil
        needsDisplay = true
        onContentChanged?()
        onStitchDocumentChanged?()
        return true
    }

    func stitchSnapshot() -> StitchEditorSnapshot {
        StitchEditorSnapshot(image: screenshotImage, document: stitchDocument,
            annotations: annotations.map { ($0, $0.clone()) }, numberCounter: numberCounter)
    }

    func restoreStitchSnapshot(_ snapshot: StitchEditorSnapshot) {
        installingStitchImage = true
        screenshotImage = snapshot.image
        installingStitchImage = false
        stitchDocument = snapshot.document
        previewStitchSeamColor(nil)
        for saved in snapshot.annotations { saved.object.copyProperties(from: saved.properties) }
        annotations = snapshot.annotations.map(\.object)
        numberCounter = snapshot.numberCounter
        clearStitchAnnotationSelection()
        if let image = snapshot.image {
            applySelection(NSRect(origin: .zero, size: image.size))
            frame.size = image.size
        }
        updateAnnotationSourceImages(annotations)
        cachedCompositedImage = nil
        needsDisplay = true
        onStitchDocumentChanged?()
    }

    /// Transparent annotation pixels for Stitch's canvas, using the same source
    /// scale as its composite rather than the display's backing scale.
    func stitchAnnotationPreview() -> CGImage? {
        guard let document = stitchDocument else { return nil }
        return renderStitchAnnotations(annotations, rect: CGRect(origin: .zero, size: selectionRect.size),
            pixels: document.bounds.size, includeHighlightDim: true)
    }

    private func stitchAnnotationOwner(_ annotation: Annotation, document: StitchDocument, scale: CGFloat) -> UUID? {
        if let id = annotation.stitchAttachment?.pieceID, document.pieces.contains(where: { $0.id == id }) { return id }
        let r = annotation.boundingRect
        let center = CGPoint(x: document.bounds.minX + r.midX * scale,
            y: document.bounds.maxY - r.midY * scale)
        return document.pieces.reversed().first(where: { $0.frame.contains(center) })?.id
    }

    func stitchAnnotationLayers() -> [UUID: StitchAnnotationLayer] {
        guard let document = stitchDocument, let screenshotImage else { return [:] }
        let scale = document.bounds.width / screenshotImage.size.width
        guard scale.isFinite, scale > 0 else { return [:] }
        var grouped: [UUID: [Annotation]] = [:]
        for annotation in annotations {
            if annotation.isStitchRedaction {
                let attached = document.pieces.filter { $0.id == annotation.stitchAttachment?.pieceID }
                let pieces = attached.isEmpty ? document.pieces : attached
                let coverage = annotation.stitchPixelCoverage(in: document.bounds, scale: scale)
                for piece in pieces {
                    let retained = coverage.intersection(piece.frame)
                    guard !retained.isNull, retained.width > 0, retained.height > 0 else { continue }
                    let clip = CGRect(x: (retained.minX - document.bounds.minX) / scale,
                        y: (document.bounds.maxY - retained.maxY) / scale,
                        width: retained.width / scale, height: retained.height / scale)
                    let fragment = annotation.clone()
                    fragment.stitchAttachment = StitchAnnotationAttachment(pieceID: piece.id,
                        lineageID: piece.lineageID, clipRect: clip)
                    grouped[piece.id, default: []].append(fragment)
                }
            } else if let owner = stitchAnnotationOwner(annotation, document: document, scale: scale) {
                grouped[owner, default: []].append(annotation)
            }
        }
        var result: [UUID: StitchAnnotationLayer] = [:]
        for piece in document.pieces {
            guard let owned = grouped[piece.id], !owned.isEmpty else { continue }
            var extent = piece.frame
            for annotation in owned {
                let padding = annotation.isStitchRedaction ? 0 : max(12, annotation.strokeWidth * 4)
                var r = (annotation.isStitchRedaction ? annotation.stitchVisibleBounds : annotation.boundingRect)
                    .insetBy(dx: -padding, dy: -padding)
                if !annotation.textDrawRect.isEmpty { r = r.union(annotation.textDrawRect) }
                // Rotation may put corners outside the unrotated bounding box.
                if annotation.rotation != 0 && !annotation.isStitchRedaction {
                    let radius = hypot(r.width, r.height) / 2
                    r = CGRect(x: r.midX - radius, y: r.midY - radius, width: radius * 2, height: radius * 2)
                }
                extent = extent.union(CGRect(x: document.bounds.minX + r.minX * scale,
                    y: document.bounds.maxY - r.maxY * scale, width: r.width * scale, height: r.height * scale))
            }
            extent = extent.integral
            if !extent.width.isFinite || !extent.height.isFinite
                || extent.width > StitchDocument.maximumDimension || extent.height > StitchDocument.maximumDimension
                || extent.width * extent.height > StitchDocument.maximumPixels {
                // Large ordinary marks must not remove masks from the moving
                // capture. Its own frame always fits the document's budget.
                extent = piece.frame.integral
            }
            let rect = CGRect(x: (extent.minX - document.bounds.minX) / scale,
                y: (document.bounds.maxY - extent.maxY) / scale,
                width: extent.width / scale, height: extent.height / scale)
            if let image = renderStitchAnnotations(owned, rect: rect, pixels: extent.size, includeHighlightDim: false) {
                result[piece.id] = StitchAnnotationLayer(image: image, frame: extent)
            } else if owned.contains(where: \.isStitchRedaction) {
                result[piece.id] = StitchAnnotationLayer(image: nil, frame: piece.frame)
            }
        }
        return result
    }

    func stitchUnattachedAnnotationPreview() -> CGImage? {
        guard let document = stitchDocument, let screenshotImage else { return nil }
        let scale = document.bounds.width / screenshotImage.size.width
        guard scale.isFinite, scale > 0 else { return nil }
        let unattached = annotations.filter { annotation in
            if annotation.isStitchRedaction {
                let covered = annotation.stitchPixelCoverage(in: document.bounds, scale: scale)
                return !document.pieces.contains { piece in
                    let intersection = piece.frame.intersection(covered)
                    return !intersection.isNull && intersection.width > 0 && intersection.height > 0
                }
            }
            return stitchAnnotationOwner(annotation, document: document, scale: scale) == nil
        }
        return renderStitchAnnotations(unattached, rect: CGRect(origin: .zero, size: selectionRect.size),
            pixels: document.bounds.size, includeHighlightDim: true,
            highlightAnnotations: annotations.filter { $0.tool == .highlight })
    }

    private func renderStitchAnnotations(_ annotations: [Annotation], rect: CGRect,
        pixels: CGSize, includeHighlightDim: Bool, highlightAnnotations: [Annotation]? = nil) -> CGImage? {
        guard (!annotations.isEmpty || !(highlightAnnotations?.isEmpty ?? true)),
            pixels.width > 0, pixels.height > 0,
            pixels.width <= StitchDocument.maximumDimension, pixels.height <= StitchDocument.maximumDimension,
            pixels.width * pixels.height <= StitchDocument.maximumPixels,
            let context = CGContext(data: nil, width: Int(ceil(pixels.width)), height: Int(ceil(pixels.height)),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: pixels.width / rect.width, y: pixels.height / rect.height)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for annotation in annotations where annotation.tool == .pixelate { annotation.draw(in: graphics) }
        if includeHighlightDim { Annotation.drawHighlightDim(for: highlightAnnotations ?? annotations, in: selectionRect) }
        for annotation in annotations where annotation.tool != .pixelate { annotation.draw(in: graphics) }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    @objc func undo(_ sender: Any?) { undo() }
    @objc func redo(_ sender: Any?) { redo() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return !undoStack.isEmpty
        case #selector(redo(_:)): return !redoStack.isEmpty
        default: return true
        }
    }

    override var isEditorMode: Bool { true }
    override var isInsideScrollView: Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Ensure the view redraws fully on magnification changes instead of
        // scaling the stale layer contents (which causes blurry regions).
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    // MARK: - Background drawing (simple — NSScrollView handles centering/zoom)

    override func drawEditorBackground(context: NSGraphicsContext) {
        // NSScrollView.backgroundColor handles the dark background.
        // CenteringClipView handles centering. Magnification handles zoom.
        guard !beautifyEnabled else { return }

        // Fast path: if we have a cached composite (screenshot + all committed annotations)
        // and nothing is actively being drawn, draw the single cached image.
        // This avoids re-rendering the screenshot + iterating all annotations every frame.
        if !isActivelyDrawing, let cached = cachedCompositedImage {
            cached.draw(in: selectionRect, from: .zero, operation: .copy, fraction: 1.0)
            drewFromCompositeCache = true
            return
        }

        drewFromCompositeCache = false
        if let image = screenshotImage {
            image.draw(in: selectionRect, from: .zero, operation: .copy, fraction: 1.0)
        }
    }

    /// Set during drawEditorBackground to signal the base draw() to skip annotation loops.
    var drewFromCompositeCache: Bool = false

    // MARK: - Selection chrome (disabled in editor)

    override func shouldClipSelectionImage() -> Bool { false }
    override func shouldDrawSelectionBorder() -> Bool { false }
    override func shouldShowResolutionBox() -> Bool { false }

    // MARK: - Coordinate transforms (identity — scroll view handles everything)

    override func adjustPointForEditor(_ p: NSPoint) -> NSPoint { p }
    override func applyEditorTransform(to context: NSGraphicsContext) {}

    // MARK: - Cursor (arrow outside image, tool cursor inside)

    override func resetCursorRects() {
        // Arrow cursor for the full document view; updateCursorForPoint overrides
        // this with the tool cursor only when the mouse is over the image area.
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if selectionRect.contains(point) {
            super.mouseMoved(with: event)
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Selection interaction (disabled in editor)

    override func shouldAllowSelectionResize() -> Bool { false }
    override func shouldAllowNewSelection() -> Bool { false }
    override func shouldAllowDetach() -> Bool { false }

    // MARK: - Zoom (handled by NSScrollView magnification, not OverlayView)

    // MARK: - Export

    override var captureDrawRect: NSRect { selectionRect }

    // Top bar is handled by EditorTopBarView (real NSView in the container)
}
