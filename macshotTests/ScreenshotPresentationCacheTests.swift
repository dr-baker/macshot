import AppKit
import XCTest

@MainActor
final class ScreenshotPresentationCacheTests: XCTestCase {
    func testExactNativePlanReusesEffectsBackgroundAndFinishedPixels() throws {
        let fixture = try fixture()
        let cache = ScreenshotPresentation.Cache()
        let presentation = ScreenshotPresentation(effects: ImageEffectsConfig(preset: .vivid),
            beautify: fixture.background, projection: fixture.projection)
        let first = try XCTUnwrap(cache.prepare(presentation, image: fixture.composite, document: fixture.document))
        XCTAssertTrue(first.isRenderCacheEnabled)
        XCTAssertNil(first.renderedCGImage)
        let output = try XCTUnwrap(first.renderCGImage())
        let rebuilt = ScreenshotPresentation(effects: ImageEffectsConfig(preset: .vivid),
            beautify: fixture.background,
            projection: try XCTUnwrap(StitchAccordionProjection(document: fixture.document)))
        let hit = try XCTUnwrap(cache.prepare(rebuilt, image: fixture.composite, document: fixture.document))
        XCTAssertTrue(first.pixels === hit.pixels)
        XCTAssertTrue(first.paperBackground?.pixels === hit.paperBackground?.pixels)
        XCTAssertTrue(output === hit.renderedCGImage)
        XCTAssertTrue(output === hit.renderCGImage())
        XCTAssertEqual(cache.retainedEntryCount, 1)
        XCTAssertLessThanOrEqual(cache.retainedByteCount, cache.maximumRetainedBytes)
    }

