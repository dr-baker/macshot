import AppKit

/// Keeps format selection inside the native save sheet and owns its callbacks.
@MainActor
final class StitchAnimationSavePanel: NSObject {
    struct Choice {
        let url: URL
        let format: StitchAnimationExporter.Format
    }
    private let panel: NSSavePanel
    private let formats = NSPopUpButton(frame: .zero, pullsDown: false)
    private var format: StitchAnimationExporter.Format = .gif

    init(panel: NSSavePanel = NSSavePanel()) {
        self.panel = panel
        super.init()
        panel.title = L("Save Animation")
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "Macshot Accordion.gif"
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 276, height: 34))
        let label = NSTextField(labelWithString: L("Format"))
        label.frame = NSRect(x: 0, y: 9, width: 60, height: 18)
        formats.addItems(withTitles: [L("Animated GIF"), L("MP4 video")])
        formats.frame = NSRect(x: 70, y: 5, width: 196, height: 26)
        formats.setAccessibilityLabel(L("Animation format"))
        formats.setAccessibilityIdentifier("stitch.animation.format")
        formats.target = self
        formats.action = #selector(formatChanged)
        accessory.addSubview(label)
        accessory.addSubview(formats)
        panel.accessoryView = accessory
    }

    func present(in window: NSWindow, completion: @escaping (Choice?) -> Void) {
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { completion(nil); return }
            // The panel resolves a typed extension before accepting the save.
            // Match that accepted file name even if the user edited it directly.
            let acceptedFormat = StitchAnimationExporter.Format(rawValue: url.pathExtension.lowercased()) ?? format
            completion(Choice(url: url, format: acceptedFormat))
        }
    }

    @objc private func formatChanged() {
        format = formats.indexOfSelectedItem == 1 ? .mp4 : .gif
        let previousName = panel.nameFieldStringValue as NSString
        let hasKnownExtension = StitchAnimationExporter.Format(rawValue: previousName.pathExtension.lowercased()) != nil
        let name = hasKnownExtension ? previousName.deletingPathExtension : previousName as String
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = name + "." + format.pathExtension
    }
}
