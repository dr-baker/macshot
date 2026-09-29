import AppKit

@MainActor
final class StitchPickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class StitchRegionPicker: NSView {
    private let image: CGImage
    private var start: CGPoint?
    private var end: CGPoint?
    var onPick: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    init(image: CGImage, frame: CGRect) { self.image = image; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        let shot = NSImage(cgImage: image, size: bounds.size)
        shot.draw(in: bounds)
        NSColor.black.withAlphaComponent(0.45).setFill(); bounds.fill()
        if let start, let end {
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
            NSGraphicsContext.saveGraphicsState(); rect.clip(); shot.draw(in: bounds); NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.setStroke(); let border = NSBezierPath(rect: rect); border.lineWidth = 2; border.stroke()
        }
        let message = L("Select the area to keep capturing · Esc to cancel") as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .semibold), .foregroundColor: NSColor.white, .backgroundColor: NSColor.black.withAlphaComponent(0.7)]
        let size = message.size(withAttributes: attrs)
        message.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - 70), withAttributes: attrs)
    }
    override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); end = start; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) { end = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard let start, let end else { return }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
        guard rect.width >= 8, rect.height >= 8 else { return }
        onPick?(CGRect(x: rect.minX / bounds.width * CGFloat(image.width), y: (bounds.height - rect.maxY) / bounds.height * CGFloat(image.height), width: rect.width / bounds.width * CGFloat(image.width), height: rect.height / bounds.height * CGFloat(image.height)).integral)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onCancel?() } }
}
