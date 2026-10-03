import AppKit
import XCTest

@MainActor
final class StitchSeamTransitionTests: XCTestCase {
    private func fixture(_ transition: StitchTransition = .wave, axis: StitchAxis = .horizontal,
                         dark: Bool = false, flat: Bool = false) throws -> StitchDocument {
        let image = ImageProbe.makeImage(width: 256, height: 256) { context in
            context.setFillColor(CGColor(srgbRed: dark ? 0.12 : 0.94,
                green: dark ? 0.15 : 0.95, blue: dark ? 0.19 : 0.97, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            if !flat {
                context.setFillColor(CGColor(srgbRed: dark ? 0.6 : 0.32,
                    green: dark ? 0.66 : 0.38, blue: dark ? 0.73 : 0.44, alpha: 1))
                for row in stride(from: 10, to: 256, by: 12) {
                    for column in stride(from: 10, to: 256, by: 40) {
                        context.fill(CGRect(x: column, y: row, width: 28, height: 3))
                    }
                }
            }
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var document = StitchDocument(pieces: [StitchPiece(image: image)], background: .transparent)
        XCTAssertTrue(document.collapse(axis: axis, from: 120, to: 136))
        document.style.transition = transition
        document.style.color = dark ? NSColor(white: 0.8, alpha: 0.9) : StitchStyle().color
        return document
    }

    private func pixels(_ image: CGImage) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
    }

    func testTreatmentsAreDistinctOnLightAndDarkContentAndBothAxes() throws {
        for dark in [false, true] {
            for axis in [StitchAxis.horizontal, .vertical] {
                var results = Set<Data>()
                for transition in StitchTransition.allCases {
                    let document = try fixture(transition, axis: axis, dark: dark)
                    let image = try XCTUnwrap(StitchRenderer.render(document))
                    XCTAssertEqual(image.width, Int(document.bounds.width))
                    XCTAssertEqual(image.height, Int(document.bounds.height))
                    results.insert(try pixels(image))
                }
                XCTAssertEqual(results.count, StitchTransition.allCases.count)
            }
        }
    }

    func testEveryTreatmentPreservesCapturedPixelsOutsideTheSeamAtFullAndPreviewSizes() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            for transition in StitchTransition.allCases {
                var document = try fixture(transition, axis: axis)
                for dimension in [CGFloat(256), 128] {
                    let image = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension))
                    document.style.visible = false
                    let original = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension))
                    document.style.visible = true
                    let a = NSBitmapImageRep(cgImage: image), b = NSBitmapImageRep(cgImage: original)
                    let scale = dimension / 256
                    for coordinate in [20, 50, 190, 220] {
                        for along in stride(from: 30, to: 220, by: 13) {
                            let x = Int(CGFloat(axis == .horizontal ? along : coordinate) * scale)
                            let y = Int(CGFloat(axis == .horizontal ? coordinate : along) * scale)
                            XCTAssertEqual(a.colorAt(x: x, y: y), b.colorAt(x: x, y: y),
                                "\(transition) must leave pixels beyond the seam unchanged")
                        }
                    }
                }
            }
        }
    }

    func testBlendDoesNotAddInkAndIgnoresLineAndShapeSettings() throws {
        var document = try fixture(.blend, flat: true)
        let original = try XCTUnwrap(StitchRenderer.render(document))
        document.style.color = .red
        document.style.lineWidth = 8
        document.style.wave = 14
        XCTAssertEqual(try pixels(XCTUnwrap(StitchRenderer.render(document))), try pixels(original))
        document.style.visible = false
        XCTAssertEqual(try pixels(XCTUnwrap(StitchRenderer.render(document))), try pixels(original))
    }

    func testPaperTreatmentsIgnoreBlurAndUnrelatedLineSettings() throws {
        for transition in [StitchTransition.torn, .fold] {
            for axis in [StitchAxis.horizontal, .vertical] {
                var document = try fixture(transition, axis: axis, dark: true)
                let original = try pixels(XCTUnwrap(StitchRenderer.render(document)))
                document.style.blur = 80
                document.style.feather = 200
                document.style.lineWidth = 0
                document.style.color = .red
                document.style.wave = 14
                document.style.breakSize = 14
                if transition == .fold { document.style.wave = 14; document.style.paperColor = .green }
                XCTAssertEqual(try pixels(XCTUnwrap(StitchRenderer.render(document))), original,
                    "\(transition) must use its own paper controls and leave content crisp")
            }
        }
    }

    func testTornHasAnExposedPaperStripWithIrregularEdgesOnBothAxes() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let document = try fixture(.torn, axis: axis, dark: true, flat: true)
            let image = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document)))
            var firstPaperPixels = Set<Int>()
            for along in stride(from: 30, through: 220, by: 5) {
                var exposed: [Int] = []
                for normal in 104..<136 {
                    let color = try XCTUnwrap(image.colorAt(x: axis == .horizontal ? along : normal,
                        y: axis == .horizontal ? normal : along)).usingColorSpace(.sRGB)!
                    if color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9 {
                        exposed.append(normal)
                    }
                }
                XCTAssertGreaterThanOrEqual(exposed.count, 4, "A tear needs exposed paper, not a thin ink line")
                XCTAssertLessThanOrEqual(exposed.count, 12)
                firstPaperPixels.insert(try XCTUnwrap(exposed.first))
            }
            XCTAssertGreaterThan(firstPaperPixels.count, 2, "Paper edges should have visibly unequal teeth")
        }
    }

    func testTransparentPaperColorHidesTheWholeTearIncludingFibersAndShadow() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = try fixture(.torn, axis: axis, dark: true)
            document.style.paperColor = document.style.paperColor.withAlphaComponent(0)
            let cleared = try pixels(XCTUnwrap(StitchRenderer.render(document)))
            document.style.visible = false
            XCTAssertEqual(try pixels(XCTUnwrap(StitchRenderer.render(document))), cleared)
        }
    }

    func testFoldHasMatteFrontTuckedReturnAndPaperLipOnBothBackgroundsAndAxes() throws {
        for dark in [false, true] {
            for axis in [StitchAxis.horizontal, .vertical] {
                var document = try fixture(.fold, axis: axis, dark: dark, flat: true)
                let folded = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document)))
                document.style.foldStrength = 0
                let untouched = try pixels(XCTUnwrap(StitchRenderer.render(document)))
                document.style.visible = false
                XCTAssertEqual(try pixels(XCTUnwrap(StitchRenderer.render(document))), untouched)
                func luminance(_ normal: Int) throws -> CGFloat {
                    let color = try XCTUnwrap(folded.colorAt(x: axis == .horizontal ? 128 : normal,
                        y: axis == .horizontal ? normal : 128)).usingColorSpace(.sRGB)!
                    return (color.redComponent + color.greenComponent + color.blueComponent) / 3
                }
                XCTAssertGreaterThan(try luminance(115) - luminance(121), 0.06,
                    "The tucked return should be darker than the broad paper face")
                XCTAssertGreaterThan(try luminance(122) - luminance(121), 0.035,
                    "An exposed paper lip should follow the tucked return")
                XCTAssertEqual(try luminance(114), try luminance(117), accuracy: 0.025,
                    "The broad face should be matte without a bright ridge gradient")
                if dark {
                    XCTAssertLessThan(try luminance(115), 0.3, "Dark captures should retain dark paper")
                } else {
                    XCTAssertGreaterThan(try luminance(115), 0.85)
                }
            }
        }
    }

    func testOpaqueFoldOccludesTextInsteadOfShowingItThroughThePaper() throws {
        for dark in [false, true] {
            for axis in [StitchAxis.horizontal, .vertical] {
                var printed = try fixture(.fold, axis: axis, dark: dark)
                var blank = try fixture(.fold, axis: axis, dark: dark, flat: true)
                printed.style.foldStrength = 1
                blank.style.foldStrength = 1
                let a = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(printed)))
                let b = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(blank)))
                for along in [32, 128, 224] {
                    for normal in [110, 116, 121, 122] {
                        let x = axis == .horizontal ? along : normal
                        let y = axis == .horizontal ? normal : along
                        let first = try XCTUnwrap(a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        let second = try XCTUnwrap(b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        XCTAssertEqual(first.redComponent, second.redComponent, accuracy: 2 / 255)
                        XCTAssertEqual(first.greenComponent, second.greenComponent, accuracy: 2 / 255)
                        XCTAssertEqual(first.blueComponent, second.blueComponent, accuracy: 2 / 255)
                    }
                }
            }
        }
    }

    func testFoldPaperFollowsLocalBackgroundsAtExportAndPreviewSizes() throws {
        let source = try XCTUnwrap(ImageProbe.makeImage(width: 512, height: 256) { context in
            context.setFillColor(CGColor(gray: 0.12, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(CGColor(gray: 0.94, alpha: 1))
            context.fill(CGRect(x: 256, y: 0, width: 256, height: 256))
        }.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: source)], background: .transparent)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 120, to: 136))
        document.style.transition = .fold
        for dimension in [CGFloat(512), 256] {
            let image = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document,
                maximumPreviewDimension: dimension)))
            let scale = dimension / 512
            let dark = try XCTUnwrap(image.colorAt(x: Int(64 * scale), y: Int(115 * scale))?.usingColorSpace(.sRGB))
            let light = try XCTUnwrap(image.colorAt(x: Int(448 * scale), y: Int(115 * scale))?.usingColorSpace(.sRGB))
            XCTAssertLessThan(dark.redComponent, 0.35)
            XCTAssertGreaterThan(light.redComponent, 0.85)
        }
    }

    func testShortFoldLimitsItsDepthAndLeavesSurroundingCapturedPixelsIntact() throws {
        let image = try XCTUnwrap(ImageProbe.solidImage(width: 20, height: 20)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        for axis in [StitchAxis.horizontal, .vertical] {
            let origin = axis == .horizontal ? CGPoint(x: 0, y: 20) : CGPoint(x: 20, y: 0)
            var document = StitchDocument(pieces: [StitchPiece(image: image), StitchPiece(image: image, origin: origin)])
            document.style.transition = .fold
            document.style.foldDepth = 40
            let folded = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document)))
            document.style.visible = false
            let original = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document)))
            for normal in [5, 10, 15, 25, 30, 35] {
                for along in 0..<20 {
                    let x = axis == .horizontal ? along : normal
                    let y = axis == .horizontal ? normal : along
                    XCTAssertEqual(folded.colorAt(x: x, y: y), original.colorAt(x: x, y: y),
                        "A short fold must not spread its decoration over the whole capture")
                }
            }
        }
    }

    func testPaperControlsPersistAndEachProducesAnUndoableRasterEdit() throws {
        for transition in [StitchTransition.torn, .fold] {
            let document = try fixture(transition)
            let editor = try makeEditor(document)
            var next = document
            if transition == .torn {
                next.style.tearWidth = 18
                next.style.tearRoughness = 10
                next.style.paperColor = NSColor(srgbRed: 0.92, green: 0.84, blue: 0.69, alpha: 0.9)
            } else {
                next.style.foldDepth = 28
                next.style.foldStrength = 0.8
            }
            XCTAssertFalse(next.isIdentical(to: document))
            let restored = try XCTUnwrap(JSONDecoder().decode(SavedStitchDocument.self,
                from: JSONEncoder().encode(XCTUnwrap(SavedStitchDocument(next)))).restore())
            XCTAssertEqual(restored.style.tearWidth, next.style.tearWidth)
            XCTAssertEqual(restored.style.tearRoughness, next.style.tearRoughness)
            XCTAssertEqual(restored.style.foldDepth, next.style.foldDepth)
            XCTAssertEqual(restored.style.foldStrength, next.style.foldStrength)
            XCTAssertEqual(try pixels(XCTUnwrap(StitchRenderer.render(restored))),
                try pixels(XCTUnwrap(StitchRenderer.render(next))))
            XCTAssertTrue(editor.applyStitchDocument(next))
            XCTAssertEqual(editor.undoStack.count, 1)
            editor.undo()
            XCTAssertEqual(editor.stitchDocument?.style.tearWidth, document.style.tearWidth)
            XCTAssertEqual(editor.stitchDocument?.style.foldDepth, document.style.foldDepth)
            editor.redo()
            XCTAssertEqual(try pixels(XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))),
                try pixels(XCTUnwrap(StitchRenderer.render(next))))
        }
    }

    func testAbsentPaperSettingsUseDefaultsAndInvalidSavedSettingsRejectRestore() throws {
        let saved = try XCTUnwrap(SavedStitchDocument(fixture(.torn)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        object["wave"] = 7
        for key in ["tearWidth", "tearRoughness", "paperColor", "foldDepth", "foldStrength", "breakSize"] { object.removeValue(forKey: key) }
        let restored = try XCTUnwrap(JSONDecoder().decode(SavedStitchDocument.self,
            from: JSONSerialization.data(withJSONObject: object)).restore())
        XCTAssertEqual(restored.style.tearWidth, StitchStyle().tearWidth)
        XCTAssertEqual(restored.style.foldDepth, StitchStyle().foldDepth)
        XCTAssertEqual(restored.style.foldStrength, StitchStyle().foldStrength)
        XCTAssertEqual(restored.style.tearRoughness, 7)
        XCTAssertEqual(restored.style.breakSize, 7)
        for (key, invalid) in [("tearWidth", -1.0), ("tearRoughness", 101.0), ("foldDepth", 101.0), ("foldStrength", 1.1), ("breakSize", -1.0)] {
            var broken = object
            broken[key] = invalid
            XCTAssertNil(try JSONDecoder().decode(SavedStitchDocument.self,
                from: JSONSerialization.data(withJSONObject: broken)).restore())
        }
    }

    func testEditableHistoryRebuildsPaperPixelsAndRetainsCensorBakesWhenCachedRenderingIsOlder() async throws {
        for transition in [StitchTransition.torn, .fold] {
            let document = try fixture(transition)
            var cachedDocument = document
            cachedDocument.style.visible = false
            let cachedPixels = try XCTUnwrap(StitchRenderer.render(cachedDocument))
            let cachedImage = NSImage(cgImage: cachedPixels, size: CGSize(width: cachedPixels.width, height: cachedPixels.height))
            let sealedImage = ImageProbe.solidImage(width: 20, height: 20,
                color: CGColor(srgbRed: 0, green: 0.5, blue: 0, alpha: 1))
            let censor = Annotation(tool: .pixelate, startPoint: CGPoint(x: 20, y: 20),
                endPoint: CGPoint(x: 40, y: 40), color: .black, strokeWidth: 1)
            censor.bakedBlurNSImage = sealedImage
            let loupe = Annotation(tool: .loupe, startPoint: CGPoint(x: 180, y: 160),
                endPoint: CGPoint(x: 220, y: 200), color: .white, strokeWidth: 1)
            loupe.loupeSourceRect = CGRect(x: 110, y: 110, width: 20, height: 20)
            loupe.bakedBlurNSImage = sealedImage
            var state = CaptureEditState()
            state.stitchDocument = try XCTUnwrap(SavedStitchDocument(document))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let history = ScreenshotHistory(directory: directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            withDefaults(["historySize": 10, "historyUnlimited": false]) {
                history.add(image: cachedImage, rawImage: cachedImage, annotations: [censor, loupe], editState: state)
            }
            await history.waitUntilIdle()
            let entry = try XCTUnwrap(history.entries.first)
            let editable = try XCTUnwrap(history.loadEditableCapture(for: entry))
            let expected = try pixels(XCTUnwrap(StitchRenderer.render(document)))
            XCTAssertEqual(try pixels(XCTUnwrap(editable.rawImage.cgImage(forProposedRect: nil, context: nil, hints: nil))), expected)
            XCTAssertEqual(editable.rawImage.size, history.loadRawImage(for: entry)?.size)
            let restoredCensor = try XCTUnwrap(editable.annotations.first { $0.tool == .pixelate })
            XCTAssertEqual(try pixels(XCTUnwrap(restoredCensor.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))),
                try pixels(XCTUnwrap(sealedImage.cgImage(forProposedRect: nil, context: nil, hints: nil))))
            XCTAssertNil(editable.annotations.first { $0.tool == .loupe }?.bakedBlurNSImage,
                "Magnifiers must refresh from the current paper rendering when the editor attaches them")
            let editor = EditorView(frame: CGRect(origin: .zero, size: editable.rawImage.size))
            editor.screenshotImage = editable.rawImage
            editor.applySelection(editor.bounds)
            editor.setAnnotations(editable.annotations)
            let undoCount = editor.undoStack.count
            let undoIdentity = editor.undoStateIdentity
            editor.applyCaptureEditState(try XCTUnwrap(editable.editState))
            XCTAssertEqual(editor.undoStack.count, undoCount, "Restoring the Stitch must not add an edit")
            XCTAssertEqual(editor.undoStateIdentity, undoIdentity)
            XCTAssertEqual(try pixels(XCTUnwrap(editor.captureSelectedRegionRaw()?.cgImage(forProposedRect: nil, context: nil, hints: nil))), expected)
            XCTAssertEqual(editor.stitchDocument?.style.transition, transition)
        }
    }

    func testEditableHistoryKeepsFlattenedFallbackWhenSavedStitchDimensionsDoNotMatch() async throws {
        let document = try fixture(.fold)
        var state = CaptureEditState()
        state.stitchDocument = try XCTUnwrap(SavedStitchDocument(document))
        let cachedImage = ImageProbe.solidImage(width: 64, height: 48)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let history = ScreenshotHistory(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        withDefaults(["historySize": 10, "historyUnlimited": false]) {
            history.add(image: cachedImage, rawImage: cachedImage, annotations: [], editState: state)
        }
        await history.waitUntilIdle()
        let entry = try XCTUnwrap(history.entries.first)
        XCTAssertNil(history.loadEditableCapture(for: entry))
        let flattened = try XCTUnwrap(history.loadImage(for: entry))
        XCTAssertEqual(try pixels(XCTUnwrap(flattened.cgImage(forProposedRect: nil, context: nil, hints: nil))),
            try pixels(XCTUnwrap(cachedImage.cgImage(forProposedRect: nil, context: nil, hints: nil))))
    }

    func testHiddenSeamsHaveNoEffectForAnyTreatment() throws {
        var document = try fixture()
        document.style.visible = false
        let original = try pixels(XCTUnwrap(StitchRenderer.render(document)))
        for transition in StitchTransition.allCases {
            document.style.transition = transition
            XCTAssertEqual(try pixels(XCTUnwrap(StitchRenderer.render(document))), original)
        }
    }

    func testShortIntersectingJoinsRenderAtReducedScaleWithoutChangingTransparencyOrCanvasSize() throws {
        let image = try XCTUnwrap(ImageProbe.solidImage(width: 20, height: 20)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        for transition in StitchTransition.allCases {
            var document = StitchDocument(pieces: [StitchPiece(image: image),
                StitchPiece(image: image, origin: CGPoint(x: 20, y: 0)),
                StitchPiece(image: image, origin: CGPoint(x: 2, y: 20))], background: .transparent)
            document.style.transition = transition
            document.style.wave = 14
            document.style.tearRoughness = 14
            document.style.tearWidth = 32
            document.style.foldDepth = 40
            document.style.breakSize = 14
            let rendered = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: 20))
            XCTAssertEqual(rendered.width, 20)
            XCTAssertEqual(rendered.height, 20)
            XCTAssertEqual(NSBitmapImageRep(cgImage: rendered).colorAt(x: 19, y: 19)?.alphaComponent, 0)
        }
    }

    func testShortJoinDecorationsAndBlurLeaveEveryUncoveredPixelTransparent() throws {
        let image = try XCTUnwrap(ImageProbe.solidImage(width: 20, height: 20)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        for transposed in [false, true] {
            let origins = [CGPoint.zero, CGPoint(x: 20, y: 0), CGPoint(x: 2, y: 20)].map {
                transposed ? CGPoint(x: $0.y, y: $0.x) : $0
            }
            for dimension in [CGFloat(40), 20] {
                var document = StitchDocument(pieces: origins.map { StitchPiece(image: image, origin: $0) },
                    background: .transparent)
                document.style.visible = false
                let original = try pixels(XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension)))
                document.style.visible = true
                document.style.wave = 14
                document.style.lineWidth = 8
                document.style.tearRoughness = 14
                document.style.tearWidth = 32
                document.style.foldDepth = 40
                document.style.breakSize = 14
                for transition in StitchTransition.allCases {
                    document.style.transition = transition
                    for blur in [CGFloat(0), 8] {
                        document.style.blur = blur
                        let result = try pixels(XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension)))
                        for alpha in stride(from: 3, to: original.count, by: 4) where original[alpha] == 0 {
                            XCTAssertEqual(result[alpha], 0,
                                "\(transition) at \(dimension) with blur \(blur) painted uncovered pixel \(alpha / 4)")
                        }
                    }
                }
            }
        }
    }

    func testEveryTreatmentSurvivesEditableHistoryRoundTripWithIdenticalPixels() throws {
        for transition in StitchTransition.allCases {
            let document = try fixture(transition)
            let encoded = try JSONEncoder().encode(XCTUnwrap(SavedStitchDocument(document)))
            let saved = try JSONDecoder().decode(SavedStitchDocument.self, from: encoded)
            let restored = try XCTUnwrap(saved.restore())
            XCTAssertEqual(restored.style.transition, transition)
            XCTAssertEqual(restored.style.wave, document.style.wave)
            XCTAssertEqual(restored.pieces.map(\.source), document.pieces.map(\.source))
            XCTAssertEqual(try pixels(XCTUnwrap(StitchRenderer.render(restored))),
                try pixels(XCTUnwrap(StitchRenderer.render(document))))
        }
    }

    func testExistingSidecarDefaultsToWaveAndUnknownTreatmentRejectsEditableRestore() throws {
        let saved = try XCTUnwrap(SavedStitchDocument(fixture(.fold)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        object.removeValue(forKey: "transition")
        let existing = try JSONDecoder().decode(SavedStitchDocument.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(existing.restore()?.style.transition, .wave)
        object["transition"] = "unknown-treatment"
        let future = try JSONDecoder().decode(SavedStitchDocument.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(future.restore(), "History should offer its flattened capture for an unreadable treatment")
    }

    func testTreatmentOnlyEditsCommitPixelsAndShareNativeUndoRedo() throws {
        let document = try fixture()
        let editor = try makeEditor(document)
        for transition in StitchTransition.allCases.dropFirst() {
            var next = document
            next.style.transition = transition
            XCTAssertFalse(next.isIdentical(to: document))
            XCTAssertTrue(editor.applyStitchDocument(next))
            XCTAssertEqual(editor.undoStack.count, 1)
            XCTAssertEqual(try pixels(XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))),
                try pixels(XCTUnwrap(StitchRenderer.render(next))))
            editor.undo()
            XCTAssertEqual(editor.stitchDocument?.style.transition, .wave)
            editor.redo()
            XCTAssertEqual(editor.stitchDocument?.style.transition, transition)
            editor.undo()
        }
    }

    func testNativeFlipsUseCanonicalTreatmentPixelsAndKeepAnnotationsAtBothSourceScales() throws {
        for transition in [StitchTransition.torn, .fold, .breakLine] {
            for scale in [CGFloat(1), 2] {
                for horizontal in [false, true] {
                    var document = try fixture(transition)
                    for index in document.pieces.indices {
                        document.pieces[index].origin.x -= 30
                        document.pieces[index].origin.y -= 20
                    }
                    let editor = try makeEditor(document, scale: scale)
                    let mark = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 16, y: 12),
                        endPoint: CGPoint(x: 24, y: 20), color: .red, strokeWidth: 1)
                    editor.annotations = [mark]
                    let original = try pixels(XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
                    if horizontal { editor.flipImageHorizontally() } else { editor.flipImageVertically() }
                    let transformed = try XCTUnwrap(editor.stitchDocument)
                    XCTAssertEqual(transformed.style.transition, transition)
                    XCTAssertEqual(try pixels(XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))),
                        try pixels(XCTUnwrap(StitchRenderer.render(transformed))))
                    XCTAssertTrue(editor.annotations.first === mark)
                    XCTAssertEqual(mark.boundingRect.midX, horizontal ? 256 / scale - 20 : 20, accuracy: 0.001)
                    XCTAssertEqual(mark.boundingRect.midY, horizontal ? 16 : 240 / scale - 16, accuracy: 0.001)
                    editor.undo()
                    XCTAssertEqual(try pixels(XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))), original)
                    editor.redo()
                    XCTAssertEqual(try pixels(XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))),
                        try pixels(XCTUnwrap(StitchRenderer.render(XCTUnwrap(editor.stitchDocument)))))
                }
            }
        }
    }

    func testFractionalSourceOriginsFlipAroundTheRasterEnvelope() throws {
        var document = try fixture(.fold)
        document.style.visible = false
        for index in document.pieces.indices {
            document.pieces[index].origin.x += 0.2
            document.pieces[index].origin.y -= 0.3
        }
        let original = try XCTUnwrap(StitchRenderer.render(document))
        for horizontal in [false, true] {
            let flipped = try XCTUnwrap(document.flipped(horizontal: horizontal))
            XCTAssertEqual(flipped.bounds.integral, document.bounds.integral)
            let result = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(flipped)))
            let before = NSBitmapImageRep(cgImage: original)
            for y in stride(from: 4, to: original.height - 4, by: 9) {
                for x in stride(from: 4, to: original.width - 4, by: 11) {
                    let a = try XCTUnwrap(before.colorAt(x: x, y: y)).usingColorSpace(.sRGB)!
                    let b = try XCTUnwrap(result.colorAt(x: horizontal ? original.width - x - 1 : x,
                        y: horizontal ? y : original.height - y - 1)).usingColorSpace(.sRGB)!
                    XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 2 / 255)
                    XCTAssertEqual(a.alphaComponent, b.alphaComponent, accuracy: 2 / 255)
                }
            }
        }
    }

    func testFractionalNativeFlipThenPieceMovementKeepsAttachedCensorPixelsAndUndo() throws {
        for horizontal in [false, true] {
            for scale in [CGFloat(1), 2] {
                var document = try fixture(.torn)
                for index in document.pieces.indices {
                    document.pieces[index].origin.x += 0.2
                    document.pieces[index].origin.y += 0.7
                }
                let editor = try makeEditor(document, scale: scale)
                let rect = CGRect(x: 32 / scale, y: 170 / scale, width: 40 / scale, height: 30 / scale)
                let censor = Annotation(tool: .pixelate, startPoint: rect.origin,
                    endPoint: CGPoint(x: rect.maxX, y: rect.maxY), color: .black, strokeWidth: 1)
                censor.bakedBlurNSImage = ImageProbe.quadrantImage(width: 40, height: 30)
                censor.stitchAttachment = StitchAnnotationAttachment(pieceID: document.pieces[0].id,
                    lineageID: document.pieces[0].lineageID, clipRect: rect)
                editor.setAnnotations([censor])
                if horizontal { editor.flipImageHorizontally() } else { editor.flipImageVertically() }
                let flipped = try XCTUnwrap(editor.stitchDocument)
                let previousRect = censor.boundingRect
                let sealed = try pixels(XCTUnwrap(censor.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
                var moved = flipped
                moved.pieces[0].origin.x = (moved.pieces[0].origin.x + 12).rounded()
                moved.pieces[0].origin.y = (moved.pieces[0].origin.y + 6).rounded()
                let dx = moved.pieces[0].origin.x - flipped.pieces[0].origin.x
                let dy = moved.pieces[0].origin.y - flipped.pieces[0].origin.y
                XCTAssertTrue(editor.applyStitchDocument(moved))
                let expected = previousRect.offsetBy(
                    dx: (dx + flipped.bounds.integral.minX - moved.bounds.integral.minX) / scale,
                    dy: (-dy + moved.bounds.integral.maxY - flipped.bounds.integral.maxY) / scale)
                XCTAssertEqual(censor.boundingRect.minX, expected.minX, accuracy: 0.001)
                XCTAssertEqual(censor.boundingRect.minY, expected.minY, accuracy: 0.001)
                XCTAssertEqual(censor.boundingRect.size, previousRect.size)
                XCTAssertEqual(censor.stitchAttachment?.pieceID, flipped.pieces[0].id)
                XCTAssertEqual(try pixels(XCTUnwrap(censor.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))), sealed)
                XCTAssertEqual(try pixels(XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))),
                    try pixels(XCTUnwrap(StitchRenderer.render(moved))))
                editor.undo()
                XCTAssertEqual(censor.boundingRect, previousRect)
                XCTAssertEqual(try pixels(XCTUnwrap(censor.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))), sealed)
                editor.redo()
                XCTAssertEqual(censor.boundingRect.minX, expected.minX, accuracy: 0.001)
                XCTAssertEqual(censor.boundingRect.minY, expected.minY, accuracy: 0.001)
            }
        }
    }

    func testNativeCropKeepsCanonicalTreatmentPixelsAndUndoAtBothSourceScales() throws {
        for transition in [StitchTransition.torn, .fold, .breakLine] {
            for scale in [CGFloat(1), 2] {
                let document = try fixture(transition)
                let editor = try makeEditor(document, scale: scale)
                let original = try pixels(XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
                let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
                window.contentView = editor
                defer { window.orderOut(nil) }
                editor.currentTool = .crop
                func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                    try XCTUnwrap(NSEvent.mouseEvent(with: type, location: editor.convert(point, to: nil),
                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 1, clickCount: 1, pressure: 1))
                }
                editor.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 10, y: 10)))
                editor.mouseDragged(with: try mouse(.leftMouseDragged,
                    CGPoint(x: editor.bounds.maxX - 10, y: editor.bounds.maxY - 10)))
                editor.mouseUp(with: try mouse(.leftMouseUp,
                    CGPoint(x: editor.bounds.maxX - 10, y: editor.bounds.maxY - 10)))
                editor.keyDown(with: TestKeyEvent.keyDown(characters: "\r", keyCode: 36))
                let cropped = try XCTUnwrap(editor.stitchDocument)
                XCTAssertEqual(cropped.bounds.size, CGSize(width: 256 - 20 * scale, height: 240 - 20 * scale))
                XCTAssertEqual(cropped.style.transition, transition)
                XCTAssertEqual(try pixels(XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))),
                    try pixels(XCTUnwrap(StitchRenderer.render(cropped))))
                editor.undo()
                XCTAssertEqual(editor.stitchDocument?.style.transition, transition)
                XCTAssertEqual(try pixels(XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))), original)
                editor.redo()
                XCTAssertEqual(try pixels(XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))),
                    try pixels(XCTUnwrap(StitchRenderer.render(XCTUnwrap(editor.stitchDocument)))))
            }
        }
    }

    func testChangingTreatmentRefreshesLoupePixelsAndPreservesCensorBake() throws {
        let document = try fixture()
        let editor = try makeEditor(document)
        let loupe = Annotation(tool: .loupe, startPoint: CGPoint(x: 190, y: 170),
            endPoint: CGPoint(x: 230, y: 210), color: .white, strokeWidth: 1)
        loupe.loupeSourceRect = CGRect(x: 100, y: 110, width: 40, height: 20)
        let censor = Annotation(tool: .pixelate, startPoint: CGPoint(x: 40, y: 160),
            endPoint: CGPoint(x: 70, y: 180), color: .red, strokeWidth: 1)
        censor.bakedBlurNSImage = ImageProbe.solidImage(width: 30, height: 20,
            color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        editor.setAnnotations([loupe, censor])
        let oldLens = try pixels(XCTUnwrap(loupe.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let sealed = try pixels(XCTUnwrap(censor.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        var next = document
        next.style.transition = .blend
        XCTAssertTrue(editor.applyStitchDocument(next))
        let newLens = try pixels(XCTUnwrap(loupe.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        XCTAssertNotEqual(newLens, oldLens)
        let expected = loupe.clone()
        expected.bakedBlurNSImage = nil
        expected.bakeLoupe()
        XCTAssertEqual(newLens, try pixels(XCTUnwrap(expected.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))))
        XCTAssertEqual(try pixels(XCTUnwrap(censor.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))), sealed)
        XCTAssertTrue(censor.sourceImage === editor.screenshotImage)
        editor.undo()
        XCTAssertEqual(try pixels(XCTUnwrap(loupe.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))), oldLens)
        editor.redo()
        XCTAssertEqual(try pixels(XCTUnwrap(loupe.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))), newLens)
        editor.flipImageVertically()
        let flippedLens = loupe.clone()
        flippedLens.bakedBlurNSImage = nil
        flippedLens.bakeLoupe()
        XCTAssertEqual(try pixels(XCTUnwrap(loupe.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))),
            try pixels(XCTUnwrap(flippedLens.bakedBlurNSImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))))
    }

    func testContentGuidePaddingReservesDecorationEvenWithBlurOff() throws {
        for transition in StitchTransition.allCases.dropFirst() {
            var document = try fixture(transition)
            document.style.blur = 0
            document.style.wave = 14
            document.style.lineWidth = 8
            XCTAssertGreaterThanOrEqual(StitchBandGuides.contentPadding(document: document),
                StitchSeamDrawing.decorationExtent(style: document.style) + 4)
        }
    }

    func testOptionalTreatmentPreviewsExportFromTheSameRenderer() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["MACSHOT_SEAM_PREVIEW_DIR"] ?? environment["TEST_RUNNER_MACSHOT_SEAM_PREVIEW_DIR"]
        for dark in [false, true] {
            for transition in StitchTransition.allCases {
                let document = try fixture(transition, dark: dark)
                let rendered = try XCTUnwrap(StitchRenderer.render(document))
                if let directory {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("\(transition.rawValue)-\(dark ? "dark" : "light").png")
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try XCTUnwrap(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:])).write(to: url)
                    if transition == .torn || transition == .fold {
                        for axis in [StitchAxis.horizontal, .vertical] {
                            for dimension in [CGFloat(256), 128] {
                                let paper = try fixture(transition, axis: axis, dark: dark, flat: true)
                                let preview = try XCTUnwrap(StitchRenderer.render(paper, maximumPreviewDimension: dimension))
                                let name = "\(transition.rawValue)-\(dark ? "dark" : "light")-\(axis)-\(Int(dimension)).png"
                                try XCTUnwrap(NSBitmapImageRep(cgImage: preview).representation(using: .png, properties: [:]))
                                    .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                            }
                        }
                    }
                }
            }
        }
    }

    private func makeEditor(_ document: StitchDocument, scale: CGFloat = 1) throws -> EditorView {
        _ = NSApplication.shared
        let image = try XCTUnwrap(StitchRenderer.render(document))
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let editor = EditorView(frame: CGRect(origin: .zero, size: size))
        editor.screenshotImage = NSImage(cgImage: image, size: size)
        editor.applySelection(editor.bounds)
        editor.showToolbars = false
        editor.installStitchDocument(document)
        return editor
    }
}
