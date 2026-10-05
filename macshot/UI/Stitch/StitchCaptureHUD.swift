import AppKit

@MainActor
final class StitchCaptureHUD {
    var onUndo: (() -> Void)?
    var onFinish: (() -> Void)?

    private var screen: NSScreen
    private var selection: NSRect
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

        let view = StitchHUDContentView()
        view.onAppearanceChanged = { [weak self] in self?.updateForegroundColors() }
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
        updateForegroundColors()
        update(count: 1, status: L("Drag to capture · hold Space to navigate"), canUndo: false)
    }

    /// Keep the same panel and controls as the selected region moves between captures.
    func setPlacement(screen: NSScreen, pixelRect: CGRect, imageSize: CGSize) {
        self.screen = screen
        let sx = screen.frame.width / imageSize.width
        let sy = screen.frame.height / imageSize.height
        selection = NSRect(x: screen.frame.minX + pixelRect.minX * sx,
                           y: screen.frame.maxY - pixelRect.maxY * sy,
                           width: pixelRect.width * sx, height: pixelRect.height * sy)
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
        let unit = count == 1 ? L("capture") : L("captures")
        countLabel.stringValue = "\(L("Stitch Capture")) · \(count) \(unit)"
        statusLabel.stringValue = status
        statusLabel.toolTip = status
        undoButton.isEnabled = canUndo
        undoButton.title = L("Undo")
        undoButton.alphaValue = canUndo ? 1 : 0.55
        finishButton.isEnabled = count > 0
        finishButton.alphaValue = count > 0 ? 1 : 0.55
        let buttons = [undoButton, finishButton]
        let buttonWidths = buttons.map { max(CGFloat(76), $0.intrinsicContentSize.width + 16) }
        let controlsWidth = buttonWidths.reduce(0, +) + 12
        let desiredWidth = max(CGFloat(460), countLabel.intrinsicContentSize.width + controlsWidth + 30)
        let width = min(desiredWidth, screen.visibleFrame.width - 8)
        let size = NSSize(width: width, height: 62)
        let frame = ScrollCaptureHUDPanel.hudFrame(
            size: size, selectionScreenRect: selection,
            screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
            topInset: screen.safeAreaInsets.top)
        panel.setFrame(frame, display: true)
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

    private func updateForegroundColors() {
        let foreground = (panel.contentView as? ScreenshotPanelView)?.panelForegroundColor ?? ToolbarLayout.iconColor
        countLabel.textColor = foreground
        statusLabel.textColor = foreground.withAlphaComponent(0.8)
        undoButton.contentTintColor = foreground
        undoButton.layer?.backgroundColor = foreground.withAlphaComponent(0.1).cgColor
        finishButton.layer?.backgroundColor = ToolbarLayout.accentColor.cgColor
    }

    @objc private func undoClicked() { onUndo?() }
    @objc private func finishClicked() { onFinish?() }
}

private final class StitchHUDPanel: ScreenshotGlassPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class StitchHUDContentView: ScreenshotPanelView {
    var onAppearanceChanged: (() -> Void)?
    override func refreshPanelAppearance() {
        super.refreshPanelAppearance()
        onAppearanceChanged?()
    }
}
