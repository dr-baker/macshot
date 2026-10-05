import AppKit
import ObjectiveC
import XCTest

@MainActor
final class ScreenshotGlassWindowTests: XCTestCase {
    func testClearWindowAppearanceKeepsActualFocusAndClassicRestoresAppKitPolicy() throws {
        try requireNativeGlass()
        let window = ScreenshotGlassWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 100),
            styleMask: .borderless, backing: .buffered, defer: false)
        try assertAppearanceWithoutFocusChanges(window, base: NSWindow.self)
    }

    func testClearNonactivatingPanelAppearanceKeepsActualFocusAndClassicRestoresAppKitPolicy() throws {
        try requireNativeGlass()
        let panel = ScreenshotGlassPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        try assertAppearanceWithoutFocusChanges(panel, base: NSPanel.self)
    }

    private func requireNativeGlass() throws {
        try XCTSkipUnless(ScreenshotGlassAvailability.isAvailable,
            "Forced glass appearance requires the validated macOS 26 bridge")
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "Reduce Transparency selects Classic chrome")
    }

    private func assertAppearanceWithoutFocusChanges(_ window: NSWindow, base: AnyClass) throws {
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil)
        }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            ScreenshotPanelStyle(material: .classic).save()
            let content = ScreenshotPanelView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
            let focus = ScreenshotFocusProbeView(frame: NSRect(x: 10, y: 10, width: 40, height: 20))
            content.addSubview(focus)
            window.contentView = content
            XCTAssertTrue(window.makeFirstResponder(focus))
            let key = window.isKeyWindow
            let main = window.isMainWindow
            let canBecomeKey = window.canBecomeKey
            let canBecomeMain = window.canBecomeMain
            let visible = window.isVisible
            let responder = window.firstResponder

            ScreenshotPanelStyle(material: .clear).save()
            XCTAssertNotNil(content.renderedGlassConfiguration)
            for selector in appearanceSelectors {
                XCTAssertTrue(try query(window, implementationFrom: type(of: window), selector: selector), selector)
            }
            assertFocusUnchanged(window, key: key, main: main, canBecomeKey: canBecomeKey,
                canBecomeMain: canBecomeMain, visible: visible, responder: responder)

            ScreenshotPanelStyle(material: .classic).save()
            XCTAssertNil(content.renderedGlassConfiguration)
            for selector in appearanceSelectors {
                let actual = try query(window, implementationFrom: type(of: window), selector: selector)
                let expected = try query(window, implementationFrom: base, selector: selector)
                XCTAssertEqual(actual, expected, selector)
            }
            assertFocusUnchanged(window, key: key, main: main, canBecomeKey: canBecomeKey,
                canBecomeMain: canBecomeMain, visible: visible, responder: responder)
        }
    }

    private func assertFocusUnchanged(_ window: NSWindow, key: Bool, main: Bool, canBecomeKey: Bool,
                                     canBecomeMain: Bool, visible: Bool, responder: NSResponder?) {
        XCTAssertEqual(window.isKeyWindow, key)
        XCTAssertEqual(window.isMainWindow, main)
        XCTAssertEqual(window.canBecomeKey, canBecomeKey)
        XCTAssertEqual(window.canBecomeMain, canBecomeMain)
        XCTAssertEqual(window.isVisible, visible)
        XCTAssertTrue(window.firstResponder === responder)
    }

    private var appearanceSelectors: [String] {
        ["hasKeyAppearance", "_hasKeyAppearance", "_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus"]
    }

    private func query(_ window: NSWindow, implementationFrom base: AnyClass, selector name: String) throws -> Bool {
        let selector = NSSelectorFromString(name)
        let method = try XCTUnwrap(class_getInstanceMethod(base, selector), name)
        typealias Query = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Query.self)(window, selector)
    }
}

private final class ScreenshotFocusProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
