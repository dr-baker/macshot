import AppKit
import XCTest

@MainActor
final class StitchEditorDocumentTests: XCTestCase {
    private func document() -> StitchDocument {
        let image = ImageProbe.quadrantImage(width: 80, height: 60)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
        return StitchDocument(pieces: [StitchPiece(image: image, origin: CGPoint(x: -40, y: -30)),
            StitchPiece(image: image, origin: CGPoint(x: 40, y: -30))])
    }
    private func editor(_ document: StitchDocument) -> EditorView {
        let view = EditorView(frame: CGRect(origin: .zero, size: document.bounds.size))
        view.screenshotImage = NSImage(cgImage: StitchRenderer.render(document)!, size: document.bounds.size)
        view.applySelection(view.bounds)
        view.showToolbars = false
        view.installStitchDocument(document)
        return view
    }
    private func mark(_ x: CGFloat, _ y: CGFloat) -> Annotation {
        Annotation(tool: .filledRectangle, startPoint: CGPoint(x: x - 3, y: y - 3),
            endPoint: CGPoint(x: x + 3, y: y + 3), color: .red, strokeWidth: 2)
    }

    func testMixedAnnotationAndPieceUndoRetainsObjectIdentity() {
        let original = document(), view = editor(original), annotation = mark(20, 30)
        view.annotations = [annotation]
        view.undoStack.append(.added(annotation))
        var moved = original
        moved.pieces[0].origin.y += 60
        XCTAssertTrue(view.applyStitchDocument(moved))
        XCTAssertEqual(annotation.startPoint.y, 27)
        let snapshot = annotation.clone()
        annotation.color = .blue
        view.undoStack.append(.propertyChange(annotation: annotation, snapshot: snapshot))
        view.undo()
        XCTAssertEqual(annotation.color, .red)
        view.undo()
        XCTAssertTrue(view.annotations[0] === annotation)
        XCTAssertEqual(view.stitchDocument?.pieces[0].origin, original.pieces[0].origin)
        XCTAssertEqual(annotation.startPoint, CGPoint(x: 17, y: 27))
        view.undo()
        XCTAssertTrue(view.annotations.isEmpty)
        view.redo(); view.redo(); view.redo()
        XCTAssertTrue(view.annotations[0] === annotation)
        XCTAssertEqual(annotation.color, .blue)
        XCTAssertEqual(view.stitchDocument?.pieces[0].origin, moved.pieces[0].origin)
    }

    func testBottomOriginAnnotationsFollowMovedPieceWithNegativeDocumentOrigin() {
        let original = document(), view = editor(original), annotation = mark(100, 20)
        view.annotations = [annotation]
        var moved = original
        moved.pieces[1].origin = CGPoint(x: -120, y: 30)
        XCTAssertTrue(view.applyStitchDocument(moved))
        XCTAssertEqual(annotation.boundingRect.midX, 20, accuracy: 0.001)
        XCTAssertEqual(annotation.boundingRect.midY, 20, accuracy: 0.001)
        view.undo()
        XCTAssertEqual(annotation.boundingRect.midX, 100)
        XCTAssertEqual(annotation.boundingRect.midY, 20)
    }

    func testCutMovesAnnotationsWithSlicesAndRemovesThoseInsideCut() {
        var original = document()
        original.pieces.removeLast()
        let view = editor(original), above = mark(20, 50), removed = mark(20, 30), below = mark(20, 10)
        view.annotations = [above, removed, below]
        var cut = original
        XCTAssertTrue(cut.collapse(axis: .horizontal, from: -10, to: 10))
        XCTAssertTrue(view.applyStitchDocument(cut))
        XCTAssertEqual(view.annotations.count, 2)
        XCTAssertTrue(view.annotations[0] === above)
        XCTAssertTrue(view.annotations[1] === below)
        XCTAssertEqual(above.boundingRect.midY, 30)
        XCTAssertEqual(below.boundingRect.midY, 10)
        view.undo()
        XCTAssertTrue(view.annotations[1] === removed)
        XCTAssertEqual(above.boundingRect.midY, 50)
        view.redo()
        XCTAssertEqual(view.annotations.count, 2)
    }

