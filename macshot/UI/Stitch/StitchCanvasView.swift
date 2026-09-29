import AppKit

@MainActor
final class StitchCanvasView: NSView {
    enum Mode: Int { case move, rows, columns }
    var document = StitchDocument()
    var mode = Mode.move { didSet { window?.invalidateCursorRects(for: self) } }
    var selectedID: UUID? { didSet { needsDisplay = true } }
    var preview: CGImage?
    var onSelect: ((UUID?) -> Void)?
    var onCut: ((StitchAxis, CGFloat, CGFloat) -> Void)?
    var onMove: ((UUID, CGPoint, Bool) -> Void)?
    var onDelete: (() -> Void)?
    var onImages: (([NSImage]) -> Void)?
    var onCopy: (() -> Void)?
    private let inset: CGFloat = 80
    private var start: CGPoint?
    private var end: CGPoint?
    private var originalOrigin: CGPoint?
    private var dragBounds: CGRect?
    private var moving = false
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

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        bounds.fill()
        guard document.canRender else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: 4)
        shadow.set()
        NSColor.white.setFill()
        imageRect.fill()
        NSGraphicsContext.restoreGraphicsState()
        if !moving, let preview {
            NSImage(cgImage: preview, size: imageRect.size).draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            for piece in document.pieces {
                guard let crop = piece.image.cropping(to: piece.source) else { continue }
                NSImage(cgImage: crop, size: piece.frame.size).draw(in: viewRect(piece.frame), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        let zoom = enclosingScrollView?.magnification ?? 1
        if let piece = document.pieces.first(where: { $0.id == selectedID }), mode == .move {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: viewRect(piece.frame).insetBy(dx: -1 / zoom, dy: -1 / zoom))
            path.lineWidth = 2 / zoom
            path.stroke()
        }
        if mode != .move, let start, let end {
            let horizontal = mode == .rows
            let band = horizontal
                ? CGRect(x: contentBounds.minX, y: min(start.y, end.y), width: contentBounds.width, height: abs(end.y - start.y))
                : CGRect(x: min(start.x, end.x), y: contentBounds.minY, width: abs(end.x - start.x), height: contentBounds.height)
            let rect = viewRect(band).intersection(imageRect)
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            rect.fill()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1.5 / zoom
            border.stroke()
            let removed = Int(horizontal ? rect.height : rect.width)
            let text = "−\(removed) px" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13 / zoom, weight: .semibold), .foregroundColor: NSColor.white, .backgroundColor: NSColor.controlAccentColor]
            text.draw(at: CGPoint(x: rect.midX, y: rect.midY), withAttributes: attributes)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .move ? .openHand : .crosshair)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
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
            moving = true
            NSCursor.closedHand.set()
            var origin = CGPoint(x: originalOrigin.x + p.x - start.x, y: originalOrigin.y + p.y - start.y)
            if !event.modifierFlags.contains(.option) {
                origin = document.snappedOrigin(for: id, proposed: origin, tolerance: 12 / (enclosingScrollView?.magnification ?? 1))
            }
            onMove?(id, origin, false)
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        let a = start, b = end
        start = nil; end = nil; dragBounds = nil
        if moving, let id = selectedID, let piece = document.pieces.first(where: { $0.id == id }) {
            onMove?(id, piece.origin, true)
        } else if mode != .move, let a, let b {
            onCut?(mode == .rows ? .horizontal : .vertical, mode == .rows ? a.y : a.x, mode == .rows ? b.y : b.x)
        }
        moving = false; originalOrigin = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command, .shift]) { undoManager?.redo(); return }
            if KeyboardShortcutMatcher.matches(event, character: "z", modifiers: .command) { undoManager?.undo(); return }
            if KeyboardShortcutMatcher.matches(event, character: "c", modifiers: .command) { onCopy?(); return }
            if KeyboardShortcutMatcher.matches(event, character: "v", modifiers: .command) {
                if let images = NSImage(pasteboard: .general) { onImages?([images]) }
                return
            }
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
