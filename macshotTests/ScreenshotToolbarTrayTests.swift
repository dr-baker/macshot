import AppKit
import XCTest

final class ScreenshotToolbarTrayGeometryTests: XCTestCase {
    func testBottomOptionsExtendAwayFromPaperAndPastTheirConnectedToolbar() throws {
        let paper = NSRect(x: 200, y: 400, width: 600, height: 300)
        let bar = NSRect(x: 250, y: 355, width: 500, height: 40)
        let options = NSRect(x: 280, y: 315, width: 460, height: 34)
        let placement = try XCTUnwrap(ScreenshotSubmenuPlacement.makeToolbarTray(
            size: NSSize(width: 368, height: 220), anchor: NSRect(x: 550, y: 320, width: 32, height: 24),
            bounds: NSRect(x: 8, y: 8, width: 984, height: 784), avoiding: paper, obstacles: [bar, options]))
        XCTAssertEqual(placement.edge, .minY)
        XCTAssertEqual(placement.frame.maxY, options.minY - 4)
        XCTAssertFalse(placement.frame.intersects(paper))
        XCTAssertFalse(placement.frame.intersects(bar))
        XCTAssertFalse(placement.frame.intersects(options))
    }

    func testTopOptionsExtendAbovePaper() throws {
        let paper = NSRect(x: 200, y: 100, width: 600, height: 300)
        let options = NSRect(x: 280, y: 450, width: 460, height: 34)
        let placement = try XCTUnwrap(ScreenshotSubmenuPlacement.makeToolbarTray(
            size: NSSize(width: 368, height: 220), anchor: NSRect(x: 550, y: 455, width: 32, height: 24),
            bounds: NSRect(x: 8, y: 8, width: 984, height: 784), avoiding: paper, obstacles: [options]))
        XCTAssertEqual(placement.edge, .maxY)
        XCTAssertEqual(placement.frame.minY, options.maxY + 4)
        XCTAssertFalse(placement.frame.intersects(paper))
    }

    func testSidePlacementKeepsNaturalSizeWhenTheOutsideVerticalSpaceIsTooShort() throws {
        let paper = NSRect(x: 200, y: 250, width: 600, height: 300)
        let options = NSRect(x: 400, y: 185, width: 400, height: 34)
        let placement = try XCTUnwrap(ScreenshotSubmenuPlacement.makeToolbarTray(
            size: NSSize(width: 368, height: 300), anchor: NSRect(x: 550, y: 190, width: 32, height: 24),
            bounds: NSRect(x: 8, y: 8, width: 1184, height: 584), avoiding: paper, obstacles: [options]))
        XCTAssertEqual(placement.edge, .maxX)
        XCTAssertEqual(placement.frame.size, NSSize(width: 368, height: 300))
        XCTAssertEqual(placement.frame.minX, options.maxX + 4)
        XCTAssertFalse(placement.frame.intersects(paper))
    }

    func testOversizedInspectorGetsAnOutsideScrollViewport() throws {
        let bounds = NSRect(x: 8, y: 8, width: 684, height: 584)
        let paper = NSRect(x: 8, y: 250, width: 684, height: 300)
        let options = NSRect(x: 80, y: 175, width: 540, height: 34)
        let placement = try XCTUnwrap(ScreenshotSubmenuPlacement.makeToolbarTray(
            size: NSSize(width: 368, height: 500), anchor: NSRect(x: 330, y: 180, width: 32, height: 24),
            bounds: bounds, avoiding: paper, obstacles: [options]))
        XCTAssertEqual(placement.edge, .minY)
        XCTAssertEqual(placement.frame.height, 163)
        XCTAssertEqual(placement.frame.width, 368)
        XCTAssertTrue(bounds.contains(placement.frame))
        XCTAssertFalse(placement.frame.intersects(paper))
    }

