import AppKit

/// Uses the standard capture selector while preserving the original display pixels.
@MainActor
final class StitchRegionSelection {
    private let capture: ScreenCapture
    private let controller: OverlayWindowController
    var onPick: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    init(capture: ScreenCapture) {
        self.capture = capture
        controller = OverlayWindowController(capture: capture)
    }

    var windowNumber: CGWindowID { controller.windowNumber }

    func show() {
        controller.setSelectionOnlyMode(onSelect: { [weak self] rect in
            guard let self else { return }
            let size = self.capture.screen.frame.size
            let image = self.capture.image
            let sx = CGFloat(image.width) / size.width
            let sy = CGFloat(image.height) / size.height
            let pixels = CGRect(x: rect.minX * sx,
                                y: (size.height - rect.maxY) * sy,
                                width: rect.width * sx, height: rect.height * sy)
                .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            self.dismiss()
            self.onPick?(pixels)
        }, onCancel: { [weak self] in self?.onCancel?() })
        controller.showOverlay()
    }

    // These selectors are created for each fresh screen image, unlike the base
    // app's pooled overlays. Close their windows rather than leaving idle panels.
    func dismiss() { controller.tearDown() }
}
