import AppKit
import XCTest

@MainActor
final class StitchRedactionTests: XCTestCase {
    private let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    private let blueRGBA = [0, 0, 255, 255]
    private let greenRGBA = [0, 255, 0, 255]
    private let redRGBA = [255, 0, 0, 255]
    private let clearRGBA = [0, 0, 0, 0]

    private func withPlainDefaults(_ body: () throws -> Void) rethrows {
        try withDefaults([
            "beautifyEnabled": false, "beautifyStyleIndex": 0, "rememberLastTool": false,
            "effectsPreset": ImageEffectPreset.none.rawValue, "effectsBrightness": 0.0,
            "effectsContrast": 1.0, "effectsSaturation": 1.0, "effectsSharpness": 0.0,
            "downscaleRetina": false,
        ], body)
    }

    private func source(width: Int, height: Int, green: Bool = false) throws -> CGImage {
        try XCTUnwrap(ImageProbe.solidImage(width: width, height: height,
            color: CGColor(srgbRed: 0, green: green ? 1 : 0, blue: green ? 0 : 1, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private func singleDocument() throws -> StitchDocument {
        var document = StitchDocument(pieces: [StitchPiece(image: try source(width: 160, height: 120),
            origin: CGPoint(x: -80, y: -60))], background: .transparent)
        document.style.visible = false
        return document
    }

    private func pairedDocument() throws -> StitchDocument {
        var document = StitchDocument(pieces: [
            StitchPiece(image: try source(width: 80, height: 64), origin: CGPoint(x: -40, y: -24)),
            StitchPiece(image: try source(width: 80, height: 64, green: true), origin: CGPoint(x: 40, y: -24)),
        ], background: .transparent)
        document.style.visible = false
        return document
    }

    private func editor(_ document: StitchDocument, scale: CGFloat = 1) throws -> EditorView {
        let size = CGSize(width: document.bounds.width / scale, height: document.bounds.height / scale)
        let view = EditorView(frame: CGRect(origin: .zero, size: size))
        view.beautifyEnabled = false
        view.effectsPreset = .none
        view.effectsBrightness = 0
        view.effectsContrast = 1
        view.effectsSaturation = 1
        view.effectsSharpness = 0
        view.screenshotImage = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(document)), size: size)
        view.applySelection(view.bounds)
        view.showToolbars = false
        view.installStitchDocument(document)
        return view
    }

    /// Fixture rectangles and pixel assertions use top-down native pixels.
    /// Only this initial placement converts them into the editor's point coordinates.
    private func redaction(_ document: StitchDocument, rect: CGRect, scale: CGFloat = 1,
        tool: AnnotationTool = .filledRectangle, mode: CensorMode = .pixelate,
        baked: NSImage? = nil) -> Annotation {
        let canvas = CGRect(x: rect.minX / scale, y: (document.bounds.height - rect.maxY) / scale,
            width: rect.width / scale, height: rect.height / scale)
        let annotation = Annotation(tool: tool, startPoint: canvas.origin,
            endPoint: CGPoint(x: canvas.maxX, y: canvas.maxY), color: red, strokeWidth: 2)
        annotation.censorMode = mode
        if let baked {
            baked.size = canvas.size
            annotation.bakedBlurNSImage = baked
        }
        return annotation
    }

    /// Every quadrant is opaque and differs from the blue and green source images.
    private func opaqueBake(width: Int, height: Int) -> NSImage {
        ImageProbe.makeImage(width: width, height: height) { context in
            let w = CGFloat(width) / 2, h = CGFloat(height) / 2
            for (rect, color) in [
                (CGRect(x: 0, y: h, width: w, height: h), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
                (CGRect(x: w, y: h, width: w, height: h), CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)),
                (CGRect(x: 0, y: 0, width: w, height: h), CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)),
                (CGRect(x: w, y: 0, width: w, height: h), CGColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)),
            ] {
                context.setFillColor(color)
                context.fill(rect)
            }
        }
    }