    func testRemovingOneDuplicateCaptureRemovesOnlyItsAnnotations() {
        let original = document(), view = editor(original)
        let first = mark(20, 30), second = mark(100, 30)
        view.annotations = [first, second]
        var removed = original
        removed.pieces.removeFirst()
        XCTAssertTrue(view.applyStitchDocument(removed))
        XCTAssertEqual(view.annotations.count, 1)
        XCTAssertTrue(view.annotations[0] === second)
        view.undo()
        XCTAssertTrue(view.annotations[0] === first)
        XCTAssertTrue(view.annotations[1] === second)
    }

    func testFlipKeepsPiecesAndUndoRestoresBothGeometryAndIdentity() {
        let original = document(), view = editor(original), annotation = mark(20, 30)
        view.annotations = [annotation]
        view.flipImageHorizontally()
        XCTAssertNotNil(view.stitchDocument)
        XCTAssertEqual(annotation.boundingRect.midX, 140)
        view.undo()
        XCTAssertNotNil(view.stitchDocument)
        XCTAssertEqual(view.stitchDocument?.pieces.map(\.id), original.pieces.map(\.id))
        XCTAssertTrue(view.annotations[0] === annotation)
        XCTAssertEqual(annotation.boundingRect.midX, 20)
        view.redo()
        XCTAssertNotNil(view.stitchDocument)
        XCTAssertEqual(annotation.boundingRect.midX, 140)
    }

