import AppKit
import XCTest

@MainActor
final class ScreenshotMovableSubmenuTests: XCTestCase {
    func testEveryFinishKeepsOversizedOptionsInOneMovableScrollablePanel() throws {
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            for material in ScreenshotPanelStyle.Material.allCases {
                ScreenshotPanelStyle(material: material).save()
                let (window, root, anchor) = fixture(height: 300)
                defer { PopoverHelper.dismiss(restoreFocus: false); window.close() }
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
                let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
                PopoverHelper.show(content, size: content.frame.size, relativeTo: anchor.bounds,
                                   of: anchor, preferredEdge: .maxY)
                let panel = try XCTUnwrap(root.subviews.compactMap { $0 as? ScreenshotPanelView }.first {
                    $0.identifier?.rawValue == "screenshot.submenu"
                })
                let grip = try XCTUnwrap(panel.subviews.compactMap { $0 as? ScreenshotSubmenuDragHandle }.first)
                let scroll = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSScrollView }.first)
                XCTAssertTrue(root.bounds.insetBy(dx: 8, dy: 8).contains(panel.frame))
                XCTAssertTrue(scroll.hasVerticalScroller)
                XCTAssertTrue(scroll.documentView === content)
                XCTAssertTrue(content.window === window)
                XCTAssertEqual(grip.accessibilityLabel(), L("Move tool options"))
                XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windowsBefore)
                if material == .classic { XCTAssertNil(panel.renderedGlassConfiguration) }
                let point = root.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), from: grip)
                XCTAssertTrue(PopoverHelper.hitTestInline(at: point, in: root) === grip)
            }
        }
    }

    func testMovingOptionsPreservesControlsAndClampsTheGripAtEveryEdge() throws {
        let (window, root, anchor) = fixture()
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.frame = NSRect(x: 16, y: 80, width: 200, height: 20)
        content.addSubview(slider)
        let presenter = try makePresenter(content: content, anchor: anchor)
        defer { presenter.dismiss(restoreFocus: false) }
        let grip = try handle(in: presenter)
        let initial = presenter.wrapper.frame
        try drag(grip, by: NSSize(width: -60, height: 40), in: root, window: window)
        XCTAssertTrue(presenter.isManuallyPositioned)
        XCTAssertEqual(presenter.wrapper.frame.minX, initial.minX - 60, accuracy: 0.01)
        XCTAssertEqual(presenter.wrapper.frame.maxY, initial.maxY + 40, accuracy: 0.01)
        XCTAssertTrue(content.subviews.first === slider)
        XCTAssertEqual(slider.doubleValue, 0.5)
        for offset in [NSSize(width: 10000, height: 10000), NSSize(width: -10000, height: -10000),
                       NSSize(width: 10000, height: 0), NSSize(width: 0, height: 10000)] {
            try drag(grip, by: offset, in: root, window: window)
            XCTAssertTrue(root.bounds.insetBy(dx: 8, dy: 8).contains(presenter.wrapper.frame))
            XCTAssertEqual(presenter.wrapper.frame.size, initial.size, "Moving to an edge must keep all fitting controls visible")
        }
    }

    func testMovingAnEdgeViewportRestoresItsFullSizeWithoutMovingTheGrip() throws {
        let (window, root, anchor) = fixture(optionsY: 180)
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 350))
        let presenter = try makePresenter(content: content, anchor: anchor)
        defer { presenter.dismiss(restoreFocus: false) }
        let grip = try handle(in: presenter)
        let initial = presenter.wrapper.frame
        XCTAssertLessThan(initial.height, content.frame.height + ScreenshotSubmenuPresenter.handleHeight)
        try drag(grip, by: NSSize(width: 16, height: -20), in: root, window: window)
        XCTAssertEqual(presenter.wrapper.frame.height, 368, accuracy: 0.01)
        XCTAssertEqual(presenter.wrapper.frame.minX, initial.minX + 16, accuracy: 0.01)
        XCTAssertEqual(presenter.wrapper.frame.maxY, initial.maxY - 20, accuracy: 0.01)
        let scroll = try viewport(in: presenter)
        XCTAssertFalse(scroll.hasVerticalScroller)
    }

    func testManualPlacementKeepsItsTopLeftWhileOptionsGrowShrinkAndScroll() throws {
        let (window, root, anchor) = fixture()
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let field = NSTextField(string: "14")
        field.frame = NSRect(x: 12, y: 80, width: 80, height: 20)
        content.addSubview(field)
        let presenter = try makePresenter(content: content, anchor: anchor)
        defer { presenter.dismiss(restoreFocus: false) }
        try drag(try handle(in: presenter), by: NSSize(width: -50, height: 100), in: root, window: window)
        let x = presenter.wrapper.frame.minX
        let top = presenter.wrapper.frame.maxY
        field.selectText(nil)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        for height in [CGFloat(320), 100, 700, 120] {
            XCTAssertTrue(presenter.resize(content, to: NSSize(width: 240, height: height)))
            XCTAssertEqual(presenter.wrapper.frame.minX, x, accuracy: 0.01)
            XCTAssertEqual(presenter.wrapper.frame.maxY, height == 700 ? root.bounds.maxY - 8 : top, accuracy: 0.01)
            XCTAssertTrue(root.bounds.insetBy(dx: 8, dy: 8).contains(presenter.wrapper.frame))
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertTrue(try viewport(in: presenter).documentView === content)
            XCTAssertEqual(try viewport(in: presenter).hasVerticalScroller, height == 700)
        }
    }

    func testWindowResizeRetainsTheMountedPanelAndFocusedControl() throws {
        let (window, root, anchor) = fixture()
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 300))
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        content.addSubview(slider)
        let presenter = try makePresenter(content: content, anchor: anchor)
        defer { presenter.dismiss(restoreFocus: false) }
        try drag(try handle(in: presenter), by: NSSize(width: -80, height: 20), in: root, window: window)
        XCTAssertTrue(window.makeFirstResponder(slider))
        window.setContentSize(NSSize(width: 300, height: 200))
        XCTAssertTrue(presenter.isVisible)
        XCTAssertTrue(root.bounds.insetBy(dx: 8, dy: 8).contains(presenter.wrapper.frame))
        XCTAssertTrue(window.firstResponder === slider)
        XCTAssertTrue(try viewport(in: presenter).documentView === content)
        XCTAssertTrue(try viewport(in: presenter).hasVerticalScroller)
    }

    func testFlippedHostsMoveThePanelInTheSameKeyboardDirections() throws {
        let (window, root, anchor) = fixture(flipped: true)
        defer { window.close() }
        root.setBoundsOrigin(NSPoint(x: 42, y: 57))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let presenter = try makePresenter(content: content, anchor: anchor)
        defer { presenter.dismiss(restoreFocus: false) }
        let grip = try handle(in: presenter)
        let point = root.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), from: grip)
        XCTAssertTrue(presenter.hitTest(at: point, in: root) === grip)
        try drag(grip, by: NSSize(width: -30, height: 30), in: root, window: window)
        let before = presenter.wrapper.frame
        grip.keyDown(with: TestKeyEvent.keyDown(characters: "\u{F700}", keyCode: 126, modifiers: []))
        XCTAssertEqual(presenter.wrapper.frame.minY, before.minY - 1, accuracy: 0.01)
        grip.keyDown(with: TestKeyEvent.keyDown(characters: "\u{F703}", keyCode: 124, modifiers: .shift))
        XCTAssertEqual(presenter.wrapper.frame.minX, before.minX + 10, accuracy: 0.01)
        let after = presenter.wrapper.frame
        for modifier in [NSEvent.ModifierFlags.command, .control, .option] {
            grip.keyDown(with: TestKeyEvent.keyDown(characters: "\u{F703}", keyCode: 124, modifiers: modifier))
            XCTAssertEqual(presenter.wrapper.frame, after, "Editor modifiers must keep their existing command routing")
        }
    }

    func testCaptureHitTestingAndCursorKeepTheGripSeparateFromControls() throws {
        let (window, root, anchor) = fixture(overlay: true)
        defer { PopoverHelper.dismiss(restoreFocus: false); (root as? OverlayView)?.reset(); window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.frame = NSRect(x: 16, y: 80, width: 200, height: 20)
        content.addSubview(slider)
        PopoverHelper.show(content, size: content.frame.size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        let panel = try XCTUnwrap(root.subviews.first { $0.identifier?.rawValue == "screenshot.submenu" })
        let grip = try XCTUnwrap(panel.subviews.compactMap { $0 as? ScreenshotSubmenuDragHandle }.first)
        let gripPoint = root.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), from: grip)
        XCTAssertTrue(root.hitTest(gripPoint) === grip)
        let sliderPoint = root.convert(NSPoint(x: slider.bounds.midX, y: slider.bounds.midY), from: slider)
        XCTAssertTrue(root.hitTest(sliderPoint) === slider)
        let screenPoint = window.convertPoint(toScreen: root.convert(gripPoint, to: nil))
        XCTAssertTrue(PopoverHelper.cursorForOptions(at: screenPoint) === NSCursor.openHand)
        grip.mouseDown(with: try mouseEvent(.leftMouseDown, at: root.convert(gripPoint, to: nil), window: window))
        let outside = NSPoint(x: window.frame.maxX + 40, y: window.frame.maxY + 40)
        XCTAssertTrue(PopoverHelper.cursorForOptions(at: outside) === NSCursor.closedHand)
        grip.mouseUp(with: try mouseEvent(.leftMouseUp, at: root.convert(gripPoint, to: nil), window: window))
        XCTAssertNil(PopoverHelper.cursorForOptions(at: outside))
        let copy = TestKeyEvent.keyDown(characters: "c", keyCode: 8, modifiers: .command)
        XCTAssertTrue(window.performKeyEquivalent(with: copy))
        XCTAssertEqual((root as? MovableOptionsCommandProbe)?.copyRequests, 1)
        window.sendEvent(TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53, modifiers: []))
        XCTAssertFalse(PopoverHelper.isVisible)
        XCTAssertTrue(window.firstResponder === root)
    }

    func testManuallyMovedPanelStaysOnScreenWhenItsWindowMovesPartiallyOffScreen() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let (window, root, anchor) = fixture()
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let presenter = try makePresenter(content: content, anchor: anchor)
        defer { presenter.dismiss(restoreFocus: false) }
        try drag(try handle(in: presenter), by: NSSize(width: -40, height: 20), in: root, window: window)
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX - 200, y: screen.visibleFrame.minY + 80))
        let frameOnScreen = window.convertToScreen(presenter.wrapper.convert(presenter.wrapper.bounds, to: nil))
        XCTAssertTrue(screen.visibleFrame.contains(frameOnScreen))
        XCTAssertTrue(presenter.isVisible)
        XCTAssertEqual(presenter.wrapper.frame.width, 240)
    }

    func testFullscreenCapturePanelsRespectTheUsableScreenWhenContentResizes() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = ScreenshotGlassWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.contentView = root
        let anchor = NSView(frame: NSRect(x: root.bounds.maxX - 34, y: 0, width: 32, height: 32))
        root.addSubview(anchor)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 1800))
        let presenter = try makePresenter(content: content, anchor: anchor)
        defer { presenter.dismiss(restoreFocus: false); window.close() }
        for size in [NSSize(width: 420, height: 1800), NSSize(width: 800, height: 2400)] {
            XCTAssertTrue(presenter.resize(content, to: size))
            let frameOnScreen = window.convertToScreen(presenter.wrapper.convert(presenter.wrapper.bounds, to: nil))
            XCTAssertTrue(screen.visibleFrame.contains(frameOnScreen))
            XCTAssertTrue(try viewport(in: presenter).hasVerticalScroller)
        }
    }

    func testCrowdedBoundsStillFitAMovablePanelInsteadOfEscapingTheWindow() throws {
        let bounds = NSRect(x: 8, y: 40, width: 284, height: 144)
        let placement = try XCTUnwrap(ScreenshotSubmenuPlacement.makeFloatingPanel(
            size: NSSize(width: 368, height: 800), anchor: NSRect(x: 260, y: 0, width: 32, height: 24),
            bounds: bounds, preferredEdge: .minY, obstacles: [bounds]))
        XCTAssertTrue(bounds.contains(placement.frame))
        XCTAssertEqual(placement.frame.size, bounds.size)
        XCTAssertNil(ScreenshotSubmenuPlacement.makeFloatingPanel(size: NSSize(width: CGFloat.nan, height: 100),
            anchor: .zero, bounds: bounds, preferredEdge: .minY, obstacles: []))
    }

    private func fixture(height: CGFloat = 480, optionsY: CGFloat = 120,
                         flipped: Bool = false, overlay: Bool = false) -> (ScreenshotGlassWindow, NSView, NSView) {
        let rect = NSRect(x: 0, y: 0, width: 640, height: height)
        let root = overlay ? MovableOptionsCommandProbe(frame: rect) : flipped ? FlippedOptionsRoot(frame: rect) : NSView(frame: rect)
        let window = ScreenshotGlassWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.minY + 80))
        }
        window.contentView = root
        let options = ScreenshotPanelView(frame: NSRect(x: 20, y: optionsY, width: 600, height: 34))
        let anchor = NSView(frame: NSRect(x: 260, y: 5, width: 32, height: 24))
        options.addSubview(anchor)
        root.addSubview(options)
        return (window, root, anchor)
    }

    private func makePresenter(content: NSView, anchor: NSView) throws -> ScreenshotSubmenuPresenter {
        try XCTUnwrap(ScreenshotSubmenuPresenter(contentView: content, size: content.frame.size,
            relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY))
    }

    private func handle(in presenter: ScreenshotSubmenuPresenter) throws -> ScreenshotSubmenuDragHandle {
        try XCTUnwrap(presenter.wrapper.subviews.compactMap { $0 as? ScreenshotSubmenuDragHandle }.first)
    }

    private func viewport(in presenter: ScreenshotSubmenuPresenter) throws -> NSScrollView {
        try XCTUnwrap(presenter.wrapper.subviews.compactMap { $0 as? NSScrollView }.first)
    }

    private func drag(_ grip: ScreenshotSubmenuDragHandle, by offset: NSSize, in root: NSView, window: NSWindow) throws {
        let start = root.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), from: grip)
        let end = NSPoint(x: start.x + offset.width, y: start.y + offset.height)
        grip.mouseDown(with: try mouseEvent(.leftMouseDown, at: root.convert(start, to: nil), window: window))
        grip.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: root.convert(end, to: nil), window: window))
        grip.mouseUp(with: try mouseEvent(.leftMouseUp, at: root.convert(end, to: nil), window: window))
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}

private final class FlippedOptionsRoot: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class MovableOptionsCommandProbe: OverlayView {
    var copyRequests = 0
    override func handleEditorKeyEquivalent(_ event: NSEvent) -> Bool {
        guard KeyboardShortcutMatcher.matches(event, character: "c", modifiers: .command) else { return false }
        copyRequests += 1
        return true
    }
}
