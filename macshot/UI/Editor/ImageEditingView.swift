import Cocoa

/// Shared image edits for the capture overlay and the window editor.
struct StitchEditorSnapshot {
    let image: NSImage?
    let document: StitchDocument?
    let annotations: [(object: Annotation, properties: Annotation)]
    let numberCounter: Int
    let selectionRect: NSRect
    let captureBackdrop: NSImage?
}

struct StitchAnnotationLayer {
    /// A missing raster requires an opaque piece placeholder during movement.
    let image: CGImage?
    /// Global top-down document pixels, including marks crossing piece edges.
    let frame: CGRect
}

class ImageEditingView: OverlayView, NSMenuItemValidation {
    override var toolbarColor: NSColor {
        guard currentTool == .stitch, let style = stitchDocument?.style else { return currentColor }
        return style.visible && style.transition.hasEditableColor ? stitchSeamColorPreview ?? style.color : style.color
    }

    private(set) var stitchSeamColorPreview: NSColor?
    var onStitchSeamColorPreview: ((NSColor?) -> Void)?

    func previewStitchSeamColor(_ color: NSColor?) {
        if color != nil {
            guard let style = stitchDocument?.style, style.visible, style.transition.hasEditableColor else { return }
        }
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
    /// Editing uses the source geometry; Preview shows the paper used by every output action.
    var stitchPreviewEnabled = false {
        didSet {
            guard stitchPreviewEnabled != oldValue else { return }
            onStitchPreviewChanged?()
            refreshStitchOptions()
        }
    }
    var onStitchPreviewChanged: (() -> Void)?
    var isShowingStitchPaperPreview: Bool {
        currentTool == .stitch && stitchPreviewEnabled && canPreviewStitchPaper
    }
    var canPreviewStitchPaper: Bool {
        guard let document = stitchDocument else { return false }
        return document.style.visible && document.style.transition == .accordion
            && document.style.accordionWidth > 0 && !document.joins.isEmpty
    }
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
        didSet {
            cachedSavedStitchDocument = nil
            renderedFoldProtection = nil
            if stitchDocument?.style.visible != true || stitchDocument?.style.transition.hasEditableColor != true {
                previewStitchSeamColor(nil)
            }
        }
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
    private(set) var stitchCaptureBackdrop: NSImage?
    private(set) var stitchCaptureSelectionRect: NSRect?

    override var overlayBackgroundImage: NSImage? { stitchCaptureBackdrop ?? screenshotImage }
    override var captureDrawRect: NSRect { stitchCaptureBackdrop == nil ? super.captureDrawRect : selectionRect }
    override func shouldAllowSelectionResize() -> Bool { stitchCaptureBackdrop == nil && stitchDocument == nil && super.shouldAllowSelectionResize() }
    override func shouldAllowNewSelection() -> Bool { stitchCaptureBackdrop == nil && stitchDocument == nil && super.shouldAllowNewSelection() }

    override func applySelection(_ rect: NSRect) {
        guard isEditorMode || stitchCaptureBackdrop == nil else { return }
        super.applySelection(rect)
    }

    /// Document operations use local image points; overlay marks remain in screen points.
    var localStitchAnnotations: [Annotation] {
        annotations.map { annotation in
            let copy = annotation.clone()
            copy.moveWithSource(dx: -selectionRect.minX, dy: -selectionRect.minY)
            copy.sourceImageBounds = copy.sourceImageBounds.offsetBy(dx: -selectionRect.minX, dy: -selectionRect.minY)
            return copy
        }
    }

    @discardableResult
    func beginStitchEditing(rawImage: NSImage? = nil) -> Bool {
        if stitchDocument != nil { return true }
        guard state == .selected, !selectionRect.isEmpty, !isRecording, !selectionOnlyMode,
              let image = rawImage ?? (isEditorMode ? screenshotImage : captureSelectedRegionRaw()),
              let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let document = StitchDocument(pieces: [StitchPiece(image: pixels)])
        guard document.canRender else { return false }
        if !isEditorMode && stitchCaptureBackdrop == nil {
            stitchCaptureBackdrop = screenshotImage
            stitchCaptureSelectionRect = selectionRect
            installingStitchImage = true
            screenshotImage = image
            installingStitchImage = false
            selectionIsWindowSnap = false
            snappedWindowID = nil
            snappedWindowImage = nil
            updateAnnotationSourceImages(annotations)
        }
        installStitchDocument(document)
        return true
    }
    private var renderedFoldProtection: [CGRect]?

    /// Annotation geometry can change without a Stitch edit. Keep preview,
    /// export, and editable history on the same guarded source pixels.
    @discardableResult
    func refreshFoldProtection() -> Bool {
        guard let document = stitchDocument, document.style.visible,
              document.style.transition == .fold, document.style.foldDepth > 0,
              document.style.foldStrength > 0 else { return true }
        guard let image = screenshotImage,
              let pixels = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        let scale = CGFloat(pixels.width) / image.size.width
        guard scale.isFinite, scale > 0 else { return false }
        let protection = StitchAnnotationTransforms.protectedRegions(localStitchAnnotations, in: document, scale: scale)
        guard protection != renderedFoldProtection else { return true }
        guard let rendered = StitchRenderer.render(document, protectedRegions: protection),
              rendered.width == pixels.width, rendered.height == pixels.height else { return false }
        installingStitchImage = true
        screenshotImage = NSImage(cgImage: rendered, size: image.size)
        installingStitchImage = false
        renderedFoldProtection = protection
        for annotation in annotations where annotation.tool == .loupe { annotation.bakedBlurNSImage = nil }
        updateAnnotationSourceImages(annotations)
        annotations = Array(annotations)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if !isManipulatingAnnotation { refreshFoldProtection() }
        super.draw(dirtyRect)
    }

    override func captureSelectedRegion() -> NSImage? {
        guard refreshFoldProtection() else { return nil }
        return super.captureSelectedRegion()
    }

    override func captureSelectedRegionRaw() -> NSImage? {
        guard refreshFoldProtection() else { return nil }
        return super.captureSelectedRegionRaw()
    }

    override var screenshotImage: NSImage? {
        didSet {
            guard !installingStitchImage else { return }
            // Effects can flatten the pieces while the source remains a crop
            // positioned inside the fullscreen capture. Keep its geometry.
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
        guard next.canRender else { return false }
        let previous = stitchDocument
        let scale: CGFloat = screenshotImage.flatMap { image in
            image.cgImage(forProposedRect: nil, context: nil, hints: nil).map { CGFloat($0.width) / image.size.width }
        } ?? 1
        guard scale.isFinite, scale > 0 else { return false }
        let localAnnotations = localStitchAnnotations
        let originalObjects = Dictionary(uniqueKeysWithValues: zip(localAnnotations, annotations).map { (ObjectIdentifier($0.0), $0.1) })
        let localChanges: [StitchAnnotationTransforms.Change]
        if let previous {
            guard let prepared = StitchAnnotationTransforms.prepare(localAnnotations, from: previous, to: next,
                scale: scale, sourceImage: screenshotImage, sourceBounds: CGRect(origin: .zero, size: captureDrawRect.size)) else {
                stitchChangeFailureMessage = L("Unable to preserve these redactions. Move or resize them and try again.")
                return false
            }
            localChanges = prepared
        } else { localChanges = localAnnotations.map { ($0, $0.clone()) } }
        let protection = StitchAnnotationTransforms.protectedRegions(localChanges.map(\.properties), in: next, scale: scale)
        guard let rendered = StitchRenderer.render(next, protectedRegions: protection) else { return false }
        if registerUndo { checkpointStitchDocument() }
        let size = NSSize(width: CGFloat(rendered.width) / scale, height: CGFloat(rendered.height) / scale)
        let origin = isEditorMode ? NSPoint.zero : NSPoint(x: selectionRect.minX, y: selectionRect.maxY - size.height)
        let changes = localChanges.map { change -> StitchAnnotationTransforms.Change in
            change.properties.moveWithSource(dx: origin.x, dy: origin.y)
            return (originalObjects[ObjectIdentifier(change.object)] ?? change.object, change.properties)
        }
        for change in changes { change.object.copyProperties(from: change.properties) }
        annotations = changes.map(\.object)
        installingStitchImage = true
        screenshotImage = NSImage(cgImage: rendered,
            size: NSSize(width: CGFloat(rendered.width) / scale, height: CGFloat(rendered.height) / scale))
        installingStitchImage = false
        stitchDocument = next
        renderedFoldProtection = protection
        super.applySelection(NSRect(origin: origin, size: size))
        if isInsideScrollView { frame.size = selectionRect.size }
        for annotation in annotations where annotation.tool == .loupe { annotation.bakedBlurNSImage = nil }
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
        refreshFoldProtection()
        return StitchEditorSnapshot(image: screenshotImage, document: stitchDocument,
            annotations: annotations.map { ($0, $0.clone()) }, numberCounter: numberCounter,
            selectionRect: selectionRect, captureBackdrop: stitchCaptureBackdrop)
    }

    func restoreStitchSnapshot(_ snapshot: StitchEditorSnapshot) {
        stitchCaptureBackdrop = snapshot.captureBackdrop
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
            super.applySelection(snapshot.selectionRect)
            if isInsideScrollView { frame.size = image.size }
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
        return renderStitchAnnotations(localStitchAnnotations, rect: CGRect(origin: .zero, size: selectionRect.size),
            pixels: document.bounds.integral.size, includeHighlightDim: true)
    }

    private func stitchAnnotationOwner(_ annotation: Annotation, document: StitchDocument, scale: CGFloat) -> UUID? {
        if let id = annotation.stitchAttachment?.pieceID, document.pieces.contains(where: { $0.id == id }) { return id }
        let r = annotation.boundingRect
        let rasterBounds = document.bounds.integral
        let center = CGPoint(x: rasterBounds.minX + r.midX * scale,
            y: rasterBounds.maxY - r.midY * scale)
        return document.pieces.reversed().first(where: { $0.frame.contains(center) })?.id
    }

    func stitchAnnotationLayers() -> [UUID: StitchAnnotationLayer] {
        guard let document = stitchDocument, let screenshotImage else { return [:] }
        let rasterBounds = document.bounds.integral
        let scale = rasterBounds.width / screenshotImage.size.width
        guard scale.isFinite, scale > 0 else { return [:] }
        var grouped: [UUID: [Annotation]] = [:]
        for annotation in localStitchAnnotations {
            if annotation.isStitchRedaction {
                let attached = document.pieces.filter { $0.id == annotation.stitchAttachment?.pieceID }
                let pieces = attached.isEmpty ? document.pieces : attached
                let coverage = annotation.stitchPixelCoverage(in: rasterBounds, scale: scale)
                for piece in pieces {
                    let retained = coverage.intersection(piece.frame)
                    guard !retained.isNull, retained.width > 0, retained.height > 0 else { continue }
                    let clip = CGRect(x: (retained.minX - rasterBounds.minX) / scale,
                        y: (rasterBounds.maxY - retained.maxY) / scale,
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
                extent = extent.union(CGRect(x: rasterBounds.minX + r.minX * scale,
                    y: rasterBounds.maxY - r.maxY * scale, width: r.width * scale, height: r.height * scale))
            }
            extent = extent.integral
            if !extent.width.isFinite || !extent.height.isFinite
                || extent.width > StitchDocument.maximumDimension || extent.height > StitchDocument.maximumDimension
                || extent.width * extent.height > StitchDocument.maximumPixels {
                // Large ordinary marks must not remove masks from the moving
                // capture. Its own frame always fits the document's budget.
                extent = piece.frame.integral
            }
            let rect = CGRect(x: (extent.minX - rasterBounds.minX) / scale,
                y: (rasterBounds.maxY - extent.maxY) / scale,
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
        let rasterBounds = document.bounds.integral
        let scale = rasterBounds.width / screenshotImage.size.width
        guard scale.isFinite, scale > 0 else { return nil }
        let localAnnotations = localStitchAnnotations
        let unattached = localAnnotations.filter { annotation in
            if annotation.isStitchRedaction {
                let covered = annotation.stitchPixelCoverage(in: rasterBounds, scale: scale)
                return !document.pieces.contains { piece in
                    let intersection = piece.frame.intersection(covered)
                    return !intersection.isNull && intersection.width > 0 && intersection.height > 0
                }
            }
            return stitchAnnotationOwner(annotation, document: document, scale: scale) == nil
        }
        return renderStitchAnnotations(unattached, rect: CGRect(origin: .zero, size: selectionRect.size),
            pixels: rasterBounds.size, includeHighlightDim: true,
            highlightAnnotations: localAnnotations.filter { $0.tool == .highlight })
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
        if includeHighlightDim { Annotation.drawHighlightDim(for: highlightAnnotations ?? annotations, in: CGRect(origin: .zero, size: selectionRect.size)) }
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

    /// Background clicks arrive here or at the clip view instead of the inline canvas.
    /// Keep the window event unchanged so the canvas performs its own pixel conversion.
    @discardableResult
    func handleStitchMoveMouseDown(with event: NSEvent) -> Bool {
        guard currentTool == .stitch,
              let canvas = subviews.compactMap({ $0 as? StitchCanvasView }).first(where: {
                  !$0.isHidden && $0.mode == .move
              }) else { return false }
        canvas.mouseDown(with: event)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if handleStitchMoveMouseDown(with: event) { return }
        super.mouseDown(with: event)
    }


    override func clearSelection() {
        guard let backdrop = stitchCaptureBackdrop else {
            super.clearSelection()
            return
        }
        // Another monitor now owns the selection. Abandon the edited crop
        // and return this overlay to its original frozen desktop.
        reset()
        screenshotImage = backdrop
        captureSourceImage = backdrop
        onStitchDocumentChanged?()
    }

    override func reset() {
        onStitchToolChanged?(false)
        stitchPreviewEnabled = false
        stitchDocument = nil
        stitchCaptureBackdrop = nil
        stitchCaptureSelectionRect = nil
        savedStitchImages.removeAll()
        super.reset()
    }
}