    func testActualCropUndoRestoresEditablePieces() {
        let original = document(), view = editor(original), annotation = mark(20, 30)
        view.annotations = [annotation]
        view.currentTool = .crop
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 10, y: 10)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 120, y: 50)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 120, y: 50)))
        XCTAssertNotNil(view.stitchDocument)
        XCTAssertEqual(view.screenshotImage?.size, CGSize(width: 110, height: 40))
        view.undo()
        XCTAssertEqual(view.stitchDocument?.pieces.map(\.id), original.pieces.map(\.id))
        XCTAssertEqual(view.screenshotImage?.size, original.bounds.size)
        XCTAssertEqual(annotation.boundingRect.midX, 20)
        XCTAssertEqual(annotation.boundingRect.midY, 30)
        view.redo()
        XCTAssertNotNil(view.stitchDocument)
    }

    func testSharedCheckpointGroupsContinuousDocumentChanges() {
        let original = document(), view = editor(original)
        view.checkpointStitchDocument()
        var next = original
        next.style.blur = 20
        XCTAssertTrue(view.applyStitchDocument(next, registerUndo: false))
        next.style.blur = 30
        XCTAssertTrue(view.applyStitchDocument(next, registerUndo: false))
        XCTAssertEqual(view.undoStack.count, 1)
        view.undo()
        XCTAssertEqual(view.stitchDocument?.style.blur, original.style.blur)
        view.redo()
        XCTAssertEqual(view.stitchDocument?.style.blur, 30)
    }

    func testSavedSlicesDeduplicateSourcesAndRestorePackingStyleAndBackground() throws {
        var original = document()
        XCTAssertTrue(original.pack())
        XCTAssertTrue(original.collapse(axis: .horizontal, from: -10, to: 10))
        original.style.blur = 21
        original.background = .color(.purple)
        let saved = try XCTUnwrap(SavedStitchDocument(original))
        XCTAssertEqual(saved.images.count, 1)
        let decoded = try JSONDecoder().decode(SavedStitchDocument.self, from: JSONEncoder().encode(saved))
        let restored = try XCTUnwrap(decoded.restore())
        XCTAssertEqual(restored.pieces.map(\.id), original.pieces.map(\.id))
        XCTAssertEqual(restored.pieces.map(\.source), original.pieces.map(\.source))
        XCTAssertEqual(restored.pieces.map(\.origin), original.pieces.map(\.origin))
        XCTAssertTrue(restored.pieces[0].image === restored.pieces[1].image)
        XCTAssertEqual(restored.placement, .packed)
        XCTAssertEqual(restored.savedPackingState.length, original.savedPackingState.length)
        XCTAssertEqual(restored.style.blur, 21)
        let restoredPixels = NSImage(cgImage: StitchRenderer.render(restored)!, size: restored.bounds.size)
        let originalPixels = NSImage(cgImage: StitchRenderer.render(original)!, size: original.bounds.size)
        let restoredBitmap = try XCTUnwrap(ImageProbe.bitmap(from: restoredPixels))
        let originalBitmap = try XCTUnwrap(ImageProbe.bitmap(from: originalPixels))
        for y in 0..<restoredBitmap.pixelsHigh {
            for x in 0..<restoredBitmap.pixelsWide {
                XCTAssertEqual(ImageProbe.describePixel(bitmap: restoredBitmap, x: x, y: y),
                    ImageProbe.describePixel(bitmap: originalBitmap, x: x, y: y))
            }
        }
    }

    func testInvalidSavedGeometryAndSourceDataAreRejected() throws {
        let saved = try XCTUnwrap(SavedStitchDocument(document()))
        var corrupt = saved
        corrupt.pieces[0].origin = [.infinity, 0]
        XCTAssertNil(corrupt.restore())
        corrupt = saved; corrupt.pieces[0].source = [-1, 0, 80, 60]
        XCTAssertNil(corrupt.restore())
        corrupt = saved; corrupt.pieces[0].imageIndex = 99
        XCTAssertNil(corrupt.restore())
        corrupt = saved; corrupt.pieces[1].id = corrupt.pieces[0].id
        XCTAssertNil(corrupt.restore())
        corrupt = saved; corrupt.images = [Data([1, 2, 3])]
        XCTAssertNil(corrupt.restore())
        corrupt = saved; corrupt.pieces[1].origin = [500_000, 0]
        XCTAssertNil(corrupt.restore())
        corrupt = saved; corrupt.background = "unknown"
        XCTAssertNil(corrupt.restore())
    }

    func testStitchOnlyHistorySnapshotRetainsRawAndSidecarAndAppliesWithoutReplacingRaw() throws {
        let original = document(), view = editor(original)
        let raw = try XCTUnwrap(view.screenshotImage)
        let state = view.captureEditState()
        XCTAssertFalse(state.hasPostProcessing)
        XCTAssertTrue(state.hasEditableContent)
        let snapshot = try HistoryImageSnapshot(image: raw, rawImage: raw, annotations: [], editState: state)
        XCTAssertTrue(snapshot.isEditable)
        XCTAssertNotNil(snapshot.raw)
        let decoded = try JSONDecoder().decode(CaptureEditState.self, from: XCTUnwrap(snapshot.editState))
        let reopened = EditorView(frame: view.frame)
        reopened.screenshotImage = raw
        reopened.applyCaptureEditState(decoded)
        XCTAssertTrue(reopened.screenshotImage === raw)
        XCTAssertEqual(reopened.stitchDocument?.pieces.map(\.id), original.pieces.map(\.id))
    }

    func testPreviewLayersAssignOverlappingOrdinaryAnnotationOnlyToTopmostPiece() throws {
        var original = document()
        original.pieces[1].origin = original.pieces[0].origin
        let view = editor(original)
        view.annotations = [Annotation(tool: .rectangle, startPoint: CGPoint(x: 17, y: 27),
            endPoint: CGPoint(x: 23, y: 33), color: .red, strokeWidth: 2)]
        let layers = view.stitchAnnotationLayers()
        XCTAssertNil(layers[original.pieces[0].id])
        XCTAssertNotNil(layers[original.pieces[1].id])
        let preview = try XCTUnwrap(view.stitchAnnotationPreview())
        XCTAssertEqual(preview.width, Int(original.bounds.width))
        XCTAssertEqual(preview.height, Int(original.bounds.height))
    }
}
