import AppKit

@MainActor
final class StitchCanvasView: NSView {
    enum Mode: Int { case move, rows, columns }
    var document = StitchDocument()
    /// Packed placement is committed by the owner on drop; dragging stays a local preview.
    var packed = false {
        didSet { if oldValue != packed { cancelGesture() } }
    }
    var mode = Mode.move {
        didSet {
            if oldValue != mode { cancelGesture() }
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
    var onCopy: (() -> Void)?
    var onMode: ((Mode) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onFit: (() -> Void)?
    private let inset: CGFloat = 80
    private var start: CGPoint?
    private var end: CGPoint?
    private var originalOrigin: CGPoint?
    private var dragBounds: CGRect?
    private var moving = false
    private var dragPreviewOrigin: CGPoint?
    private var hoverTracking: NSTrackingArea?
    private(set) var hoveredID: UUID?
    struct AlignmentGuide: Equatable {
        let start: CGPoint
        let end: CGPoint
    }
    private(set) var alignmentGuides: [AlignmentGuide] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var contentBounds: CGRect { dragBounds ?? document.bounds }
    private var imageRect: CGRect { CGRect(x: inset, y: inset, width: contentBounds.width, height: contentBounds.height) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .tiff, .png])
        setAccessibilityLabel(L("Stitch canvas"))
        setAccessibilityHelp(L("Choose Remove Rows or Remove Columns and drag across a gap. Choose Move to reposition pieces."))
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh(_ value: StitchDocument, preview: CGImage?) {
        document = value
        if !value.pieces.contains(where: { $0.id == hoveredID }) { hoveredID = nil }
        self.preview = preview
        if dragBounds == nil, value.canRender {
            setFrameSize(NSSize(width: value.bounds.width + inset * 2, height: value.bounds.height + inset * 2))
        }
        needsDisplay = true
    }
    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
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

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.15, alpha: 1).setFill()
        bounds.fill()
        guard document.canRender else { return }
        let zoom = enclosingScrollView?.magnification ?? 1
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
        if mode != .move, let start, let end {
            let horizontal = mode == .rows
            let band = horizontal
                ? CGRect(x: contentBounds.minX, y: min(start.y, end.y), width: contentBounds.width, height: abs(end.y - start.y))
                : CGRect(x: min(start.x, end.x), y: contentBounds.minY, width: abs(end.x - start.x), height: contentBounds.height)
            let rect = viewRect(band).intersection(imageRect)
            guard !rect.isNull, !rect.isEmpty,
                  rect.minX.isFinite, rect.minY.isFinite,
                  rect.width.isFinite, rect.height.isFinite else { return }
            ToolbarLayout.accentColor.withAlphaComponent(0.2).setFill()
            rect.fill()
            ToolbarLayout.accentColor.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1.5 / zoom
            border.stroke()
            let removed = Int(horizontal ? rect.height : rect.width)
            let text = "−\(removed) px" as NSString
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

    private func cancelGesture() {
        let wasMoving = moving
        start = nil; end = nil; dragBounds = nil; originalOrigin = nil; moving = false
        hoveredID = nil; alignmentGuides = []; dragPreviewOrigin = nil; packedPreview = nil
        if wasMoving { onCancelMove?() }
        needsDisplay = true
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
    override func mouseMoved(with event: NSEvent) {
        guard mode == .move, !moving, start == nil else { return }
        let point = canvasPoint(event)
        let id = document.pieces.reversed().first(where: { $0.frame.contains(point) })?.id
        if id != hoveredID { hoveredID = id; needsDisplay = true }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        hoveredID = nil
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        hoveredID = nil; alignmentGuides = []; packedPreview = nil
        let p = canvasPoint(event)
        guard document.bounds.contains(p) else { selectedID = nil; onSelect?(nil); return }
        start = p; end = p; dragBounds = document.bounds
        if mode == .move {
            let piece = document.pieces.reversed().first { $0.frame.contains(p) }
            selectedID = piece?.id; originalOrigin = piece?.origin
            onSelect?(selectedID)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = canvasPoint(event)
        end = p
        if mode == .move, let id = selectedID, let originalOrigin {
            let zoom = enclosingScrollView?.magnification ?? 1
            guard moving || hypot(p.x - start.x, p.y - start.y) * zoom >= 3 else { return }
            moving = true
            NSCursor.closedHand.set()
            var origin = CGPoint(x: originalOrigin.x + p.x - start.x, y: originalOrigin.y + p.y - start.y)
            if !packed, !event.modifierFlags.contains(.option) {
                origin = document.snappedOrigin(for: id, proposed: origin, tolerance: 12 / (enclosingScrollView?.magnification ?? 1))
                alignmentGuides = guides(for: id, origin: origin)
            } else {
                alignmentGuides = []
            }
            dragPreviewOrigin = origin
            onMove?(id, origin, false)
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let a = start, b = end
        start = nil; end = nil; dragBounds = nil
        if moving, let id = selectedID, let piece = document.pieces.first(where: { $0.id == id }) {
            onMove?(id, dragPreviewOrigin ?? piece.origin, true)
        } else if mode != .move, let a, let b {
            onCut?(mode == .rows ? .horizontal : .vertical, mode == .rows ? a.y : a.x, mode == .rows ? b.y : b.x)
        }
        moving = false; originalOrigin = nil
        alignmentGuides = []; hoveredID = nil; dragPreviewOrigin = nil; packedPreview = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
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
        let extensionLength = 8 / (enclosingScrollView?.magnification ?? 1)
        return vertical.sorted(by: { $0.key < $1.key }).map { x, range in
            AlignmentGuide(start: CGPoint(x: x, y: range.lowerBound - extensionLength), end: CGPoint(x: x, y: range.upperBound + extensionLength))
        } + horizontal.sorted(by: { $0.key < $1.key }).map { y, range in
            AlignmentGuide(start: CGPoint(x: range.lowerBound - extensionLength, y: y), end: CGPoint(x: range.upperBound + extensionLength, y: y))
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command, .shift]) { undoManager?.redo(); return }
            if KeyboardShortcutMatcher.matches(event, character: "z", modifiers: .command) { undoManager?.undo(); return }
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
            case "r": onMode?(.rows); return
            case "c": onMode?(.columns); return
            default: break
            }
        }
        if event.keyCode == 53 {
            cancelGesture()
            selectedID = nil
            onSelect?(nil)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
        if let id = selectedID, let piece = document.pieces.first(where: { $0.id == id }), [123,124,125,126].contains(Int(event.keyCode)) {
            let amount: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var p = piece.origin
            switch event.keyCode { case 123: p.x -= amount; case 124: p.x += amount; case 125: p.y += amount; default: p.y -= amount }
            onMove?(id, p, false); onMove?(id, p, true)
            return
        }
        super.keyDown(with: event)
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
