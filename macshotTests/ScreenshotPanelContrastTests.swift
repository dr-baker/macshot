import AppKit
import XCTest

@MainActor
final class ScreenshotPanelContrastTests: XCTestCase {
    func testLightAndDarkBackgroundsChooseOppositeForegroundsAndAppearances() {
        var style = ScreenshotPanelStyle()
        style.tintUsesTheme = false
        style.tint = nil
        assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: .white), white: false)
        assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: .black), white: true)
    }

    func testMidtonesUseLinearizedSRGBContrast() {
        var style = ScreenshotPanelStyle()
        style.tintUsesTheme = false
        style.tint = nil
        // These grays straddle the point where black and white provide equal contrast.
        assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: gray(0.45)), white: true)
        assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: gray(0.5)), white: false)
    }

    func testSaturatedTintsChooseForegroundByLuminance() {
        var style = ScreenshotPanelStyle()
        style.tintUsesTheme = false
        style.tintOpacity = 1
        for (tint, white) in [
            (ScreenshotPanelStyle.Tint(red: 1, green: 0, blue: 0), false),
            (.init(red: 0, green: 1, blue: 0), false),
            (.init(red: 0, green: 0, blue: 1), true),
            (.init(red: 1, green: 1, blue: 0), false)
        ] {
            style.tint = tint
            assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: .white), white: white)
        }
    }

    func testTintStrengthBlendsWithTheBaseBeforeChoosingForeground() {
        var style = ScreenshotPanelStyle()
        style.tintUsesTheme = false
        style.tint = .init(red: 0, green: 0, blue: 0)
        style.tintOpacity = 0.5
        assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: .white), white: false)
        style.tintOpacity = 0.75
        assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: .white), white: true)

        style.tint = .init(red: 1, green: 1, blue: 1)
        style.tintOpacity = 0.25
        assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: .black), white: true)
        style.tintOpacity = 0.5
        assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: .black), white: false)
    }

    func testClearedAndZeroStrengthTintLeaveTheBaseColorInControl() {
        var style = ScreenshotPanelStyle(material: .clear)
        style.tintUsesTheme = false
        style.tint = nil
        style.tintOpacity = 1
        assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: .white), white: false)
        style.tint = .init(red: 0, green: 0, blue: 0)
        style.tintOpacity = 0
        assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: .white), white: false)
    }

    func testThemeTintChangesContrastAndIgnoresTheStoredCustomTint() {
        var style = ScreenshotPanelStyle()
        style.tintUsesTheme = false
        style.tintOpacity = 1
        style.tint = .init(red: 1, green: 0, blue: 0)
        style.tintUsesTheme = true
        let darkTheme = color(0, 0, 1)
        let lightTheme = color(1, 1, 0)
        let dark = ScreenshotPanelContrast.resolve(style: style, baseColor: .white, themeColor: darkTheme)
        let light = ScreenshotPanelContrast.resolve(style: style, baseColor: .black, themeColor: lightTheme)
        assertContrast(dark, white: true)
        assertContrast(light, white: false)
        XCTAssertTrue(dark.backgroundColor.isEqual(darkTheme))
        XCTAssertTrue(light.backgroundColor.isEqual(lightTheme))

        style.tintOpacity = 0
        assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: .white, themeColor: darkTheme), white: false)
    }

    func testSelectedControlForegroundContrastsWithItsAccentFill() {
        assertColor(ScreenshotPanelContrast.foregroundColor(on: color(0.8, 0.7, 0.2)), white: false)
        assertColor(ScreenshotPanelContrast.foregroundColor(on: color(0.1, 0.2, 0.6)), white: true)
    }

    func testImportedInvalidStrengthCannotChangeTheContrastEstimate() {
        var style = ScreenshotPanelStyle()
        style.tintUsesTheme = false
        style.tint = .init(red: 0, green: 0, blue: 0)
        for strength in [Double.nan, .infinity, -1] {
            style.tintOpacity = strength
            assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: .white), white: false)
        }
        style.tintOpacity = 2
        assertContrast(ScreenshotPanelContrast.resolve(style: style, baseColor: .white), white: true)
    }

    private func assertContrast(_ contrast: ScreenshotPanelContrast, white: Bool,
                                file: StaticString = #filePath, line: UInt = #line) {
        assertColor(contrast.foregroundColor, white: white, file: file, line: line)
        XCTAssertEqual(contrast.appearanceName, white ? .darkAqua : .aqua, file: file, line: line)
    }

    private func assertColor(_ color: NSColor, white: Bool,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let color = color.usingColorSpace(.sRGB) else {
            XCTFail("Foreground must resolve to sRGB", file: file, line: line)
            return
        }
        let expected: CGFloat = white ? 1 : 0
        XCTAssertEqual(color.redComponent, expected, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(color.greenComponent, expected, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(color.blueComponent, expected, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001, file: file, line: line)
    }

    private func gray(_ value: CGFloat) -> NSColor { color(value, value, value) }
    private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
