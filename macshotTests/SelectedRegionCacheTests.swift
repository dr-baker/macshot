import AppKit
import XCTest

@MainActor
final class SelectedRegionCacheTests: XCTestCase {
    private func fixture() -> EditorView {
        let view = EditorView(frame: CGRect(x: 0, y: 0, width: 80, height: 60))
        view.showToolbars = false
        view.screenshotImage = ImageProbe.quadrantImage(width: 80, height: 60)
        view.applySelection(view.bounds)
        return view
    }

    func testUnchangedNativeCaptureAndRawCaptureReuseFrozenPixels() throws {
        let view = fixture()
        let first = try XCTUnwrap(view.captureSelectedRegion())
        XCTAssertTrue(view.captureSelectedRegion() === first)
        XCTAssertTrue(view.captureSelectedRegionRaw() === first)
        let pixels = try XCTUnwrap(first.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(pixels.width, 80)
        XCTAssertEqual(pixels.height, 60)
    }

    func testAnnotationMutationInvalidatesTheCompositeAndPreservesPreviousPixels() throws {
        let view = fixture()
        let mark = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 10, y: 10),
            endPoint: CGPoint(x: 30, y: 30), color: .black, strokeWidth: 1)
        view.annotations = [mark]
        let first = try XCTUnwrap(view.captureSelectedRegion())
        let firstPixels = try XCTUnwrap(first.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let previousData = try XCTUnwrap(firstPixels.dataProvider?.data)
        XCTAssertTrue(view.captureSelectedRegion() === first)
        mark.color = .white
        let second = try XCTUnwrap(view.captureSelectedRegion())
        let secondPixels = try XCTUnwrap(second.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertFalse(second === first)
        XCTAssertNotEqual(previousData as Data, try XCTUnwrap(secondPixels.dataProvider?.data) as Data)
        XCTAssertEqual(previousData as Data, try XCTUnwrap(firstPixels.dataProvider?.data) as Data)
        let raw = try XCTUnwrap(view.captureSelectedRegionRaw())
        XCTAssertFalse(raw === second)
        XCTAssertTrue(view.captureSelectedRegionRaw() === raw)
        XCTAssertTrue(view.captureSelectedRegion() === second)
    }

    func testCopyDuringRotationUsesCurrentGeometryAndDoesNotRetainDragFrames() throws {
        let view = EditorView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        view.showToolbars = false
        view.screenshotImage = ImageProbe.quadrantImage(width: 200, height: 200)
        view.applySelection(view.bounds)
        let window = NSWindow(contentRect: view.bounds, styleMask: .borderless,
            backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        let mark = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 60, y: 60),
            endPoint: CGPoint(x: 110, y: 90), color: .black, strokeWidth: 1)
        view.annotations = [mark]
        view.currentTool = .select
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 85, y: 75)))
        view.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 85, y: 75)))
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let first = try XCTUnwrap(view.captureSelectedRegion())
        view.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 85, y: 114)))
        XCTAssertTrue(view.isManipulatingAnnotation)
        view.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 124, y: 100)))
        XCTAssertNotEqual(mark.rotation, 0)
        let rotated = try XCTUnwrap(view.captureSelectedRegion())
        XCTAssertFalse(rotated === first)
        let originalPixels = try XCTUnwrap(first.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rotatedPixels = try XCTUnwrap(rotated.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertNotEqual(try XCTUnwrap(originalPixels.dataProvider?.data) as Data,
            try XCTUnwrap(rotatedPixels.dataProvider?.data) as Data)
        XCTAssertFalse(view.captureSelectedRegion() === rotated)
        view.mouseUp(with: try mouse(.leftMouseUp, CGPoint(x: 124, y: 100)))
        XCTAssertFalse(view.isManipulatingAnnotation)
        let settled = try XCTUnwrap(view.captureSelectedRegion())
        XCTAssertTrue(view.captureSelectedRegion() === settled)
    }

    func testBlurDrawingDoesNotInvalidateAnUnchangedFinishedComposite() throws {
        let view = fixture()
        let blur = Annotation(tool: .blur, startPoint: CGPoint(x: 10, y: 10),
            endPoint: CGPoint(x: 30, y: 30), color: .black, strokeWidth: 1)
        view.setAnnotations([blur])
        _ = try XCTUnwrap(view.captureSelectedRegion())
        let settled = try XCTUnwrap(view.captureSelectedRegion())
        let revision = blur.renderRevision
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(blur.renderRevision, revision)
        XCTAssertTrue(view.captureSelectedRegion() === settled)
    }

    func testSelectionAndSourceReplacementCannotReuseOldPixels() throws {
        let view = fixture()
        let first = try XCTUnwrap(view.captureSelectedRegion())
        view.applySelection(CGRect(x: 5, y: 5, width: 40, height: 30))
        let cropped = try XCTUnwrap(view.captureSelectedRegion())
        XCTAssertFalse(cropped === first)
        XCTAssertEqual(cropped.size, CGSize(width: 40, height: 30))
        view.screenshotImage = ImageProbe.solidImage(width: 80, height: 60, color: NSColor.black.cgColor)
        XCTAssertFalse(view.captureSelectedRegion() === cropped)
        view.reset()
        XCTAssertNil(view.captureSelectedRegion())
    }
}
