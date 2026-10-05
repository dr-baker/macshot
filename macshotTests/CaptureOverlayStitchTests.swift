import AppKit
import XCTest

@MainActor
final class CaptureOverlayStitchTests: XCTestCase {
    private func capture(scale: Int = 1) throws -> ImageEditingView {
        let view = ImageEditingView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let pixels = try XCTUnwrap(ImageProbe.quadrantImage(width: 400 * scale, height: 300 * scale)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        view.screenshotImage = NSImage(cgImage: pixels, size: view.frame.size)
        view.captureSourceImage = view.screenshotImage
        view.applySelection(CGRect(x: 40, y: 50, width: 160, height: 100))
        view.showToolbars = false
        view.beautifyEnabled = false
        view.effectsPreset = .none
        view.effectsBrightness = 0
        view.effectsContrast = 1
        view.effectsSaturation = 1
        view.effectsSharpness = 0
        return view
    }

    func testEditedOutputBypassesOriginalCrossScreenPixelsForBothAxesAndScales() throws {
        for scale in [1, 2] {
            for axis in [StitchAxis.horizontal, .vertical] {
                let view = try capture(scale: scale)
                let frame = view.frame
                XCTAssertTrue(view.beginStitchEditing())
                var document = try XCTUnwrap(view.stitchDocument)
                XCTAssertTrue(document.collapse(axis: axis, from: CGFloat(20 * scale), to: CGFloat(40 * scale)))
                XCTAssertTrue(view.applyStitchDocument(document))
                var crossScreenRequests = 0
                let image = try XCTUnwrap(OverlayWindowController.captureRegion(in: view) {
                    crossScreenRequests += 1
                    return ImageProbe.solidImage(width: 800, height: 600)
                })
                let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                XCTAssertEqual(crossScreenRequests, 0)
                XCTAssertEqual(pixels.width, (axis == .vertical ? 140 : 160) * scale)
                XCTAssertEqual(pixels.height, (axis == .horizontal ? 80 : 100) * scale)
                XCTAssertEqual(image.size, view.selectionRect.size)
                XCTAssertEqual(view.frame, frame)
                XCTAssertEqual(view.selectionRect.minX, 40)
                XCTAssertEqual(view.selectionRect.maxY, 150)
            }
        }
    }

    func testOrdinaryCaptureStillUsesAvailableCrossScreenImage() throws {
        let view = try capture()
        let joined = ImageProbe.solidImage(width: 320, height: 100)
        let result = OverlayWindowController.captureRegion(in: view) { joined }
        XCTAssertTrue(result === joined)
        let local = try XCTUnwrap(OverlayWindowController.captureRegion(in: view) { nil })
        XCTAssertEqual(local.size, view.selectionRect.size)
        let raw = try XCTUnwrap(view.captureSelectedRegionRaw())
        XCTAssertNil(OverlayWindowController.snapshotAnnotationData(in: view, rawImage: raw))
    }

    func testStitchOnlySnapshotRetainsCutPixelsAndEditablePiecesAfterCaptureReset() throws {
        let view = try capture(scale: 2)
        XCTAssertTrue(view.beginStitchEditing())
        var document = try XCTUnwrap(view.stitchDocument)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 40, to: 80))
        XCTAssertTrue(view.applyStitchDocument(document))
        let raw = try XCTUnwrap(view.captureSelectedRegionRaw())
        let snapshot = try XCTUnwrap(OverlayWindowController.snapshotAnnotationData(in: view, rawImage: raw))
        XCTAssertTrue(snapshot.annotations.isEmpty)
        let state = try XCTUnwrap(snapshot.editState)
        XCTAssertFalse(state.hasPostProcessing)
        XCTAssertTrue(state.hasEditableContent)
        view.reset()
        view.screenshotImage = nil
        let saved = try XCTUnwrap(state.stitchDocument)
        let restored = try XCTUnwrap(saved.restore())
        XCTAssertEqual(restored.pieces.map(\.id), document.pieces.map(\.id))
        XCTAssertEqual(restored.pieces.map(\.source), document.pieces.map(\.source))
        XCTAssertEqual(snapshot.rawImage.size, CGSize(width: 160, height: 80))
        let reopened = EditorView(frame: CGRect(origin: .zero, size: raw.size))
        reopened.screenshotImage = snapshot.rawImage
        reopened.applySelection(reopened.bounds)
        reopened.applyCaptureEditState(state)
        XCTAssertEqual(reopened.stitchDocument?.pieces.map(\.id), document.pieces.map(\.id))
        XCTAssertEqual(reopened.captureSelectedRegionRaw()?.size, snapshot.rawImage.size)
    }

    func testSnapshotNormalizesRedactionClipsAndLoupeSourcesWithoutMovingLiveMarks() throws {
        let view = try capture()
        XCTAssertTrue(view.beginStitchEditing())
        let piece = try XCTUnwrap(view.stitchDocument?.pieces.first)
        let mask = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 45, y: 55),
            endPoint: CGPoint(x: 95, y: 95), color: .black, strokeWidth: 1)
        mask.stitchAttachment = StitchAnnotationAttachment(pieceID: piece.id, lineageID: piece.lineageID,
            clipRect: CGRect(x: 50, y: 60, width: 20, height: 15))
        let loupe = Annotation(tool: .loupe, startPoint: CGPoint(x: 80, y: 90),
            endPoint: CGPoint(x: 100, y: 110), color: .red, strokeWidth: 1)
        loupe.loupeSourceRect = CGRect(x: 60, y: 75, width: 20, height: 20)
        view.annotations = [mask, loupe]
        let raw = try XCTUnwrap(view.captureSelectedRegionRaw())
        let snapshot = try XCTUnwrap(OverlayWindowController.snapshotAnnotationData(in: view, rawImage: raw))
        XCTAssertEqual(snapshot.annotations.count, 2)
        XCTAssertFalse(snapshot.annotations[0] === mask)
        XCTAssertFalse(snapshot.annotations[1] === loupe)
        XCTAssertEqual(snapshot.annotations[0].startPoint, CGPoint(x: 5, y: 5))
        XCTAssertEqual(snapshot.annotations[0].stitchAttachment?.clipRect, CGRect(x: 10, y: 10, width: 20, height: 15))
        XCTAssertEqual(snapshot.annotations[1].loupeSourceRect, CGRect(x: 20, y: 25, width: 20, height: 20))
        XCTAssertEqual(mask.startPoint, CGPoint(x: 45, y: 55))
        XCTAssertEqual(mask.stitchAttachment?.clipRect, CGRect(x: 50, y: 60, width: 20, height: 15))
        XCTAssertEqual(loupe.loupeSourceRect, CGRect(x: 60, y: 75, width: 20, height: 20))
    }
}
