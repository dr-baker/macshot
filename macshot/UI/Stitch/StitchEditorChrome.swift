import AppKit

/// Matches EditorTopBarView's 32-point chrome, labels, symbols, and zoom menu.
@MainActor
final class StitchEditorTopBar: NSView {
    var onAdd: (() -> Void)?
    var onPieces: ((NSView) -> Void)?
    var onFit: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    var onCanvas: ((NSView) -> Void)?
    var onPlacement: ((StitchPlacement) -> Void)?
    private let dimensions = NSTextField(labelWithString: "")
    private let zoomButton = NSButton()
    private var zoom: CGFloat = 1
    private let placement = NSPopUpButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ToolbarLayout.bgColor.cgColor
        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        dimensions.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.45)
        let add = symbol("rectangle.badge.plus", title: L("Add Images"), action: #selector(addClicked))
        let pieces = symbol("square.3.layers.3d", title: L("PIECES"), action: #selector(piecesClicked(_:)))
        let fit = symbol("arrow.up.left.and.arrow.down.right", title: L("Fit Canvas"), action: #selector(fitClicked))
        let background = symbol("paintpalette", title: L("Canvas background"), action: #selector(canvasClicked(_:)))
        placement.addItems(withTitles: [L("Free Move"), L("Packed")])
        placement.isBordered = false
        placement.font = .systemFont(ofSize: 11, weight: .medium)
        placement.contentTintColor = ToolbarLayout.iconColor.withAlphaComponent(0.85)
        placement.toolTip = L("Free Move keeps your placement. Packed closes gaps and rearranges pieces on drop.")
        placement.setAccessibilityLabel(L("Piece arrangement"))
        placement.target = self; placement.action = #selector(placementChanged)
        zoomButton.bezelStyle = .recessed
        zoomButton.isBordered = false
        zoomButton.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomButton.contentTintColor = ToolbarLayout.iconColor.withAlphaComponent(0.45)
        zoomButton.target = self
        zoomButton.action = #selector(zoomClicked)
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = NSColor(white: 0.25, alpha: 1).cgColor
        for view in [dimensions, add, pieces, background, placement, fit, zoomButton, border] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            dimensions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dimensions.centerYAnchor.constraint(equalTo: centerYAnchor),
            add.leadingAnchor.constraint(equalTo: dimensions.trailingAnchor, constant: 16),
            pieces.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 4),
            background.leadingAnchor.constraint(equalTo: pieces.trailingAnchor, constant: 4),
            placement.leadingAnchor.constraint(equalTo: background.trailingAnchor, constant: 8),
            placement.centerYAnchor.constraint(equalTo: centerYAnchor),
            placement.heightAnchor.constraint(equalToConstant: 24),
            fit.leadingAnchor.constraint(equalTo: placement.trailingAnchor, constant: 12),
            zoomButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            zoomButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
            border.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        for button in [add, pieces, background, fit] {
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        updateZoom(1)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func symbol(_ name: String, title: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .recessed
        button.isBordered = false
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.contentTintColor = ToolbarLayout.iconColor.withAlphaComponent(0.85)
        button.toolTip = title
        button.target = self
        button.action = action
        return button
    }
    func update(width: Int, height: Int, pieces: Int) {
        dimensions.stringValue = "\(width) × \(height)"
        dimensions.toolTip = "\(pieces) \(L("pieces"))"
    }
    func updateZoom(_ value: CGFloat) { zoom = value; zoomButton.title = "\(Int(value * 100))% ▾" }
    func updatePlacement(_ value: StitchPlacement) { placement.selectItem(at: value == .packed ? 1 : 0) }
    @objc private func placementChanged() { onPlacement?(placement.indexOfSelectedItem == 1 ? .packed : .free) }
    @objc private func canvasClicked(_ sender: NSButton) { onCanvas?(sender) }
    @objc private func addClicked() { onAdd?() }
    @objc private func piecesClicked(_ sender: NSButton) { onPieces?(sender) }
    @objc private func fitClicked() { onFit?() }
    @objc private func zoomClicked() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, tag) in [(L("Zoom In"), -1), (L("Zoom Out"), -2), (L("Fit Canvas"), -3)] {
            let item = NSMenuItem(title: title, action: #selector(zoomChosen(_:)), keyEquivalent: "")
            item.target = self; item.tag = tag; menu.addItem(item)
            item.keyEquivalent = tag == -1 ? "+" : tag == -2 ? "-" : "1"
            item.keyEquivalentModifierMask = .command
        }
        menu.addItem(.separator())
        for percent in [25, 50, 100, 200, 400] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(zoomChosen(_:)), keyEquivalent: "")
            item.target = self; item.tag = percent
            if percent == 100 { item.keyEquivalent = "0"; item.keyEquivalentModifierMask = .command }
            item.state = abs(zoom * 100 - CGFloat(percent)) < 0.5 ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: zoomButton.bounds.height + 2), in: zoomButton)
    }
    @objc private func zoomChosen(_ sender: NSMenuItem) {
        switch sender.tag {
        case -1: onZoom?(zoom * 1.25)
        case -2: onZoom?(zoom / 1.25)
        case -3: onFit?()
        default: onZoom?(CGFloat(sender.tag) / 100)
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// Same rounded, accent-tinted options background as ToolOptionsRowView.
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
