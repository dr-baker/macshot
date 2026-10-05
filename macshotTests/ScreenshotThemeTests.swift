import AppKit
import XCTest

@MainActor
final class ScreenshotThemeTests: XCTestCase {
    private let light = NSAppearance(named: .aqua)!
    private let dark = NSAppearance(named: .darkAqua)!

    func testEveryPresetHasDistinctReadableLightAndDarkPalettes() throws {
        XCTAssertEqual(ToolbarThemePreset.all.map(\.id), ["default", "classic", "ocean", "sunset", "forest", "mono"])
        for preset in ToolbarThemePreset.all {
            let lightPalette = preset.palette(for: light)
            let darkPalette = preset.palette(for: dark)
            let lightBackground = try rgb(lightPalette.bg)
            let darkBackground = try rgb(darkPalette.bg)
            XCTAssertGreaterThan(lightBackground.relativeLuminance, 0.65, preset.name)
            XCTAssertLessThan(darkBackground.relativeLuminance, 0.12, preset.name)
            for palette in [lightPalette, darkPalette] {
                let foreground = try rgb(palette.icon).relativeLuminance
                let background = try rgb(palette.bg).relativeLuminance
                let contrast = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
                XCTAssertGreaterThanOrEqual(contrast, 4.5, preset.name)
            }
        }
    }

    func testSunsetKeepsPinkBackgroundsAndOrangeAccentsInBothAppearances() throws {
        let sunset = try preset("sunset")
        for appearance in [light, dark] {
            let palette = sunset.palette(for: appearance)
            let background = try rgb(palette.bg)
            let accent = try rgb(palette.accent)
            XCTAssertGreaterThan(background.red, background.blue)
            XCTAssertGreaterThan(background.blue, background.green)
            XCTAssertGreaterThan(accent.red - accent.green, 0.2)
            XCTAssertGreaterThan(accent.green - accent.blue, 0.15)
        }
    }

    func testExplicitAppearanceModeIgnoresCurrentPanelDrawingAppearance() throws {
        try withThemeDefaults {
            ToolbarLayout.colorMode = .light
            dark.performAsCurrentDrawingAppearance {
                XCTAssertEqual(ToolbarLayout.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)
            }
            ToolbarLayout.colorMode = .dark
            light.performAsCurrentDrawingAppearance {
                XCTAssertEqual(ToolbarLayout.appearance?.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
            }
            ToolbarLayout.colorMode = .system
            let expected = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) ?? .aqua
            XCTAssertEqual(ToolbarLayout.appearance?.bestMatch(from: [.aqua, .darkAqua]), expected)
        }
    }

    func testLegacySunsetColorsSelectItsNewAdaptivePaletteWithoutRewritingPreferences() throws {
        try withThemeDefaults {
            let legacy: [(String, NSColor)] = [
                ("toolbarAccentColor", NSColor(calibratedRed: 1, green: 0.55, blue: 0.20, alpha: 1)),
                ("toolbarIconColor", .white),
                ("toolbarBgColor", NSColor(calibratedRed: 0.15, green: 0.10, blue: 0.12, alpha: 1)),
            ]
            for (key, color) in legacy { UserDefaults.standard.set(try archive(color), forKey: key) }
            let stored = legacy.map { UserDefaults.standard.data(forKey: $0.0) }
            let sunset = try preset("sunset")
            XCTAssertEqual(ToolbarLayout.selectedThemePreset?.id, "sunset")
            ToolbarLayout.colorMode = .light
            assertPalette(ToolbarLayout.palette(for: light), equals: sunset.palette(for: light))
            ToolbarLayout.colorMode = .dark
            assertPalette(ToolbarLayout.palette(for: dark), equals: sunset.palette(for: dark))
            XCTAssertEqual(legacy.map { UserDefaults.standard.data(forKey: $0.0) }, stored)
            XCTAssertNil(UserDefaults.standard.object(forKey: "toolbarThemePreset"))
        }
    }

    func testUnrecognizedStoredCustomColorsRemainFixedAcrossAppearanceChanges() throws {
        try withThemeDefaults {
            let custom = ToolbarThemePreset.Palette(accent: color(0.13, 0.44, 0.61),
                icon: color(0.91, 0.96, 1), bg: color(0.12, 0.22, 0.35))
            for (key, value) in [("toolbarAccentColor", custom.accent), ("toolbarIconColor", custom.icon), ("toolbarBgColor", custom.bg)] {
                UserDefaults.standard.set(try archive(value), forKey: key)
            }
            XCTAssertNil(ToolbarLayout.selectedThemePreset)
            assertPalette(ToolbarLayout.palette(for: light), equals: custom)
            assertPalette(ToolbarLayout.palette(for: dark), equals: custom)
        }
    }

