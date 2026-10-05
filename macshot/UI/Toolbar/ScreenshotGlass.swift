import AppKit

/// The screenshot chrome uses native Clear and Regular glass with a shared tint.
/// Its active appearance comes from the window bridge, rather than extra effects.
struct ScreenshotGlassConfiguration: Equatable {
    var material: ScreenshotPanelStyle.Material
    var tint: ScreenshotPanelStyle.Tint?
    var tintOpacity: Double
    var cornerRadius: CGFloat
}

enum ScreenshotGlassAvailability {
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) {
            return ScreenshotGlassWindow.supportedAppearance && ScreenshotGlassPanel.supportedAppearance
        }
        return false
    }
}

extension ScreenshotPanelStyle {
    var glassConfiguration: ScreenshotGlassConfiguration? {
        guard material != .classic, ScreenshotGlassAvailability.isAvailable else { return nil }
        let value = normalized
        return ScreenshotGlassConfiguration(material: material, tint: value.resolvedTint(themeColor: ToolbarLayout.bgColor),
            tintOpacity: value.tintOpacity, cornerRadius: ToolbarLayout.cornerRadius)
    }
}
