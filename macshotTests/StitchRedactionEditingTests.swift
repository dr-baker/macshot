import AppKit
import XCTest

@MainActor
final class StitchRedactionEditingTests: XCTestCase {
    private func editor(_ document: StitchDocument) throws -> EditorView {
        let view = EditorView(frame: CGRect(origin: .zero, size: document.bounds.size))
        view.screenshotImage = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(document)), size: document.bounds.size)
        view.applySelection(view.bounds)
        view.showToolbars = false
        view.installStitchDocument(document)
        return view
    }

    private func document() throws -> StitchDocument {
        let image = try XCTUnwrap(ImageProbe.solidImage(width: 100, height: 100,
            color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: image)])
        document.style.visible = false
        return document
    }

    private func exported(_ view: EditorView) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(view.captureSelectedRegion())
        return NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    }

    private func assertRed(_ bitmap: NSBitmapImageRep, x: Int, canvasY: Int,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1 - canvasY), file: file, line: line)
        XCTAssertGreaterThan(color.redComponent, 0.99, file: file, line: line)
        XCTAssertLessThan(color.greenComponent, 0.01, file: file, line: line)
        XCTAssertLessThan(color.blueComponent, 0.01, file: file, line: line)
        XCTAssertGreaterThan(color.alphaComponent, 0.99, file: file, line: line)
    }

    func testFirstPieceMovementPreviewKeepsEveryCoveredSourcePixelRedacted() throws {
        let blue = try XCTUnwrap(ImageProbe.solidImage(width: 60, height: 60,
            color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var original = StitchDocument(pieces: [StitchPiece(image: blue),
            StitchPiece(image: blue, origin: CGPoint(x: 60, y: 0))])
        original.style.visible = false
        let view = try editor(original)
        let redaction = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 40, y: 10),
            endPoint: CGPoint(x: 80, y: 50), color: .red, strokeWidth: 1)
        view.annotations = [redaction]
        let originalUndo = view.undoStateIdentity
        let layers = view.stitchAnnotationLayers()
        var moved = original
        moved.pieces[1].origin = CGPoint(x: 100, y: 40)
        let raw = try XCTUnwrap(StitchRenderer.render(moved))
        let preview = ImageProbe.makeImage(width: 160, height: 100) { context in
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            NSImage(cgImage: raw, size: moved.bounds.size).draw(in: CGRect(origin: .zero, size: moved.bounds.size))
            for piece in moved.pieces {
                guard let layer = layers[piece.id], let image = layer.image,
                      let before = original.pieces.first(where: { $0.id == piece.id }) else { continue }
                let frame = layer.frame.offsetBy(dx: piece.origin.x - before.origin.x,
                    dy: piece.origin.y - before.origin.y)
                let rect = CGRect(x: frame.minX - moved.bounds.minX,
                    y: moved.bounds.maxY - frame.maxY, width: frame.width, height: frame.height)
                NSImage(cgImage: image, size: frame.size).draw(in: rect,
                    from: .zero, operation: .sourceOver, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(preview.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        for (xs, ys) in [(40..<60, 10..<50), (100..<120, 50..<90)] {
            for y in ys {
                for x in xs { try assertRed(bitmap, x: x, canvasY: 99 - y) }
            }
        }
        for point in [(30, 30), (130, 70)] {
            let source = try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1))
            XCTAssertGreaterThan(source.blueComponent, 0.99)
            XCTAssertLessThan(source.redComponent, 0.01)
        }
        XCTAssertTrue(view.annotations.first === redaction)
        XCTAssertNil(redaction.stitchAttachment)
        XCTAssertEqual(view.undoStateIdentity, originalUndo)
    }

    func testMaximumDimensionMovingLayerRetainsMasksDespiteOversizedOrdinaryMarks() throws {
        let width = Int(StitchDocument.maximumDimension)
        let blue = try XCTUnwrap(ImageProbe.solidImage(width: width, height: 100,
            color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var original = StitchDocument(pieces: [StitchPiece(image: blue)])
        original.style.visible = false
        let view = try editor(original)
        let redaction = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 0, y: 10),
            endPoint: CGPoint(x: 20, y: 30), color: .red, strokeWidth: 1)
        let largeOrdinaryMark = Annotation(tool: .rectangle, startPoint: CGPoint(x: 0, y: 40),
            endPoint: CGPoint(x: CGFloat(width), y: 60), color: .white, strokeWidth: 1)
        for marks in [[redaction], [redaction, largeOrdinaryMark]] {
            view.annotations = marks
            let layer = try XCTUnwrap(view.stitchAnnotationLayers()[original.pieces[0].id])
            let image = try XCTUnwrap(layer.image)
            XCTAssertEqual(image.width, width)
            XCTAssertEqual(image.height, 100)
            let bitmap = NSBitmapImageRep(cgImage: image)
            for y in 70..<90 {
                for x in 0..<20 {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                    let rgba = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                        .map { Int(($0 * 255).rounded()) }
                    XCTAssertEqual(rgba, [255, 0, 0, 255])
                }
            }
            XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 25, y: 79)).alphaComponent, 0)
        }
    }

    func testGapCenteredMaskUsesSourceLayersWithoutAStationaryDuplicate() throws {
        let blue = try XCTUnwrap(ImageProbe.solidImage(width: 40, height: 60,
            color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var original = StitchDocument(pieces: [StitchPiece(image: blue),
            StitchPiece(image: blue, origin: CGPoint(x: 80, y: 0))])
        original.style.visible = false
        let view = try editor(original)
        let crossing = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 20, y: 10),
            endPoint: CGPoint(x: 100, y: 50), color: .red, strokeWidth: 1)
        let gapOnly = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 55, y: 0),
            endPoint: CGPoint(x: 65, y: 6), color: .green, strokeWidth: 1)
        view.annotations = [crossing, gapOnly]
        let layers = view.stitchAnnotationLayers()
        for (piece, xs) in [(original.pieces[0], 20..<40), (original.pieces[1], 0..<20)] {
            let layer = try XCTUnwrap(layers[piece.id])
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(layer.image))
            for y in 10..<50 {
                for x in xs { try assertRed(bitmap, x: x, canvasY: y) }
            }
        }
        let stationary = NSBitmapImageRep(cgImage: try XCTUnwrap(view.stitchUnattachedAnnotationPreview()))
        for point in [(30, 30), (60, 30), (90, 30)] {
            XCTAssertEqual(try XCTUnwrap(stationary.colorAt(x: point.0, y: point.1)).alphaComponent, 0,
                "The crossing mask must move with source pieces without leaving stationary pixels.")
        }
        let gapPixel = try XCTUnwrap(stationary.colorAt(x: 60, y: 56))
        XCTAssertGreaterThan(gapPixel.greenComponent, 0.99)
        XCTAssertGreaterThan(gapPixel.alphaComponent, 0.99)
    }

    func testFailedMaskRasterDrawsOpaqueMovingPieceWhileUnredactedPieceRemainsVisible() throws {
        let blue = try XCTUnwrap(ImageProbe.solidImage(width: 40, height: 40,
            color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let green = try XCTUnwrap(ImageProbe.solidImage(width: 40, height: 40,
            color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: blue),
            StitchPiece(image: green, origin: CGPoint(x: 60, y: 0))])
        document.style.visible = false
        let canvas = StitchCanvasView(frame: .zero)
        canvas.refresh(document, preview: StitchRenderer.render(document))
        canvas.annotationLayers = [document.pieces[0].id: StitchAnnotationLayer(image: nil,
            frame: document.pieces[0].frame)]
        let window = NSWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = canvas
        defer { window.orderOut(nil) }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [.option],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 95, y: 95)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 105, y: 100)))
        let image = ImageProbe.makeImage(width: 260, height: 200) { context in
            context.translateBy(x: 0, y: 200)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            canvas.draw(canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let hidden = try XCTUnwrap(bitmap.colorAt(x: 105, y: 100))
        XCTAssertEqual([hidden.redComponent, hidden.greenComponent, hidden.blueComponent, hidden.alphaComponent], [0, 0, 0, 1])
        let visible = try XCTUnwrap(bitmap.colorAt(x: 160, y: 100))
        XCTAssertEqual([visible.redComponent, visible.greenComponent, visible.blueComponent, visible.alphaComponent], [0, 1, 0, 1])
    }

    func testResizeAndRotationReturningToOriginalGeometryRestoreExactFragmentClipAndPixels() throws {
        let defaults = UserDefaults.standard
        let doubleClickPreference = defaults.object(forKey: "doubleClickToCopy")
        defaults.set(false, forKey: "doubleClickToCopy")
        defer {
            if let doubleClickPreference { defaults.set(doubleClickPreference, forKey: "doubleClickToCopy") }
            else { defaults.removeObject(forKey: "doubleClickToCopy") }
        }
        for rotate in [false, true] {
            let original = try document(), view = try editor(original)
            let redaction = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 20, y: 20),
                endPoint: CGPoint(x: 70, y: 60), color: .red, strokeWidth: 1)
            redaction.rectCornerRadius = 6
            view.annotations = [redaction]
            var cut = original
            XCTAssertTrue(cut.collapse(axis: .vertical, from: 40, to: 50))
            XCTAssertTrue(view.applyStitchDocument(cut))
            let fragment = try XCTUnwrap(view.annotations.first)
            let originalGeometry = fragment.clone()
            let originalAttachment = try XCTUnwrap(fragment.stitchAttachment)
            let baseline = try exported(view)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            defer { window.orderOut(nil) }
            var timestamp: TimeInterval = 0
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                timestamp += 1
                return NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [.option],
                    timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            view.currentTool = .select
            view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 28, y: 40)))
            view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 28, y: 40)))
            // Drawing the selected mark installs the actual resize/rotation hit targets.
            _ = ImageProbe.makeImage(width: 90, height: 100) { context in
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                view.draw(view.bounds)
                NSGraphicsContext.restoreGraphicsState()
            }
            let originalUndo = view.undoStateIdentity
            let originalDepth = view.undoStack.count
            var revisions = 0
            view.onContentChanged = { revisions += 1 }
            let handle = rotate ? CGPoint(x: 45, y: 84.5) : CGPoint(x: 15.5, y: 40)
            let away = rotate ? CGPoint(x: 65, y: 80) : CGPoint(x: 10.5, y: 40)
            view.mouseDown(with: mouse(.leftMouseDown, handle))
            view.mouseDragged(with: mouse(.leftMouseDragged, away))
            XCTAssertNotEqual(fragment.stitchAttachment, originalAttachment,
                "The real geometry gesture must exercise fragment detachment.")
            view.mouseDragged(with: mouse(.leftMouseDragged, handle))
            view.mouseUp(with: mouse(.leftMouseUp, handle))
            XCTAssertEqual(fragment.startPoint, originalGeometry.startPoint)
            XCTAssertEqual(fragment.endPoint, originalGeometry.endPoint)
            XCTAssertEqual(fragment.rotation, 0, accuracy: 0.0001)
            XCTAssertEqual(fragment.stitchAttachment, originalAttachment)
            XCTAssertEqual(view.undoStack.count, originalDepth)
            XCTAssertEqual(view.undoStateIdentity, originalUndo)
            XCTAssertEqual(revisions, 0)
            let returned = try exported(view)
            XCTAssertEqual(returned.pixelsWide, baseline.pixelsWide)
            XCTAssertEqual(returned.pixelsHigh, baseline.pixelsHigh)
            for y in 0..<baseline.pixelsHigh {
                for x in 0..<baseline.pixelsWide {
                    XCTAssertEqual(ImageProbe.describePixel(bitmap: returned, x: x, y: y),
                        ImageProbe.describePixel(bitmap: baseline, x: x, y: y))
                }
            }
        }
    }

    func testResizingCutFragmentPaintsNewCoverageAndRetainsItThroughReloadAndSourceMove() throws {
        let original = try document(), view = try editor(original)
        let redaction = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 10, y: 20),
            endPoint: CGPoint(x: 90, y: 80), color: .red, strokeWidth: 1)
        view.annotations = [redaction]
        var cut = original
        XCTAssertTrue(cut.collapse(axis: .horizontal, from: 40, to: 60))
        XCTAssertTrue(view.applyStitchDocument(cut))
        let fragment = try XCTUnwrap(view.annotations.first { $0.boundingRect.minY == 40 })
        let beforeResize = fragment.clone()
        fragment.endPoint.x = 98
        fragment.updateStitchClipForGeometryEdit()
        view.undoStack.append(.propertyChange(annotation: fragment, snapshot: beforeResize))
        try assertRed(exported(view), x: 95, canvasY: 50)
        view.undo()
        let undone = try XCTUnwrap(try exported(view).colorAt(x: 95, y: 29))
        XCTAssertGreaterThan(undone.blueComponent, 0.99)
        view.redo()
        try assertRed(exported(view), x: 95, canvasY: 50)

        let saved = try XCTUnwrap(view.savedStitchDocument)
        let restored = try XCTUnwrap(saved.restore())
        let reopened = try editor(restored)
        reopened.setAnnotations(try XCTUnwrap(AnnotationSerializer.decode(
            try XCTUnwrap(AnnotationSerializer.encode(view.annotations)), requireAll: true)))
        try assertRed(exported(reopened), x: 95, canvasY: 50)
        var moved = restored
        moved.pieces[0].origin.x += 20
        XCTAssertTrue(reopened.applyStitchDocument(moved))
        try assertRed(exported(reopened), x: 115, canvasY: 50)
        reopened.undo()
        try assertRed(exported(reopened), x: 95, canvasY: 50)
        reopened.redo()
        try assertRed(exported(reopened), x: 115, canvasY: 50)
    }

    func testCensorsReopenedAfterCanvasGrowthRebakeFromTheNewSourceWhenMoved() throws {
        for tool in [AnnotationTool.pixelate, .blur] {
            let blue = ImageProbe.solidImage(width: 60, height: 60,
                color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            let green = ImageProbe.makeImage(width: 60, height: 60) { context in
                context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 60, height: 60))
                context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                context.fill(CGRect(x: 19, y: 19, width: 2, height: 2))
            }
            var original = StitchDocument(pieces: [StitchPiece(image: try XCTUnwrap(blue.cgImage(forProposedRect: nil, context: nil, hints: nil)))])
            original.style.visible = false
            let view = try editor(original)
            let redaction = Annotation(tool: tool, startPoint: CGPoint(x: 10, y: 10),
                endPoint: CGPoint(x: 30, y: 30), color: .black, strokeWidth: 1)
            redaction.censorMode = tool == .blur ? .blur : .pixelate
            view.setAnnotations([redaction])
            var grown = original
            grown.pieces.append(StitchPiece(image: try XCTUnwrap(green.cgImage(forProposedRect: nil, context: nil, hints: nil)),
                origin: CGPoint(x: 0, y: 60)))
            XCTAssertTrue(view.applyStitchDocument(grown))
            view.undo(); view.redo()
            let restored = try XCTUnwrap(try XCTUnwrap(view.savedStitchDocument).restore())
            let reopened = try editor(restored)
            reopened.setAnnotations(try XCTUnwrap(AnnotationSerializer.decode(
                try XCTUnwrap(AnnotationSerializer.encode(view.annotations)), requireAll: true)))
            let mark = try XCTUnwrap(reopened.annotations.first)
            XCTAssertTrue(mark.sourceImage === reopened.screenshotImage)
            XCTAssertEqual(mark.sourceImageBounds, CGRect(x: 0, y: 0, width: 60, height: 120))
            let snapshot = mark.clone()
            mark.move(dx: 0, dy: -60)
            mark.bakePixelate()
            reopened.undoStack.append(.propertyChange(annotation: mark, snapshot: snapshot))
            let pixel = try XCTUnwrap(try exported(reopened).colorAt(x: 20, y: 99))
            XCTAssertGreaterThan(pixel.greenComponent, 0.5, "The moved censor must hide the black mark using the new green source.")
            XCTAssertLessThan(pixel.blueComponent, 0.1)
            XCTAssertGreaterThan(pixel.alphaComponent, 0.99)
            reopened.undo()
            let raw = try XCTUnwrap(try exported(reopened).colorAt(x: 20, y: 99))
            XCTAssertLessThan(raw.greenComponent, 0.1, "Undo moves the censor back, exposing the original black fixture.")
            reopened.redo()
            let redone = try XCTUnwrap(try exported(reopened).colorAt(x: 20, y: 99))
            XCTAssertGreaterThan(redone.greenComponent, 0.5)
            XCTAssertLessThan(redone.blueComponent, 0.1)
        }
    }

    func testFlipMirrorsFragmentClipsAndBakedPixelsThroughUndoAndRedo() throws {
        let original = try document(), view = try editor(original)
        let redaction = Annotation(tool: .pixelate, startPoint: CGPoint(x: 10, y: 20),
            endPoint: CGPoint(x: 90, y: 80), color: .black, strokeWidth: 1)
        redaction.bakedBlurNSImage = ImageProbe.quadrantImage(width: 80, height: 60)
        view.annotations = [redaction]
        var cut = original
        XCTAssertTrue(cut.collapse(axis: .horizontal, from: 40, to: 60))
        XCTAssertTrue(view.applyStitchDocument(cut))
        var baseline = try exported(view)
        for horizontal in [true, false] {
            if horizontal { view.flipImageHorizontally() } else { view.flipImageVertically() }
            let mirrored = try exported(view)
            for y in 0..<baseline.pixelsHigh {
                for x in 0..<baseline.pixelsWide {
                    XCTAssertEqual(ImageProbe.describePixel(bitmap: mirrored, x: x, y: y),
                        ImageProbe.describePixel(bitmap: baseline,
                            x: horizontal ? baseline.pixelsWide - 1 - x : x,
                            y: horizontal ? y : baseline.pixelsHigh - 1 - y))
                }
            }
            view.undo()
            let undone = try exported(view)
            for point in [(20, 25), (75, 25), (20, 55), (75, 55)] {
                XCTAssertEqual(ImageProbe.describePixel(bitmap: undone, x: point.0, y: point.1),
                    ImageProbe.describePixel(bitmap: baseline, x: point.0, y: point.1))
            }
            view.redo()
            baseline = try exported(view)
        }
    }

    func testFractionalCropUsesResolvedPixelsForFragmentGeometryAndUndo() throws {
        let original = try document(), view = try editor(original)
        let redaction = Annotation(tool: .pixelate, startPoint: CGPoint(x: 10, y: 20),
            endPoint: CGPoint(x: 90, y: 80), color: .black, strokeWidth: 1)
        redaction.bakedBlurNSImage = ImageProbe.quadrantImage(width: 80, height: 60)
        view.annotations = [redaction]
        var cut = original
        XCTAssertTrue(cut.collapse(axis: .horizontal, from: 40, to: 60))
        XCTAssertTrue(view.applyStitchDocument(cut))
        let baseline = try exported(view)
        view.currentTool = .crop
        view.showToolbars = false
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [.option],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        view.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 10.2, y: 10.2)))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 90.6, y: 70.6)))
        view.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 90.6, y: 70.6)))
        let cropped = try exported(view)
        XCTAssertEqual(cropped.pixelsWide, 80)
        XCTAssertEqual(cropped.pixelsHigh, 60)
        guard cropped.pixelsWide == 80, cropped.pixelsHigh == 60 else { return }
        for y in 0..<60 {
            for x in 0..<80 {
                XCTAssertEqual(ImageProbe.describePixel(bitmap: cropped, x: x, y: y),
                    ImageProbe.describePixel(bitmap: baseline, x: x + 10, y: y + 9))
            }
        }
        view.undo()
        XCTAssertEqual(try exported(view).pixelsHigh, 80)
        view.redo()
        XCTAssertEqual(try exported(view).pixelsHigh, 60)
    }

    func testRejectedSourceChangeAndControllerCutPreservePixelsAndUndoAtomically() throws {
        let original = try document(), view = try editor(original)
        let redaction = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 10, y: 20),
            endPoint: CGPoint(x: 90, y: 80), color: .red, strokeWidth: 1)
        view.annotations = [redaction]
        view.undoStack = [.added(redaction)]
        let originalImage = view.screenshotImage
        var replaced = original
        var replacement = StitchPiece(image: try XCTUnwrap(ImageProbe.quadrantImage(width: 100, height: 100)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)))
        replacement.id = original.pieces[0].id
        replacement.lineageID = original.pieces[0].lineageID
        replaced.pieces = [replacement]
        XCTAssertFalse(view.applyStitchDocument(replaced))
        XCTAssertEqual(view.undoStack.count, 1)
        XCTAssertTrue(view.screenshotImage === originalImage)
        XCTAssertTrue(view.annotations[0] === redaction)
        try assertRed(exported(view), x: 20, canvasY: 25)

        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        let controller = StitchEditorController(document: original, window: window)
        var refuseCut = true
        controller.onDocumentChanged = { next, registerUndo in
            if refuseCut && next.bounds.height < original.bounds.height { return false }
            return view.applyStitchDocument(next, registerUndo: registerUndo)
        }
        controller.attach(to: view)
        defer { controller.suspend(); window.orderOut(nil) }
        let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? StitchCanvasView }.first)
        canvas.selectedID = original.pieces[0].id
        canvas.onCut?(.horizontal, 40, 60)
        XCTAssertEqual(canvas.document.bounds, original.bounds)
        XCTAssertEqual(canvas.selectedID, original.pieces[0].id)
        XCTAssertEqual(view.undoStack.count, 1)
        XCTAssertTrue(view.screenshotImage === originalImage)
        try assertRed(exported(view), x: 20, canvasY: 25)
        refuseCut = false
        canvas.onCut?(.horizontal, 40, 60)
        XCTAssertEqual(view.undoStack.count, 2)
        XCTAssertEqual(canvas.document.bounds.height, 80)
        try assertRed(exported(view), x: 20, canvasY: 25)
        try assertRed(exported(view), x: 20, canvasY: 55)
    }

    func testFullyRemovedRedactionDisappearsWithItsSourcePixelsAndUndoRestoresProtection() throws {
        let original = try document(), view = try editor(original)
        let redaction = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 10, y: 45),
            endPoint: CGPoint(x: 90, y: 55), color: .red, strokeWidth: 1)
        view.annotations = [redaction]
        try assertRed(exported(view), x: 20, canvasY: 50)
        var cut = original
        XCTAssertTrue(cut.collapse(axis: .horizontal, from: 40, to: 60))
        XCTAssertTrue(view.applyStitchDocument(cut))
        let removed = try exported(view)
        for y in 0..<removed.pixelsHigh {
            for x in 0..<removed.pixelsWide {
                let pixel = try XCTUnwrap(removed.colorAt(x: x, y: y))
                XCTAssertLessThan(pixel.redComponent, 0.01)
                XCTAssertGreaterThan(pixel.blueComponent, 0.99)
            }
        }
        view.undo()
        XCTAssertTrue(view.annotations.first === redaction)
        try assertRed(exported(view), x: 20, canvasY: 50)
        view.redo()
        XCTAssertTrue(view.annotations.isEmpty)
    }

    func testRootedLoupeSourceAndLensFollowTheirOwnPiecesWhileNormalDragMovesOnlyLens() throws {
        let blue = try XCTUnwrap(ImageProbe.solidImage(width: 60, height: 60,
            color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let green = try XCTUnwrap(ImageProbe.solidImage(width: 60, height: 60,
            color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var original = StitchDocument(pieces: [StitchPiece(image: blue), StitchPiece(image: green, origin: CGPoint(x: 60, y: 0))])
        original.style.visible = false
        let view = try editor(original)
        let loupe = Annotation(tool: .loupe, startPoint: CGPoint(x: 80, y: 20),
            endPoint: CGPoint(x: 100, y: 40), color: .white, strokeWidth: 1)
        loupe.loupeSourceRect = CGRect(x: 15, y: 25, width: 10, height: 10)
        view.setAnnotations([loupe])
        var moved = original
        moved.pieces[1].origin = CGPoint(x: 80, y: 40)
        XCTAssertTrue(view.applyStitchDocument(moved))
        XCTAssertEqual(loupe.boundingRect.midX, 110)
        XCTAssertEqual(loupe.boundingRect.midY, 30)
        XCTAssertEqual(loupe.loupeSourceRect?.midX, 20)
        XCTAssertEqual(loupe.loupeSourceRect?.midY, 70)
        let lens = try XCTUnwrap(try exported(view).colorAt(x: 110, y: 69))
        XCTAssertGreaterThan(lens.blueComponent, 0.99)
        XCTAssertLessThan(lens.greenComponent, 0.01)
        let rooted = loupe.loupeSourceRect
        loupe.move(dx: 10, dy: 0)
        loupe.bakeLoupe()
        XCTAssertEqual(loupe.loupeSourceRect, rooted)
        let dragged = try XCTUnwrap(try exported(view).colorAt(x: 120, y: 69))
        XCTAssertGreaterThan(dragged.blueComponent, 0.99)
        XCTAssertLessThan(dragged.greenComponent, 0.01)
    }
}
