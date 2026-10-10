import AppKit
import XCTest

@MainActor
final class StitchPaperControllerTests: XCTestCase {
    func testProjectedFrameKeepsRetinaScaleAndCompactAnnotationCoordinates() throws {
        let pixels = try XCTUnwrap(ImageProbe.solidImage(width: 600, height: 240)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: pixels)])
        XCTAssertTrue(document.collapse(axis: .vertical, from: 100, to: 500))
        document.style.transition = .accordion
        document.style.accordionPerspective = 0
        document.style.accordionYaw = 0
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document, progress: 0))
        let selection = CGRect(x: 30, y: 40, width: document.bounds.width / 2, height: document.bounds.height / 2)
        for flipped in [false, true] {
            let frame = StitchEditorController.paperOutputFrame(projection: projection,
                selection: selection, isFlipped: flipped)
            XCTAssertEqual(frame.width, projection.outputBounds.width / 2)
            XCTAssertEqual(frame.height, projection.outputBounds.height / 2)
            XCTAssertEqual(frame.minX, selection.minX + (projection.outputBounds.minX - projection.documentBounds.minX) / 2)
            let expectedY = flipped ? projection.outputBounds.minY - projection.documentBounds.minY
                : projection.documentBounds.maxY - projection.outputBounds.maxY
            XCTAssertEqual(frame.minY, selection.minY + expectedY / 2)
            XCTAssertGreaterThan(frame.width, selection.width, "Restored paper must extend beyond its shortened editing canvas")
        }
        XCTAssertEqual(selection.size, CGSize(width: 100, height: 120))
    }

    func testLargeRemovedBandBoundsPreviewByProjectedOutput() throws {
        let pixels = try XCTUnwrap(ImageProbe.solidImage(width: 6000, height: 100)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: pixels)])
        XCTAssertTrue(document.collapse(axis: .vertical, from: 50, to: 5950))
        document.style.transition = .accordion
        document.style.accordionPerspective = 0
        document.style.accordionYaw = 0
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        let composite = try XCTUnwrap(StitchRenderer.render(document))
        let previewSize = try XCTUnwrap(StitchEditorController.paperPreviewTextureSize(pixels: composite,
            sourceSize: document.bounds.size, projection: projection))
        XCTAssertLessThan(previewSize.width, CGFloat(composite.width), "A small source alone does not bound the unfolded paper")
        let nativeOutput = projection.outputBounds.width / projection.documentBounds.width * previewSize.width
            + ScreenshotPresentation.paperPadding * 2 * previewSize.width / document.bounds.width
        XCTAssertLessThanOrEqual(nativeOutput, 2000)
        XCTAssertEqual(composite.width, 100, "Preview budgeting must preserve native source pixels for Copy")
    }

    private func fixture(removeBand: Bool = true) throws -> (ImageEditingView, StitchEditorController, StitchPaperPreviewView, NSWindow) {
        let pixels = try XCTUnwrap(ImageProbe.quadrantImage(width: 160, height: 120)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: pixels)])
        if removeBand { XCTAssertTrue(document.collapse(axis: .horizontal, from: 40, to: 60)) }
        document.style.transition = .accordion
        let editor = ImageEditingView(frame: CGRect(origin: .zero, size: document.bounds.size))
        editor.screenshotImage = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(document)), size: document.bounds.size)
        editor.applySelection(editor.bounds)
        editor.installStitchDocument(document)
        editor.beautifyEnabled = false
        editor.currentTool = .stitch
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = editor
        let controller = StitchEditorController(document: document, window: window)
        controller.onDocumentChanged = { document, registerUndo in
            editor.applyStitchDocument(document, registerUndo: registerUndo)
        }
        editor.onStitchDocumentChanged = { [weak controller, weak editor] in
            if let document = editor?.stitchDocument { controller?.restore(document) }
        }
        controller.attach(to: editor)
        let preview = try XCTUnwrap(editor.subviews.compactMap { $0 as? StitchPaperPreviewView }.first)
        return (editor, controller, preview, window)
    }

    func testCameraDragAddsOneUndoEntryAndCancellationRestoresBothAngles() throws {
        let (editor, controller, preview, window) = try fixture()
        defer { controller.suspend(); window.orderOut(nil) }
        let initialUndo = editor.undoStack.count
        preview.onCameraBegin?()
        for step: CGFloat in [5, 10, 20] {
            preview.onCameraChanged?(StitchPaperCamera(perspective: step, yaw: -step))
        }
        preview.onCameraEnd?(true)
        XCTAssertEqual(editor.undoStack.count, initialUndo + 1)
        XCTAssertEqual(editor.stitchDocument?.style.accordionPerspective, 20)
        XCTAssertEqual(editor.stitchDocument?.style.accordionYaw, -20)
        preview.onCameraBegin?()
        preview.onCameraChanged?(StitchPaperCamera(perspective: -25, yaw: 30))
        preview.onCameraEnd?(false)
        XCTAssertEqual(editor.undoStack.count, initialUndo + 1)
        XCTAssertEqual(editor.stitchDocument?.style.accordionPerspective, 20)
        XCTAssertEqual(editor.stitchDocument?.style.accordionYaw, -20)
        XCTAssertEqual(preview.camera, StitchPaperCamera(perspective: 20, yaw: -20))
        editor.undo()
        XCTAssertEqual(editor.stitchDocument?.style.accordionPerspective, 14)
        XCTAssertEqual(editor.stitchDocument?.style.accordionYaw, 11.2)
    }

    func testAnglePadAndAnimationAreAvailableWithoutEnablingBeautifyDecoration() throws {
        let (editor, controller, _, window) = try fixture()
        defer { controller.suspend(); window.orderOut(nil) }
        let options = controller.makeSeamOptions()
        let angle = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchPaperAngleControl }.first)
        XCTAssertFalse(angle.isHidden)
        XCTAssertTrue(options.bounds.contains(angle.frame))
        let animation = try XCTUnwrap(options.subviews.first { $0.identifier?.rawValue == "stitch.seam.animation" } as? NSButton)
        XCTAssertTrue(animation.isEnabled)
        XCTAssertFalse(editor.beautifyEnabled)
        let projection = try XCTUnwrap(editor.stitchDocument.flatMap { StitchAccordionProjection(document: $0) })
        let frame = StitchEditorController.paperOutputFrame(projection: projection,
            selection: editor.selectionRect, isFlipped: editor.isFlipped).insetBy(dx: -12, dy: -12)
        XCTAssertEqual(editor.screenshotPresentationRect, frame)
    }

    func testAngleChosenBeforeFirstCutPersistsAndIsUsedByTheFirstFold() throws {
        let (editor, controller, _, window) = try fixture(removeBand: false)
        defer { controller.suspend(); window.orderOut(nil) }
        let options = controller.makeSeamOptions()
        let angle = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchPaperAngleControl }.first)
        let animation = try XCTUnwrap(options.subviews.first { $0.identifier?.rawValue == "stitch.seam.animation" } as? NSButton)
        XCTAssertTrue(angle.isEnabled)
        XCTAssertFalse(animation.isEnabled)
        XCTAssertFalse(editor.canPreviewStitchPaper)
        let initialUndo = editor.undoStack.count
        let chosen = StitchPaperCamera(perspective: -18, yaw: 27)
        angle.onCameraBegin?()
        angle.onCameraChanged?(chosen)
        angle.onCameraEnd?(true)
        XCTAssertEqual(editor.undoStack.count, initialUndo + 1)
        XCTAssertEqual(editor.stitchDocument?.style.accordionPerspective, chosen.perspective)
        XCTAssertEqual(editor.stitchDocument?.style.accordionYaw, chosen.yaw)
        XCTAssertFalse(editor.stitchPreviewEnabled)
        let canvas = try XCTUnwrap(editor.subviews.compactMap { $0 as? StitchCanvasView }.first)
        canvas.onCut?(.horizontal, 40, 60)
        let folded = try XCTUnwrap(editor.stitchDocument)
        XCTAssertEqual(try XCTUnwrap(StitchAccordionProjection.Source(document: folded)).camera, chosen)
        XCTAssertTrue(editor.stitchPreviewEnabled)
        XCTAssertTrue(animation.isEnabled)
        XCTAssertEqual(editor.undoStack.count, initialUndo + 2)
    }

    func testUndoDuringAngleDragReleasesItsEscapeScopeAndIgnoresTheLaterMouseUp() throws {
        let (editor, controller, preview, window) = try fixture()
        defer { controller.suspend(); window.orderOut(nil) }
        let commands = ScreenshotCommandResponder.install(in: window, editor: editor)
        preview.onCameraBegin?()
        preview.onCameraChanged?(StitchPaperCamera(perspective: 20, yaw: -20))
        preview.onCameraEnd?(true)
        let options = controller.makeSeamOptions()
        editor.addSubview(options)
        let angle = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchPaperAngleControl }.first)
        let origin = angle.convert(CGPoint(x: angle.padRect.midX, y: angle.padRect.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
        }
        angle.mouseDown(with: try event(.leftMouseDown, origin))
        angle.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: origin.x + 10, y: origin.y + 5)))
        XCTAssertTrue(commands.hasTransientScope)
        editor.undo()
        XCTAssertFalse(commands.hasTransientScope)
        XCTAssertEqual(angle.camera, StitchPaperCamera())
        let undoCount = editor.undoStack.count
        angle.mouseUp(with: try event(.leftMouseUp, origin))
        XCTAssertFalse(commands.hasTransientScope)
        XCTAssertEqual(editor.undoStack.count, undoCount)
        XCTAssertEqual(editor.stitchDocument?.style.accordionPerspective, 14)
        XCTAssertEqual(editor.stitchDocument?.style.accordionYaw, 11.2)
    }
}
