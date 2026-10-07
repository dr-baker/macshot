import AppKit

@MainActor
final class StitchCanvasView: NSView, NSMenuItemValidation {
    enum Mode: Int { case removeSpace, move }
    var document = StitchDocument()
    weak var inlineEditor: ImageEditingView? {
        didSet {
            setAccessibilityLabel(L(inlineEditor == nil ? "Stitch canvas" : "Stitch editing canvas"))
            setAccessibilityHelp(L(inlineEditor == nil
                ? "Drag up or down to remove rows, or left or right to remove columns. Choose Move to arrange pieces. Hold Option to ignore snapping."
                : "Drag up or down to remove rows, or left or right to remove columns. Choose Move to arrange pieces. Hold Option to ignore snapping. Other tool shortcuts use the image editor."))
            syncInlineGeometry()
        }
    }
    /// Packed placement is committed by the owner on drop; dragging stays a local preview.
    var packed = false {
        didSet { if oldValue != packed { cancelGesture() } }
    }
    var mode = Mode.removeSpace {
        didSet {
            if oldValue != mode { cancelCollapseAnimation(); cancelGesture() }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var selectedID: UUID? { didSet { needsDisplay = true } }
    var packedPreview: StitchDocument? { didSet { needsDisplay = true } }
    var packedDropFrame: CGRect? {
        guard packed, moving, let selectedID else { return nil }
        return packedPreview?.pieces.first(where: { $0.id == selectedID })?.frame
    }
    var preview: CGImage?
    var backgroundPreview: CGImage? { didSet { needsDisplay = true } }
    var onSelect: ((UUID?) -> Void)?
    var onCut: ((StitchAxis, CGFloat, CGFloat) -> Void)?
    var onMove: ((UUID, CGPoint, Bool) -> Void)?
    var onCancelMove: (() -> Void)?
    var onDelete: (() -> Void)?
    var onImages: (([NSImage]) -> Void)?
    var annotationLayers: [UUID: StitchAnnotationLayer] = [:] { didSet { needsDisplay = true } }
    var annotationPreview: CGImage? { didSet { needsDisplay = true } }
    var unattachedAnnotationPreview: CGImage? { didSet { needsDisplay = true } }
    var canUndo: (() -> Bool)?
    var canRedo: (() -> Bool)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    var onMode: ((Mode) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onFit: (() -> Void)?
    var bandGuideRows: [CGFloat] = [] { didSet { refreshBandSnapping(); needsDisplay = true } }
    var bandGuideColumns: [CGFloat] = [] { didSet { refreshBandSnapping(); needsDisplay = true } }
    private(set) var bandAxis: StitchAxis?
    private(set) var bandGuideMatches: [CGFloat] = []
    private(set) var bandHoverRow: CGFloat?
    private(set) var bandHoverColumn: CGFloat?
    private var gestureBandGuides: StitchBandGuides.Result?
    private var bandStartInWindow: CGPoint?
    private var bandEndInWindow: CGPoint?
    /// Direction must be deliberate in screen points, independent of image scale and zoom.
    private static let bandDragThreshold: CGFloat = 4
    private static let bandDirectionMargin: CGFloat = 2
    private var rawBandStart: CGPoint?
    private var rawBandEnd: CGPoint?
    private var rawBandHover: CGPoint?
    private var bandHoverInWindow: CGPoint?
    var showsBandGuides: Bool {
        mode == .removeSpace && document.canRender && (rawBandStart != nil || rawBandHover != nil)
    }
    private var bandSnapBypassed = false
    private var inset: CGFloat { inlineEditor == nil ? 80 : 0 }
    private var effectiveZoom: CGFloat {
        let projection = inlineEditor != nil && bounds.width > 0 ? frame.width / bounds.width : 1
        return max(0.0001, (enclosingScrollView?.magnification ?? 1) * projection)
    }
    private var start: CGPoint?
    private var end: CGPoint?
    private var originalOrigin: CGPoint?
    private var dragBounds: CGRect?
    private var moving = false
    private var dragPreviewOrigin: CGPoint?
    private var hoverTracking: NSTrackingArea?
    private var collapseAnimation: StitchAccordionCollapseView?
    private(set) var hoveredID: UUID?
    struct AlignmentGuide: Equatable {
        let start: CGPoint
        let end: CGPoint
    }
    private(set) var alignmentGuides: [AlignmentGuide] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var contentBounds: CGRect { (dragBounds ?? document.bounds).integral }
    private var imageRect: CGRect { CGRect(x: inset, y: inset, width: contentBounds.width, height: contentBounds.height) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .tiff, .png])
        setAccessibilityLabel(L("Stitch canvas"))
        setAccessibilityHelp(L("Drag up or down to remove rows, or left or right to remove columns. Choose Move to arrange pieces. Hold Option to ignore snapping."))
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh(_ value: StitchDocument, preview: CGImage?) {
        if !document.isIdentical(to: value) { cancelCollapseAnimation() }
        document = value
        if !value.pieces.contains(where: { $0.id == hoveredID }) { hoveredID = nil }
        self.preview = preview
        if dragBounds == nil, value.canRender {
            if inlineEditor != nil { syncInlineGeometry() }
            else { setFrameSize(NSSize(width: value.bounds.width + inset * 2, height: value.bounds.height + inset * 2)) }
        }
        if let bandHoverInWindow { updateBandHover(at: bandHoverInWindow) }
        else { refreshBandSnapping() }
        needsDisplay = true
    }
    /// The editor owns point geometry; this child retains source-pixel coordinates.
    func syncInlineGeometry() {
        guard let inlineEditor, document.canRender else { return }
        frame = inlineEditor.selectionRect
        bounds = CGRect(origin: .zero, size: contentBounds.size)
        if let bandHoverInWindow { updateBandHover(at: bandHoverInWindow) }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        canvasPoint(at: event.locationInWindow)
    }
    private func canvasPoint(at locationInWindow: CGPoint) -> CGPoint {
        let p = convert(locationInWindow, from: nil)
        return CGPoint(x: p.x - inset + contentBounds.minX, y: p.y - inset + contentBounds.minY)
    }
    private func viewRect(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: inset - contentBounds.minX, dy: inset - contentBounds.minY)
    }
    private func displayedFrame(_ piece: StitchPiece) -> CGRect {
        if moving, piece.id == selectedID, let dragPreviewOrigin {
            return CGRect(origin: dragPreviewOrigin, size: piece.frame.size)
        }
        return piece.frame
    }
    private func isOverCapturedContent(_ point: CGPoint) -> Bool {
        document.pieces.contains { $0.frame.contains(point) }
    }
    private func isUnobstructedCanvasPoint(at locationInWindow: CGPoint) -> Bool {
        guard let contentView = window?.contentView else { return true }
        let point = contentView.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
        return contentView.hitTest(point) === self
    }
    private func updateBandHover(at locationInWindow: CGPoint) {
        let point = canvasPoint(at: locationInWindow)
        let isOverImage = isOverCapturedContent(point) && isUnobstructedCanvasPoint(at: locationInWindow)
        rawBandHover = isOverImage ? point : nil
        bandHoverInWindow = isOverImage ? locationInWindow : nil
        refreshBandSnapping()
    }
    private func clearBandHover() {
        rawBandHover = nil; bandHoverInWindow = nil; bandHoverRow = nil; bandHoverColumn = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.15, alpha: 1).setFill()
        bounds.fill()
        guard document.canRender else { return }
        let zoom = effectiveZoom
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: 4)
        shadow.set()
        let fill = document.background.fillColor
        let transparent = (fill?.alphaComponent ?? 1) < 1
        ToolbarLayout.bgColor.setFill()
        imageRect.fill()
        NSGraphicsContext.restoreGraphicsState()
        if transparent {
            let tile: CGFloat = 12 / zoom
            let region = imageRect.intersection(visibleRect)
            if !region.isNull {
                NSGraphicsContext.saveGraphicsState()
                imageRect.clip()
                for row in Int(floor(region.minY / tile))...Int(ceil(region.maxY / tile)) {
                    for column in Int(floor(region.minX / tile))...Int(ceil(region.maxX / tile)) {
                        NSColor(white: (row + column) % 2 == 0 ? 0.24 : 0.28, alpha: 1).setFill()
                        CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile).fill()
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if (moving || preview == nil), let backgroundPreview {
            NSImage(cgImage: backgroundPreview, size: imageRect.size).draw(in: imageRect, from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if !moving, let preview {
            NSImage(cgImage: preview, size: imageRect.size).draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let displayedPieces = packed && moving ? (packedPreview?.pieces ?? document.pieces) : document.pieces
            let pieces = moving
                ? displayedPieces.filter { $0.id != selectedID } + displayedPieces.filter { $0.id == selectedID }
                : displayedPieces
            for piece in pieces {
                // Draw the destination beneath the lifted piece so the pointer preview stays legible.
                if piece.id == selectedID, let slot = packedDropFrame {
                    let path = NSBezierPath(rect: viewRect(slot).insetBy(dx: 1 / zoom, dy: 1 / zoom))
                    ToolbarLayout.accentColor.withAlphaComponent(0.12).setFill()
                    path.fill()
                    ToolbarLayout.accentColor.withAlphaComponent(0.9).setStroke()
                    path.lineWidth = 2 / zoom
                    path.setLineDash([6 / zoom, 4 / zoom], count: 2, phase: 0)
                    path.stroke()
                }
                guard let crop = piece.image.cropping(to: piece.source) else { continue }
                NSGraphicsContext.saveGraphicsState()
                if moving, piece.id == selectedID {
                    let lift = NSShadow()
                    lift.shadowColor = NSColor.black.withAlphaComponent(0.3)
                    lift.shadowBlurRadius = 10 / zoom
                    lift.shadowOffset = NSSize(width: 0, height: 3 / zoom)
                    lift.set()
                }
                NSImage(cgImage: crop, size: piece.frame.size).draw(in: viewRect(displayedFrame(piece)), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        if moving {
            if let unattachedAnnotationPreview {
                NSImage(cgImage: unattachedAnnotationPreview, size: contentBounds.size).draw(in: imageRect,
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let placed = packedPreview?.pieces ?? document.pieces
            for piece in placed {
                guard let layer = annotationLayers[piece.id],
                      let original = document.pieces.first(where: { $0.id == piece.id }) else { continue }
                let delta = displayedFrame(piece).origin
                let rect = layer.frame.offsetBy(dx: delta.x - original.origin.x, dy: delta.y - original.origin.y)
                if let image = layer.image {
                    NSImage(cgImage: image, size: layer.frame.size).draw(in: viewRect(rect),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                } else {
                    NSColor.black.setFill()
                    NSBezierPath(rect: viewRect(displayedFrame(piece))).fill()
                }
            }
        }
        if !moving, let annotationPreview {
            NSImage(cgImage: annotationPreview, size: contentBounds.size).draw(in: imageRect, from: .zero,
                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        drawBandGuides(zoom: zoom)
        if mode == .move, !moving, let hoveredID, hoveredID != selectedID,
           let piece = document.pieces.first(where: { $0.id == hoveredID }) {
            ToolbarLayout.accentColor.withAlphaComponent(0.55).setStroke()
            let outline = NSBezierPath(rect: viewRect(piece.frame).insetBy(dx: -0.5 / zoom, dy: -0.5 / zoom))
            outline.lineWidth = 1 / zoom
            outline.stroke()
        }
        ToolbarLayout.accentColor.withAlphaComponent(0.8).setStroke()
        for guide in alignmentGuides {
            let path = NSBezierPath()
            path.move(to: viewRect(CGRect(origin: guide.start, size: .zero)).origin)
            path.line(to: viewRect(CGRect(origin: guide.end, size: .zero)).origin)
            path.lineWidth = 1 / zoom
            path.setLineDash([4 / zoom, 3 / zoom], count: 2, phase: 0)
            path.stroke()
        }
        if let piece = document.pieces.first(where: { $0.id == selectedID }), mode == .move {
            ToolbarLayout.accentColor.setStroke()
            let path = NSBezierPath(rect: viewRect(displayedFrame(piece)).insetBy(dx: -1 / zoom, dy: -1 / zoom))
            path.lineWidth = 2 / zoom
            path.stroke()
            // A move handle explains the selection without implying it can resize.
            let frame = viewRect(displayedFrame(piece))
            let handle = NSRect(x: frame.minX + 5 / zoom, y: frame.minY + 5 / zoom,
                                width: 24 / zoom, height: 24 / zoom)
            ToolbarLayout.bgColor.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: handle, xRadius: 5 / zoom, yRadius: 5 / zoom).fill()
            if let icon = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil) {
                let tinted = icon.withSymbolConfiguration(.init(paletteColors: [ToolbarLayout.iconColor])) ?? icon
                tinted.draw(in: handle.insetBy(dx: 5 / zoom, dy: 5 / zoom), from: .zero,
                            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        if let removal, let bandAxis {
            let rect = viewRect(removal.rect).intersection(imageRect)
            guard !rect.isNull, !rect.isEmpty,
                  rect.minX.isFinite, rect.minY.isFinite,
                  rect.width.isFinite, rect.height.isFinite else { return }
            ToolbarLayout.accentColor.withAlphaComponent(0.2).setFill()
            rect.fill()
            ToolbarLayout.accentColor.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1.5 / zoom
            border.stroke()
            let removed = Self.formatRemovalAmount(removal.length)
            let hint = bandCandidates(for: bandAxis).isEmpty ? "" : "\n" + L(bandSnapBypassed ? "Guides ignored" : "⌥ Ignore guides")
            let text = "−\(removed) px\(hint)" as NSString
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13 / zoom, weight: .semibold),
                .foregroundColor: ToolbarLayout.iconColor, .paragraphStyle: paragraph
            ]
            let textSize = text.size(withAttributes: attributes)
            let visibleBand = rect.intersection(visibleRect)
            if !visibleBand.isNull, !visibleBand.isEmpty {
                let pill = Self.cutLabelRect(size: CGSize(width: textSize.width + 20 / zoom, height: textSize.height + 12 / zoom),
                                             band: visibleBand, visible: visibleRect, zoom: zoom)
                ToolbarLayout.bgColor.withAlphaComponent(0.97).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 7 / zoom, yRadius: 7 / zoom).fill()
                ToolbarLayout.accentColor.withAlphaComponent(0.75).setStroke()
                let border = NSBezierPath(roundedRect: pill, xRadius: 7 / zoom, yRadius: 7 / zoom)
                border.lineWidth = 1 / zoom
                border.stroke()
                text.draw(in: CGRect(x: pill.minX + 8 / zoom, y: pill.midY - textSize.height / 2,
                                     width: max(0, pill.width - 16 / zoom), height: textSize.height), withAttributes: attributes)
            }
        }
    }

    func cancelEditingGesture() { cancelCollapseAnimation(); cancelGesture() }

    func prepareAccordionCollapse(axis: StitchAxis, from: CGFloat, to: CGFloat) -> StitchAccordionCollapseView.Snapshot? {
        cancelCollapseAnimation()
        guard inlineEditor != nil, window != nil, document.style.visible, document.style.transition == .accordion,
              document.style.accordionWidth.isFinite, document.style.accordionWidth > 0,
              document.style.accordionPleats.isFinite,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let band = document.removalBand(axis: axis, from: from, to: to),
              let image = collapseTexture() else { return nil }
        return StitchAccordionCollapseView.Snapshot(image: image, frame: frame, documentBounds: contentBounds,
            band: band, axis: axis, style: document.style)
    }

    func animateAccordionCollapse(_ before: StitchAccordionCollapseView.Snapshot?) {
        guard let before, let parent = superview, let after = collapseTexture(),
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = StitchAccordionCollapseView(before: before, afterImage: after, afterFrame: frame)
        collapseAnimation = animation
        parent.addSubview(animation, positioned: .above, relativeTo: self)
        animation.play { [weak self, weak animation] in
            animation?.removeFromSuperview()
            if self?.collapseAnimation === animation { self?.collapseAnimation = nil }
        }
    }

    private func collapseTexture() -> CGImage? {
        guard let editor = inlineEditor, document.canRender,
              editor.annotations.isEmpty || annotationPreview != nil,
              let source = editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, StitchAccordionCollapseView.maximumTextureDimension / max(contentBounds.width, contentBounds.height))
        let width = max(1, Int(ceil(contentBounds.width * scale)))
        let height = max(1, Int(ceil(contentBounds.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.draw(source, in: rect)
        if let annotationPreview { context.draw(annotationPreview, in: rect) }
        return context.makeImage()
    }

    private func cancelCollapseAnimation() {
        collapseAnimation?.layer?.removeAllAnimations()
        collapseAnimation?.removeFromSuperview()
        collapseAnimation = nil
    }

    var removalBand: CGRect? { removal?.rect }
    var removalAmountText: String? { removal.map { Self.formatRemovalAmount($0.length) } }

    private static func formatRemovalAmount(_ length: CGFloat) -> String {
        String(format: "%.12g", Double(length))
    }
    private var removal: StitchDocument.RemovalBand? {
        guard mode == .removeSpace, let bandAxis, let start, let end,
              let bandStartInWindow, let bandEndInWindow else { return nil }
        let distance = bandAxis == .horizontal ? bandEndInWindow.y - bandStartInWindow.y : bandEndInWindow.x - bandStartInWindow.x
        guard abs(distance) >= Self.bandDragThreshold else { return nil }
        return document.removalBand(axis: bandAxis, from: bandAxis == .horizontal ? start.y : start.x,
                                    to: bandAxis == .horizontal ? end.y : end.x)
    }
    private func bandCandidates(for axis: StitchAxis) -> [CGFloat] {
        guard document.canRender else { return [] }
        let range = axis == .horizontal ? contentBounds.minY...contentBounds.maxY : contentBounds.minX...contentBounds.maxX
        let guides = gestureBandGuides?.values(for: axis) ?? (axis == .horizontal ? bandGuideRows : bandGuideColumns)
        return guides.filter { $0.isFinite && range.contains($0) }
    }
    private func bandMatch(_ point: CGPoint, axis: StitchAxis) -> CGFloat? {
        guard !bandSnapBypassed else { return nil }
        let coordinate = axis == .horizontal ? point.y : point.x
        guard let closest = bandCandidates(for: axis).min(by: { abs($0 - coordinate) < abs($1 - coordinate) }),
              abs(closest - coordinate) <= 6 / effectiveZoom else { return nil }
        return closest
    }
    private func resolveBandAxis(at location: CGPoint) {
        guard bandAxis == nil, let bandStartInWindow else { return }
        let dx = abs(location.x - bandStartInWindow.x), dy = abs(location.y - bandStartInWindow.y)
        guard max(dx, dy) >= Self.bandDragThreshold,
              abs(dx - dy) >= Self.bandDirectionMargin else { return }
        bandAxis = dy > dx ? .horizontal : .vertical
    }
    private func refreshBandSnapping() {
        guard mode == .removeSpace else { return }
        bandGuideMatches = []
        func snapped(_ raw: CGPoint) -> CGPoint {
            var point = raw
            if let bandAxis, let match = bandMatch(raw, axis: bandAxis) {
                if bandAxis == .horizontal { point.y = match } else { point.x = match }
                if !bandGuideMatches.contains(match) { bandGuideMatches.append(match) }
            }
            return point
        }
        if let rawBandStart { start = snapped(rawBandStart) }
        if let rawBandEnd { end = snapped(rawBandEnd) }
        bandHoverRow = rawBandHover.flatMap { bandMatch($0, axis: .horizontal) }
        bandHoverColumn = rawBandHover.flatMap { bandMatch($0, axis: .vertical) }
    }
    private func drawBandGuides(zoom: CGFloat) {
        guard showsBandGuides else { return }
        let region = imageRect.intersection(visibleRect)
        guard !region.isNull else { return }
        for axis in [StitchAxis.horizontal, .vertical] where bandAxis == nil || bandAxis == axis {
            drawBandGuides(for: axis, in: region, zoom: zoom)
        }
    }
    private func drawBandGuides(for axis: StitchAxis, in region: CGRect, zoom: CGFloat) {
        let horizontal = axis == .horizontal
        for position in bandCandidates(for: axis) {
            let coordinate = position - (horizontal ? contentBounds.minY : contentBounds.minX) + inset
            let line = NSBezierPath()
            if horizontal {
                guard coordinate >= region.minY, coordinate <= region.maxY else { continue }
                line.move(to: CGPoint(x: region.minX, y: coordinate))
                line.line(to: CGPoint(x: region.maxX, y: coordinate))
            } else {
                guard coordinate >= region.minX, coordinate <= region.maxX else { continue }
                line.move(to: CGPoint(x: coordinate, y: region.minY))
                line.line(to: CGPoint(x: coordinate, y: region.maxY))
            }
            let matched = bandAxis == axis ? bandGuideMatches.contains(position)
                : (horizontal ? bandHoverRow : bandHoverColumn) == position
            if matched {
                ToolbarLayout.accentColor.withAlphaComponent(bandAxis == nil ? 0.5 : 0.85).setStroke()
                line.lineWidth = 1.5 / zoom
                line.stroke()
            } else {
                line.setLineDash([4 / zoom, 5 / zoom], count: 2, phase: 0)
                NSColor.white.withAlphaComponent(bandAxis == nil ? 0.16 : 0.3).setStroke()
                line.lineWidth = 1.5 / zoom
                line.stroke()
                NSColor.black.withAlphaComponent(bandAxis == nil ? 0.12 : 0.18).setStroke()
                line.lineWidth = 0.75 / zoom
                line.stroke()
            }
        }
    }

    private func cancelGesture() {
        let wasMoving = moving
        start = nil; end = nil; dragBounds = nil; originalOrigin = nil; moving = false
        gestureBandGuides = nil; bandAxis = nil; bandStartInWindow = nil; bandEndInWindow = nil
        rawBandStart = nil; rawBandEnd = nil; rawBandHover = nil; bandHoverInWindow = nil
        bandGuideMatches = []; bandHoverRow = nil; bandHoverColumn = nil
        hoveredID = nil; alignmentGuides = []; dragPreviewOrigin = nil; packedPreview = nil
        if wasMoving { onCancelMove?() }
        needsDisplay = true
    }

    private func deselectPiece() {
        cancelGesture()
        selectedID = nil
        onSelect?(nil)
        window?.invalidateCursorRects(for: self)
    }

    /// Capture overlays manage cursors imperatively as well as through cursor rects.
    func cursor(at point: CGPoint) -> NSCursor {
        let contentPoint = CGPoint(x: point.x - inset + contentBounds.minX, y: point.y - inset + contentBounds.minY)
        guard bounds.contains(point), isOverCapturedContent(contentPoint) else { return .arrow }
        return mode == .move ? (moving ? .closedHand : .openHand) : .crosshair
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        if mode == .move {
            for piece in document.pieces { addCursorRect(viewRect(piece.frame), cursor: .openHand) }
        } else { addCursorRect(imageRect, cursor: .crosshair) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        if window !== newWindow {
            cancelCollapseAnimation()
            ScreenshotCommandResponder.uninstallStitchCanvas(self, in: window)
            cancelGesture()
        }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            ScreenshotCommandResponder.installStitchCanvas(self, in: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification, object: window)
        }
    }
    @objc private func windowDidResignKey(_ notification: Notification) {
        cancelCollapseAnimation()
        clearBandHover()
    }
    override func mouseMoved(with event: NSEvent) {
        if mode == .removeSpace, start == nil {
            bandSnapBypassed = event.modifierFlags.contains(.option)
            let wasShowingGuides = showsBandGuides
            let previousRow = bandHoverRow, previousColumn = bandHoverColumn
            updateBandHover(at: event.locationInWindow)
            if wasShowingGuides != showsBandGuides || previousRow != bandHoverRow || previousColumn != bandHoverColumn {
                needsDisplay = true
            }
            return
        }
        guard mode == .move, !moving, start == nil else { return }
        let point = canvasPoint(event)
        let id = document.pieces.reversed().first(where: { $0.frame.contains(point) })?.id
        if id != hoveredID { hoveredID = id; needsDisplay = true }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        hoveredID = nil
        clearBandHover()
    }
    override func mouseDown(with event: NSEvent) {
        cancelCollapseAnimation()
        window?.makeFirstResponder(self)
        hoveredID = nil; alignmentGuides = []; packedPreview = nil
        let p = canvasPoint(event)
        let piece = mode == .move ? document.pieces.reversed().first { $0.frame.contains(p) } : nil
        guard document.bounds.contains(p), mode != .move || piece != nil else {
            deselectPiece()
            return
        }
        start = p; end = p; dragBounds = document.bounds
        if mode == .removeSpace {
            gestureBandGuides = StitchBandGuides.Result(rows: bandCandidates(for: .horizontal), columns: bandCandidates(for: .vertical))
            bandAxis = nil; bandStartInWindow = event.locationInWindow; bandEndInWindow = event.locationInWindow
            rawBandStart = p; rawBandEnd = p; rawBandHover = nil; bandHoverInWindow = nil
            bandSnapBypassed = event.modifierFlags.contains(.option)
            refreshBandSnapping()
        }
        if mode == .move {
            selectedID = piece?.id; originalOrigin = piece?.origin
            onSelect?(selectedID)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = canvasPoint(event)
        end = p
        if mode == .removeSpace {
            rawBandEnd = p
            bandEndInWindow = event.locationInWindow
            bandSnapBypassed = event.modifierFlags.contains(.option)
            resolveBandAxis(at: event.locationInWindow)
            refreshBandSnapping()
        }
        if mode == .move, selectedID != nil, originalOrigin != nil {
            let zoom = effectiveZoom
            guard moving || hypot(p.x - start.x, p.y - start.y) * zoom >= 3 else { return }
            moving = true
            NSCursor.closedHand.set()
            updateMovePreview(at: p, modifiers: event.modifierFlags)
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let wasRemoving = mode == .removeSpace && rawBandStart != nil
        let hadBandPreview = removalBand != nil
        if mode == .removeSpace, start != nil {
            rawBandEnd = canvasPoint(event)
            bandEndInWindow = event.locationInWindow
            bandSnapBypassed = event.modifierFlags.contains(.option)
            refreshBandSnapping()
        }
        if mode == .move, moving {
            updateMovePreview(at: canvasPoint(event), modifiers: event.modifierFlags, notify: false)
        }
        let a = start, b = end
        let cutAxis = hadBandPreview && removalBand != nil ? bandAxis : nil
        start = nil; end = nil; dragBounds = nil
        gestureBandGuides = nil; bandAxis = nil; bandStartInWindow = nil; bandEndInWindow = nil
        rawBandStart = nil; rawBandEnd = nil; bandGuideMatches = []
        if moving, let id = selectedID, let piece = document.pieces.first(where: { $0.id == id }) {
            onMove?(id, dragPreviewOrigin ?? piece.origin, true)
        } else if mode == .removeSpace, let cutAxis, let a, let b {
            // Keep the proposed endpoints so clipped fractional bounds are not rounded twice.
            onCut?(cutAxis, cutAxis == .horizontal ? a.y : a.x, cutAxis == .horizontal ? b.y : b.x)
        }
        moving = false; originalOrigin = nil
        alignmentGuides = []; hoveredID = nil; dragPreviewOrigin = nil; packedPreview = nil
        if wasRemoving { updateBandHover(at: event.locationInWindow) }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func flagsChanged(with event: NSEvent) {
        if inlineEditor != nil, let commands = ScreenshotCommandResponder.forWindow(window) {
            commands.flagsChanged(with: event)
            return
        }
        if !handleStitchModifierEvent(event) { super.flagsChanged(with: event) }
    }

    func handleStitchModifierEvent(_ event: NSEvent) -> Bool {
        if mode == .move {
            guard moving, !packed, let end else { return false }
            updateMovePreview(at: end, modifiers: event.modifierFlags)
            needsDisplay = true
            return true
        }
        bandSnapBypassed = event.modifierFlags.contains(.option)
        refreshBandSnapping()
        needsDisplay = true
        return true
    }

    private func updateMovePreview(at point: CGPoint, modifiers: NSEvent.ModifierFlags, notify: Bool = true) {
        guard let start, let id = selectedID, let originalOrigin else { return }
        var origin = CGPoint(x: originalOrigin.x + point.x - start.x, y: originalOrigin.y + point.y - start.y)
        if !packed, !modifiers.contains(.option) {
            origin = document.snappedOrigin(for: id, proposed: origin, tolerance: 12 / effectiveZoom)
            alignmentGuides = guides(for: id, origin: origin)
        } else { alignmentGuides = [] }
        dragPreviewOrigin = origin
        if notify { onMove?(id, origin, false) }
    }

    /// Center on the visible cut, with enough viewport inset to keep the pill's stroke inside.
    static func cutLabelRect(size: CGSize, band: CGRect, visible: CGRect, zoom: CGFloat) -> CGRect {
        let padding = min(6 / zoom, min(visible.width, visible.height) / 2)
        let available = visible.insetBy(dx: padding, dy: padding)
        let width = min(size.width, available.width), height = min(size.height, available.height)
        return CGRect(x: min(max(band.midX - width / 2, available.minX), available.maxX - width),
                      y: min(max(band.midY - height / 2, available.minY), available.maxY - height),
                      width: width, height: height)
    }

    private func guides(for id: UUID, origin: CGPoint) -> [AlignmentGuide] {
        guard let piece = document.pieces.first(where: { $0.id == id }) else { return [] }
        let frame = CGRect(origin: origin, size: piece.frame.size)
        var vertical: [CGFloat: ClosedRange<CGFloat>] = [:]
        var horizontal: [CGFloat: ClosedRange<CGFloat>] = [:]
        for other in document.pieces where other.id != id {
            for x in [frame.minX, frame.maxX] where [other.frame.minX, other.frame.maxX].contains(where: { abs($0 - x) < 0.01 }) {
                let range = min(frame.minY, other.frame.minY)...max(frame.maxY, other.frame.maxY)
                if let old = vertical[x] { vertical[x] = min(old.lowerBound, range.lowerBound)...max(old.upperBound, range.upperBound) }
                else { vertical[x] = range }
            }
            for y in [frame.minY, frame.maxY] where [other.frame.minY, other.frame.maxY].contains(where: { abs($0 - y) < 0.01 }) {
                let range = min(frame.minX, other.frame.minX)...max(frame.maxX, other.frame.maxX)
                if let old = horizontal[y] { horizontal[y] = min(old.lowerBound, range.lowerBound)...max(old.upperBound, range.upperBound) }
                else { horizontal[y] = range }
            }
        }
        let extensionLength = 8 / effectiveZoom
        return vertical.sorted(by: { $0.key < $1.key }).map { x, range in
            AlignmentGuide(start: CGPoint(x: x, y: range.lowerBound - extensionLength), end: CGPoint(x: x, y: range.upperBound + extensionLength))
        } + horizontal.sorted(by: { $0.key < $1.key }).map { y, range in
            AlignmentGuide(start: CGPoint(x: range.lowerBound - extensionLength, y: y), end: CGPoint(x: range.upperBound + extensionLength, y: y))
        }
    }
    @objc func undo(_ sender: Any?) { onUndo?() }
    @objc func redo(_ sender: Any?) { onRedo?() }
    @objc func copy(_ sender: Any?) { onCopy?() }
    @objc func paste(_ sender: Any?) {
        if let image = NSImage(pasteboard: .general) { onImages?([image]) }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undo(_:)) { return canUndo?() ?? false }
        if item.action == #selector(redo(_:)) { return canRedo?() ?? false }
        return true
    }
    override func keyDown(with event: NSEvent) {
        if let inlineEditor {
            if let commands = ScreenshotCommandResponder.forWindow(window) {
                commands.keyDown(with: event)
                return
            }
            if handleStitchInteractionKeyEvent(event) { return }
            inlineEditor.keyDown(with: event)
            return
        }
        if let command = EditorCommandShortcutManager.action(for: event) {
            if command == .undo { onUndo?() } else { onRedo?() }
            return
        }
        if event.modifierFlags.contains(.command) {
            if KeyboardShortcutMatcher.matches(event, character: "s", modifiers: .command) { onSave?(); return }
            if KeyboardShortcutMatcher.matches(event, character: "c", modifiers: .command) { onCopy?(); return }
            if KeyboardShortcutMatcher.matches(event, character: "1", modifiers: .command) { onFit?(); return }
            if KeyboardShortcutMatcher.matches(event, character: "0", modifiers: .command) { onZoom?(1); return }
            let character = KeyboardShortcutMatcher.semanticCharacter(for: event)
            if character == "+" || character == "=" { onZoom?((enclosingScrollView?.magnification ?? 1) * 1.25); return }
            if character == "-" { onZoom?((enclosingScrollView?.magnification ?? 1) / 1.25); return }
            if KeyboardShortcutMatcher.matches(event, character: "v", modifiers: .command) {
                if let images = NSImage(pasteboard: .general) { onImages?([images]) }
                return
            }
        }
        if KeyboardShortcutMatcher.modifiers(in: event).isEmpty {
            switch KeyboardShortcutMatcher.semanticCharacter(for: event) {
            case "v": onMode?(.move); return
            default: break
            }
        }
        if event.keyCode == 53 {
            deselectPiece()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
        if nudgeSelectedPiece(with: event) { return }
        super.keyDown(with: event)
    }

    /// Piece interactions take priority over the editor's ordinary canvas commands.
    func handleStitchInteractionKeyEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, start != nil || selectedID != nil {
            deselectPiece()
            return true
        }
        guard mode == .move, !event.modifierFlags.contains(.command) else { return false }
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
            return true
        }
        return nudgeSelectedPiece(with: event)
    }

    private func nudgeSelectedPiece(with event: NSEvent) -> Bool {
        guard let id = selectedID, let piece = document.pieces.first(where: { $0.id == id }),
              [123, 124, 125, 126].contains(Int(event.keyCode)) else { return false }
        let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var p = piece.origin
        switch event.keyCode {
        case 123: p.x -= amount
        case 124: p.x += amount
        case 125: p.y += amount
        default: p.y -= amount
        }
        onMove?(id, p, false)
        onMove?(id, p, true)
        return true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let board = sender.draggingPasteboard
        var images: [NSImage] = []
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls.prefix(24) {
                let access = url.startAccessingSecurityScopedResource()
                if let image = NSImage(contentsOf: url) { images.append(image) }
                if access { url.stopAccessingSecurityScopedResource() }
            }
        } else if let image = NSImage(pasteboard: board) { images = [image] }
        guard !images.isEmpty else { return false }
        onImages?(images)
        return true
    }
}
