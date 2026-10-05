import AppKit
import XCTest

@MainActor
final class CaptureStitchImageTests: XCTestCase {
    private func capture() throws -> ImageEditingView {
        let view = ImageEditingView(frame: CGRect(x: 0, y: 0, width: 200, height: 160))
        let source = ImageProbe.quadrantImage(width: 400, height: 320)
        let pixels = try XCTUnwrap(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let screenshot = NSImage(cgImage: pixels, size: view.bounds.size)
        view.captureSourceImage = screenshot
        view.screenshotImage = screenshot
        view.applySelection(CGRect(x: 20, y: 10, width: 100, height: 80))
        return view
    }

    private func assertSamePixels(_ first: NSImage, _ second: NSImage,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let a = try XCTUnwrap(ImageProbe.bitmap(from: first), file: file, line: line)
        let b = try XCTUnwrap(ImageProbe.bitmap(from: second), file: file, line: line)
        XCTAssertEqual(a.pixelsWide, b.pixelsWide, file: file, line: line)
        XCTAssertEqual(a.pixelsHigh, b.pixelsHigh, file: file, line: line)
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return }
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                XCTAssertEqual(ImageProbe.describePixel(bitmap: a, x: x, y: y),
                               ImageProbe.describePixel(bitmap: b, x: x, y: y), file: file, line: line)
            }
        }
    }

    func testBothCutsKeepTheOverlayAndExportSourcePixelsAtTwoTimesScale() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let view = try capture()
            let frame = view.frame
            let original = try XCTUnwrap(view.captureSelectedRegionRaw())
            XCTAssertTrue(view.beginStitchEditing())
            var next = try XCTUnwrap(view.stitchDocument)
            next.style.visible = false
            XCTAssertTrue(next.collapse(axis: axis, from: 40, to: 80))
            XCTAssertTrue(view.applyStitchDocument(next))
            let raw = try XCTUnwrap(view.captureSelectedRegionRaw())
            let expectedPixels = try XCTUnwrap(StitchRenderer.render(next))
            let expected = NSImage(cgImage: expectedPixels, size: raw.size)
            try assertSamePixels(raw, expected)
            XCTAssertEqual(view.frame, frame)
            XCTAssertFalse(view.isEditorMode)
            XCTAssertEqual(view.selectionRect.minX, 20)
            XCTAssertEqual(view.selectionRect.maxY, 90)
            XCTAssertEqual(raw.size, axis == .horizontal ? CGSize(width: 100, height: 60) : CGSize(width: 80, height: 80))
            view.undo()
            XCTAssertEqual(view.selectionRect, CGRect(x: 20, y: 10, width: 100, height: 80))
            try assertSamePixels(try XCTUnwrap(view.captureSelectedRegionRaw()), original)
            view.redo()
            try assertSamePixels(try XCTUnwrap(view.captureSelectedRegionRaw()), expected)
            XCTAssertEqual(view.frame, frame)
        }
    }

    func testOffsetAnnotationsFollowTheCutAndKeepTheirIdentityAcrossMixedUndo() throws {
        let view = try capture()
        let mark = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 30, y: 20),
                              endPoint: CGPoint(x: 40, y: 25), color: .red, strokeWidth: 2)
        view.annotations = [mark]
        view.undoStack = [.added(mark)]
        XCTAssertTrue(view.beginStitchEditing())
        var next = try XCTUnwrap(view.stitchDocument)
        next.style.visible = false
        XCTAssertTrue(next.collapse(axis: .horizontal, from: 40, to: 80))
        XCTAssertTrue(view.applyStitchDocument(next))
        XCTAssertTrue(view.annotations[0] === mark)
        XCTAssertEqual(mark.startPoint, CGPoint(x: 30, y: 40))
        let output = try XCTUnwrap(view.captureSelectedRegion())
        let red = try XCTUnwrap(ImageProbe.pixelColor(output, x: 25, y: 95)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(red.redComponent, 0.9)
        XCTAssertLessThan(red.greenComponent, 0.2)
        XCTAssertLessThan(red.blueComponent, 0.2)
        view.undo()
        XCTAssertTrue(view.annotations[0] === mark)
        XCTAssertEqual(mark.startPoint, CGPoint(x: 30, y: 20))
        view.undo()
        XCTAssertTrue(view.annotations.isEmpty)
        view.redo()
        XCTAssertTrue(view.annotations[0] === mark)
        view.redo()
        XCTAssertEqual(mark.startPoint, CGPoint(x: 30, y: 40))
    }

    func testStitchOnlyHistoryRestoresEditablePiecesAndCorrectRawPixels() throws {
        let view = try capture()
        XCTAssertTrue(view.beginStitchEditing())
        var next = try XCTUnwrap(view.stitchDocument)
        XCTAssertTrue(next.collapse(axis: .vertical, from: 40, to: 80))
        XCTAssertTrue(view.applyStitchDocument(next))
        let state = view.captureEditState()
        XCTAssertTrue(state.hasEditableContent)
        XCTAssertFalse(state.hasPostProcessing)
        let raw = try XCTUnwrap(view.captureSelectedRegionRaw())
        let editor = EditorView(frame: CGRect(origin: .zero, size: raw.size))
        editor.screenshotImage = raw
        editor.applySelection(editor.bounds)
        editor.applyCaptureEditState(state)
        XCTAssertEqual(editor.stitchDocument?.pieces.count, 2)
        try assertSamePixels(try XCTUnwrap(editor.captureSelectedRegionRaw()), raw)
    }

    func testEditedCaptureRejectsCropControlsAndResetReleasesItsSource() throws {
        let view = try capture()
        view.selectionIsWindowSnap = true
        view.snappedWindowID = 42
        view.snappedWindowImage = view.screenshotImage
        XCTAssertTrue(view.beginStitchEditing())
        XCTAssertFalse(view.selectionIsWindowSnap)
        XCTAssertNil(view.snappedWindowID)
        XCTAssertNil(view.snappedWindowImage)
        let rect = view.selectionRect
        XCTAssertFalse(view.shouldAllowSelectionResize())
        XCTAssertFalse(view.shouldAllowNewSelection())
        XCTAssertFalse(view.canStartKeyboardMoveSelection())
        XCTAssertFalse(view.applyPixelSize(w: 50, h: 50))
        view.applyLockedAspect(1)
        view.applySelection(CGRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertEqual(view.selectionRect, rect)
        view.currentTool = .rectangle
        XCTAssertFalse(view.shouldAllowSelectionResize())
        view.reset()
        XCTAssertNil(view.stitchDocument)
        XCTAssertNil(view.stitchCaptureBackdrop)
        XCTAssertTrue(view.shouldAllowSelectionResize())
    }

    func testInvertKeepsTheCropGeometryThroughUndoRedoAndReenteringStitch() throws {
        let view = try capture()
        let backdrop = try XCTUnwrap(view.screenshotImage)
        let originalRect = view.selectionRect
        view.usesExternalScreenshotPreview = true
        var backdropUpdates = 0
        view.externalScreenshotPreviewUpdater = { _ in backdropUpdates += 1 }
        XCTAssertTrue(view.beginStitchEditing())
        var document = try XCTUnwrap(view.stitchDocument)
        document.style.visible = false
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 40, to: 80))
        XCTAssertTrue(view.applyStitchDocument(document))
        let cut = try XCTUnwrap(view.captureSelectedRegionRaw())
        let expected = try XCTUnwrap(OverlayView.invertedCopy(of: cut))
        let cutRect = view.selectionRect

        view.handleToolbarAction(.invertColors)
        XCTAssertNil(view.stitchDocument)
        XCTAssertTrue(view.stitchCaptureBackdrop === backdrop)
        XCTAssertEqual(view.stitchCaptureSelectionRect, originalRect)
        XCTAssertEqual(view.captureDrawRect, cutRect)
        XCTAssertFalse(view.shouldAllowSelectionResize())
        XCTAssertFalse(view.shouldAllowNewSelection())
        XCTAssertEqual(view.selectionPixelSize.w, 200)
        XCTAssertEqual(view.selectionPixelSize.h, 120)
        let output = try XCTUnwrap(OverlayWindowController.captureRegion(in: view) {
            XCTFail("An image effect must not recapture the original desktop")
            return backdrop
        })
        try assertSamePixels(output, expected)
        XCTAssertEqual(backdropUpdates, 0)
        view.undo()
        XCTAssertEqual(view.stitchDocument?.pieces.count, 2)
        try assertSamePixels(try XCTUnwrap(view.captureSelectedRegionRaw()), cut)
        view.redo()
        try assertSamePixels(try XCTUnwrap(view.captureSelectedRegionRaw()), expected)
        XCTAssertTrue(view.beginStitchEditing())
        XCTAssertTrue(view.stitchCaptureBackdrop === backdrop)
        XCTAssertEqual(view.stitchCaptureSelectionRect, originalRect)
        try assertSamePixels(try XCTUnwrap(view.captureSelectedRegionRaw()), expected)
    }

    func testBeautifyPreviewUsesTheEditedCropInBothFrameModes() throws {
        for mode in [BeautifyMode.window, .rounded] {
            let view = try capture()
            view.showToolbars = false
            XCTAssertTrue(view.beginStitchEditing())
            var document = try XCTUnwrap(view.stitchDocument)
            document.style.visible = false
            XCTAssertTrue(document.collapse(axis: .horizontal, from: 40, to: 80))
            XCTAssertTrue(view.applyStitchDocument(document))
            let raw = try XCTUnwrap(view.captureSelectedRegionRaw())
            view.currentTool = .select
            view.showToolbars = false
            view.beautifyEnabled = true
            view.beautifyMode = mode
            view.beautifyPadding = 8
            view.beautifyCornerRadius = 0
            view.beautifyShadowRadius = 0
            view.effectsPreset = .none
            view.effectsBrightness = 0
            view.effectsContrast = 1
            view.effectsSaturation = 1
            view.effectsSharpness = 0
            let preview = ImageProbe.makeImage(width: 200, height: 160) { context in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
            for local in [CGPoint(x: 8, y: 8), CGPoint(x: 85, y: 8), CGPoint(x: 8, y: 55), CGPoint(x: 85, y: 55)] {
                let expected = try XCTUnwrap(ImageProbe.pixelColor(raw, x: Int(local.x * 2), y: Int((raw.size.height - local.y) * 2)))
                let actual = try XCTUnwrap(ImageProbe.pixelColor(preview, x: Int(view.selectionRect.minX + local.x),
                    y: Int(160 - view.selectionRect.minY - local.y)))
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.03, "\(mode), \(local)")
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.03, "\(mode), \(local)")
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.03, "\(mode), \(local)")
            }
        }
    }

    func testClearingAnEditedSelectionRestoresTheDesktopAndRemovesItsCanvas() throws {
        let view = try capture()
        let backdrop = try XCTUnwrap(view.screenshotImage)
        XCTAssertTrue(view.beginStitchEditing())
        var document = try XCTUnwrap(view.stitchDocument)
        XCTAssertTrue(document.collapse(axis: .vertical, from: 40, to: 80))
        XCTAssertTrue(view.applyStitchDocument(document))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = view
        defer { window.orderOut(nil) }
        let controller = StitchEditorController(document: document, window: window)
        view.onStitchToolChanged = { enabled in if !enabled { controller.suspend() } }
        view.currentTool = .stitch
        controller.attach(to: view)
        XCTAssertTrue(view.subviews.contains { $0 is StitchCanvasView })
        view.annotations = [Annotation(tool: .arrow, startPoint: CGPoint(x: 30, y: 30),
            endPoint: CGPoint(x: 60, y: 60), color: .red, strokeWidth: 2)]

        view.clearSelection()
        XCTAssertEqual(view.state, .idle)
        XCTAssertNil(view.stitchDocument)
        XCTAssertNil(view.stitchCaptureBackdrop)
        XCTAssertNil(view.stitchCaptureSelectionRect)
        XCTAssertTrue(view.screenshotImage === backdrop)
        XCTAssertTrue(view.captureSourceImage === backdrop)
        XCTAssertFalse(view.subviews.contains { $0 is StitchCanvasView })
        XCTAssertTrue(view.annotations.isEmpty)
        XCTAssertTrue(view.undoStack.isEmpty)
        XCTAssertTrue(view.redoStack.isEmpty)
        XCTAssertNotEqual(view.currentTool, .stitch)
        XCTAssertEqual(view.captureDrawRect, view.bounds)
        XCTAssertTrue(view.shouldAllowNewSelection())
        view.applySelection(CGRect(x: 80, y: 60, width: 90, height: 80))
        XCTAssertEqual(view.selectionRect, CGRect(x: 80, y: 60, width: 90, height: 80))
        try assertSamePixels(try XCTUnwrap(view.captureSelectedRegionRaw()),
            try XCTUnwrap(OverlayWindowController.captureRegion(in: view) { nil }))
    }
}
