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
            XCTAssertEqual(button.contentTintColor, ToolbarLayout.accentColor)
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
            XCTAssertEqual(button.contentTintColor, ToolbarLayout.accentColor)
            button.isSelectedTab = false
            XCTAssertEqual(button.contentTintColor, .labelColor)
            XCTAssertEqual(button.accessibilityValue() as? Int, 0)
            XCTAssertFalse(button.isAccessibilitySelected())
        }
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
