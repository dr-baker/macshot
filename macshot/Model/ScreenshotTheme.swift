import AppKit

enum ToolbarThemeColorMode: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    private static let lightAppearance = NSAppearance(named: .aqua)!
    private static let darkAppearance = NSAppearance(named: .darkAqua)!

    func appearance(system: NSAppearance?) -> NSAppearance {
        switch self {
        case .system:
            return system?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? Self.darkAppearance : Self.lightAppearance
        case .light: return Self.lightAppearance
        case .dark: return Self.darkAppearance
        }
    }
}

struct ToolbarThemePreset: Equatable {
    struct Palette: Equatable {
        let accent: NSColor
        let icon: NSColor
        let bg: NSColor

        static func systemAccent(_ accent: ScreenshotThemeRGB, isDark: Bool) -> Self {
            let background = ScreenshotThemeBackground.derive(from: accent, isDark: isDark)
            let luminance = background.relativeLuminance
            let icon: NSColor = (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05) ? .black : .white
            return Self(accent: accent.nsColor, icon: icon, bg: background.nsColor)
        }

        fileprivate func matches(_ other: Self) -> Bool {
            Self.close(accent, other.accent) && Self.close(icon, other.icon) && Self.close(bg, other.bg)
        }

        private static func close(_ a: NSColor, _ b: NSColor) -> Bool {
            guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
            return abs(a.redComponent - b.redComponent) < 0.01
                && abs(a.greenComponent - b.greenComponent) < 0.01
                && abs(a.blueComponent - b.blueComponent) < 0.01
                && abs(a.alphaComponent - b.alphaComponent) < 0.01
        }
    }

    let id: String
    let name: String
    private let light: Palette
    private let dark: Palette
    private let legacy: Palette

    func palette(for appearance: NSAppearance) -> Palette {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }

    static let all: [Self] = [
        Self(id: "default", name: "Default",
            light: Palette(accent: rgb(0.55, 0.30, 0.85), icon: rgb(0.18, 0.16, 0.22), bg: rgb(0.965, 0.950, 0.995)),
            dark: Palette(accent: rgb(0.55, 0.30, 0.85), icon: .white, bg: rgb(0.12, 0.12, 0.12)),
            legacy: Palette(accent: calibrated(0.55, 0.30, 0.85), icon: .white, bg: NSColor(white: 0.12, alpha: 1))),
        Self(id: "classic", name: "Classic",
            light: Palette(accent: rgb(0.00, 0.48, 1.00), icon: rgb(0.12, 0.15, 0.18), bg: rgb(0.955, 0.970, 0.995)),
            dark: Palette(accent: rgb(0.00, 0.48, 1.00), icon: .white, bg: rgb(0.12, 0.12, 0.12)),
            legacy: Palette(accent: calibrated(0.00, 0.48, 1.00), icon: .white, bg: NSColor(white: 0.12, alpha: 1))),
        Self(id: "ocean", name: "Ocean",
            light: Palette(accent: rgb(0.08, 0.49, 0.58), icon: rgb(0.06, 0.20, 0.24), bg: rgb(0.920, 0.975, 0.985)),
            dark: Palette(accent: rgb(0.20, 0.70, 0.75), icon: .white, bg: rgb(0.08, 0.12, 0.18)),
            legacy: Palette(accent: calibrated(0.20, 0.70, 0.75), icon: .white, bg: calibrated(0.08, 0.12, 0.18))),
        Self(id: "sunset", name: "Sunset",
            light: Palette(accent: rgb(0.96, 0.43, 0.16), icon: rgb(0.30, 0.12, 0.19), bg: rgb(0.995, 0.890, 0.900)),
            dark: Palette(accent: rgb(1.00, 0.60, 0.28), icon: rgb(0.96, 0.90, 0.92), bg: rgb(0.24, 0.145, 0.18)),
            legacy: Palette(accent: calibrated(1.00, 0.55, 0.20), icon: .white, bg: calibrated(0.15, 0.10, 0.12))),
        Self(id: "forest", name: "Forest",
            light: Palette(accent: rgb(0.10, 0.51, 0.28), icon: rgb(0.11, 0.20, 0.14), bg: rgb(0.930, 0.975, 0.945)),
            dark: Palette(accent: rgb(0.30, 0.75, 0.45), icon: .white, bg: rgb(0.08, 0.14, 0.10)),
            legacy: Palette(accent: calibrated(0.30, 0.75, 0.45), icon: .white, bg: calibrated(0.08, 0.14, 0.10))),
        Self(id: "mono", name: "Mono",
            light: Palette(accent: rgb(0.30, 0.30, 0.30), icon: rgb(0.15, 0.15, 0.15), bg: rgb(0.96, 0.96, 0.965)),
            dark: Palette(accent: rgb(0.75, 0.75, 0.77), icon: .white, bg: rgb(0.10, 0.10, 0.10)),
            legacy: Palette(accent: NSColor(white: 0.30, alpha: 1), icon: .white, bg: NSColor(white: 0.10, alpha: 1))),
    ]

