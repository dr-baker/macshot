import AppKit
import XCTest

@MainActor
final class ScreenshotSubmenuContrastTests: XCTestCase {
    func testStitchNativeControlsInheritTheirPanelsResolvedAppearance() throws {
        let panel = NSView(frame: .zero)
        let options = StitchOptionsView(frame: .zero)
        let control = NSPopUpButton(frame: .zero)
        panel.addSubview(options)
        options.addSubview(control)

        for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            panel.appearance = try XCTUnwrap(NSAppearance(named: name))
            XCTAssertEqual(options.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)
            XCTAssertEqual(control.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), name)
        }
    }
}
