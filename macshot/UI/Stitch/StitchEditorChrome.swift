import AppKit

final class StitchOptionsView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = ToolbarLayout.bgColor.cgColor
        appearance = ToolbarLayout.appearance
    }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Uses the base editor's immediate, button-anchored tooltip treatment.
final class StitchTooltipView: NSView {
    var text = "" { didSet { needsDisplay = true } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: NSPoint(x: 6, y: 3), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor,
        ])
    }
}

/// Reorders the rendering stack without changing piece identity or canvas geometry.
enum StitchPieceOrder {
    @discardableResult
    static func move(_ id: UUID, in pieces: inout [StitchPiece], to destination: Int) -> Bool {
        guard let source = pieces.firstIndex(where: { $0.id == id }),
              pieces.indices.contains(destination), source != destination else { return false }
        let piece = pieces.remove(at: source)
        pieces.insert(piece, at: destination)
        return true
    }
}

/// Cancellation is read by the serial preview queue and written by the main thread.
final class StitchPreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