    func testEditingOneColorFreezesTheDisplayedPaletteAndDoesNotReinferAPreset() throws {
        try withThemeDefaults {
            let ocean = try preset("ocean")
            ToolbarLayout.colorMode = .light
            ToolbarLayout.applyThemePreset(ocean)
            let before = ToolbarLayout.palette(for: light)
            // Even an explicit edit back to the same color records custom intent.
            ToolbarLayout.saveAccentColor(before.accent)
            XCTAssertEqual(UserDefaults.standard.string(forKey: "toolbarThemePreset"), "custom")
            XCTAssertNil(ToolbarLayout.selectedThemePreset)
            ToolbarLayout.colorMode = .dark
            assertPalette(ToolbarLayout.palette(for: dark), equals: before)
            let changedBackground = color(0.2, 0.25, 0.3)
            ToolbarLayout.saveBgColor(changedBackground)
            let changed = ToolbarLayout.palette(for: dark)
            assertColor(changed.accent, equals: before.accent)
            assertColor(changed.icon, equals: before.icon)
            assertColor(changed.bg, equals: changedBackground)
        }
    }

    func testSystemAccentOverlayPreservesTheUnderlyingPresetAndCustomColors() throws {
        try withThemeDefaults {
            for isCustom in [false, true] {
                ToolbarLayout.colorMode = .light
                ToolbarLayout.applyThemePreset(try preset("sunset"))
                if isCustom { ToolbarLayout.saveBgColor(color(0.94, 0.90, 0.88)) }
                let before = ToolbarLayout.palette(for: light)
                let selected = ToolbarLayout.selectedThemePreset?.id
                let keys = ["toolbarThemePreset", "toolbarAccentColor", "toolbarIconColor", "toolbarBgColor"]
                let stored = keys.map { FieldDescriber.describe(UserDefaults.standard.object(forKey: $0) as Any) }
                ToolbarLayout.usesSystemAccent = true
                XCTAssertEqual(ToolbarLayout.selectedThemePreset?.id, selected)
                let systemLight = try rgb(ToolbarLayout.palette(for: light).bg).oklch
                let systemDark = try rgb(ToolbarLayout.palette(for: dark).bg).oklch
                XCTAssertEqual(systemLight.lightness, 0.96, accuracy: 0.00001)
                XCTAssertEqual(systemDark.lightness, 0.25, accuracy: 0.00001)
                XCTAssertEqual(keys.map { FieldDescriber.describe(UserDefaults.standard.object(forKey: $0) as Any) }, stored)
                ToolbarLayout.usesSystemAccent = false
                assertPalette(ToolbarLayout.palette(for: light), equals: before)
            }
        }
    }

    func testApplyingPresetAndEditingBackgroundLeaveSystemAccentModeDeliberately() throws {
        try withThemeDefaults {
            ToolbarLayout.usesSystemAccent = true
            ToolbarLayout.applyThemePreset(try preset("forest"))
            XCTAssertFalse(ToolbarLayout.usesSystemAccent)
            XCTAssertEqual(ToolbarLayout.selectedThemePreset?.id, "forest")
            ToolbarLayout.colorMode = .light
            ToolbarLayout.usesSystemAccent = true
            let displayed = ToolbarLayout.palette(for: light)
            let background = color(0.9, 0.91, 0.94)
            ToolbarLayout.saveBgColor(background)
            XCTAssertFalse(ToolbarLayout.usesSystemAccent)
            XCTAssertNil(ToolbarLayout.selectedThemePreset)
            let custom = ToolbarLayout.palette(for: dark)
            assertColor(custom.accent, equals: displayed.accent)
            assertColor(custom.icon, equals: displayed.icon)
            assertColor(custom.bg, equals: background)
        }
    }

    private func withThemeDefaults(_ body: () throws -> Void) rethrows {
        try withDefaults(["toolbarThemePreset": nil, "toolbarColorMode": nil, "toolbarUsesSystemAccent": nil,
            "toolbarAccentColor": nil, "toolbarIconColor": nil, "toolbarBgColor": nil], body)
    }

    private func preset(_ id: String) throws -> ToolbarThemePreset {
        try XCTUnwrap(ToolbarThemePreset.all.first { $0.id == id })
    }

