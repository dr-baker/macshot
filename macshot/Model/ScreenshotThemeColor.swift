import AppKit

/// Encoded sRGB and OKLCH conversions use Björn Ottosson's published matrices.
/// https://bottosson.github.io/posts/oklab/
/// The sRGB transfer functions also follow CSS Color 4.
/// https://www.w3.org/TR/css-color-4/#color-conversion-code
struct ScreenshotThemeRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
    }

    var nsColor: NSColor {
        let value = clamped
        return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
    }

    var clamped: Self {
        Self(red: Self.bounded(red), green: Self.bounded(green), blue: Self.bounded(blue))
    }

    var isInGamut: Bool {
        [red, green, blue].allSatisfy { $0.isFinite && $0 >= -0.0000001 && $0 <= 1.0000001 }
    }

    var relativeLuminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    var oklch: ScreenshotThemeOKLCH {
        let r = Self.linear(red), g = Self.linear(green), b = Self.linear(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let labB = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let chroma = hypot(a, labB)
        return ScreenshotThemeOKLCH(lightness: lightness, chroma: chroma,
            hue: chroma < 0.000004 ? 0 : atan2(labB, a))
    }

    static func linear(_ value: Double) -> Double {
        let magnitude = abs(value)
        let sign = value < 0 ? -1.0 : 1.0
        return magnitude <= 0.04045 ? value / 12.92 : sign * pow((magnitude + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ value: Double) -> Double {
        let magnitude = abs(value)
        let sign = value < 0 ? -1.0 : 1.0
        return magnitude <= 0.0031308 ? 12.92 * value : sign * (1.055 * pow(magnitude, 1 / 2.4) - 0.055)
    }

    private static func bounded(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

struct ScreenshotThemeOKLCH: Equatable {
    var lightness: Double
    var chroma: Double
    /// Hue in radians. Neutral colors use zero because their hue is undefined.
    var hue: Double

    var sRGB: ScreenshotThemeRGB {
        let a = chroma * cos(hue), b = chroma * sin(hue)
        let l = lightness + 0.3963377774 * a + 0.2158037573 * b
        let m = lightness - 0.1055613458 * a - 0.0638541728 * b
        let s = lightness - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        return ScreenshotThemeRGB(
            red: ScreenshotThemeRGB.encoded(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
            green: ScreenshotThemeRGB.encoded(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
            blue: ScreenshotThemeRGB.encoded(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3))
    }

    /// Reduce chroma while retaining lightness and hue, rather than clipping
    /// individual RGB channels and shifting the background's color.
    var gamutMappedSRGB: ScreenshotThemeRGB {
        if sRGB.isInGamut { return sRGB.clamped }
        var lower = 0.0
        var upper = chroma
        var result = ScreenshotThemeOKLCH(lightness: lightness, chroma: 0, hue: hue).sRGB
        for _ in 0..<14 {
            let candidate = ScreenshotThemeOKLCH(lightness: lightness, chroma: (lower + upper) / 2, hue: hue)
            let rgb = candidate.sRGB
            if rgb.isInGamut {
                lower = candidate.chroma
                result = rgb
            } else {
                upper = candidate.chroma
            }
        }
        return result.clamped
    }
}

enum ScreenshotThemeBackground {
    /// The system accent supplies hue. The panel stays quiet by using a small
    /// fraction of its chroma at a fixed light or dark perceptual lightness.
    static func derive(from accent: ScreenshotThemeRGB, isDark: Bool) -> ScreenshotThemeRGB {
        let color = accent.clamped.oklch
        let chroma = min(color.chroma * (isDark ? 0.22 : 0.15), isDark ? 0.035 : 0.018)
        return ScreenshotThemeOKLCH(lightness: isDark ? 0.25 : 0.96, chroma: chroma,
            hue: color.hue).gamutMappedSRGB
    }
}

/// Text needs a stronger version of an accent than a filled control does.
/// Keep its hue and change only perceptual lightness, reducing chroma only when
/// necessary to stay in sRGB. This runs on appearance changes, never in draw().
enum ScreenshotThemeForeground {
    static func readableAccent(_ accent: ScreenshotThemeRGB, on background: ScreenshotThemeRGB) -> ScreenshotThemeRGB {
        let accent = accent.clamped
        let background = background.clamped
        func contrast(_ color: ScreenshotThemeRGB) -> Double {
            let a = color.relativeLuminance, b = background.relativeLuminance
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
        let black = ScreenshotThemeRGB(red: 0, green: 0, blue: 0)
        let white = ScreenshotThemeRGB(red: 1, green: 1, blue: 1)
        let endpoint = contrast(white) > contrast(black) ? white : black
        // Aim for 7:1 for the small toolbar captions. Midtone custom backgrounds
        // may only permit the stronger of black or white.
        let target = min(7, contrast(endpoint))
        guard contrast(accent) < target else { return accent }
        let color = accent.oklch
        let endLightness = endpoint.red
        var lower = 0.0, upper = 1.0
        var result = endpoint
        for _ in 0..<18 {
            let fraction = (lower + upper) / 2
            let candidate = ScreenshotThemeOKLCH(
                lightness: color.lightness + (endLightness - color.lightness) * fraction,
                chroma: color.chroma, hue: color.hue).gamutMappedSRGB
            if contrast(candidate) >= target {
                upper = fraction
                result = candidate
            } else {
                lower = fraction
            }
        }
        return result
    }
}
