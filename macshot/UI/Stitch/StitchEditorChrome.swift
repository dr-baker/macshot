import AppKit

final class StitchOptionsView: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Uses the base editor's immediate, button-anchored tooltip treatment.
final class StitchTooltipView: ScreenshotTooltipView {}

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
