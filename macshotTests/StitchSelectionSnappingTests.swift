import AppKit
import XCTest

@MainActor
final class StitchSelectionSnappingTests: XCTestCase {
    private func view() -> OverlayView {
        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.stitchSizeRecommendations = { _, _ in
            .init(widths: [.init(value: 200, reason: .capture), .init(value: 300, reason: .row)],
                  heights: [.init(value: 100, reason: .capture), .init(value: 150, reason: .column)])
        }
        return view
    }

    func testBothDimensionsSnapWithoutMovingTheAnchor() {
        let view = view()
        let point = view.stitchSnappedSelectionPoint(raw: CGPoint(x: 247, y: 153),
            boundaryAdjusted: CGPoint(x: 249, y: 157), anchor: CGPoint(x: 50, y: 50), enabled: true)
        XCTAssertEqual(point, CGPoint(x: 250, y: 150))
        XCTAssertEqual(view.stitchDimensionGuides.filter(\.matched).count, 2)
    }

    func testReverseDragAndAlternateSize() {
        let view = view()
        XCTAssertEqual(view.stitchSnappedSelectionPoint(raw: CGPoint(x: 198, y: 352),
            boundaryAdjusted: CGPoint(x: 198, y: 352), anchor: CGPoint(x: 500, y: 500), enabled: true),
            CGPoint(x: 200, y: 350))
        XCTAssertTrue(view.stitchDimensionGuides.contains { $0.isWidth && $0.dimension == 300 && $0.matched })
    }

    func testFarDimensionsKeepExistingBoundarySnap() {
        let view = view()
        let adjusted = CGPoint(x: 225, y: 177)
        XCTAssertEqual(view.stitchSnappedSelectionPoint(raw: CGPoint(x: 222, y: 175),
            boundaryAdjusted: adjusted, anchor: CGPoint(x: 50, y: 50), enabled: true), adjusted)
        XCTAssertFalse(view.stitchDimensionGuides.contains(where: \.matched))
    }

    func testOutOfScreenTargetsNeverResizePastDisplay() {
        let view = view()
        let raw = CGPoint(x: 799, y: 599)
        XCTAssertEqual(view.stitchSnappedSelectionPoint(raw: raw, boundaryAdjusted: raw,
            anchor: CGPoint(x: 602, y: 502), enabled: true), raw)
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
    }

    func testBypassClearsFeedbackAndOrdinaryCaptureHasNoTargets() {
        let view = view()
        let raw = CGPoint(x: 247, y: 153)
        _ = view.stitchSnappedSelectionPoint(raw: raw, boundaryAdjusted: raw,
                                           anchor: CGPoint(x: 50, y: 50), enabled: true)
        XCTAssertFalse(view.stitchDimensionGuides.isEmpty)
        XCTAssertEqual(view.stitchSnappedSelectionPoint(raw: raw, boundaryAdjusted: raw,
            anchor: CGPoint(x: 50, y: 50), enabled: false), raw)
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
        view.stitchSizeRecommendations = nil
        XCTAssertEqual(view.stitchSnappedSelectionPoint(raw: raw, boundaryAdjusted: raw,
            anchor: CGPoint(x: 50, y: 50), enabled: true), raw)
    }

    func testProviderReceivesSpaceAvailableInTheDragDirection() {
        let view = view()
        var sizes: [CGSize] = []
        view.stitchSizeRecommendations = { _, maximum in
            sizes.append(maximum)
            return .init(widths: [], heights: [])
        }
        _ = view.stitchSnappedSelectionPoint(raw: CGPoint(x: 300, y: 200),
            boundaryAdjusted: CGPoint(x: 300, y: 200), anchor: CGPoint(x: 250, y: 150), enabled: true)
        _ = view.stitchSnappedSelectionPoint(raw: CGPoint(x: 200, y: 100),
            boundaryAdjusted: CGPoint(x: 200, y: 100), anchor: CGPoint(x: 250, y: 150), enabled: true)
        XCTAssertEqual(sizes, [CGSize(width: 550, height: 450), CGSize(width: 250, height: 150)])
    }

    func testSelectionDragUsesTargetsAndOptionAndShiftReleaseThem() {
        let view = view()
        view.selectionOnlyMode = true
        view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 50, y: 50)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 247, y: 153)))
        XCTAssertEqual(view.selectionRect, CGRect(x: 50, y: 50, width: 200, height: 100))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 247, y: 153), .option))
        XCTAssertEqual(view.selectionRect.size, CGSize(width: 197, height: 103))
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 247, y: 153), .shift))
        XCTAssertEqual(view.selectionRect.size, CGSize(width: 103, height: 103))
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
    }

    func testResetDoesNotLeakTargetsIntoPooledCaptureOverlay() {
        let view = view()
        view.reset()
        XCTAssertNil(view.stitchSizeRecommendations)
        XCTAssertTrue(view.stitchDimensionGuides.isEmpty)
    }

    func testRecommendationsUseRegisteredLayoutRatherThanAbsoluteScreenCoordinates() throws {
        let first = try XCTUnwrap(ImageProbe.quadrantImage(width: 100, height: 80)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let second = try XCTUnwrap(ImageProbe.quadrantImage(width: 200, height: 80)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var pending: ((StitchCaptureFrame?) -> Void)?
        let coordinator = StitchCaptureCoordinator(
            first: .init(image: first, position: CGPoint(x: 1000, y: 2000)),
            capture: { pending = $0 }, analyze: { _, _, _, complete in
                complete(false, StitchAlignment.Match(offset: CGPoint(x: 100, y: 0), error: 0))
            })
        coordinator.requestCapture()
        pending?(.init(image: second, position: CGPoint(x: 1500, y: 2000)))
        let result = coordinator.selectionRecommendations(at: CGPoint(x: 1400, y: 2080))
        XCTAssertEqual(result.widths.first?.value, 100)
        XCTAssertEqual(result.widths.first?.reason, .column)
    }

    func testGuideRenderingPreview() throws {
        let view = view()
        let page = NSImage(size: view.bounds.size)
        page.lockFocus()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        view.bounds.fill()
        for row in 0..<14 {
            let text = row == 0 ? "A page worth capturing" : "Content stays aligned as you add to your stitch."
            (text as NSString).draw(at: CGPoint(x: 80, y: 520 - row * 30), withAttributes: [
                .font: NSFont.systemFont(ofSize: row == 0 ? 24 : 15), .foregroundColor: NSColor.darkGray
            ])
        }
        page.unlockFocus()
        view.screenshotImage = page
        view.selectionOnlyMode = true
        view.mouseDown(with: mouse(.leftMouseDown, view, CGPoint(x: 80, y: 220)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view, CGPoint(x: 378, y: 366)))
        view.stitchReferencePixelsPerPoint = 2
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let output = ProcessInfo.processInfo.environment["MACSHOT_STITCH_GUIDE_PREVIEW"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }

    private func mouse(_ type: NSEvent.EventType, _ view: OverlayView, _ point: CGPoint,
                       _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