    private func archive(_ color: NSColor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: false)
    }

    private func rgb(_ color: NSColor) throws -> ScreenshotThemeRGB {
        try XCTUnwrap(ScreenshotThemeRGB(color: color))
    }

    private func color(_ red: Double, _ green: Double, _ blue: Double) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private func assertPalette(_ actual: ToolbarThemePreset.Palette, equals expected: ToolbarThemePreset.Palette) {
        assertColor(actual.accent, equals: expected.accent)
        assertColor(actual.icon, equals: expected.icon)
        assertColor(actual.bg, equals: expected.bg)
    }

    private func assertColor(_ actual: NSColor, equals expected: NSColor,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let actual = ScreenshotThemeRGB(color: actual), let expected = ScreenshotThemeRGB(color: expected) else {
            XCTFail("Colors must resolve to sRGB", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.red, expected.red, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.green, expected.green, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.blue, expected.blue, accuracy: 0.000001, file: file, line: line)
    }
}

@MainActor
final class ScreenshotThemeColorTests: XCTestCase {
    func testReadableAccentsKeepHueAndReachCaptionContrast() {
        let accents = [ScreenshotThemeRGB(red: 1, green: 0.45, blue: 0.15),
                       .init(red: 0.2, green: 0.7, blue: 0.3),
                       .init(red: 0.55, green: 0.3, blue: 0.85),
                       .init(red: 0.48, green: 0.48, blue: 0.48)]
        for background in [ScreenshotThemeRGB(red: 1, green: 1, blue: 1),
                           .init(red: 0.15, green: 0.15, blue: 0.15)] {
            for accent in accents {
                let result = ScreenshotThemeForeground.readableAccent(accent, on: background)
                let a = result.relativeLuminance, b = background.relativeLuminance
                XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 6.99)
                XCTAssertTrue(result.isInGamut)
                if accent.oklch.chroma > 0.01 {
                    XCTAssertEqual(cos(result.oklch.hue - accent.oklch.hue), 1, accuracy: 0.001)
                }
                XCTAssertEqual(ScreenshotThemeForeground.readableAccent(result, on: background), result)
            }
        }
    }

    func testSRGBRoundTripsThroughOKLCHIncludingPrimariesAndNeutrals() {
        for color in [rgb(0, 0, 0), rgb(1, 1, 1), rgb(1, 0, 0), rgb(0, 1, 0), rgb(0, 0, 1), rgb(0.2, 0.4, 0.8)] {
            let result = color.oklch.sRGB
            XCTAssertEqual(result.red, color.red, accuracy: 0.00001)
            XCTAssertEqual(result.green, color.green, accuracy: 0.00001)
            XCTAssertEqual(result.blue, color.blue, accuracy: 0.00001)
        }
        let red = rgb(1, 0, 0).oklch
        XCTAssertEqual(red.lightness, 0.62795536, accuracy: 0.000001)
        XCTAssertEqual(red.chroma, 0.25768331, accuracy: 0.000001)
        XCTAssertEqual(red.hue * 180 / .pi, 29.233885, accuracy: 0.00001)
    }

    func testDerivedBackgroundsStayInGamutWithRestrainedChromaAndRetainAccentHue() {
        for accent in [rgb(1, 0, 0), rgb(0, 1, 0), rgb(0, 0, 1), rgb(1, 0.4, 0.1), rgb(0.2, 0.4, 0.8)] {
            for isDark in [false, true] {
                let result = ScreenshotThemeBackground.derive(from: accent, isDark: isDark)
                XCTAssertTrue(result.isInGamut)
                let color = result.oklch
                XCTAssertEqual(color.lightness, isDark ? 0.25 : 0.96, accuracy: 0.00001)
                XCTAssertLessThanOrEqual(color.chroma, (isDark ? 0.035 : 0.018) + 0.000001)
                let hueDelta = color.hue - accent.oklch.hue
                XCTAssertEqual(atan2(sin(hueDelta), cos(hueDelta)), 0, accuracy: 0.00001)
            }
        }
    }

    func testNeutralSystemAccentProducesNeutralBackgroundsWithReadableIcons() {
        for isDark in [false, true] {
            let neutral = rgb(0.5, 0.5, 0.5)
            let result = ScreenshotThemeBackground.derive(from: neutral, isDark: isDark)
            XCTAssertEqual(result.red, result.green, accuracy: 0.000001)
            XCTAssertEqual(result.green, result.blue, accuracy: 0.000001)
            let palette = ToolbarThemePreset.Palette.systemAccent(neutral, isDark: isDark)
            let foreground = ScreenshotThemeRGB(color: palette.icon)!.relativeLuminance
            let background = result.relativeLuminance
            XCTAssertGreaterThanOrEqual((max(foreground, background) + 0.05) / (min(foreground, background) + 0.05), 4.5)
        }
    }

    private func rgb(_ red: Double, _ green: Double, _ blue: Double) -> ScreenshotThemeRGB {
        ScreenshotThemeRGB(red: red, green: green, blue: blue)
    }
}
