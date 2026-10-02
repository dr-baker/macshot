import AppKit

/// Native buttons keep keyboard focus, actions, and selection available to AppKit and VoiceOver.
@MainActor
final class StitchSeamStylePicker: NSView {
    var onSelectionChanged: ((StitchTransition) -> Void)?
    var selection: StitchTransition = .wave { didSet { syncButtons() } }
    var isEnabled = true { didSet { syncButtons() } }
    private var buttons: [NSButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.group)
        setAccessibilityLabel(L("Seam transition"))
        for (index, transition) in StitchTransition.allCases.enumerated() {
            let button = NSButton(title: Self.title(for: transition), target: self, action: #selector(choose(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("stitch.transition.\(transition.rawValue)")
            button.tag = index
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.focusRingType = .exterior
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.image = Self.previews[transition]
            button.imagePosition = .imageAbove
            button.imageScaling = .scaleProportionallyDown
            button.contentTintColor = ToolbarLayout.iconColor
            button.setAccessibilityLabel(button.title)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.borderWidth = 1
            addSubview(button)
            buttons.append(button)
        }
        syncButtons()
        needsLayout = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let spacing: CGFloat = 6
        let width = (bounds.width - spacing * CGFloat(buttons.count - 1)) / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * (width + spacing), y: 0, width: width, height: bounds.height)
        }
    }

    static func title(for transition: StitchTransition) -> String {
        switch transition {
        case .wave: return L("Wave")
        case .blend: return L("Blend")
        case .torn: return L("Torn")
        case .fold: return L("Fold")
        case .breakLine: return L("Break")
        }
    }

    private func syncButtons() {
        alphaValue = isEnabled ? 1 : 0.35
        for (index, button) in buttons.enumerated() {
            let selected = StitchTransition.allCases[index] == selection
            button.state = selected ? .on : .off
            button.isEnabled = isEnabled
            button.layer?.backgroundColor = (selected
                ? ToolbarLayout.accentColor.withAlphaComponent(0.18)
                : ToolbarLayout.iconColor.withAlphaComponent(0.035)).cgColor
            button.layer?.borderColor = (selected
                ? ToolbarLayout.accentColor
                : ToolbarLayout.iconColor.withAlphaComponent(0.14)).cgColor
        }
    }

    @objc private func choose(_ sender: NSButton) {
        guard isEnabled, StitchTransition.allCases.indices.contains(sender.tag) else { return }
        selection = StitchTransition.allCases[sender.tag]
        onSelectionChanged?(selection)
    }

    /// A small, neutral screenshot sample goes through the same seam renderer as the canvas and export.
    private static let previews: [StitchTransition: NSImage] = {
        func sample(brightness: CGFloat) -> CGImage? {
            guard let context = CGContext(data: nil, width: 128, height: 40, bitsPerComponent: 8,
                bytesPerRow: 128 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.setFillColor(NSColor(white: brightness, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 40))
            context.setFillColor(NSColor(white: 0.65, alpha: 1).cgColor)
            for (index, width) in [84, 104, 68].enumerated() {
                context.fill(CGRect(x: 12, y: 7 + index * 12, width: width, height: 3))
            }
            return context.makeImage()
        }
        guard let upper = sample(brightness: 0.95), let lower = sample(brightness: 0.88) else { return [:] }
        let pieces = [StitchPiece(image: upper), StitchPiece(image: lower, origin: CGPoint(x: 0, y: 40))]
        return Dictionary(uniqueKeysWithValues: StitchTransition.allCases.compactMap { transition in
            var style = StitchStyle()
            style.transition = transition
            style.color = NSColor(white: 0.24, alpha: 0.9)
            style.lineWidth = 2
            style.wave = 5
            style.blur = 3
            style.feather = 20
            guard let rendered = StitchRenderer.render(StitchDocument(pieces: pieces, style: style)) else { return nil }
            let image = NSImage(cgImage: rendered, size: NSSize(width: 56, height: 35))
            return (transition, image)
        })
    }()
}
