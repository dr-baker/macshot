import AppKit

@MainActor
final class StitchCaptureHUD {
    var onUndo: (() -> Void)?
    var onFinish: (() -> Void)?

    private let screen: NSScreen
    private let selection: NSRect
    private let panel: StitchHUDPanel
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let undoButton = NSButton()
    private let finishButton = NSButton()

    init(screen: NSScreen, pixelRect: CGRect, imageSize: CGSize) {
        self.screen = screen
        let sx = screen.frame.width / imageSize.width
        let sy = screen.frame.height / imageSize.height
        selection = NSRect(x: screen.frame.minX + pixelRect.minX * sx,
                           y: screen.frame.maxY - pixelRect.maxY * sy,
                           width: pixelRect.width * sx, height: pixelRect.height * sy)
        panel = StitchHUDPanel(contentRect: .zero,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(259)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none

        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = ToolbarLayout.cornerRadius
        view.layer?.backgroundColor = ToolbarLayout.bgColor.cgColor
        panel.contentView = view

        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: 11)
        for label in [countLabel, statusLabel] {
            label.textColor = ToolbarLayout.iconColor
            label.lineBreakMode = .byTruncatingTail
            view.addSubview(label)
        }
        statusLabel.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.75)
        configure(undoButton, title: L("Undo"), action: #selector(undoClicked))
        configure(finishButton, title: L("Finish ↵"), action: #selector(finishClicked), primary: true)
        update(count: 1, status: L("Drag to capture · hold Space to navigate"), canUndo: false)
    }

    var windowNumbers: [CGWindowID] {
        [CGWindowID(panel.windowNumber)]
    }

    private func configure(_ button: NSButton, title: String, action: Selector, primary: Bool = false) {
        button.title = title
        button.bezelStyle = .recessed
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.contentTintColor = primary ? .white : ToolbarLayout.iconColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 12
        button.layer?.backgroundColor = (primary ? ToolbarLayout.accentColor : ToolbarLayout.iconColor.withAlphaComponent(0.1)).cgColor
        button.target = self
        button.action = action
        button.focusRingType = .none
        panel.contentView?.addSubview(button)
    }

    func update(count: Int, status: String, canUndo: Bool) {
        countLabel.stringValue = "\(L("Stitch Capture")) · \(count) \(L("captures"))"
        statusLabel.stringValue = status
        statusLabel.toolTip = status
        undoButton.isEnabled = canUndo
        undoButton.title = L("Undo")
        undoButton.alphaValue = canUndo ? 1 : 0.55
        let buttons = [undoButton, finishButton]
        let buttonWidths = buttons.map { max(CGFloat(76), $0.intrinsicContentSize.width + 16) }
        let controlsWidth = buttonWidths.reduce(0, +) + 12
        let desiredWidth = max(CGFloat(460), countLabel.intrinsicContentSize.width + controlsWidth + 30)
        let width = min(desiredWidth, screen.visibleFrame.width - 8)
        let size = NSSize(width: width, height: 62)
        panel.setFrame(ScrollCaptureHUDPanel.hudFrame(
            size: size, selectionScreenRect: selection,
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
            topInset: screen.safeAreaInsets.top), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        let buttonsX = width - controlsWidth - 10
        countLabel.frame = NSRect(x: 10, y: 34, width: max(30, buttonsX - 18), height: 17)
        statusLabel.frame = NSRect(x: 10, y: 9, width: width - 20, height: 16)
        var buttonX = buttonsX
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: buttonX, y: 30, width: buttonWidths[index], height: 24)
            buttonX += buttonWidths[index] + 6
        }
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }
    func close() { panel.close() }
    @objc private func undoClicked() { onUndo?() }
    @objc private func finishClicked() { onFinish?() }
}

private final class StitchHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
