import AppKit

/// Keeps format selection inside the native save sheet and owns its callbacks.
@MainActor
final class StitchAnimationSavePanel: NSObject {
    struct Choice {
        let url: URL
        let format: StitchAnimationExporter.Format
    }
    private let panel = NSSavePanel()
    private let formats = NSPopUpButton(frame: .zero, pullsDown: false)
    private var format: StitchAnimationExporter.Format = .mp4

    func present(in window: NSWindow, completion: @escaping (Choice?) -> Void) {
        panel.title = L("Save Animation")
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "Macshot Accordion.mp4"
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 276, height: 34))
        let label = NSTextField(labelWithString: L("Format"))
        label.frame = NSRect(x: 0, y: 9, width: 60, height: 18)
        formats.addItems(withTitles: [L("MP4 video"), L("Animated GIF")])
        formats.frame = NSRect(x: 70, y: 5, width: 196, height: 26)
        formats.setAccessibilityLabel(L("Animation format"))
        formats.target = self
        formats.action = #selector(formatChanged)
        accessory.addSubview(label)
        accessory.addSubview(formats)
        panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { [self] response in
            guard response == .OK, let url = panel.url else { completion(nil); return }
            completion(Choice(url: url, format: format))
        }
    }

    @objc private func formatChanged() {
        format = formats.indexOfSelectedItem == 1 ? .gif : .mp4
        let previousName = panel.nameFieldStringValue as NSString
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = previousName.deletingPathExtension + "." + format.pathExtension
    }
}
