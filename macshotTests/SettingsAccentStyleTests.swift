import AppKit
import XCTest

@MainActor
final class SettingsAccentStyleTests: XCTestCase {
    func testCustomAccentChangesNativeHooksAndSystemModeRestoresTheirOriginalColors() {
        let root = NSView(frame: .zero)
        let nested = NSView(frame: .zero)
        root.addSubview(nested)
        let slider = NSSlider(value: 0.4, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.isEnabled = false
        slider.trackFillColor = .controlAccentColor
        let button = NSButton(title: "Save", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.bezelColor = .controlAccentColor
        let segments = NSSegmentedControl(labels: ["Light", "Dark"], trackingMode: .selectOne,
                                         target: nil, action: nil)
        segments.selectedSegment = 1
        segments.selectedSegmentBezelColor = .controlAccentColor
        for control in [slider, button, segments] as [NSView] { nested.addSubview(control) }
        let originalSlider = slider.trackFillColor
        let originalButton = button.bezelColor
        let originalSegment = segments.selectedSegmentBezelColor

        SettingsAccentStyle.apply(to: root, accentColor: .systemOrange)
        XCTAssertEqual(slider.trackFillColor, .systemOrange)
        XCTAssertEqual(button.bezelColor, .systemOrange)
        XCTAssertEqual(segments.selectedSegmentBezelColor, .systemOrange)
        SettingsAccentStyle.apply(to: root, accentColor: .systemPurple)
        XCTAssertEqual(slider.trackFillColor, .systemPurple)
        XCTAssertEqual(button.bezelColor, .systemPurple)
        XCTAssertEqual(segments.selectedSegmentBezelColor, .systemPurple)
        XCTAssertFalse(slider.isEnabled)
        XCTAssertEqual(slider.doubleValue, 0.4)
        XCTAssertEqual(segments.selectedSegment, 1)

        SettingsAccentStyle.apply(to: root, accentColor: nil)
        XCTAssertEqual(slider.trackFillColor, originalSlider)
        XCTAssertEqual(button.bezelColor, originalButton)
        XCTAssertEqual(segments.selectedSegmentBezelColor, originalSegment)
    }

    func testBorderlessActionsFollowAccentWithoutReplacingExplicitLinkTint() {
        let root = NSView(frame: .zero)
        let action = NSButton(title: "Reset", target: nil, action: nil)
        action.isBordered = false
        let link = NSButton(title: "Help", target: nil, action: nil)
        link.isBordered = false
        link.contentTintColor = .linkColor
        root.addSubview(action)
        root.addSubview(link)

        SettingsAccentStyle.apply(to: root, accentColor: .systemOrange)
        XCTAssertEqual(action.contentTintColor, .systemOrange)
        XCTAssertEqual(link.contentTintColor, .linkColor)
        SettingsAccentStyle.apply(to: root, accentColor: nil)
        XCTAssertNil(action.contentTintColor)
        XCTAssertEqual(link.contentTintColor, .linkColor)
    }

    func testNativeCheckboxAccentPreservesStateAndContentWhileScreenshotControlsStayIndependent() {
        let root = NSView(frame: .zero)
        let checkbox = SettingsAccentStyle.checkbox(title: "Enabled", target: nil, action: nil)
        checkbox.state = .on
        let originalBezel = checkbox.bezelColor
        let originalContent = checkbox.contentTintColor
        let panel = ScreenshotPanelView(frame: .zero)
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.trackFillColor = .systemGreen
        panel.addSubview(slider)
        root.addSubview(checkbox)
        root.addSubview(panel)

        SettingsAccentStyle.apply(to: root, accentColor: .systemOrange)
        XCTAssertEqual(checkbox.bezelColor, .systemOrange)
        XCTAssertEqual(checkbox.contentTintColor, originalContent)
        XCTAssertEqual(checkbox.state, .on)
        XCTAssertEqual(checkbox.title, "Enabled")
        XCTAssertEqual(slider.trackFillColor, .systemGreen)
        SettingsAccentStyle.apply(to: root, accentColor: nil)
        XCTAssertEqual(checkbox.bezelColor, originalBezel)
        XCTAssertEqual(checkbox.contentTintColor, originalContent)
        XCTAssertEqual(checkbox.state, .on)
    }
}
