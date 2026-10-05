import AppKit
import XCTest

@MainActor
final class SettingsToolbarButtonTests: XCTestCase {
    func testSelectedTabTracksAppAccentWithoutReplacingNativeActions() throws {
        _ = NSApplication.shared
        try withDefaults(["toolbarThemePreset": "sunset", "toolbarColorMode": "light", "toolbarUsesSystemAccent": false]) {
            let receiver = SettingsTabActionProbe()
            let button = SettingsToolbarButton(itemIdentifier: .init("appearance"), title: "Appearance",
                image: NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil),
                target: receiver, action: #selector(SettingsTabActionProbe.select(_:)))
            let item = button.makeToolbarItem()
            XCTAssertTrue(item.view === button)
            button.isSelectedTab = true
            assertSelectedContrast(button)
            XCTAssertEqual(button.accessibilityValue() as? Int, 1)
            XCTAssertTrue(button.isAccessibilitySelected())
            button.performClick(nil)
            XCTAssertTrue(receiver.sender === button)
            receiver.sender = nil
            let overflow = try XCTUnwrap(item.menuFormRepresentation)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(overflow.action), to: overflow.target, from: overflow))
            XCTAssertTrue(receiver.sender === button)
            XCTAssertEqual(button.itemIdentifier.rawValue, "appearance")
            ToolbarLayout.usesSystemAccent = true
            button.refreshAppearance()
            assertSelectedContrast(button)
            button.isSelectedTab = false
            XCTAssertEqual(button.contentTintColor, .secondaryLabelColor)
            XCTAssertEqual(button.accessibilityValue() as? Int, 0)
            XCTAssertFalse(button.isAccessibilitySelected())
        }
    }

    func testGraySelectedTabStaysReadableInLightAndDarkAppearances() throws {
        _ = NSApplication.shared
        try withDefaults(["toolbarThemePreset": "custom", "toolbarAccentColor":
            try NSKeyedArchiver.archivedData(withRootObject: NSColor(srgbRed: 0.48, green: 0.48, blue: 0.48, alpha: 1),
                requiringSecureCoding: false), "toolbarUsesSystemAccent": false]) {
            let button = SettingsToolbarButton(itemIdentifier: .init("appearance"), title: "Appearance",
                image: nil, target: nil, action: nil)
            button.isSelectedTab = true
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                button.appearance = NSAppearance(named: name)
                button.refreshAppearance()
                assertSelectedContrast(button)
            }
        }
    }

    private func assertSelectedContrast(_ button: SettingsToolbarButton,
                                        file: StaticString = #filePath, line: UInt = #line) {
        var background = NSColor.windowBackgroundColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
        }
        let foreground = ScreenshotThemeRGB(color: button.contentTintColor!)!.relativeLuminance
        let surface = ScreenshotThemeRGB(color: background)!.relativeLuminance
        XCTAssertGreaterThanOrEqual((max(foreground, surface) + 0.05) / (min(foreground, surface) + 0.05),
            6.99, file: file, line: line)
    }

    func testTranslatedTabTitleDeterminesItsWidth() {
        let button = SettingsToolbarButton(itemIdentifier: .init("capture"), title: "Bildschirmaufnahme",
            image: nil, target: nil, action: nil)
        let titleWidth = (button.title as NSString).size(withAttributes: [.font: button.font!]).width
        XCTAssertGreaterThan(button.intrinsicContentSize.width, titleWidth)
        XCTAssertEqual(button.accessibilityLabel(), "Bildschirmaufnahme")
    }
}

@MainActor
private final class SettingsTabActionProbe: NSObject {
    var sender: NSButton?
    @objc func select(_ sender: NSButton) { self.sender = sender }
}
