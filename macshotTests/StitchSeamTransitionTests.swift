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

    private func foldTextureFixture(axis: StitchAxis, dark: Bool = false,
                                    printed: Bool = true, hasAlpha: Bool = false) throws -> StitchDocument {
        let paper = dark ? SIMD3<UInt8>(31, 38, 48) : SIMD3<UInt8>(240, 242, 247)
        let ink = dark ? SIMD3<UInt8>(192, 207, 226) : SIMD3<UInt8>(52, 64, 79)
        var bytes = [UInt8](repeating: 0, count: 256 * 256 * 4)
        for y in 0..<256 {
            for x in 0..<256 {
                let normal = axis == .horizontal ? y : x
                let along = axis == .horizontal ? x : y
                let isInk = printed && (117..<119).contains(normal)
                    && (20..<236).contains(along) && along % 48 < 32
                let color = isInk ? ink : paper
                let alpha: UInt8
                if hasAlpha {
                    let alongAlpha = [96, 160, 224, 255][along / 64]
                    let normalAlpha = normal < 117 ? 255 : normal < 119 ? 112 : 192
                    let hole = (80..<112).contains(along) && (108..<152).contains(normal)
                    alpha = hole ? 0 : UInt8((alongAlpha * normalAlpha + 127) / 255)
                } else {
                    alpha = 255
                }
                let offset = (y * 256 + x) * 4
                for (channel, value) in [color.x, color.y, color.z].enumerated() {
                    bytes[offset + channel] = UInt8((Int(value) * Int(alpha) + 127) / 255)
                }
                bytes[offset + 3] = alpha
            }
        }
        let image = try XCTUnwrap(CGImage(width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 256 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        var document = StitchDocument(pieces: [StitchPiece(image: image)], background: .transparent)
        XCTAssertTrue(document.collapse(axis: axis, from: 120, to: 136))
        document.style.transition = .fold
        return document
    }

    private func seamColor(_ bitmap: NSBitmapImageRep, axis: StitchAxis,
                           along: Int, normal: Int, scale: CGFloat = 1) throws -> NSColor {
        try XCTUnwrap(bitmap.colorAt(x: Int(CGFloat(axis == .horizontal ? along : normal) * scale),
            y: Int(CGFloat(axis == .horizontal ? normal : along) * scale))?.usingColorSpace(.sRGB))
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
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
                XCTAssertEqual(try pixels(XCTUnwrap(StitchRenderer.render(document))), original,
                    "\(transition) must use its own paper controls and leave content crisp")
            }
        }
    }

    func testTornHasSeparatedContrastingPaperEdgesWithIrregularTeethOnBothAxes() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = try fixture(.torn, axis: axis, dark: true, flat: true)
            let image = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document)))
            document.style.visible = false
            let original = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document)))
            var firstPaperPixels = Set<Int>()
            for along in stride(from: 30, through: 220, by: 5) {
                var exposed: [Int] = []
                for normal in 104..<136 {
                    let color = try XCTUnwrap(image.colorAt(x: axis == .horizontal ? along : normal,
                        y: axis == .horizontal ? normal : along)).usingColorSpace(.sRGB)!
                    let base = try XCTUnwrap(original.colorAt(x: axis == .horizontal ? along : normal,
                        y: axis == .horizontal ? normal : along)).usingColorSpace(.sRGB)!
                    if abs(color.redComponent - base.redComponent) > 0.02
                        && abs(color.greenComponent - base.greenComponent) > 0.02
                        && abs(color.blueComponent - base.blueComponent) > 0.02 {
                        exposed.append(normal)
                    }
                }
                XCTAssertGreaterThanOrEqual(exposed.count, 2, "Both torn lips should contrast with the local background")
                XCTAssertLessThanOrEqual(exposed.count, 12)
                firstPaperPixels.insert(try XCTUnwrap(exposed.first))
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(exposed.last) - XCTUnwrap(exposed.first), 4,
                    "The tear should have separated edges around its unaltered paper color")
            }
            XCTAssertGreaterThan(firstPaperPixels.count, 2, "Paper edges should have visibly unequal teeth")
        }
    }

    func testZeroPaperWidthHidesTheWholeTearIncludingFibersAndShadow() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = try fixture(.torn, axis: axis, dark: true)
            document.style.tearWidth = 0
            let cleared = try pixels(XCTUnwrap(StitchRenderer.render(document)))
            document.style.visible = false
            XCTAssertEqual(try pixels(XCTUnwrap(StitchRenderer.render(document))), cleared)
        }
    }

    func testFoldHasAThinReturnAndFadingShadowBelowTheJoinOnBothBackgroundsAndAxes() throws {
        for dark in [false, true] {
            for axis in [StitchAxis.horizontal, .vertical] {
                var document = try fixture(.fold, axis: axis, dark: dark, flat: true)
                let folded = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document)))
                document.style.visible = false
                let original = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document)))
                func darkening(_ normal: Int) throws -> CGFloat {
                    let before = try seamColor(original, axis: axis, along: 128, normal: normal)
                    let after = try seamColor(folded, axis: axis, along: 128, normal: normal)
                    return luminance(before) - luminance(after)
                }

                for normal in 108..<119 {
                    XCTAssertEqual(try darkening(normal), 0, accuracy: 2 / 255,
                        "The flat upper sheet must retain its captured color")
                }
                let returnShade = try (119..<122).map { try darkening($0) }.max()!
                let nearShadow = try (121..<123).map { try darkening($0) }.max()!
                XCTAssertGreaterThan(returnShade, 1 / 255, "The returned edge must remain visible")
                XCTAssertGreaterThan(nearShadow, 1 / 255, "The lower edge must cast a shadow")
                XCTAssertLessThan(returnShade, 0.25, "A shallow fold needs a restrained edge")
                XCTAssertLessThan(try darkening(124), nearShadow,
                    "The shadow must fade as it falls away from the lower edge")
                for normal in 125..<136 {
                    XCTAssertEqual(try darkening(normal), 0, accuracy: 1 / 255)
                }
                let changedRows = try (108..<136).filter { try abs(darkening($0)) > 2 / 255 }
                XCTAssertLessThanOrEqual(changedRows.count, 6,
                    "The returned edge and shadow must fit in a narrow strip")
            }
        }
    }

    func testFoldStrengthAboveMidpointProgressivelyDeepensTheLowerShadowAtUnchangedDepth() throws {
        for dark in [false, true] {
            for axis in [StitchAxis.horizontal, .vertical] {
                var document = try fixture(.fold, axis: axis, dark: dark, flat: true)
                document.style.foldDepth = 18
                document.style.visible = false
                let original = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document)))
                document.style.visible = true
                var previousShadow: CGFloat = 0
                for strength: CGFloat in [1, 1.5, 2] {
                    document.style.foldStrength = strength
                    let folded = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document)))
                    var shadow: CGFloat = 0
                    for along in stride(from: 32, to: 224, by: 16) {
                        for normal in 121..<125 {
                            shadow += try luminance(seamColor(original, axis: axis, along: along, normal: normal))
                                - luminance(seamColor(folded, axis: axis, along: along, normal: normal))
                        }
                    }
                    XCTAssertGreaterThan(shadow, previousShadow,
                        "Strength \(strength) must deepen the lower shadow at depth 18: \(axis), dark=\(dark)")
                    previousShadow = shadow
                }
            }
        }
    }

    func testFoldGentlyDistortsTheUpperEdgeWhileRetainingPrintedDetailsAtExportAndPreviewSizes() throws {
        for dark in [false, true] {
            for axis in [StitchAxis.horizontal, .vertical] {
                var printed = try foldTextureFixture(axis: axis, dark: dark)
                var blank = try foldTextureFixture(axis: axis, dark: dark, printed: false)
                printed.style.foldStrength = 1
                blank.style.foldStrength = 1
                for dimension: CGFloat in [256, 128, 127] {
                    printed.style.visible = true
                    blank.style.visible = true
                    let foldedPrint = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(printed,
                        maximumPreviewDimension: dimension)))
                    let foldedBlank = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(blank,
                        maximumPreviewDimension: dimension)))
                    printed.style.visible = false
                    blank.style.visible = false
                    let originalPrint = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(printed,
                        maximumPreviewDimension: dimension)))
                    let originalBlank = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(blank,
                        maximumPreviewDimension: dimension)))
                    let scale = dimension / 256
                    var capturedContrast: CGFloat = 0, retainedContrast: CGFloat = 0
                    var capturedMoment: CGFloat = 0, retainedMoment: CGFloat = 0
                    for normal in 112..<120 {
                        for along in stride(from: 30, to: 220, by: 5) {
                            let original = try abs(luminance(seamColor(originalPrint, axis: axis,
                                along: along, normal: normal, scale: scale))
                                - luminance(seamColor(originalBlank, axis: axis,
                                    along: along, normal: normal, scale: scale)))
                            let folded = try abs(luminance(seamColor(foldedPrint, axis: axis,
                                along: along, normal: normal, scale: scale))
                                - luminance(seamColor(foldedBlank, axis: axis,
                                    along: along, normal: normal, scale: scale)))
                            capturedContrast += original
                            retainedContrast += folded
                            capturedMoment += CGFloat(normal) * original
                            retainedMoment += CGFloat(normal) * folded
                        }
                    }
                    XCTAssertGreaterThan(capturedContrast, 1)
                    XCTAssertGreaterThan(retainedContrast, capturedContrast * 0.55,
                        "Printed details must travel with the upper sheet: \(axis), dark=\(dark), dimension=\(dimension)")
                    if dimension == 256 {
                        let shift = retainedMoment / retainedContrast - capturedMoment / capturedContrast
                        XCTAssertGreaterThan(shift, 0.04, "The upper edge must bend toward the join")
                        XCTAssertLessThan(shift, 1, "The captured details must move by less than one pixel")
                    }
                }
            }
        }
    }

    func testZeroFoldDepthOrStrengthIsAnExactNoOpAtExportAndFractionalPreviewSizes() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = try foldTextureFixture(axis: axis, hasAlpha: true)
            for dimension: CGFloat in [256, 128, 127] {
                document.style.visible = false
                let original = try pixels(XCTUnwrap(StitchRenderer.render(document,
                    maximumPreviewDimension: dimension)))
                document.style.visible = true
                for (depth, strength): (CGFloat, CGFloat) in [(0, 1), (40, 0), (0, 2), (80, 0)] {
                    document.style.foldDepth = depth
                    document.style.foldStrength = strength
                    XCTAssertEqual(try pixels(XCTUnwrap(StitchRenderer.render(document,
                        maximumPreviewDimension: dimension))), original)
                }
            }
        }
    }

    func testFoldPreservesSourceAlphaAndInteriorHolesWithFractionalOriginsAndPreviews() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = try foldTextureFixture(axis: axis, hasAlpha: true)
            let source = NSBitmapImageRep(cgImage: document.pieces[0].image)
            XCTAssertNotEqual(try seamColor(source, axis: axis, along: 160, normal: 116).alphaComponent,
                try seamColor(source, axis: axis, along: 160, normal: 118).alphaComponent,
                "The fixture must change alpha across the bend, where source samples move")
            for index in document.pieces.indices {
                document.pieces[index].origin.x += 0.25
                document.pieces[index].origin.y -= 0.35
            }
            let bounds = document.bounds.integral
            for dimension: CGFloat in [257, 128, 127] {
                document.style.visible = false
                let original = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension))
                document.style.visible = true
                for (depth, strength): (CGFloat, CGFloat) in [(18, 1), (80, 2)] {
                    document.style.foldDepth = depth
                    document.style.foldStrength = strength
                    let folded = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension))
                    XCTAssertEqual(folded.width, original.width)
                    XCTAssertEqual(folded.height, original.height)
                    XCTAssertEqual(document.bounds.integral, bounds)
                    let before = try pixels(original), after = try pixels(folded)
                    XCTAssertNotEqual(after, before, "The fold must still render on partially transparent content")
                    let changedAlpha = stride(from: 3, to: before.count, by: 4).first { after[$0] != before[$0] }
                    XCTAssertNil(changedAlpha,
                        "Strength \(strength), depth \(depth): every source alpha byte must survive, including holes. First change: \(String(describing: changedAlpha))")
                }
            }
        }
    }

    func testFoldKeepsRedactedSourcePixelsUnderTheirMasksInEditorExportsAndUndoRedo() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            for tool in [AnnotationTool.filledRectangle, .pixelate, .blur] {
                for scale: CGFloat in [1, 2] {
                    for (depth, strength): (CGFloat, CGFloat) in [(18, 0.5), (18, 1), (80, 2)] {
                        let fixture = try redactedFoldFixture(axis: axis, tool: tool, scale: scale)
                        try assertFoldRedactionCoverage(fixture.editor, axis: axis, bendsExposedStroke: false)
                        var folded = fixture.document
                        folded.style.visible = true
                        folded.style.transition = .fold
                        folded.style.foldDepth = depth
                        folded.style.foldStrength = strength
                        XCTAssertTrue(fixture.editor.applyStitchDocument(folded))
                        try assertFoldRedactionCoverage(fixture.editor, axis: axis, bendsExposedStroke: true)
                        fixture.editor.undo()
                        try assertFoldRedactionCoverage(fixture.editor, axis: axis, bendsExposedStroke: false)
                        fixture.editor.redo()
                        try assertFoldRedactionCoverage(fixture.editor, axis: axis, bendsExposedStroke: true)
                    }
                }
            }
        }
    }

    func testEditableHistoryReopenKeepsFoldedSourcePixelsUnderFilledAndBakedRedactions() async throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            for tool in [AnnotationTool.filledRectangle, .pixelate, .blur] {
                let fixture = try redactedFoldFixture(axis: axis, tool: tool, scale: 2)
                var folded = fixture.document
                folded.style.visible = true
                folded.style.transition = .fold
                folded.style.foldDepth = 80
                folded.style.foldStrength = 2
                XCTAssertTrue(fixture.editor.applyStitchDocument(folded))
                let raw = try XCTUnwrap(fixture.editor.captureSelectedRegionRaw())
                let composited = try XCTUnwrap(fixture.editor.captureSelectedRegion())
                let state = fixture.editor.captureEditState()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let history = ScreenshotHistory(directory: directory)
                defer { try? FileManager.default.removeItem(at: directory) }
                withDefaults(["historySize": 10, "historyUnlimited": false]) {
                    history.add(image: composited, rawImage: raw, annotations: fixture.editor.annotations, editState: state)
                }
                await history.waitUntilIdle()
                let entry = try XCTUnwrap(history.entries.first)
                let editable = try XCTUnwrap(history.loadEditableCapture(for: entry))
                let reopened = EditorView(frame: CGRect(origin: .zero, size: editable.rawImage.size))
                reopened.screenshotImage = editable.rawImage
                reopened.applySelection(reopened.bounds)
                reopened.setAnnotations(editable.annotations)
                reopened.applyCaptureEditState(try XCTUnwrap(editable.editState))
                try assertFoldRedactionCoverage(reopened, axis: axis, bendsExposedStroke: true)
                XCTAssertEqual(reopened.screenshotImage?.size, raw.size)
                let restoredMask = try XCTUnwrap(reopened.annotations.first)
                if tool != .filledRectangle {
                    let originalBake = try XCTUnwrap(fixture.editor.annotations.first?.bakedBlurNSImage)
                    let restoredBake = try XCTUnwrap(restoredMask.bakedBlurNSImage)
                    XCTAssertEqual(try pixels(XCTUnwrap(restoredBake.cgImage(forProposedRect: nil,
                        context: nil, hints: nil))), try pixels(XCTUnwrap(originalBake.cgImage(forProposedRect: nil,
                            context: nil, hints: nil))))
                }
            }
        }
    }

    func testRedactionsAddedMovedAndDeletedAfterFoldRefreshRawExportAndHistoryPixels() async throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let fixture = try redactedFoldFixture(axis: axis, tool: .filledRectangle, scale: 1)
            let editor = fixture.editor
            editor.setAnnotations([])
            var folded = fixture.document
            folded.style.visible = true
            folded.style.transition = .fold
            folded.style.foldDepth = 80
            folded.style.foldStrength = 2
            XCTAssertTrue(editor.applyStitchDocument(folded))
            let unprotected = try assertFoldRawMatchesCurrentProtection(editor)

            // This later mask reaches the lower crease. Its protected section
            // also keeps the upper bend straight above the annotation.
            let nativeMask = axis == .horizontal ? CGRect(x: 48, y: 119, width: 160, height: 3)
                : CGRect(x: 119, y: 48, width: 3, height: 160)
            let canvasMask = CGRect(x: nativeMask.minX, y: folded.bounds.integral.height - nativeMask.maxY,
                width: nativeMask.width, height: nativeMask.height)
            let mask = Annotation(tool: .filledRectangle, startPoint: canvasMask.origin,
                endPoint: CGPoint(x: canvasMask.maxX, y: canvasMask.maxY), color: .red, strokeWidth: 1)
            mask.rectCornerRadius = 0
            mask.outlineColor = nil
            editor.setAnnotations([mask])
            let addedExport = try pixels(XCTUnwrap(editor.captureSelectedRegion()?.cgImage(forProposedRect: nil,
                context: nil, hints: nil)))
            let protected = try assertFoldRawMatchesCurrentProtection(editor)
            XCTAssertEqual(addedExport, try pixels(XCTUnwrap(editor.captureSelectedRegion()?.cgImage(forProposedRect: nil,
                context: nil, hints: nil))), "Export must refresh coverage before the raw-capture entry is called")
            XCTAssertNotEqual(try pixels(protected), try pixels(unprotected),
                "Adding a redaction after Fold must refresh the raster above its protected section")
            let beforeMove = mask.clone()
            mask.move(dx: axis == .horizontal ? 24 : 0, dy: axis == .horizontal ? 0 : -24)
            editor.undoStack.append(.propertyChange(annotation: mask, snapshot: beforeMove))
            let movedExport = try XCTUnwrap(editor.captureSelectedRegion())
            let movedExportPixels = try pixels(XCTUnwrap(movedExport.cgImage(forProposedRect: nil,
                context: nil, hints: nil)))
            let movedRaw = try assertFoldRawMatchesCurrentProtection(editor)
            XCTAssertNotEqual(try pixels(movedRaw), try pixels(protected))
            XCTAssertEqual(movedExportPixels, try pixels(XCTUnwrap(editor.captureSelectedRegion()?.cgImage(forProposedRect: nil,
                context: nil, hints: nil))))
            editor.undo()
            XCTAssertTrue(editor.refreshFoldProtection())
            XCTAssertEqual(try pixels(assertFoldRawMatchesCurrentProtection(editor)), try pixels(protected))
            editor.redo()
            XCTAssertEqual(try pixels(assertFoldRawMatchesCurrentProtection(editor)), try pixels(movedRaw))

            let raw = try XCTUnwrap(editor.captureSelectedRegionRaw())
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let history = ScreenshotHistory(directory: directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            withDefaults(["historySize": 10, "historyUnlimited": false]) {
                history.add(image: movedExport, rawImage: raw, annotations: editor.annotations,
                    editState: editor.captureEditState())
            }
            await history.waitUntilIdle()
            let editable = try XCTUnwrap(history.loadEditableCapture(for: XCTUnwrap(history.entries.first)))
            let reopened = EditorView(frame: CGRect(origin: .zero, size: editable.rawImage.size))
            reopened.screenshotImage = editable.rawImage
            reopened.applySelection(reopened.bounds)
            reopened.setAnnotations(editable.annotations)
            reopened.applyCaptureEditState(try XCTUnwrap(editable.editState))
            XCTAssertEqual(try pixels(assertFoldRawMatchesCurrentProtection(reopened)), try pixels(movedRaw))
            XCTAssertEqual(try pixels(XCTUnwrap(reopened.captureSelectedRegion()?.cgImage(forProposedRect: nil,
                context: nil, hints: nil))), movedExportPixels,
                "History must reopen the same protected Fold and annotations seen in the editor export")

            let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = editor
            defer { window.orderOut(nil) }
            editor.currentTool = .select
            let center = CGPoint(x: mask.boundingRect.midX, y: mask.boundingRect.midY)
            func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: editor.convert(center, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1))
            }
            editor.mouseDown(with: try mouse(.leftMouseDown))
            editor.mouseUp(with: try mouse(.leftMouseUp))
            editor.keyDown(with: TestKeyEvent.keyDown(characters: "\u{8}", keyCode: 51))
            XCTAssertTrue(editor.annotations.isEmpty)
            XCTAssertEqual(try pixels(XCTUnwrap(editor.captureSelectedRegion()?.cgImage(forProposedRect: nil,
                context: nil, hints: nil))), try pixels(unprotected))
            XCTAssertEqual(try pixels(assertFoldRawMatchesCurrentProtection(editor)), try pixels(unprotected))
            editor.undo()
            XCTAssertEqual(try pixels(XCTUnwrap(editor.captureSelectedRegion()?.cgImage(forProposedRect: nil,
                context: nil, hints: nil))), movedExportPixels)
            XCTAssertEqual(try pixels(assertFoldRawMatchesCurrentProtection(editor)), try pixels(movedRaw))
            editor.redo()
            XCTAssertTrue(editor.annotations.isEmpty)
            XCTAssertEqual(try pixels(XCTUnwrap(editor.captureSelectedRegion()?.cgImage(forProposedRect: nil,
                context: nil, hints: nil))), try pixels(unprotected))
            XCTAssertEqual(try pixels(assertFoldRawMatchesCurrentProtection(editor)), try pixels(unprotected))
        }
    }

    func testFoldLeavesColoredUncoveredGapsBesideShortJoinsUntouched() throws {
        let image = try XCTUnwrap(ImageProbe.solidImage(width: 20, height: 20)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        for transposed in [false, true] {
            let origins = [CGPoint.zero, CGPoint(x: 20, y: 0), CGPoint(x: 2, y: 20)].map {
                transposed ? CGPoint(x: $0.y, y: $0.x) : $0
            }
            var document = StitchDocument(pieces: origins.map { StitchPiece(image: image, origin: $0) },
                background: .color(.magenta))
            document.style.transition = .fold
            document.style.foldDepth = 80
            document.style.foldStrength = 2
            for dimension: CGFloat in [40, 20, 19] {
                document.style.visible = false
                let before = try pixels(XCTUnwrap(StitchRenderer.render(document,
                    maximumPreviewDimension: dimension)))
                document.style.visible = true
                let after = try pixels(XCTUnwrap(StitchRenderer.render(document,
                    maximumPreviewDimension: dimension)))
                var gaps = 0
                for offset in stride(from: 0, to: before.count, by: 4)
                    where before[offset] == 255 && before[offset + 1] == 0 && before[offset + 2] == 255 {
                    gaps += 1
                    XCTAssertEqual(after[offset..<(offset + 4)], before[offset..<(offset + 4)],
                        "The fold must not distort or shade the canvas fill beside a short join")
                }
                XCTAssertGreaterThan(gaps, 0)
            }
        }
    }

    func testFoldStyleEditsPreserveCanvasAndAnnotationCoordinatesAtBothSourceScales() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            for scale: CGFloat in [1, 2] {
                var document = try fixture(.wave, axis: axis)
                for index in document.pieces.indices {
                    document.pieces[index].origin.x += 0.2
                    document.pieces[index].origin.y += 0.7
                }
                let editor = try makeEditor(document, scale: scale)
                let mark = Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 90 / scale, y: 110 / scale),
                    endPoint: CGPoint(x: 140 / scale, y: 116 / scale), color: .red, strokeWidth: 1)
                editor.setAnnotations([mark])
                let canvas = editor.bounds, imageSize = editor.screenshotImage?.size
                let start = mark.startPoint, end = mark.endPoint
                document.style.transition = .fold
                document.style.foldDepth = 40
                document.style.foldStrength = 1
                XCTAssertTrue(editor.applyStitchDocument(document))
                XCTAssertEqual(editor.bounds, canvas)
                XCTAssertEqual(editor.screenshotImage?.size, imageSize)
                XCTAssertTrue(editor.annotations.first === mark)
                XCTAssertEqual(mark.startPoint, start)
                XCTAssertEqual(mark.endPoint, end)
                XCTAssertEqual(editor.stitchDocument?.pieces.map(\.origin), document.pieces.map(\.origin))
                XCTAssertEqual(editor.stitchDocument?.pieces.map(\.source), document.pieces.map(\.source))
            }
        }
    }

    func testShortFoldLimitsItsDepthAndLeavesSurroundingCapturedPixelsIntact() throws {
        let image = try XCTUnwrap(ImageProbe.solidImage(width: 20, height: 20)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        for axis in [StitchAxis.horizontal, .vertical] {
            let origin = axis == .horizontal ? CGPoint(x: 0, y: 20) : CGPoint(x: 20, y: 0)
            var document = StitchDocument(pieces: [StitchPiece(image: image), StitchPiece(image: image, origin: origin)])
            document.style.transition = .fold
            document.style.foldDepth = 80
            document.style.foldStrength = 2
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

    func testLegacyManualPaperColorIsIgnoredAndNewHistoryOmitsIt() throws {
        let document = try fixture(.torn, dark: true)
        let saved = try XCTUnwrap(SavedStitchDocument(document))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertNil(object["paperColor"])
        for legacy in [[1, 0, 0, 0.5], "invalid old paper color"] as [Any] {
            object["paperColor"] = legacy
            let restored = try XCTUnwrap(JSONDecoder().decode(SavedStitchDocument.self,
                from: JSONSerialization.data(withJSONObject: object)).restore())
            XCTAssertEqual(try pixels(XCTUnwrap(StitchRenderer.render(restored))),
                           try pixels(XCTUnwrap(StitchRenderer.render(document))))
            let newObject = try XCTUnwrap(JSONSerialization.jsonObject(with:
                JSONEncoder().encode(XCTUnwrap(SavedStitchDocument(restored)))) as? [String: Any])
            XCTAssertNil(newObject["paperColor"])
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
        for (key, invalid) in [("tearWidth", -1.0), ("tearRoughness", 101.0), ("foldDepth", 101.0), ("foldStrength", 2.1), ("breakSize", -1.0)] {
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

    func testNativeCropUndoRedoRebakesRootedLoupeAfterControllerRestoresFinalCanvasBounds() throws {
        for scale: CGFloat in [1, 2] {
            let document = try fixture(.fold)
            let editor = try makeEditor(document, scale: scale)
            let loupe = Annotation(tool: .loupe, startPoint: CGPoint(x: 170 / scale, y: 150 / scale),
                endPoint: CGPoint(x: 210 / scale, y: 190 / scale), color: .white, strokeWidth: 1)
            loupe.loupeSourceRect = CGRect(x: 108 / scale, y: 108 / scale, width: 24 / scale, height: 24 / scale)
            loupe.loupeMagnification = 2
            editor.setAnnotations([loupe])
            let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = editor
            let controller = StitchEditorController(document: document, window: window)
            controller.onDocumentChanged = { [weak editor] value, registerUndo in
                editor?.applyStitchDocument(value, registerUndo: registerUndo) ?? false
            }
            var restores = 0
            editor.onStitchDocumentChanged = { [weak controller, weak editor] in
                if let value = editor?.stitchDocument {
                    restores += 1
                    controller?.restore(value)
                }
            }
            controller.attach(to: editor)
            defer { controller.suspend(); editor.onStitchDocumentChanged = nil; window.orderOut(nil) }
            XCTAssertTrue(controller.isAttached)

            func assertCurrentLoupe(size: CGSize) throws {
                XCTAssertEqual(editor.selectionRect.size, size)
                XCTAssertEqual(editor.screenshotImage?.size, size)
                XCTAssertTrue(editor.annotations.first === loupe)
                XCTAssertTrue(loupe.sourceImage === editor.screenshotImage)
                XCTAssertEqual(loupe.sourceImageBounds, editor.captureDrawRect)
                let actual = try pixels(XCTUnwrap(loupe.bakedBlurNSImage?.cgImage(forProposedRect: nil,
                    context: nil, hints: nil)))
                let expected = loupe.clone()
                expected.sourceImage = editor.screenshotImage
                expected.sourceImageBounds = editor.captureDrawRect
                expected.bakedBlurNSImage = nil
                expected.bakeLoupe()
                XCTAssertEqual(actual, try pixels(XCTUnwrap(expected.bakedBlurNSImage?.cgImage(forProposedRect: nil,
                    context: nil, hints: nil))),
                    "The controller must bake the rooted loupe using the final restored canvas bounds")
            }

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
            let croppedSize = CGSize(width: 256 / scale - 20, height: 240 / scale - 20)
            XCTAssertGreaterThan(restores, 0)
            try assertCurrentLoupe(size: croppedSize)
            let beforeUndo = restores
            editor.undo()
            XCTAssertGreaterThan(restores, beforeUndo)
            try assertCurrentLoupe(size: CGSize(width: 256 / scale, height: 240 / scale))
            let beforeRedo = restores
            editor.redo()
            XCTAssertGreaterThan(restores, beforeRedo)
            try assertCurrentLoupe(size: croppedSize)
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

    func testOptionalFoldContentFixtures() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["MACSHOT_SEAM_PREVIEW_DIR"]
            ?? environment["TEST_RUNNER_MACSHOT_SEAM_PREVIEW_DIR"] else { return }
        for theme in ["light", "dark", "colored"] {
            for axis in [StitchAxis.horizontal, .vertical] {
                var fixture = try foldContentFixture(axis: axis, theme: theme)
                let prefix = "fold-content-\(theme)-\(axis)"
                try writeFixture(fixture.source, directory: directory, name: "\(prefix)-source.png")
                try writeFixture(XCTUnwrap(StitchRenderer.render(fixture.document)),
                    directory: directory, name: "\(prefix)-full.png")
                for dimension: CGFloat in [256, 127] {
                    try writeFixture(XCTUnwrap(StitchRenderer.render(fixture.document,
                        maximumPreviewDimension: dimension)), directory: directory,
                        name: "\(prefix)-preview-\(Int(dimension)).png")
                }
                fixture.document.style.foldDepth = 18
                fixture.document.style.foldStrength = 2
                try writeFixture(XCTUnwrap(StitchRenderer.render(fixture.document)),
                    directory: directory, name: "\(prefix)-strength-2-full.png")
                fixture.document.style.foldDepth = 80
                try writeFixture(XCTUnwrap(StitchRenderer.render(fixture.document)),
                    directory: directory, name: "\(prefix)-max-full.png")
                for dimension: CGFloat in [256, 127] {
                    try writeFixture(XCTUnwrap(StitchRenderer.render(fixture.document,
                        maximumPreviewDimension: dimension)), directory: directory,
                        name: "\(prefix)-max-preview-\(Int(dimension)).png")
                }
                fixture.document.style.visible = false
                try writeFixture(XCTUnwrap(StitchRenderer.render(fixture.document)),
                    directory: directory, name: "\(prefix)-unfolded.png")
            }
        }
    }

    private func foldContentFixture(axis: StitchAxis, theme: String) throws
        -> (source: CGImage, document: StitchDocument) {
        let background: NSColor, ink: NSColor, secondary: NSColor
        switch theme {
        case "dark":
            background = NSColor(srgbRed: 0.12, green: 0.15, blue: 0.19, alpha: 1)
            ink = NSColor(srgbRed: 0.88, green: 0.91, blue: 0.96, alpha: 1)
            secondary = NSColor(srgbRed: 0.57, green: 0.63, blue: 0.71, alpha: 1)
        case "colored":
            background = NSColor(srgbRed: 0.18, green: 0.42, blue: 0.36, alpha: 1)
            ink = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.88, alpha: 1)
            secondary = NSColor(srgbRed: 0.66, green: 0.83, blue: 0.73, alpha: 1)
        default:
            background = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.94, alpha: 1)
            ink = NSColor(srgbRed: 0.18, green: 0.22, blue: 0.28, alpha: 1)
            secondary = NSColor(srgbRed: 0.42, green: 0.47, blue: 0.54, alpha: 1)
        }
        let source = try XCTUnwrap(ImageProbe.makeImage(width: 512, height: 384) { context in
            context.translateBy(x: 0, y: 384)
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 384))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            defer { NSGraphicsContext.restoreGraphicsState() }
            func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat,
                      size: CGFloat = 16, weight: NSFont.Weight = .regular,
                      color: NSColor? = nil, alignment: NSTextAlignment = .left) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = alignment
                (value as NSString).draw(in: CGRect(x: x, y: y, width: width, height: size * 1.6),
                    withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                        .foregroundColor: color ?? ink, .paragraphStyle: paragraph])
            }
            context.setFillColor(secondary.cgColor)
            if axis == .horizontal {
                text("Monthly report", x: 24, y: 24, width: 464, size: 24, weight: .semibold)
                text("Engineering / October 2026", x: 24, y: 58, width: 464, size: 12, color: secondary)
                text("Project", x: 24, y: 99, width: 260, size: 12, weight: .semibold, color: secondary)
                text("Captures", x: 354, y: 99, width: 134, size: 12, weight: .semibold,
                    color: secondary, alignment: .right)
                context.fill(CGRect(x: 24, y: 121, width: 464, height: 1))
                text("Workspace", x: 24, y: 133, width: 270)
                text("12,480", x: 354, y: 133, width: 134, alignment: .right)
                text("Typography check", x: 24, y: 172, width: 270)
                text("3,712", x: 354, y: 172, width: 134, alignment: .right)
                context.fill(CGRect(x: 24, y: 190, width: 464, height: 1))
                text("Export queue", x: 24, y: 219, width: 270)
                text("846", x: 354, y: 219, width: 134, alignment: .right)
                context.fill(CGRect(x: 24, y: 252, width: 464, height: 1))
                text("All captured details stay editable.", x: 24, y: 278, width: 464,
                    size: 13, color: secondary)
            } else {
                text("Usage", x: 24, y: 24, width: 154, size: 24, weight: .semibold)
                text("October 2026", x: 24, y: 59, width: 154, size: 12, color: secondary)
                text("This month", x: 224, y: 24, width: 264, size: 24, weight: .semibold)
                text("Captured work", x: 224, y: 59, width: 264, size: 12, color: secondary)
                for (index, label) in ["Workspace", "Capture tools", "Export queue", "History"].enumerated() {
                    let y = CGFloat(113 + index * 54)
                    text(label, x: 24, y: y, width: 154, size: 13, color: secondary)
                    text(["12,480", "3,712", "846", "2,604"][index], x: 24, y: y + 18,
                        width: 166, size: 16, weight: .medium, alignment: .right)
                    text(["Active projects", "Screenshots saved", "Ready to share", "Source images retained"][index],
                        x: 224, y: y + 18, width: 264, size: 15)
                }
                context.fill(CGRect(x: 190, y: 106, width: 1, height: 232))
            }
        }.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: source)], background: .transparent)
        XCTAssertTrue(document.collapse(axis: axis, from: 192, to: 208))
        document.style.transition = .fold
        return (source, document)
    }

    private func writeFixture(_ image: CGImage, directory: String, name: String) throws {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }

    private func redactedFoldFixture(axis: StitchAxis, tool: AnnotationTool, scale: CGFloat) throws
        -> (document: StitchDocument, editor: EditorView) {
        let source = try XCTUnwrap(ImageProbe.makeImage(width: 256, height: 256) { context in
            context.translateBy(x: 0, y: 256)
            context.scaleBy(x: 1, y: -1)
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
            // The long stripe is secret. The short stripe remains visible and
            // proves that Fold still bends content outside protected sections.
            for along in [CGRect(x: 16, y: 117, width: 16, height: 1),
                          CGRect(x: 48, y: 117, width: 160, height: 1)] {
                let stripe = axis == .horizontal ? along
                    : CGRect(x: along.minY, y: along.minX, width: along.height, height: along.width)
                context.fill(stripe)
            }
        }.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: source)], background: .transparent)
        XCTAssertTrue(document.collapse(axis: axis, from: 120, to: 136))
        document.style.visible = false
        let editor = try makeEditor(document, scale: scale)
        editor.beautifyEnabled = false
        editor.effectsPreset = .none
        editor.effectsBrightness = 0
        editor.effectsContrast = 1
        editor.effectsSaturation = 1
        editor.effectsSharpness = 0
        let nativeMask = axis == .horizontal ? CGRect(x: 48, y: 112, width: 160, height: 6)
            : CGRect(x: 112, y: 48, width: 6, height: 160)
        let canvasMask = CGRect(x: nativeMask.minX / scale,
            y: (document.bounds.integral.height - nativeMask.maxY) / scale,
            width: nativeMask.width / scale, height: nativeMask.height / scale)
        let mask = Annotation(tool: tool, startPoint: canvasMask.origin,
            endPoint: CGPoint(x: canvasMask.maxX, y: canvasMask.maxY), color: .red, strokeWidth: 1)
        mask.rectCornerRadius = 0
        mask.outlineColor = nil
        mask.censorMode = tool == .blur ? .blur : .pixelate
        if tool != .filledRectangle {
            let baked = ImageProbe.solidImage(width: Int(nativeMask.width), height: Int(nativeMask.height),
                color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            baked.size = canvasMask.size
            mask.bakedBlurNSImage = baked
        }
        editor.setAnnotations([mask])
        XCTAssertEqual(mask.stitchPixelCoverage(in: document.bounds.integral, scale: scale), nativeMask)
        return (document, editor)
    }

    private func assertFoldRedactionCoverage(_ editor: EditorView, axis: StitchAxis, bendsExposedStroke: Bool,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let output = try XCTUnwrap(editor.captureSelectedRegion(), file: file, line: line)
        let image = try XCTUnwrap(output.cgImage(forProposedRect: nil, context: nil, hints: nil), file: file, line: line)
        let bitmap = NSBitmapImageRep(cgImage: image)
        // NSBitmapImageRep.colorAt returns calibrated colors. Converting those
        // to sRGB shifts saturated channels on this Mac despite unchanged bytes.
        let bytes = try pixels(image)
        func channels(along: Int, normal: Int) -> SIMD4<UInt8> {
            let x = axis == .horizontal ? along : normal
            let y = axis == .horizontal ? normal : along
            let offset = (y * image.width + x) * 4
            return SIMD4(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
        }
        let document = try XCTUnwrap(editor.stitchDocument, file: file, line: line)
        XCTAssertEqual(bitmap.pixelsWide, Int(document.bounds.integral.width), file: file, line: line)
        XCTAssertEqual(bitmap.pixelsHigh, Int(document.bounds.integral.height), file: file, line: line)
        for along in 48..<208 {
            let covered = channels(along: along, normal: 117)
            guard covered.x >= 253, covered.y <= 2, covered.z <= 2, covered.w == 255 else {
                XCTFail("The source stripe must stay under its red mask at \(along) along the \(axis) seam: \(covered)",
                    file: file, line: line)
                return
            }
            let outside = channels(along: along, normal: 118)
            guard outside.y <= 2 else {
                XCTFail("Fold pulled the hidden green stripe beyond the redaction's lower edge at \(along) along the \(axis) seam",
                    file: file, line: line)
                return
            }
        }
        let exposed = channels(along: 24, normal: 118)
        if bendsExposedStroke {
            XCTAssertGreaterThan(exposed.y, 38,
                "Captured details outside the redaction must continue to bend", file: file, line: line)
        } else {
            XCTAssertLessThanOrEqual(exposed.y, 2, file: file, line: line)
        }
    }

    @discardableResult
    private func assertFoldRawMatchesCurrentProtection(_ editor: EditorView,
        file: StaticString = #filePath, line: UInt = #line) throws -> CGImage {
        let raw = try XCTUnwrap(editor.captureSelectedRegionRaw(), file: file, line: line)
        let image = try XCTUnwrap(raw.cgImage(forProposedRect: nil, context: nil, hints: nil), file: file, line: line)
        let document = try XCTUnwrap(editor.stitchDocument, file: file, line: line)
        let scale = CGFloat(image.width) / raw.size.width
        let protection = editor.annotations.filter(\.isStitchRedaction).map {
            $0.stitchPixelCoverage(in: document.bounds.integral, scale: scale)
        }
        let canonical = try XCTUnwrap(StitchRenderer.render(document, protectedRegions: protection), file: file, line: line)
        XCTAssertEqual(try pixels(image), try pixels(canonical),
            "The editor capture must refresh Fold from current redaction coverage", file: file, line: line)
        return image
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