    fileprivate static func matching(_ palette: Palette) -> Self? {
        all.first { $0.legacy.matches(palette) || $0.light.matches(palette) || $0.dark.matches(palette) }
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func calibrated(_ red: Double, _ green: Double, _ blue: Double) -> NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }
}

/// Decode stored custom colors only after their data changes. Presets remain
/// adaptive; explicitly edited colors remain fixed when appearance changes.
final class ToolbarThemePreferences {
    static let shared = ToolbarThemePreferences()
    private let defaults = UserDefaults.standard
    private var cachedSelection: (key: StoredKey, value: Selection)?
    private var cachedSystemPalette: (key: SystemKey, value: ToolbarThemePreset.Palette)?

    private enum Selection {
        case preset(ToolbarThemePreset)
        case custom(ToolbarThemePreset.Palette)
    }

    private struct StoredKey: Equatable {
        var presetID: String?
        var accent: Data?
        var icon: Data?
        var background: Data?
    }

    private struct SystemKey: Equatable {
        var accent: ScreenshotThemeRGB
        var isDark: Bool
    }

    var selectedPreset: ToolbarThemePreset? {
        if case .preset(let preset) = selection { return preset }
        return nil
    }

    func palette(for appearance: NSAppearance, usesSystemAccent: Bool) -> ToolbarThemePreset.Palette {
        if usesSystemAccent {
            var accent = ScreenshotThemeRGB(red: 0, green: 0.48, blue: 1)
            appearance.performAsCurrentDrawingAppearance {
                accent = ScreenshotThemeRGB(color: .controlAccentColor)?.clamped ?? accent
            }
            let key = SystemKey(accent: accent, isDark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            if let cachedSystemPalette, cachedSystemPalette.key == key { return cachedSystemPalette.value }
            let palette = ToolbarThemePreset.Palette.systemAccent(accent, isDark: key.isDark)
            cachedSystemPalette = (key, palette)
            return palette
        }
        switch selection {
        case .preset(let preset): return preset.palette(for: appearance)
        case .custom(let palette): return palette
        }
    }

    func apply(_ preset: ToolbarThemePreset) {
        defaults.set(preset.id, forKey: "toolbarThemePreset")
        defaults.set(false, forKey: "toolbarUsesSystemAccent")
        for key in ["toolbarAccentColor", "toolbarIconColor", "toolbarBgColor"] { defaults.removeObject(forKey: key) }
    }

    func saveCustom(_ palette: ToolbarThemePreset.Palette) {
        let values = [("toolbarAccentColor", palette.accent), ("toolbarIconColor", palette.icon), ("toolbarBgColor", palette.bg)]
        let data = values.compactMap { try? NSKeyedArchiver.archivedData(withRootObject: $0.1, requiringSecureCoding: false) }
        guard data.count == values.count else { return }
        for (value, archived) in zip(values, data) { defaults.set(archived, forKey: value.0) }
        defaults.set("custom", forKey: "toolbarThemePreset")
        defaults.set(false, forKey: "toolbarUsesSystemAccent")
    }

    func reset() {
        for key in ["toolbarThemePreset", "toolbarAccentColor", "toolbarIconColor", "toolbarBgColor", "toolbarUsesSystemAccent"] {
            defaults.removeObject(forKey: key)
        }
    }

    private var selection: Selection {
        let key = StoredKey(presetID: defaults.string(forKey: "toolbarThemePreset"),
            accent: defaults.data(forKey: "toolbarAccentColor"), icon: defaults.data(forKey: "toolbarIconColor"),
            background: defaults.data(forKey: "toolbarBgColor"))
        if let cachedSelection, cachedSelection.key == key { return cachedSelection.value }
        let value: Selection
        if let preset = ToolbarThemePreset.all.first(where: { $0.id == key.presetID }) {
            value = .preset(preset)
        } else {
            let palette = ToolbarThemePreset.Palette(
                accent: decode(key.accent) ?? ToolbarLayout.defaultAccentColor,
                icon: decode(key.icon) ?? ToolbarLayout.defaultIconColor,
                bg: decode(key.background) ?? ToolbarLayout.defaultBgColor)
            if key.presetID == "custom" {
                value = .custom(palette)
            } else if key.accent == nil && key.icon == nil && key.background == nil {
                value = .preset(ToolbarThemePreset.all[0])
            } else if let preset = ToolbarThemePreset.matching(palette) {
                value = .preset(preset)
            } else {
                value = .custom(palette)
            }
        }
        cachedSelection = (key, value)
        return value
    }

    private func decode(_ data: Data?) -> NSColor? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }
}