    private func exported(_ view: EditorView, file: StaticString = #filePath, line: UInt = #line) throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(view.captureSelectedRegion(), file: file, line: line)
        let bitmap = try XCTUnwrap(ImageProbe.bitmap(from: image), file: file, line: line)
        let document = try XCTUnwrap(view.stitchDocument, file: file, line: line)
        XCTAssertEqual(bitmap.pixelsWide, Int(document.bounds.integral.width), file: file, line: line)
        XCTAssertEqual(bitmap.pixelsHigh, Int(document.bounds.integral.height), file: file, line: line)
        return bitmap
    }

    private func rgba(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> [Int]? {
        guard x >= 0, y >= 0, x < bitmap.pixelsWide, y < bitmap.pixelsHigh,
            let color = bitmap.colorAt(x: x, y: y) else { return nil }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            .map { Int(($0 * 255).rounded()) }
    }

    private func assertRegion(_ bitmap: NSBitmapImageRep, rect: CGRect, equals expected: [Int],
        tolerance: Int = 0, file: StaticString = #filePath, line: UInt = #line) {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let actual = rgba(bitmap, x: x, y: y),
                    zip(actual, expected).allSatisfy({ abs($0 - $1) <= tolerance }) else {
                    XCTFail("Pixel \(x),\(y) is \(String(describing: rgba(bitmap, x: x, y: y))); expected \(expected)",
                        file: file, line: line)
                    return
                }
            }
        }
    }

    private func assertRegion(_ actual: NSBitmapImageRep, at origin: CGPoint,
        matches expected: NSBitmapImageRep, rect: CGRect, tolerance: Int = 1,
        file: StaticString = #filePath, line: UInt = #line) {
        for y in 0..<Int(rect.height) {
            for x in 0..<Int(rect.width) {
                let ax = Int(origin.x) + x, ay = Int(origin.y) + y
                let ex = Int(rect.minX) + x, ey = Int(rect.minY) + y
                let actualPixel = rgba(actual, x: ax, y: ay), expectedPixel = rgba(expected, x: ex, y: ey)
                guard let a = actualPixel, let e = expectedPixel,
                    zip(a, e).allSatisfy({ abs($0 - $1) <= tolerance }) else {
                    XCTFail("Export pixel \(ax),\(ay) is \(String(describing: actualPixel)); retained fixture pixel \(ex),\(ey) is \(String(describing: expectedPixel))",
                        file: file, line: line)
                    return
                }
            }
        }
    }

    private func assertSameExport(_ actual: NSBitmapImageRep, _ expected: NSBitmapImageRep,
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.pixelsWide, expected.pixelsWide, file: file, line: line)
        XCTAssertEqual(actual.pixelsHigh, expected.pixelsHigh, file: file, line: line)
        assertRegion(actual, at: .zero, matches: expected,
            rect: CGRect(x: 0, y: 0, width: expected.pixelsWide, height: expected.pixelsHigh),
            tolerance: 0, file: file, line: line)
    }

    private func assertAttachments(_ view: EditorView, lineages: Set<UUID>,
        file: StaticString = #filePath, line: UInt = #line) throws {
        let document = try XCTUnwrap(view.stitchDocument, file: file, line: line)
        var found: Set<UUID> = []
        for annotation in view.annotations {
            let attachment = try XCTUnwrap(annotation.stitchAttachment, file: file, line: line)
            let piece = try XCTUnwrap(document.pieces.first { $0.id == attachment.pieceID }, file: file, line: line)
            XCTAssertEqual(attachment.lineageID, piece.lineageID, file: file, line: line)
            XCTAssertTrue(attachment.isValid, file: file, line: line)
            found.insert(piece.lineageID)
        }
        XCTAssertEqual(found, lineages, file: file, line: line)
    }

    private func assertCurrentSources(_ view: EditorView, file: StaticString = #filePath, line: UInt = #line) {
        for annotation in view.annotations where annotation.tool == .pixelate || annotation.tool == .blur {
            XCTAssertTrue(annotation.sourceImage === view.screenshotImage, file: file, line: line)
            XCTAssertEqual(annotation.sourceImageBounds, view.captureDrawRect, file: file, line: line)
            XCTAssertNotNil(annotation.bakedBlurNSImage, file: file, line: line)
        }
    }

    private func assertIdentities(_ actual: [Annotation], _ expected: [Annotation],
        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) { XCTAssertTrue(a === e, file: file, line: line) }
    }

    private func checkFilledCut(axis: StitchAxis, lower: CGFloat, upper: CGFloat) throws {
        try withPlainDefaults {
            for scale in [CGFloat(1), CGFloat(2)] {
                let original = try singleDocument(), view = try editor(original, scale: scale)
                let annotation = redaction(original, rect: CGRect(x: 24, y: 24, width: 112, height: 72), scale: scale)
                view.setAnnotations([annotation])
                let before = try exported(view)
                var cut = original
                let start = axis == .horizontal ? original.bounds.minY : original.bounds.minX
                XCTAssertTrue(cut.collapse(axis: axis, from: start + lower, to: start + upper))
                XCTAssertTrue(view.applyStitchDocument(cut))
                let after = try exported(view)
                let protected = axis == .horizontal
                    ? CGRect(x: 24, y: 24, width: 112, height: 52)
                    : CGRect(x: 24, y: 24, width: 92, height: 72)
                assertRegion(after, rect: protected, equals: redRGBA)
                assertRegion(after, rect: CGRect(x: 4, y: 4, width: 12, height: 12), equals: blueRGBA)
                assertRegion(after, rect: CGRect(x: after.pixelsWide - 16, y: after.pixelsHigh - 16,
                    width: 12, height: 12), equals: blueRGBA)
                XCTAssertEqual(view.screenshotImage?.size,
                    CGSize(width: CGFloat(after.pixelsWide) / scale, height: CGFloat(after.pixelsHigh) / scale))
                XCTAssertEqual(view.annotations.count, 2)
                let fragments = view.annotations
                XCTAssertTrue(fragments.first === annotation)
                try assertAttachments(view, lineages: [original.pieces[0].lineageID])
                XCTAssertEqual(Set(fragments.compactMap { $0.stitchAttachment?.pieceID }), Set(cut.pieces.map(\.id)))

                view.undo()
                assertIdentities(view.annotations, [annotation])
                XCTAssertNil(annotation.stitchAttachment)
                assertSameExport(try exported(view), before)
                view.redo()
                assertIdentities(view.annotations, fragments)
                assertSameExport(try exported(view), after)
            }
        }
    }

    func testHorizontalCutPreservesFilledRedactionWhoseCenterIsRemoved() throws {
        try checkFilledCut(axis: .horizontal, lower: 50, upper: 70)
    }

    func testHorizontalCutPreservesBothSidesWhenFilledRedactionCenterSurvives() throws {
        try checkFilledCut(axis: .horizontal, lower: 35, upper: 55)
    }

    func testVerticalCutPreservesFilledRedactionWhoseCenterIsRemoved() throws {
        try checkFilledCut(axis: .vertical, lower: 70, upper: 90)
    }

    func testVerticalCutPreservesBothSidesWhenFilledRedactionCenterSurvives() throws {
        try checkFilledCut(axis: .vertical, lower: 55, upper: 75)
    }

    func testFinalizedCensorSliversOfOneToFourPointsRemainOpaqueOnBothAxesAtTwoTimesScale() throws {
        try withPlainDefaults {
            for tool in [AnnotationTool.pixelate, .blur] {
                for axis in [StitchAxis.horizontal, .vertical] {
                    for points in [1, 2, 4] {
                        let original = try singleDocument(), view = try editor(original, scale: 2)
                        let bake = opaqueBake(width: 64, height: 64)
                        let fixture = try XCTUnwrap(ImageProbe.bitmap(from: bake))
                        let annotation = redaction(original, rect: CGRect(x: 48, y: 28, width: 64, height: 64),
                            scale: 2, tool: tool, mode: tool == .blur ? .blur : .pixelate, baked: bake)
                        view.setAnnotations([annotation])
                        let before = try exported(view)
                        let retained = CGFloat(points * 2)
                        var cut = original
                        let lower = axis == .horizontal ? original.bounds.minY + 28 : original.bounds.minX + 48
                        XCTAssertTrue(cut.collapse(axis: axis, from: lower + retained, to: lower + 64 - retained))
                        XCTAssertTrue(view.applyStitchDocument(cut))
                        let after = try exported(view)
                        if axis == .horizontal {
                            assertRegion(after, at: CGPoint(x: 48, y: 28), matches: fixture,
                                rect: CGRect(x: 0, y: 0, width: 64, height: retained))
                            assertRegion(after, at: CGPoint(x: 48, y: 28 + retained), matches: fixture,
                                rect: CGRect(x: 0, y: 64 - retained, width: 64, height: retained))
                        } else {
                            assertRegion(after, at: CGPoint(x: 48, y: 28), matches: fixture,
                                rect: CGRect(x: 0, y: 0, width: retained, height: 64))
                            assertRegion(after, at: CGPoint(x: 48 + retained, y: 28), matches: fixture,
                                rect: CGRect(x: 64 - retained, y: 0, width: retained, height: 64))
                        }
                        assertRegion(after, rect: CGRect(x: 4, y: 4, width: 8, height: 8), equals: blueRGBA)
                        XCTAssertEqual(view.annotations.count, 2)
                        for fragment in view.annotations {
                            let size = axis == .horizontal ? fragment.boundingRect.height : fragment.boundingRect.width
                            XCTAssertEqual(size, CGFloat(points))
                        }
                        assertCurrentSources(view)
                        let fragments = view.annotations, bakes = fragments.map(\.bakedBlurNSImage)
                        view.undo()
                        assertIdentities(view.annotations, [annotation])
                        XCTAssertTrue(annotation.bakedBlurNSImage === bake)
                        assertCurrentSources(view)
                        assertSameExport(try exported(view), before)
                        view.redo()
                        assertIdentities(view.annotations, fragments)
                        for (fragment, image) in zip(view.annotations, bakes) {
                            XCTAssertTrue(fragment.bakedBlurNSImage === image)
                        }
                        assertCurrentSources(view)
                        assertSameExport(try exported(view), after)
                    }
                }
            }
        }
    }

    func testCrossingFilledRedactionFollowsBothCapturesThroughMovePackReorderAndReflow() throws {
        try withPlainDefaults {
            let original = try pairedDocument(), view = try editor(original)
            let annotation = redaction(original, rect: CGRect(x: 48, y: 16, width: 64, height: 32))
            view.setAnnotations([annotation])
            let before = try exported(view)
            var moved = original
            moved.pieces[0].origin = CGPoint(x: -80, y: 8)
            XCTAssertTrue(view.applyStitchDocument(moved))
            let movedPixels = try exported(view)
            assertRegion(movedPixels, rect: CGRect(x: 48, y: 48, width: 32, height: 32), equals: redRGBA)
            assertRegion(movedPixels, rect: CGRect(x: 120, y: 16, width: 32, height: 32), equals: redRGBA)
            assertRegion(movedPixels, rect: CGRect(x: 96, y: 40, width: 8, height: 8), equals: clearRGBA)
            assertRegion(movedPixels, rect: CGRect(x: 4, y: 36, width: 8, height: 8), equals: blueRGBA)
            assertRegion(movedPixels, rect: CGRect(x: 124, y: 4, width: 8, height: 8), equals: greenRGBA)
            let fragments = view.annotations
            try assertAttachments(view, lineages: Set(original.pieces.map(\.lineageID)))

            var packed = moved
            XCTAssertTrue(packed.pack())
            XCTAssertTrue(view.applyStitchDocument(packed))
            let packedPixels = try exported(view)
            assertRegion(packedPixels, rect: CGRect(x: 0, y: 16, width: 32, height: 32), equals: redRGBA)
            assertRegion(packedPixels, rect: CGRect(x: 128, y: 16, width: 32, height: 32), equals: redRGBA)
            assertRegion(packedPixels, rect: CGRect(x: 40, y: 4, width: 8, height: 8), equals: greenRGBA)
            assertRegion(packedPixels, rect: CGRect(x: 88, y: 4, width: 8, height: 8), equals: blueRGBA)

            var reordered = packed
            XCTAssertTrue(reordered.movePacked(id: original.pieces[0].id, proposed: CGPoint(x: -200, y: -24)))
            XCTAssertTrue(view.applyStitchDocument(reordered))
            let reorderedPixels = try exported(view)
            assertRegion(reorderedPixels, rect: CGRect(x: 48, y: 16, width: 64, height: 32), equals: redRGBA)
            assertRegion(reorderedPixels, rect: CGRect(x: 4, y: 4, width: 8, height: 8), equals: blueRGBA)
            assertRegion(reorderedPixels, rect: CGRect(x: 124, y: 4, width: 8, height: 8), equals: greenRGBA)
            assertIdentities(view.annotations, fragments)

            var reflowed = reordered
            reflowed.pieces.removeFirst()
            XCTAssertTrue(reflowed.reflowPacked())
            XCTAssertTrue(view.applyStitchDocument(reflowed))
            let reflowedPixels = try exported(view)
            assertRegion(reflowedPixels, rect: CGRect(x: 0, y: 16, width: 32, height: 32), equals: redRGBA)
            assertRegion(reflowedPixels, rect: CGRect(x: 40, y: 4, width: 8, height: 8), equals: greenRGBA)
            try assertAttachments(view, lineages: [original.pieces[1].lineageID])

            view.undo()
            assertIdentities(view.annotations, fragments)
            assertSameExport(try exported(view), reorderedPixels)
            view.undo()
            assertSameExport(try exported(view), packedPixels)
            view.undo()
            assertSameExport(try exported(view), movedPixels)
            view.undo()
            assertIdentities(view.annotations, [annotation])
            assertSameExport(try exported(view), before)
            for _ in 0..<4 { view.redo() }
            assertSameExport(try exported(view), reflowedPixels)
        }
    }

    func testFinalizedCensorModesRetainOpaqueBakeThroughStyleBackgroundMovementUndoAndReload() throws {
        try withPlainDefaults {
            let modes: [(AnnotationTool, CensorMode)] = [
                (.pixelate, .pixelate), (.pixelate, .blur), (.pixelate, .solid), (.pixelate, .erase), (.blur, .blur),
            ]
            for (tool, mode) in modes {
                let original = try pairedDocument(), view = try editor(original)
                let bake = opaqueBake(width: 64, height: 32)
                let fixture = try XCTUnwrap(ImageProbe.bitmap(from: bake))
                let annotation = redaction(original, rect: CGRect(x: 48, y: 16, width: 64, height: 32),
                    tool: tool, mode: mode, baked: bake)
                view.setAnnotations([annotation])
                var styled = original
                styled.style.visible = true
                styled.style.color = .yellow
                styled.style.lineWidth = 3
                styled.style.wave = 0
                styled.style.blur = 6
                styled.style.feather = 12
                styled.background = .color(.white)
                XCTAssertTrue(view.applyStitchDocument(styled))
                let styledPixels = try exported(view)
                assertRegion(styledPixels, at: CGPoint(x: 48, y: 16), matches: fixture,
                    rect: CGRect(x: 0, y: 0, width: 64, height: 32))
                assertRegion(styledPixels, rect: CGRect(x: 4, y: 4, width: 8, height: 8), equals: blueRGBA)
                assertRegion(styledPixels, rect: CGRect(x: 140, y: 4, width: 8, height: 8), equals: greenRGBA)
                XCTAssertTrue(annotation.bakedBlurNSImage === bake)
                assertCurrentSources(view)

                var moved = styled
                moved.pieces[0].origin = CGPoint(x: -64, y: 0)
                XCTAssertTrue(view.applyStitchDocument(moved))
                let movedPixels = try exported(view)
                assertRegion(movedPixels, at: CGPoint(x: 48, y: 40), matches: fixture,
                    rect: CGRect(x: 0, y: 0, width: 32, height: 32))
                assertRegion(movedPixels, at: CGPoint(x: 104, y: 16), matches: fixture,
                    rect: CGRect(x: 32, y: 0, width: 32, height: 32))
                assertRegion(movedPixels, rect: CGRect(x: 88, y: 40, width: 8, height: 8), equals: [255, 255, 255, 255])
                assertRegion(movedPixels, rect: CGRect(x: 4, y: 28, width: 8, height: 8), equals: blueRGBA)
                assertRegion(movedPixels, rect: CGRect(x: 148, y: 4, width: 8, height: 8), equals: greenRGBA)
                assertCurrentSources(view)
                try assertAttachments(view, lineages: Set(original.pieces.map(\.lineageID)))
                let fragments = view.annotations, bakes = fragments.map(\.bakedBlurNSImage)

                view.undo()
                assertIdentities(view.annotations, [annotation])
                XCTAssertTrue(annotation.bakedBlurNSImage === bake)
                assertCurrentSources(view)
                assertSameExport(try exported(view), styledPixels)
                view.redo()
                assertIdentities(view.annotations, fragments)
                for (fragment, image) in zip(view.annotations, bakes) { XCTAssertTrue(fragment.bakedBlurNSImage === image) }
                assertCurrentSources(view)
                assertSameExport(try exported(view), movedPixels)

                let saved = try XCTUnwrap(SavedStitchDocument(moved))
                let decoded = try JSONDecoder().decode(SavedStitchDocument.self, from: JSONEncoder().encode(saved))
                let restored = try XCTUnwrap(decoded.restore())
                let data = try XCTUnwrap(AnnotationSerializer.encode(view.annotations))
                let annotations = try XCTUnwrap(AnnotationSerializer.decode(data, requireAll: true))
                XCTAssertEqual(annotations.map(\.stitchAttachment), fragments.map(\.stitchAttachment))
                let reopened = try editor(restored)
                reopened.setAnnotations(annotations)
                assertSameExport(try exported(reopened), movedPixels)
                assertCurrentSources(reopened)
                var movedAgain = restored
                movedAgain.pieces[0].origin = CGPoint(x: -80, y: 24)
                XCTAssertTrue(reopened.applyStitchDocument(movedAgain))
                let movedAgainPixels = try exported(reopened)
                assertRegion(movedAgainPixels, at: CGPoint(x: 48, y: 64), matches: fixture,
                    rect: CGRect(x: 0, y: 0, width: 32, height: 32))
                assertRegion(movedAgainPixels, at: CGPoint(x: 120, y: 16), matches: fixture,
                    rect: CGRect(x: 32, y: 0, width: 32, height: 32))
                assertRegion(movedAgainPixels, rect: CGRect(x: 96, y: 40, width: 8, height: 8), equals: [255, 255, 255, 255])
                assertCurrentSources(reopened)
                try assertAttachments(reopened, lineages: Set(restored.pieces.map(\.lineageID)))
            }
        }
    }

    func testOverlappingDuplicateImageCapturesKeepIndependentProtectionAfterReloadAndFurtherMovement() throws {
        try withPlainDefaults {
            let image = try source(width: 80, height: 64)
            let first = StitchPiece(image: image, origin: CGPoint(x: -40, y: -24))
            let second = StitchPiece(image: image, origin: first.origin)
            var original = StitchDocument(pieces: [first, second], background: .transparent)
            original.style.visible = false
            let view = try editor(original)
            let annotation = redaction(original, rect: CGRect(x: 16, y: 16, width: 48, height: 32))
            view.setAnnotations([annotation])
            var separated = original
            separated.pieces[0].origin.x = -120
            XCTAssertTrue(view.applyStitchDocument(separated))
            let separatedPixels = try exported(view)
            assertRegion(separatedPixels, rect: CGRect(x: 16, y: 16, width: 48, height: 32), equals: redRGBA)
            assertRegion(separatedPixels, rect: CGRect(x: 96, y: 16, width: 48, height: 32), equals: redRGBA)
            assertRegion(separatedPixels, rect: CGRect(x: 4, y: 4, width: 8, height: 8), equals: blueRGBA)
            assertRegion(separatedPixels, rect: CGRect(x: 84, y: 4, width: 8, height: 8), equals: blueRGBA)
            try assertAttachments(view, lineages: [first.lineageID, second.lineageID])

            let saved = try XCTUnwrap(SavedStitchDocument(separated))
            XCTAssertEqual(saved.images.count, 1)
            XCTAssertNotEqual(saved.pieces[0].lineageID, saved.pieces[1].lineageID)
            let decoded = try JSONDecoder().decode(SavedStitchDocument.self, from: JSONEncoder().encode(saved))
            let restored = try XCTUnwrap(decoded.restore())
            XCTAssertTrue(restored.pieces[0].image === restored.pieces[1].image)
            let data = try XCTUnwrap(AnnotationSerializer.encode(view.annotations))
            let restoredAnnotations = try XCTUnwrap(AnnotationSerializer.decode(data, requireAll: true))
            let reopened = try editor(restored)
            reopened.setAnnotations(restoredAnnotations)
            assertSameExport(try exported(reopened), separatedPixels)
            var moved = restored
            moved.pieces[0].origin.y = 40
            XCTAssertTrue(reopened.applyStitchDocument(moved))
            let movedPixels = try exported(reopened)
            assertRegion(movedPixels, rect: CGRect(x: 16, y: 80, width: 48, height: 32), equals: redRGBA)
            assertRegion(movedPixels, rect: CGRect(x: 96, y: 16, width: 48, height: 32), equals: redRGBA)
            assertRegion(movedPixels, rect: CGRect(x: 16, y: 16, width: 48, height: 32), equals: clearRGBA)
            assertRegion(movedPixels, rect: CGRect(x: 4, y: 68, width: 8, height: 8), equals: blueRGBA)
            try assertAttachments(reopened, lineages: [first.lineageID, second.lineageID])
            reopened.undo()
            assertSameExport(try exported(reopened), separatedPixels)
            reopened.redo()
            assertSameExport(try exported(reopened), movedPixels)
        }
    }

    func testRotatedFilledRedactionRetainsExactProtectedPixelsAcrossCutAndMovedSlice() throws {
        try withPlainDefaults {
            let original = try singleDocument(), view = try editor(original)
            let annotation = redaction(original, rect: CGRect(x: 40, y: 40, width: 80, height: 40))
            annotation.rotation = .pi / 4
            view.setAnnotations([annotation])
            let before = try exported(view)
            assertRegion(before, rect: CGRect(x: 76, y: 44, width: 8, height: 8), equals: redRGBA)
            assertRegion(before, rect: CGRect(x: 76, y: 68, width: 8, height: 8), equals: redRGBA)
            let topEdge = try XCTUnwrap(rgba(before, x: 93, y: 17))
            let bottomEdge = try XCTUnwrap(rgba(before, x: 37, y: 73))
            XCTAssertGreaterThan(topEdge[0], 0)
            XCTAssertLessThan(topEdge[0], 255)
            XCTAssertGreaterThan(bottomEdge[0], 0)
            XCTAssertLessThan(bottomEdge[0], 255)
            var cut = original
            XCTAssertTrue(cut.collapse(axis: .horizontal, from: original.bounds.minY + 56, to: original.bounds.minY + 64))
            XCTAssertTrue(view.applyStitchDocument(cut))
            let cutPixels = try exported(view)
            // These antialiased corners must retain their original coverage;
            // clipping at fractional shape bounds previously faded them twice.
            XCTAssertEqual(try XCTUnwrap(rgba(cutPixels, x: 93, y: 17)), topEdge)
            XCTAssertEqual(try XCTUnwrap(rgba(cutPixels, x: 37, y: 65)), bottomEdge)
            assertRegion(cutPixels, at: .zero, matches: before, rect: CGRect(x: 0, y: 0, width: 160, height: 56))
            assertRegion(cutPixels, at: CGPoint(x: 0, y: 56), matches: before,
                rect: CGRect(x: 0, y: 64, width: 160, height: 56))
            var moved = cut
            moved.pieces[0].origin.x += 40
            XCTAssertTrue(view.applyStitchDocument(moved))
            let movedPixels = try exported(view)
            XCTAssertEqual(try XCTUnwrap(rgba(movedPixels, x: 133, y: 17)), topEdge)
            XCTAssertEqual(try XCTUnwrap(rgba(movedPixels, x: 37, y: 65)), bottomEdge)
            assertRegion(movedPixels, at: CGPoint(x: 40, y: 0), matches: before,
                rect: CGRect(x: 0, y: 0, width: 160, height: 56))
            assertRegion(movedPixels, at: CGPoint(x: 0, y: 56), matches: before,
                rect: CGRect(x: 0, y: 64, width: 160, height: 56))
            assertRegion(movedPixels, rect: CGRect(x: 4, y: 4, width: 24, height: 24), equals: clearRGBA)
            assertRegion(movedPixels, rect: CGRect(x: 172, y: 72, width: 16, height: 24), equals: clearRGBA)
            try assertAttachments(view, lineages: [original.pieces[0].lineageID])
            view.undo()
            assertSameExport(try exported(view), cutPixels)
            view.undo()
            assertIdentities(view.annotations, [annotation])
            assertSameExport(try exported(view), before)
            view.redo()
            view.redo()
            assertSameExport(try exported(view), movedPixels)
        }
    }
}
