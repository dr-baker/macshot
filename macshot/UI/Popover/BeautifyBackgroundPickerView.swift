import Cocoa

/// Backgrounds and coordinated frame presets share the existing Beautify menu.
final class BeautifyBackgroundPickerView: NSView {
    var onSelectGradient: ((Int) -> Void)?
    var onCustomImage: (() -> Void)?
    var onSelectWallpaper: ((MacOSWallpaper, CGImage, Data) -> Void)?
    var onSelectFrame: ((BeautifyFramePreset) -> Void)?

    private let gradients: GradientPickerView
    private let tabs = NSSegmentedControl(labels: [L("Gradients"), L("Wallpapers")], trackingMode: .selectOne, target: nil, action: nil)
    private let frames = NSSegmentedControl(labels: [L("Compact"), L("Roomy")], trackingMode: .selectOne, target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let gallery = NSView()
    private let status = NSTextField(labelWithString: "")
    private let loading = NSProgressIndicator()
    private let wallpapers: [MacOSWallpaper]
    private var buttons: [NSButton] = []
    private var selectionGeneration = 0
    private let queue = DispatchQueue(label: "com.drbaker.macshot.wallpaper-images", qos: .userInitiated)

    init(styleIndex: Int, wallpaperID: String?, padding: CGFloat, radius: CGFloat, shadow: CGFloat,
         wallpapers: [MacOSWallpaper] = MacOSWallpapers.installed) {
        gradients = GradientPickerView(selectedIndex: styleIndex)
        self.wallpapers = wallpapers
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: max(280, gradients.preferredSize.height + 90)))
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = styleIndex == -1 && wallpaperID != nil ? 1 : 0
        tabs.frame = NSRect(x: 12, y: bounds.height - 34, width: 296, height: 24)
        tabs.setAccessibilityLabel(L("Background type"))
        addSubview(tabs)

        let contentRect = NSRect(x: 8, y: 48, width: 304, height: bounds.height - 90)
        gradients.frame.origin = NSPoint(x: (bounds.width - gradients.frame.width) / 2,
                                         y: contentRect.maxY - gradients.frame.height)
        gradients.onSelect = { [weak self] index in
            self?.selectionGeneration += 1
            self?.loading.stopAnimation(nil)
            self?.onSelectGradient?(index)
        }
        gradients.onCustomImage = { [weak self] in self?.onCustomImage?() }
        addSubview(gradients)

        scrollView.frame = contentRect
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = gallery
        addSubview(scrollView)
        buildGallery(selectedID: wallpaperID)

        let label = NSTextField(labelWithString: L("Frame"))
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = screenshotForegroundColor
        label.frame = NSRect(x: 12, y: 17, width: 44, height: 18)
        addSubview(label)
        frames.target = self
        frames.action = #selector(frameChanged)
        frames.selectedSegment = -1
        for preset in [BeautifyFramePreset.compact, .roomy] where preset.matches(padding: padding, radius: radius, shadow: shadow) {
            frames.selectedSegment = preset.rawValue
        }
        frames.frame = NSRect(x: 62, y: 14, width: 186, height: 24)
        frames.setAccessibilityLabel(L("Frame spacing"))
        addSubview(frames)
        loading.style = .spinning
        loading.controlSize = .small
        loading.isDisplayedWhenStopped = false
        loading.frame = NSRect(x: 278, y: 17, width: 16, height: 16)
        addSubview(loading)
        updateTab()
    }

    required init?(coder: NSCoder) { fatalError() }
    var preferredSize: NSSize { frame.size }

    private func buildGallery(selectedID: String?) {
        let rows = (wallpapers.count + 2) / 3
        gallery.frame = NSRect(x: 0, y: 0, width: 292, height: max(scrollView.bounds.height, CGFloat(rows) * 80 + 8))
        if wallpapers.isEmpty {
            status.stringValue = L("No installed wallpapers found. Choose an image from Gradients.")
            status.font = .systemFont(ofSize: 12)
            status.textColor = screenshotForegroundColor
            status.maximumNumberOfLines = 3
            status.frame = NSRect(x: 12, y: gallery.bounds.height - 80, width: 268, height: 64)
            gallery.addSubview(status)
            return
        }
        for (index, wallpaper) in wallpapers.enumerated() {
            let x = CGFloat(index % 3) * 96 + 4
            let y = gallery.bounds.height - CGFloat(index / 3 + 1) * 80
            let button = NSButton(image: NSImage(), target: self, action: #selector(wallpaperClicked(_:)))
            button.tag = index
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.imageScaling = .scaleProportionallyUpOrDown
            button.frame = NSRect(x: x, y: y + 23, width: 88, height: 52)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.masksToBounds = true
            button.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            button.toolTip = wallpaper.title
            button.setAccessibilityLabel(wallpaper.title)
            button.state = wallpaper.id == selectedID ? .on : .off
            gallery.addSubview(button)
            buttons.append(button)
            let label = NSTextField(labelWithString: wallpaper.title)
            label.font = .systemFont(ofSize: 10)
            label.textColor = screenshotForegroundColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: x, y: y + 4, width: 88, height: 16)
            gallery.addSubview(label)
            queue.async { [weak self, weak button] in
                let image = MacOSWallpapers.image(for: wallpaper, maxDimension: 256).flatMap { image in
                    let ratio: CGFloat = 88 / 52
                    let width = min(CGFloat(image.width), CGFloat(image.height) * ratio)
                    let height = width / ratio
                    return image.cropping(to: CGRect(x: (CGFloat(image.width) - width) / 2,
                        y: (CGFloat(image.height) - height) / 2, width: width, height: height))
                }
                DispatchQueue.main.async {
                    guard let self, let button else { return }
                    if let image { button.image = NSImage(cgImage: image, size: NSSize(width: 88, height: 52)) }
                    else { button.isEnabled = false }
                    self.updateSelectionBorders()
                }
            }
        }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: gallery.bounds.height - scrollView.bounds.height))
    }

    private func updateSelectionBorders() {
        for button in buttons {
            button.layer?.borderWidth = button.state == .on ? 2 : 0
            button.layer?.borderColor = ToolbarLayout.accentColor.cgColor
        }
    }

    @objc private func tabChanged() { updateTab() }
    private func updateTab() {
        gradients.isHidden = tabs.selectedSegment != 0
        scrollView.isHidden = tabs.selectedSegment != 1
    }

    @objc private func frameChanged() {
        if let preset = BeautifyFramePreset(rawValue: frames.selectedSegment) { onSelectFrame?(preset) }
    }

    @objc private func wallpaperClicked(_ sender: NSButton) {
        guard wallpapers.indices.contains(sender.tag) else { return }
        selectionGeneration += 1
        let generation = selectionGeneration
        let wallpaper = wallpapers[sender.tag]
        loading.startAnimation(nil)
        queue.async { [weak self] in
            let image = MacOSWallpapers.image(for: wallpaper, maxDimension: 4096)
            let data = image.flatMap(MacOSWallpapers.pngData)
            DispatchQueue.main.async {
                guard let self, generation == self.selectionGeneration else { return }
                self.loading.stopAnimation(nil)
                guard let image, let data else { NSSound.beep(); return }
                for button in self.buttons { button.state = button === sender ? .on : .off }
                self.gradients.selectedIndex = -1
                self.updateSelectionBorders()
                self.onSelectWallpaper?(wallpaper, image, data)
            }
        }
    }
}