    func testOrdinaryEffectsAndBeautifyReuseFinishedPresentation() throws {
        let fixture = try fixture()
        let cache = ScreenshotPresentation.Cache()
        var config = fixture.background
        config.mode = .rounded
        let presentation = ScreenshotPresentation(effects: ImageEffectsConfig(preset: .vivid), beautify: config)
        let first = try XCTUnwrap(cache.prepare(presentation, image: fixture.composite))
        let hit = try XCTUnwrap(cache.prepare(presentation, image: fixture.composite))
        XCTAssertTrue(first.pixels === hit.pixels)
        XCTAssertTrue(first.renderCGImage() === hit.renderCGImage())
        let rendered = try XCTUnwrap(cache.render(presentation, image: fixture.composite))
        XCTAssertEqual(rendered.size, first.imageSize)
        XCTAssertTrue(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) === first.pixels)
    }

    func testDifferentSourcePixelsAndPointSizeCannotReuseFinishedOutput() throws {
        let fixture = try fixture()
        let cache = ScreenshotPresentation.Cache()
        let presentation = ScreenshotPresentation(projection: fixture.projection)
        let initial = try XCTUnwrap(cache.prepare(presentation, image: fixture.composite))
        let initialOutput = try XCTUnwrap(initial.renderCGImage())
        let replacement = ImageProbe.solidImage(width: 200, height: 160, color: NSColor.red.cgColor)
        let replaced = try XCTUnwrap(cache.prepare(presentation, image: replacement))
        XCTAssertFalse(initial.pixels === replaced.pixels)
        XCTAssertNil(replaced.renderedCGImage)
        XCTAssertFalse(initialOutput === replaced.renderCGImage())

        _ = cache.prepare(presentation, image: fixture.composite)
        let smallerPoints = NSImage(cgImage: initial.pixels, size: NSSize(width: 50, height: 40))
        let resized = try XCTUnwrap(cache.prepare(presentation, image: smallerPoints))
        XCTAssertEqual(resized.sourceSize, smallerPoints.size)
        XCTAssertNil(resized.renderedCGImage)
        XCTAssertEqual(cache.retainedEntryCount, 1)
    }

    func testEachEffectSettingInvalidatesTheFinishedPixels() throws {
        let fixture = try fixture()
        let variants = [ImageEffectsConfig(preset: .sepia), ImageEffectsConfig(brightness: 0.1),
            ImageEffectsConfig(contrast: 1.2), ImageEffectsConfig(saturation: 0.4),
            ImageEffectsConfig(sharpness: 0.8)]
        for effect in variants {
            let cache = ScreenshotPresentation.Cache()
            let first = try XCTUnwrap(cache.prepare(ScreenshotPresentation(projection: fixture.projection),
                image: fixture.composite))
            let output = try XCTUnwrap(first.renderCGImage())
            let changed = try XCTUnwrap(cache.prepare(ScreenshotPresentation(effects: effect,
                projection: fixture.projection), image: fixture.composite))
            XCTAssertFalse(first.pixels === changed.pixels)
            XCTAssertNil(changed.renderedCGImage)
            XCTAssertFalse(output === changed.renderCGImage())
        }
    }

    func testCameraAndPleatChangesReuseEffectedSheetAndSizeTheBackgroundAgain() throws {
        let fixture = try fixture()
        let effects = ImageEffectsConfig(preset: .vivid)
        for cameraOnly in [true, false] {
            let cache = ScreenshotPresentation.Cache()
            let first = try XCTUnwrap(cache.prepare(ScreenshotPresentation(effects: effects,
                beautify: fixture.background, projection: fixture.projection), image: fixture.composite))
            let firstOutput = try XCTUnwrap(first.renderCGImage())
            var document = fixture.document
            if cameraOnly { document.style.accordionYaw += 7 }
            else { document.style.accordionPleats += 1 }
            let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
            let changed = try XCTUnwrap(cache.prepare(ScreenshotPresentation(effects: effects,
                beautify: fixture.background, projection: projection), image: fixture.composite, document: document))
            XCTAssertTrue(first.pixels === changed.pixels)
            let oldDimensions = try XCTUnwrap(fixture.projection.outputPixelDimensions(pixelWidth: first.pixels.width,
                pixelHeight: first.pixels.height))
            let newDimensions = try XCTUnwrap(projection.outputPixelDimensions(pixelWidth: changed.pixels.width,
                pixelHeight: changed.pixels.height))
            let sameExtent = first.projectedSize == changed.projectedSize
                && oldDimensions.width == newDimensions.width && oldDimensions.height == newDimensions.height
            XCTAssertEqual(first.paperBackground?.pixels === changed.paperBackground?.pixels, sameExtent,
                           "Only unchanged output extents may reuse the prepared background")
            XCTAssertEqual(changed.paperBackground?.contentSize, changed.projectedSize)
            XCTAssertNil(changed.renderedCGImage)
            let output = try XCTUnwrap(changed.renderCGImage())
            XCTAssertFalse(firstOutput === output)
            XCTAssertNotEqual(pixelData(firstOutput), pixelData(output), "The new mesh must render anew")
        }
    }

    func testProjectedBackgroundChangesInvalidateTheNativeBackground() throws {
        let fixture = try fixture()
        var differentPixels = fixture.background
        differentPixels.customBackgroundImage = ImageProbe.solidImage(width: 16, height: 16,
            color: NSColor.red.cgColor)
        differentPixels.cachedBackgroundCGImage = nil
        differentPixels.prepareBackgroundCache()
        var differentBlur = fixture.background
        differentBlur.backgroundBlur = 3
        // Real settings replace this cache when blur changes. Keeping the same
        // immutable pixels here also proves blur is independently in the key.
        for background in [differentPixels, differentBlur] {
            let cache = ScreenshotPresentation.Cache()
            let first = try XCTUnwrap(cache.prepare(ScreenshotPresentation(beautify: fixture.background,
                projection: fixture.projection), image: fixture.composite))
            _ = first.renderCGImage()
            let changed = try XCTUnwrap(cache.prepare(ScreenshotPresentation(beautify: background,
                projection: fixture.projection), image: fixture.composite))
            XCTAssertFalse(first.paperBackground?.pixels === changed.paperBackground?.pixels)
            XCTAssertNil(changed.renderedCGImage)
        }
        let cache = ScreenshotPresentation.Cache()
        let gradient = BeautifyConfig(styleIndex: BeautifyRenderer.styles.count - 1)
        let first = try XCTUnwrap(cache.prepare(ScreenshotPresentation(beautify: gradient,
            projection: fixture.projection), image: fixture.composite))
        let changed = try XCTUnwrap(cache.prepare(ScreenshotPresentation(beautify: BeautifyConfig(styleIndex: 0),
            projection: fixture.projection), image: fixture.composite))
        XCTAssertFalse(first.paperBackground?.pixels === changed.paperBackground?.pixels)
    }

    func testChangedEnvelopeInvalidatesOutputWhileReusingCompactTexture() throws {
        let fixture = try fixture()
        let cache = ScreenshotPresentation.Cache()
        let first = try XCTUnwrap(cache.prepare(ScreenshotPresentation(projection: fixture.projection),
            image: fixture.composite))
        let output = try XCTUnwrap(first.renderCGImage())
        let expanded = try XCTUnwrap(fixture.projection.withOutputBounds(
            fixture.projection.outputBounds.insetBy(dx: -10, dy: -10)))
        let changed = try XCTUnwrap(cache.prepare(ScreenshotPresentation(projection: expanded),
            image: fixture.composite))
        XCTAssertTrue(first.pixels === changed.pixels, "A canvas extent does not change the safe compact texture")
        XCTAssertNil(changed.renderedCGImage, "Identical faces with a different canvas must miss the native output cache")
        let larger = try XCTUnwrap(changed.renderCGImage())
        XCTAssertEqual(larger.width, output.width + 20)
        XCTAssertEqual(larger.height, output.height + 20)
        XCTAssertEqual(changed.imageSize.width, first.imageSize.width + 10)
        XCTAssertEqual(changed.imageSize.height, first.imageSize.height + 10)
        let hit = try XCTUnwrap(cache.prepare(ScreenshotPresentation(projection: expanded), image: fixture.composite))
        XCTAssertTrue(larger === hit.renderedCGImage)
    }

    func testCameraEditsReuseBackgroundWhenTheOutputEnvelopeIsUnchanged() throws {
        let fixture = try fixture()
        var document = fixture.document
        document.style.accordionYaw += 7
        let rotated = try XCTUnwrap(StitchAccordionProjection(document: document))
        let envelope = fixture.projection.outputBounds.union(rotated.outputBounds).insetBy(dx: -2, dy: -2)
        let firstProjection = try XCTUnwrap(fixture.projection.withOutputBounds(envelope))
        let nextProjection = try XCTUnwrap(rotated.withOutputBounds(envelope))
        let cache = ScreenshotPresentation.Cache()
        let first = try XCTUnwrap(cache.prepare(ScreenshotPresentation(beautify: fixture.background,
            projection: firstProjection), image: fixture.composite))
        let old = try XCTUnwrap(first.renderCGImage())
        let next = try XCTUnwrap(cache.prepare(ScreenshotPresentation(beautify: fixture.background,
            projection: nextProjection), image: fixture.composite))
        XCTAssertTrue(first.pixels === next.pixels)
        XCTAssertTrue(first.paperBackground?.pixels === next.paperBackground?.pixels)
        XCTAssertNil(next.renderedCGImage)
        XCTAssertFalse(old === next.renderCGImage())
    }

    func testPaperIgnoresDecorationsThatAreNotPartOfItsPresentation() throws {
        let fixture = try fixture()
        let cache = ScreenshotPresentation.Cache()
        let first = try XCTUnwrap(cache.prepare(ScreenshotPresentation(beautify: fixture.background,
            projection: fixture.projection), image: fixture.composite))
        let output = try XCTUnwrap(first.renderCGImage())
        var decorations = fixture.background
        decorations.mode = .rounded
        decorations.styleIndex += 1 // A custom wallpaper does not use gradient styles.
        decorations.padding = 70
        decorations.cornerRadius = 24
        decorations.shadowRadius = 80
        decorations.bgRadius = 30
        decorations.isWindowSnap = true
        let hit = try XCTUnwrap(cache.prepare(ScreenshotPresentation(beautify: decorations,
            projection: fixture.projection), image: fixture.composite))
        XCTAssertTrue(output === hit.renderedCGImage)
        XCTAssertTrue(first.paperBackground?.pixels === hit.paperBackground?.pixels)
    }

    func testOrdinaryDecorationChangesInvalidateTheFinishedPresentation() throws {
        let fixture = try fixture()
        let original = fixture.background
        var variants: [BeautifyConfig] = []
        var changed = original; changed.mode = .rounded; variants.append(changed)
        changed = original; changed.styleIndex += 1; variants.append(changed)
        changed = original; changed.padding += 5; variants.append(changed)
        changed = original; changed.cornerRadius += 3; variants.append(changed)
        changed = original; changed.shadowRadius += 3; variants.append(changed)
        changed = original; changed.bgRadius += 3; variants.append(changed)
        changed = original; changed.isWindowSnap.toggle(); variants.append(changed)
        changed = original; changed.backgroundBlur += 3; variants.append(changed)
        for variant in variants {
            let cache = ScreenshotPresentation.Cache()
            let first = try XCTUnwrap(cache.prepare(ScreenshotPresentation(beautify: original), image: fixture.composite))
            let second = try XCTUnwrap(cache.prepare(ScreenshotPresentation(beautify: variant), image: fixture.composite))
            XCTAssertFalse(first.pixels === second.pixels)
        }
    }

    func testInvalidProjectionPlanAndInvalidSettingsCannotHitAPreviousEntry() throws {
        let fixture = try fixture()
        let cache = ScreenshotPresentation.Cache()
        let valid = ScreenshotPresentation(projection: fixture.projection)
        let first = try XCTUnwrap(cache.prepare(valid, image: fixture.composite))
        _ = first.renderCGImage()
        let editor = EditorView(frame: CGRect(origin: .zero, size: fixture.composite.size))
        var invalid = fixture.document
        invalid.style.accordionPleats = .nan
        editor.installStitchDocument(invalid)
        XCTAssertNil(cache.prepare(ScreenshotPresentation(view: editor), image: fixture.composite,
                                  document: invalid))
        XCTAssertEqual(cache.retainedEntryCount, 0)
        _ = cache.prepare(valid, image: fixture.composite)
        var invalidBackground = fixture.background
        invalidBackground.backgroundBlur = .nan
        XCTAssertNil(cache.prepare(ScreenshotPresentation(beautify: invalidBackground,
            projection: fixture.projection), image: fixture.composite))
        XCTAssertNil(cache.prepare(ScreenshotPresentation(effects: ImageEffectsConfig(brightness: .nan),
            projection: fixture.projection), image: fixture.composite))
        invalid.pieces = []
        XCTAssertNil(cache.prepare(valid, image: fixture.composite, document: invalid))
        editor.reset()
    }

    func testCachedOutputKeepsNativeScaleAlphaAndOnlyCompositedRedactions() throws {
        let fixture = try fixture()
        let cache = ScreenshotPresentation.Cache()
        let presentation = ScreenshotPresentation(projection: fixture.projection)
        let first = try XCTUnwrap(cache.prepare(presentation, image: fixture.composite))
        let output = try XCTUnwrap(first.renderCGImage())
        let hit = try XCTUnwrap(cache.prepare(presentation, image: fixture.composite))
        XCTAssertTrue(output === hit.renderedCGImage)
        let dimensions = try XCTUnwrap(fixture.projection.outputPixelDimensions(pixelWidth: 200, pixelHeight: 160))
        XCTAssertEqual(output.width, dimensions.width)
        XCTAssertEqual(output.height, dimensions.height)
        XCTAssertEqual(hit.imageSize, NSSize(width: fixture.projection.outputBounds.width / 2,
                                           height: fixture.projection.outputBounds.height / 2))
        XCTAssertEqual(CGFloat(output.width) / hit.imageSize.width, 2)
        XCTAssertEqual(CGFloat(output.height) / hit.imageSize.height, 2)
        let bitmap = NSBitmapImageRep(cgImage: output)
        let projected = try XCTUnwrap(fixture.projection.project(CGPoint(x: 100, y: 130)))
        let redaction = try XCTUnwrap(bitmap.colorAt(x: Int((projected.x - fixture.projection.outputBounds.minX).rounded()),
                                                    y: Int((projected.y - fixture.projection.outputBounds.minY).rounded())))
        XCTAssertLessThan(redaction.redComponent, 0.05)
        XCTAssertGreaterThan(redaction.alphaComponent, 0.9)
        var clear = 0
        for y in 0..<output.height {
            for x in 0..<output.width where bitmap.colorAt(x: x, y: y)!.alphaComponent < 0.1 { clear += 1 }
        }
        XCTAssertGreaterThan(clear, 20)
        let decorated = try XCTUnwrap(cache.prepare(ScreenshotPresentation(beautify: fixture.background,
            projection: fixture.projection), image: fixture.composite))
        let fullNative = try XCTUnwrap(decorated.renderCGImage())
        XCTAssertEqual(fullNative.width, dimensions.width + 48)
        XCTAssertEqual(fullNative.height, dimensions.height + 48)
        XCTAssertEqual(decorated.imageSize, NSSize(width: hit.imageSize.width + 24,
                                                 height: hit.imageSize.height + 24))
    }

    func testNativeCacheSamplesInsertedPaperFromTheSafeCompositeOnly() throws {
        let original = try XCTUnwrap(ImageProbe.solidImage(width: 160, height: 140,
            color: NSColor.green.cgColor).cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: original)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 40, to: 80))
        document.style.transition = .accordion
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document, progress: 0))
        let composite = ImageProbe.solidImage(width: 320, height: 200,
            color: CGColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1))
        composite.size = NSSize(width: 160, height: 100)
        let cache = ScreenshotPresentation.Cache()
        let presentation = ScreenshotPresentation(projection: projection)
        let prepared = try XCTUnwrap(cache.prepare(presentation, image: composite))
        let output = try XCTUnwrap(prepared.renderCGImage())
        let paper = try XCTUnwrap(projection.faces.first { $0.paperSample != nil && $0.isFrontFacing })
        let x = (paper.a.projected.x + paper.b.projected.x + paper.c.projected.x) / 3
        let y = (paper.a.projected.y + paper.b.projected.y + paper.c.projected.y) / 3
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: output).colorAt(
            x: Int(((x - projection.outputBounds.minX) * 2).rounded()),
            y: Int(((y - projection.outputBounds.minY) * 2).rounded())))
        XCTAssertLessThan(color.greenComponent, 0.2, "The raw green capture is unavailable to paper sampling")
        XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.01)
        XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.01)
        XCTAssertGreaterThan(color.alphaComponent, 0.9)
        let hit = try XCTUnwrap(cache.prepare(presentation, image: composite))
        XCTAssertTrue(output === hit.renderedCGImage)
    }

    func testRetentionIncludesCompositeWallpaperPreparedBackgroundAndFinalReservation() throws {
        let fixture = try fixture()
        let presentation = ScreenshotPresentation(beautify: fixture.background, projection: fixture.projection)
        let cache = ScreenshotPresentation.Cache()
        let first = try XCTUnwrap(cache.prepare(presentation, image: fixture.composite))
        let background = try XCTUnwrap(first.paperBackground?.pixels)
        let source = try XCTUnwrap(fixture.composite.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let wallpaper = try XCTUnwrap(fixture.background.cachedBackgroundCGImage)
        let expected = source.bytesPerRow * source.height + wallpaper.bytesPerRow * wallpaper.height
            + background.bytesPerRow * background.height + background.width * background.height * 4
        XCTAssertEqual(cache.retainedByteCount, expected)
        let exact = ScreenshotPresentation.Cache(maximumRetainedBytes: expected)
        XCTAssertTrue(try XCTUnwrap(exact.prepare(presentation, image: fixture.composite)).isRenderCacheEnabled)
        let tooSmall = ScreenshotPresentation.Cache(maximumRetainedBytes: expected - 1)
        let uncached = try XCTUnwrap(tooSmall.prepare(presentation, image: fixture.composite))
        XCTAssertFalse(uncached.isRenderCacheEnabled)
        XCTAssertNotNil(uncached.renderCGImage(), "Oversized captures still render through the normal output path")
        XCTAssertEqual(tooSmall.retainedEntryCount, 0)
        XCTAssertEqual(tooSmall.retainedByteCount, 0)
        cache.clear()
        XCTAssertEqual(cache.retainedEntryCount, 0)
        XCTAssertEqual(cache.retainedByteCount, 0)
    }

    func testRetentionReservesInsertedPaperAtItsNativeOutputSize() throws {
        let fixture = try fixture()
        let projection = try XCTUnwrap(StitchAccordionProjection(document: fixture.document, progress: 0))
        let presentation = ScreenshotPresentation(projection: projection)
        let pixels = try XCTUnwrap(fixture.composite.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let dimensions = try XCTUnwrap(projection.outputPixelDimensions(pixelWidth: pixels.width,
            pixelHeight: pixels.height))
        XCTAssertEqual(dimensions.width, 200)
        XCTAssertEqual(dimensions.height, 200)
        let required = pixels.bytesPerRow * pixels.height + dimensions.width * dimensions.height * 4
        let exact = ScreenshotPresentation.Cache(maximumRetainedBytes: required)
        let prepared = try XCTUnwrap(exact.prepare(presentation, image: fixture.composite))
        XCTAssertEqual(exact.retainedByteCount, required)
        XCTAssertTrue(prepared.isRenderCacheEnabled)
        let output = try XCTUnwrap(prepared.renderCGImage())
        XCTAssertTrue(output === prepared.renderedCGImage)
        XCTAssertEqual(prepared.imageSize, NSSize(width: 100, height: 100))
        let tooSmall = ScreenshotPresentation.Cache(maximumRetainedBytes: required - 1)
        XCTAssertFalse(try XCTUnwrap(tooSmall.prepare(presentation, image: fixture.composite)).isRenderCacheEnabled)
        XCTAssertEqual(tooSmall.retainedByteCount, 0)
    }

    func testOneEntryReplacesHistoryInsteadOfKeepingEveryCameraSetting() throws {
        let fixture = try fixture()
        let cache = ScreenshotPresentation.Cache()
        let first = try XCTUnwrap(cache.prepare(ScreenshotPresentation(projection: fixture.projection),
            image: fixture.composite))
        let old = try XCTUnwrap(first.renderCGImage())
        for yaw in [-20, -5, 20] {
            var document = fixture.document
            document.style.accordionYaw = CGFloat(yaw)
            _ = cache.prepare(ScreenshotPresentation(projection: try XCTUnwrap(StitchAccordionProjection(document: document))),
                image: fixture.composite)
            XCTAssertEqual(cache.retainedEntryCount, 1)
        }
        let returned = try XCTUnwrap(cache.prepare(ScreenshotPresentation(projection: fixture.projection),
            image: fixture.composite))
        XCTAssertNil(returned.renderedCGImage)
        XCTAssertFalse(old === returned.renderCGImage())
    }

    func testConcurrentNativeRendersShareOneFinishedImage() async throws {
        let fixture = try fixture()
        let prepared = try XCTUnwrap(ScreenshotPresentation.Cache().prepare(
            ScreenshotPresentation(beautify: fixture.background, projection: fixture.projection), image: fixture.composite))
        let results = CacheImages()
        let completed = expectation(description: "Concurrent native renders finished")
        DispatchQueue.global(qos: .userInitiated).async {
            DispatchQueue.concurrentPerform(iterations: 8) { _ in results.append(prepared.renderCGImage()) }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        let output = try XCTUnwrap(prepared.renderedCGImage)
        XCTAssertEqual(results.images.count, 8)
        XCTAssertTrue(results.images.allSatisfy { $0 === output })
    }

    func testWarmRenderDoesNotBlockMainLookupOrMainRender() async throws {
        let pixels = try XCTUnwrap(ImageProbe.solidImage(width: 4, height: 4)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let result = ScreenshotPresentation.RenderedPixels(maximumRetainedBytes: 1024)
        let started = expectation(description: "Worker entered render")
        let finished = expectation(description: "Worker published render")
        let gate = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = result.render {
                started.fulfill()
                gate.wait()
                return pixels
            }
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)
        defer { gate.signal() }
        XCTAssertNil(result.image, "Reading a result must return while the worker is gated")
        XCTAssertTrue(result.render { pixels } === pixels,
                      "Main-thread output can render immediately instead of waiting for an idle warm")
        XCTAssertNil(result.image, "Main-thread fallback does not overwrite the worker's owned result")
        gate.signal()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertTrue(result.image === pixels)
    }

    func testFailedOrOversizedRenderedPixelsAreNotRetained() throws {
        let pixels = try XCTUnwrap(ImageProbe.solidImage(width: 4, height: 4)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let memo = ScreenshotPresentation.RenderedPixels(maximumRetainedBytes: 1)
        XCTAssertNil(memo.render { nil })
        XCTAssertTrue(memo.render { pixels } === pixels)
        XCTAssertNil(memo.image)
        let retry = ScreenshotPresentation.RenderedPixels(maximumRetainedBytes: 1024)
        XCTAssertNil(retry.render { nil })
        XCTAssertTrue(retry.render { pixels } === pixels)
        XCTAssertTrue(retry.image === pixels)
    }

    func testNativePresentationReuseBenchmark() throws {
        guard ProcessInfo.processInfo.environment["MACSHOT_PRESENTATION_CACHE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set MACSHOT_PRESENTATION_CACHE_BENCHMARK=1 to measure native presentation reuse")
        }
        let width = 3840, height = 2160
        let source = try XCTUnwrap(ImageProbe.solidImage(width: width, height: height + 140)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: source)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 900, to: 1040))
        document.style.transition = .accordion
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        let image = ImageProbe.quadrantImage(width: width, height: height)
        image.size = NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2)
        var background = BeautifyConfig(customBackgroundImage: ImageProbe.solidImage(width: 16, height: 16))
        background.prepareBackgroundCache()
        let presentation = ScreenshotPresentation(beautify: background, projection: projection)
        let cache = ScreenshotPresentation.Cache()
        let prepared = try XCTUnwrap(cache.prepare(presentation, image: image, document: document))
        XCTAssertTrue(prepared.isRenderCacheEnabled)
        let warmed = try XCTUnwrap(prepared.renderCGImage())
        let expected = pixelData(warmed)
        var coldMilliseconds: [Double] = [], warmMilliseconds: [Double] = []
        for _ in 0..<5 {
            try autoreleasepool {
                let begin = DispatchTime.now().uptimeNanoseconds
                let rendered = try XCTUnwrap(presentation.render(image))
                coldMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000)
                let pixels = try XCTUnwrap(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil))
                XCTAssertEqual(pixelData(pixels), expected)
            }
            try autoreleasepool {
                let begin = DispatchTime.now().uptimeNanoseconds
                let rendered = try XCTUnwrap(cache.render(presentation, image: image, document: document))
                warmMilliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000)
                XCTAssertTrue(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) === warmed)
            }
        }
        print("Native presentation reuse, \(width)x\(height), baseline ms=\(coldMilliseconds), warmed ms=\(warmMilliseconds)")
    }

    private func fixture() throws -> (document: StitchDocument, projection: StitchAccordionProjection,
                                     composite: NSImage, background: BeautifyConfig) {
        let original = try XCTUnwrap(ImageProbe.solidImage(width: 200, height: 200, color: NSColor.white.cgColor)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: original)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 80, to: 120))
        document.style.transition = .accordion
        let composite = ImageProbe.makeImage(width: 200, height: 160) { context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 90, y: 20, width: 20, height: 20))
        }
        composite.size = NSSize(width: 100, height: 80)
        var background = BeautifyConfig(mode: .window, customBackgroundImage: ImageProbe.solidImage(width: 16, height: 16,
            color: CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1)))
        background.prepareBackgroundCache()
        return (document, try XCTUnwrap(StitchAccordionProjection(document: document)), composite, background)
    }

    private func pixelData(_ pixels: CGImage) -> Data? { pixels.dataProvider?.data as Data? }
}

private nonisolated final class CacheImages: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CGImage?] = []
    var images: [CGImage?] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ image: CGImage?) { lock.lock(); values.append(image); lock.unlock() }
}