    func testFullWindowPaperStillLeavesToolbarReachableInASmallWindow() throws {
        let bounds = NSRect(x: 8, y: 8, width: 304, height: 184)
        let options = NSRect(x: 50, y: 40, width: 220, height: 34)
        let placement = try XCTUnwrap(ScreenshotSubmenuPlacement.makeToolbarTray(
            size: NSSize(width: 368, height: 500), anchor: NSRect(x: 130, y: 45, width: 32, height: 20),
            bounds: bounds, avoiding: bounds, obstacles: [options]))
        XCTAssertTrue(bounds.contains(placement.frame))
        XCTAssertFalse(placement.frame.intersects(options))
        XCTAssertLessThan(placement.frame.width, 368)
        XCTAssertLessThan(placement.frame.height, 500)
    }

    func testOtherPanelsAreObstaclesWithoutDetachingTheTrayFromItsToolbar() throws {
        let paper = NSRect(x: 200, y: 400, width: 600, height: 300)
        let options = NSRect(x: 280, y: 315, width: 460, height: 34)
        let unrelated = NSRect(x: 300, y: 100, width: 420, height: 180)
        let placement = try XCTUnwrap(ScreenshotSubmenuPlacement.makeToolbarTray(
            size: NSSize(width: 200, height: 150), anchor: NSRect(x: 550, y: 320, width: 32, height: 24),
            bounds: NSRect(x: 8, y: 8, width: 984, height: 784), avoiding: paper, obstacles: [options, unrelated]))
        XCTAssertFalse(placement.frame.intersects(unrelated))
        XCTAssertFalse(placement.frame.intersects(options))
        XCTAssertFalse(placement.frame.intersects(paper))
    }
}

