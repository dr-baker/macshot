import AppKit

/// A foreground estimate from the configured panel color, with no screen sampling.
/// Resolve when the style or theme changes, then reuse the result while drawing.
struct ScreenshotPanelContrast {
    let foregroundColor: NSColor
    let appearanceName: NSAppearance.Name
    /// Classic draws this exact color; Clear uses it as a contrast estimate.
    let backgroundColor: NSColor

    /// Supply a concrete, appearance-resolved base color. Resolve the tint from
    /// the theme background when the user has selected the theme color.
    static func resolve(style: ScreenshotPanelStyle, baseColor: NSColor, themeColor: NSColor? = nil) -> Self {
        let style = style.normalized
        let base = RGB(baseColor)
        let background: RGB
        if !(style.material == .classic && style.tintUsesTheme),
           let tint = style.resolvedTint(themeColor: themeColor ?? ToolbarLayout.bgColor) {
            background = base.blended(with: RGB(red: tint.red, green: tint.green, blue: tint.blue),
                                      strength: style.tintOpacity)
        } else {
            background = base
        }
        return resolve(background: background)
    }

    /// Use this for the icon or label inside a selected control's accent fill.
    static func foregroundColor(on backgroundColor: NSColor) -> NSColor {
        resolve(background: RGB(backgroundColor)).foregroundColor
    }

    private static func resolve(background: RGB) -> Self {
        let luminance = background.relativeLuminance
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        if blackContrast >= whiteContrast {
            return Self(foregroundColor: .black, appearanceName: .aqua, backgroundColor: background.nsColor)
        }
        return Self(foregroundColor: .white, appearanceName: .darkAqua, backgroundColor: background.nsColor)
    }

    private struct RGB {
        let red: Double
        let green: Double
        let blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = Self.bounded(red)
            self.green = Self.bounded(green)
            self.blue = Self.bounded(blue)
        }

        init(_ color: NSColor) {
            guard let color = color.usingColorSpace(.sRGB) else {
                self.init(red: 0, green: 0, blue: 0)
                return
            }
            self.init(red: Double(color.redComponent), green: Double(color.greenComponent),
                      blue: Double(color.blueComponent))
        }

        func blended(with tint: Self, strength: Double) -> Self {
            let strength = Self.bounded(strength)
            return Self(red: red + (tint.red - red) * strength,
                        green: green + (tint.green - green) * strength,
                        blue: blue + (tint.blue - blue) * strength)
        }

        var relativeLuminance: Double {
            0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
        }

        var nsColor: NSColor {
            NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
        }

        private static func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }

        private static func bounded(_ component: Double) -> Double {
            component.isFinite ? min(max(component, 0), 1) : 0
        }
    }
}
