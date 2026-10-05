import AppKit
import XCTest

final class ScreenshotSubmenuPlacementTests: XCTestCase {
    @MainActor
    func testBothGlassFinishesKeepFittingSubmenusInTheCaptureWindow() throws {
        guard ScreenshotGlassAvailability.isAvailable else { throw XCTSkip("Native glass requires supported macOS") }
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            let window = ScreenshotGlassWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
            window.contentView = root
            let anchor = NSView(frame: NSRect(x: 280, y: 40, width: 32, height: 32))
            root.addSubview(anchor)
            for finish in [ScreenshotPanelStyle.Material.clear, .regular] {
                ScreenshotPanelStyle(material: finish).save()
                let content = NSView(frame: .zero)
                let menu = try XCTUnwrap(ScreenshotSubmenuPresenter(contentView: content,
                    size: NSSize(width: 200, height: 120), relativeTo: anchor.bounds,
                    of: anchor, preferredEdge: .maxY))
                XCTAssertTrue(menu.isVisible)
                XCTAssertTrue(content.window === window)
                XCTAssertEqual(menu.wrapper.renderedGlassConfiguration?.material, finish)
                menu.dismiss(restoreFocus: false)
            }
        }
    }

    func testPreferredSideFlipsAtWindowEdgeAndKeepsTheMenuAnchored() throws {
        let bounds = NSRect(x: 0, y: 0, width: 640, height: 480)
        let anchor = NSRect(x: 260, y: 400, width: 100, height: 32)
        let placement = try XCTUnwrap(ScreenshotSubmenuPlacement.make(
            size: NSSize(width: 240, height: 200), anchor: anchor, bounds: bounds, preferredEdge: .maxY))
        XCTAssertEqual(placement.edge, .minY)
        XCTAssertEqual(placement.frame.maxY, anchor.minY - 4)
        XCTAssertTrue(bounds.contains(placement.frame))
        XCTAssertFalse(placement.frame.intersects(anchor))
    }

    func testClampsAcrossTheWindowWithoutMovingThroughTheAnchor() throws {
        let bounds = NSRect(x: 8, y: 8, width: 624, height: 464)
        let anchor = NSRect(x: 10, y: 300, width: 24, height: 24)
        let placement = try XCTUnwrap(ScreenshotSubmenuPlacement.make(
            size: NSSize(width: 300, height: 150), anchor: anchor, bounds: bounds, preferredEdge: .minY))
        XCTAssertEqual(placement.frame.minX, bounds.minX)
        XCTAssertEqual(placement.frame.maxY, anchor.minY - 4)
        XCTAssertTrue(bounds.contains(placement.frame))
    }

    func testTriesHorizontalSidesWhenThereIsNoVerticalRoom() throws {
        let bounds = NSRect(x: 0, y: 0, width: 640, height: 240)
        let anchor = NSRect(x: 300, y: 100, width: 40, height: 40)
        let placement = try XCTUnwrap(ScreenshotSubmenuPlacement.make(
            size: NSSize(width: 200, height: 180), anchor: anchor, bounds: bounds, preferredEdge: .minY))
        XCTAssertEqual(placement.edge, .minX)
        XCTAssertEqual(placement.frame.maxX, anchor.minX - 4)
        XCTAssertTrue(bounds.contains(placement.frame))
        XCTAssertFalse(placement.frame.intersects(anchor))
    }

    func testInsufficientSpaceUsesNativePopoverInsteadOfCoveringTheAnchor() {
        let bounds = NSRect(x: 0, y: 0, width: 640, height: 240)
        let anchor = NSRect(x: 300, y: 100, width: 40, height: 40)
        XCTAssertNil(ScreenshotSubmenuPlacement.make(size: NSSize(width: 600, height: 180),
            anchor: anchor, bounds: bounds, preferredEdge: .minY))
        XCTAssertNil(ScreenshotSubmenuPlacement.make(size: NSSize(width: 200, height: 300),
            anchor: anchor, bounds: bounds, preferredEdge: .minY))
        XCTAssertNil(ScreenshotSubmenuPlacement.make(size: NSSize(width: CGFloat.nan, height: 180),
            anchor: anchor, bounds: bounds, preferredEdge: .minY))
        XCTAssertNil(ScreenshotSubmenuPlacement.make(size: NSSize(width: 200, height: 180),
            anchor: NSRect(x: 650, y: 100, width: 40, height: 40), bounds: bounds, preferredEdge: .minY))
    }

    func testBottomBarMenusClearTheAdjacentOptionsRow() throws {
        let bar = NSRect(x: 100, y: 40, width: 400, height: 40)
        let options = NSRect(x: 150, y: 84, width: 300, height: 36)
        let placement = try XCTUnwrap(ScreenshotSubmenuPlacement.make(size: NSSize(width: 240, height: 200),
            anchor: NSRect(x: 280, y: 44, width: 32, height: 32),
            bounds: NSRect(x: 0, y: 0, width: 640, height: 480),
            preferredEdge: .minY, avoiding: [bar, options]))
        XCTAssertEqual(placement.edge, .maxY)
        XCTAssertEqual(placement.frame.minY, options.maxY + 4)
        XCTAssertFalse(placement.frame.intersects(bar))
        XCTAssertFalse(placement.frame.intersects(options))
    }

    func testSideBarMenusKeepTheOtherToolButtonsReachable() throws {
        let bar = NSRect(x: 592, y: 20, width: 40, height: 440)
        let placement = try XCTUnwrap(ScreenshotSubmenuPlacement.make(size: NSSize(width: 240, height: 200),
            anchor: NSRect(x: 596, y: 240, width: 32, height: 32),
            bounds: NSRect(x: 8, y: 8, width: 624, height: 464),
            preferredEdge: .minY, avoiding: [bar]))
        XCTAssertEqual(placement.edge, .minX)
        XCTAssertEqual(placement.frame.maxX, bar.minX - 4)
        XCTAssertFalse(placement.frame.intersects(bar))
    }
}