@MainActor
final class ScreenshotToolbarTrayHierarchyTests: XCTestCase {
    func testAllFinishesUseOneMountedTrayWithControlsVisibleOnFirstOpen() throws {
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            for material in ScreenshotPanelStyle.Material.allCases {
                ScreenshotPanelStyle(material: material).save()
                let (window, root, anchor, lateImage) = fixture()
                defer { PopoverHelper.dismiss(restoreFocus: false); window.close() }
                let content = NSView(frame: NSRect(x: 0, y: 0, width: 368, height: 220))
                let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
                content.addSubview(slider)
                let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
                PopoverHelper.showToolbarTray(content, size: content.frame.size, relativeTo: anchor.bounds,
                    of: anchor, avoiding: lateImage.frame, in: root)
                let tray = try XCTUnwrap(root.subviews.compactMap { $0 as? ScreenshotPanelView }.first {
                    $0.identifier?.rawValue == "screenshot.toolbar-tray"
                })
                XCTAssertTrue(content.window === window)
                XCTAssertEqual(content.alphaValue, 1)
                XCTAssertEqual(tray.alphaValue, 1)
                XCTAssertFalse(tray.animatesGlassPresentation)
                XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windowsBefore)
                XCTAssertFalse(tray.frame.intersects(lateImage.frame))
                if material != .classic, ScreenshotGlassAvailability.isAvailable {
                    let group = try XCTUnwrap(root.subviews.compactMap { $0 as? ScreenshotGlassGroupView }.first)
                    let order = root.subviews
                    XCTAssertGreaterThan(try XCTUnwrap(order.firstIndex(of: group)), try XCTUnwrap(order.firstIndex(of: lateImage)))
                    XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: group)), try XCTUnwrap(order.firstIndex(of: tray)))
                    XCTAssertEqual(group.frame, root.bounds)
                    XCTAssertFalse(group.isHidden)
                } else {
                    XCTAssertNil(tray.renderedGlassConfiguration)
                    XCTAssertFalse(try XCTUnwrap(tray.subviews.first).isHidden)
                }
            }
        }
    }

    func testResizingScrollableTrayKeepsLiveControlsAndFocus() throws {
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            ScreenshotPanelStyle(material: .classic).save()
            let (window, root, anchor, image) = fixture(height: 600)
            defer { window.close() }
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 368, height: 800))
            let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
            content.addSubview(slider)
            let presenter = try XCTUnwrap(ScreenshotSubmenuPresenter(contentView: content,
                size: content.frame.size, relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY,
                avoiding: image.frame, in: root))
            defer { presenter.dismiss(restoreFocus: false) }
            let scroll = try XCTUnwrap(presenter.wrapper.subviews.compactMap { $0 as? NSScrollView }.first)
            XCTAssertTrue(scroll.hasVerticalScroller)
            XCTAssertTrue(window.makeFirstResponder(slider))
            XCTAssertTrue(presenter.resize(content, to: NSSize(width: 368, height: 250)))
            XCTAssertTrue(window.firstResponder === slider)
            XCTAssertTrue(scroll.documentView === content)
            XCTAssertTrue(content.subviews.first === slider)
            XCTAssertTrue(root.bounds.contains(presenter.wrapper.frame))
            XCTAssertFalse(presenter.wrapper.frame.intersects(image.frame))
        }
    }

    func testTrayEscapeToggleAndCopyKeepNativeCommandOwnership() throws {
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            ScreenshotPanelStyle(material: .classic).save()
            let (window, root, anchor, image) = fixture()
            defer { PopoverHelper.dismiss(restoreFocus: false); window.close() }
            let editor = ScreenshotTrayCommandProbe(frame: image.frame)
            root.addSubview(editor, positioned: .below, relativeTo: image)
            ScreenshotCommandResponder.install(in: window, editor: editor)
            XCTAssertTrue(window.makeFirstResponder(editor))
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 368, height: 220))
            let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
            content.addSubview(slider)
            PopoverHelper.showToolbarTray(content, size: content.frame.size, relativeTo: anchor.bounds,
                of: anchor, avoiding: image.frame, in: root)
            XCTAssertTrue(window.makeFirstResponder(slider))
            let copy = TestKeyEvent.keyDown(characters: "c", keyCode: 8, modifiers: .command)
            XCTAssertTrue(window.performKeyEquivalent(with: copy))
            XCTAssertEqual(editor.copyRequests, 1)
            let field = NSTextField(string: "14")
            content.addSubview(field)
            field.selectText(nil)
            let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
            XCTAssertTrue(fieldEditor.isFieldEditor)
            _ = window.performKeyEquivalent(with: copy)
            XCTAssertEqual(editor.copyRequests, 1)
            XCTAssertTrue(window.firstResponder === fieldEditor)
            window.sendEvent(TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53, modifiers: []))
            XCTAssertFalse(PopoverHelper.isVisible)
            XCTAssertTrue(window.firstResponder === editor)

            let otherAnchor = NSView(frame: NSRect(x: 30, y: 0, width: 24, height: 24))
            anchor.superview?.addSubview(otherAnchor)
            XCTAssertFalse(PopoverHelper.toggleClosedIfOpen(anchorView: otherAnchor))
            PopoverHelper.showToolbarTray(content, size: content.frame.size, relativeTo: otherAnchor.bounds,
                of: otherAnchor, avoiding: image.frame, in: root)
            XCTAssertTrue(PopoverHelper.isVisible)
            XCTAssertFalse(PopoverHelper.toggleClosedIfOpen(anchorView: anchor))
            XCTAssertTrue(PopoverHelper.toggleClosedIfOpen(anchorView: otherAnchor))
            XCTAssertFalse(PopoverHelper.isVisible)
        }
    }

    private func fixture(height: CGFloat = 800) -> (ScreenshotGlassWindow, NSView, NSView, NSView) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: height))
        let window = ScreenshotGlassWindow(contentRect: root.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        let options = ScreenshotPanelView(frame: NSRect(x: 80, y: 175, width: 540, height: 34))
        let anchor = NSView(frame: NSRect(x: 250, y: 5, width: 32, height: 24))
        options.addSubview(anchor)
        root.addSubview(options)
        let lateImage = NSView(frame: NSRect(x: 8, y: 250, width: 684, height: min(300, height - 258)))
        root.addSubview(lateImage)
        return (window, root, anchor, lateImage)
    }
}

@MainActor
private final class ScreenshotTrayCommandProbe: OverlayView {
    var copyRequests = 0
    override var acceptsFirstResponder: Bool { true }
    override func handleEditorKeyEquivalent(_ event: NSEvent) -> Bool {
        guard KeyboardShortcutMatcher.matches(event, character: "c", modifiers: .command) else { return false }
        copyRequests += 1
        return true
    }
}
