import AppKit

/// The screenshot controls have three finishes and one shared tint preference.
struct ScreenshotPanelStyle: Codable, Equatable {
    enum Material: String, Codable, CaseIterable {
        case clear, regular, classic
        var title: String {
            switch self { case .clear: return "Clear"; case .regular: return "Regular"; case .classic: return "Classic" }
        }
    }

    struct Tint: Codable, Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init?(color: NSColor) {
            guard let color = color.usingColorSpace(.sRGB) else { return nil }
            self.init(red: Double(color.redComponent), green: Double(color.greenComponent), blue: Double(color.blueComponent))
        }

        var normalized: Self {
            Self(red: ScreenshotPanelStyle.bounded(red), green: ScreenshotPanelStyle.bounded(green),
                 blue: ScreenshotPanelStyle.bounded(blue))
        }

        var nsColor: NSColor {
            let value = normalized
            return NSColor(srgbRed: value.red, green: value.green, blue: value.blue, alpha: 1)
        }
    }

    // Retain the stored color choice when moving out of the developer material lab.
    static let defaultsKey = "stitchCaptureBarStyle"
    static let didChange = Notification.Name("ScreenshotPanelStyleDidChange")
    var material: Material
    var tint: Tint? = Tint(red: 0, green: 0, blue: 0)
    var tintOpacity: Double = 0.70
    var tintUsesTheme = true

    init(material: Material = .clear) {
        self.material = material
    }

    var normalized: Self {
        var result = self
        result.tint = tint?.normalized
        result.tintOpacity = Self.bounded(tintOpacity)
        return result
    }

    func resolvedTint(themeColor: NSColor) -> Tint? {
        tintUsesTheme ? Tint(color: themeColor)?.normalized : tint?.normalized
    }

    mutating func setTint(_ tint: Tint?) {
        self.tint = tint?.normalized
        tintUsesTheme = false
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value.normalized
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private static func bounded(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private enum CodingKeys: String, CodingKey {
        case material, tint, tintOpacity, tintUsesTheme
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Preserve supported finishes; retired experiments use Clear.
        self.init(material: Material(rawValue: c.decode(.material, or: "clear")) ?? .clear)
        tint = c.contains(.tint) ? c.decodeOptional(.tint) : tint
        tintOpacity = c.decode(.tintOpacity, or: tintOpacity)
        tintUsesTheme = c.decode(.tintUsesTheme, or: false)
        self = normalized
    }

    func encode(to encoder: Encoder) throws {
        let value = normalized
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value.material, forKey: .material)
        if let tint = value.tint { try c.encode(tint, forKey: .tint) }
        else { try c.encodeNil(forKey: .tint) }
        try c.encode(value.tintOpacity, forKey: .tintOpacity)
        try c.encode(value.tintUsesTheme, forKey: .tintUsesTheme)
    }
}
