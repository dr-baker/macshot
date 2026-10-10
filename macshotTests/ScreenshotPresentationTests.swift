import AppKit
import XCTest

@MainActor
final class ScreenshotPresentationTests: XCTestCase {
    func testProjectedPaperRevealsWallpaperAndNeverAddsWindowChrome() throws {
        let paper = trapezoid()
        let config = wallpaperConfig(padding: 20)
        let result = try XCTUnwrap(BeautifyRenderer.renderPaper(image: paper, config: config))
        XCTAssertEqual(result.size, NSSize(width: 240, height: 200), "Paper never gains a synthetic title bar")
        for point in [CGPoint(x: 2, y: 100), CGPoint(x: 23, y: 23)] {
            let color = try XCTUnwrap(ImageProbe.pixelColor(result, x: Int(point.x), y: Int(point.y)))
            XCTAssertEqual(color.blueComponent, 0.8, accuracy: 0.02)
            XCTAssertEqual(color.redComponent, 0.1, accuracy: 0.02)
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
        }
        let content = try XCTUnwrap(ImageProbe.pixelColor(result, x: 120, y: 100))
        XCTAssertGreaterThan(content.greenComponent, 0.7)
    }

    func testPaperShadowFollowsAlphaInsteadOfTheSourceRectangle() throws {
        let paper = ImageProbe.makeImage(width: 200, height: 160) { context in
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 60, y: 40, width: 80, height: 80))
        }
        var config = wallpaperConfig(padding: 20)
        config.customBackgroundImage = ImageProbe.solidImage(width: 20, height: 20, color: NSColor.white.cgColor)
        config.cachedBackgroundCGImage = nil
        let plain = try XCTUnwrap(BeautifyRenderer.renderPaper(image: paper, config: config))
        config.shadowRadius = 8
        let shadowed = try XCTUnwrap(BeautifyRenderer.renderPaper(image: paper, config: config))
        let nearPaper = try XCTUnwrap(ImageProbe.pixelColor(shadowed, x: 77, y: 100))
        let plainNear = try XCTUnwrap(ImageProbe.pixelColor(plain, x: 77, y: 100))
        XCTAssertLessThan(nearPaper.redComponent, plainNear.redComponent - 0.03)
        let farInsideSource = try XCTUnwrap(ImageProbe.pixelColor(shadowed, x: 24, y: 24))
        XCTAssertEqual(farInsideSource.redComponent, 1, accuracy: 0.01,
                       "Clear source corners must show the background without a rectangle caster")
    }

    func testGradientAndZeroPaddingUseTheExistingFrameDimensions() throws {
        for padding: CGFloat in [0, 12] {
            let config = BeautifyConfig(mode: .window, styleIndex: BeautifyRenderer.styles.count - 1,
                                       padding: padding, cornerRadius: 0, shadowRadius: 0, bgRadius: 0)
            let result = try XCTUnwrap(BeautifyRenderer.renderPaper(image: trapezoid(), config: config))
            XCTAssertEqual(result.size, NSSize(width: 200 + padding * 2, height: 160 + padding * 2))
            let clearPaperCorner = try XCTUnwrap(ImageProbe.pixelColor(result,
                x: Int(padding) + 2, y: Int(padding) + 2))
            XCTAssertEqual(clearPaperCorner.alphaComponent, 1, accuracy: 0.001)
            XCTAssertLessThan(clearPaperCorner.greenComponent, 0.2)
        }
    }

    func testPaperOutputPreservesNativePixelScale() throws {
        let source = ImageProbe.solidImage(width: 120, height: 80, color: NSColor.white.cgColor)
        source.size = NSSize(width: 60, height: 40)
        let rendered = try XCTUnwrap(BeautifyRenderer.renderPaper(image: source, config: wallpaperConfig(padding: 10)))
        let pixels = try XCTUnwrap(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(rendered.size, NSSize(width: 80, height: 60))
        XCTAssertEqual(pixels.width, 160)
        XCTAssertEqual(pixels.height, 120)
        let background = try XCTUnwrap(ImageProbe.pixelColor(rendered, x: 4, y: 60))
        XCTAssertEqual(background.blueComponent, 0.8, accuracy: 0.02)
    }

    func testDisabledBeautifyKeepsProjectedAlphaAndCompositedRedactions() throws {
        let document = try accordionDocument()
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        XCTAssertTrue(projection.hasProjectedOutput)
        let flatComposite = ImageProbe.makeImage(width: 200, height: 160) { context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
            // The document's source is white. This black mark exists only in the composited input.
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 90, y: 20, width: 20, height: 20))
        }
        let output = try XCTUnwrap(ScreenshotPresentation(projection: projection).render(flatComposite))
        XCTAssertEqual(output.size, projection.outputBounds.size)
        let pixels = try XCTUnwrap(output.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: pixels)
        var transparent = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where bitmap.colorAt(x: x, y: y)!.alphaComponent < 0.1 { transparent += 1 }
        }
        XCTAssertGreaterThan(transparent, 20, "Perspective cutouts remain transparent when framing is disabled")
        let projectedMark = try XCTUnwrap(projection.project(CGPoint(x: 100, y: 130)))
        let mark = try XCTUnwrap(bitmap.colorAt(x: Int((projectedMark.x - projection.outputBounds.minX).rounded()),
                                              y: Int((projectedMark.y - projection.outputBounds.minY).rounded())))
        XCTAssertLessThan(mark.redComponent, 0.05, "Project the redacted composite, never the document source")
        XCTAssertGreaterThan(mark.alphaComponent, 0.9)
    }

    func testPreparedBackgroundRendersOffMainAndKeepsItsWallpaperSnapshot() async throws {
        let source = ImageProbe.solidImage(width: 200, height: 160, color: NSColor.white.cgColor)
        let projection = try XCTUnwrap(StitchAccordionProjection(document: accordionDocument()))
        var config = wallpaperConfig(padding: 12)
        let wallpaper = try XCTUnwrap(config.customBackgroundImage)
        let presentation = ScreenshotPresentation(beautify: config, projection: projection)
        let prepared = try XCTUnwrap(presentation.prepare(source))
        wallpaper.size = NSSize(width: 1, height: 1000)
        config.customBackgroundImage = ImageProbe.solidImage(width: 20, height: 20, color: NSColor.red.cgColor)
        let pixels: CGImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: prepared.renderCGImage())
            }
        }
        let result = NSImage(cgImage: try XCTUnwrap(pixels), size: prepared.imageSize)
        XCTAssertEqual(result.size, NSSize(width: projection.outputBounds.width + 24,
                                          height: projection.outputBounds.height + 24))
        let margin = try XCTUnwrap(ImageProbe.pixelColor(result, x: 2, y: 90))
        XCTAssertEqual(margin.blueComponent, 0.8, accuracy: 0.02)
        XCTAssertEqual(margin.redComponent, 0.1, accuracy: 0.02)
    }

    func testPresentationSnapshotsSettingsBeforeOverlayReset() throws {
        let document = try accordionDocument()
        let view = EditorView(frame: CGRect(x: 0, y: 0, width: 200, height: 160))
        view.screenshotImage = ImageProbe.solidImage(width: 200, height: 160, color: NSColor.white.cgColor)
        view.applySelection(CGRect(x: 0, y: 0, width: 200, height: 160))
        view.installStitchDocument(document)
        view.beautifyEnabled = true
        view.beautifyPadding = 9
        view.beautifyMode = .window
        view.beautifyCornerRadius = 0
        view.beautifyShadowRadius = 0
        let presentation = ScreenshotPresentation(view: view)
        XCTAssertTrue(presentation.hasProjectedOutput)
        let flat = try XCTUnwrap(view.captureSelectedRegion())
        view.reset()
        let result = try XCTUnwrap(presentation.render(flat))
        let projection = try XCTUnwrap(presentation.projection)
        XCTAssertEqual(result.size, NSSize(width: projection.outputBounds.width + 24,
                                          height: projection.outputBounds.height + 24))
    }

    func testOrdinaryWindowRoundedAndSnappedScreenshotsKeepExistingPresentation() throws {
        let source = ImageProbe.solidImage(width: 120, height: 80)
        for mode in [BeautifyMode.window, .rounded] {
            for snapped in [false, true] {
                let config = BeautifyConfig(mode: mode, styleIndex: BeautifyRenderer.styles.count - 1,
                    padding: 12, shadowRadius: 0, isWindowSnap: snapped)
                let existing = BeautifyRenderer.render(image: source, config: config)
                let result = try XCTUnwrap(ScreenshotPresentation(beautify: config).render(source))
                XCTAssertEqual(result.size, existing.size)
                XCTAssertEqual(FieldDescriber.describe(result), FieldDescriber.describe(existing))
            }
        }
        let identity = try XCTUnwrap(ScreenshotPresentation().render(source))
        XCTAssertTrue(identity === source)
    }

    func testPaperIgnoresDecorationAndRejectsInvalidBackgroundBlur() throws {
        let source = ImageProbe.solidImage(width: 200, height: 160)
        let projection = try XCTUnwrap(StitchAccordionProjection(document: accordionDocument()))
        for padding in [CGFloat.nan, .infinity, -1, 100_000] {
            let config = BeautifyConfig(padding: padding)
            XCTAssertNotNil(ScreenshotPresentation(beautify: config, projection: projection).render(source))
        }
        for blur in [CGFloat.nan, .infinity, -1, 51] {
            let config = BeautifyConfig(backgroundBlur: blur)
            XCTAssertNil(ScreenshotPresentation(beautify: config, projection: projection).render(source))
        }
    }

    func testAnimationTextureIsFlatClippedAndBoundedWithoutWallpaper() throws {
        let source = ImageProbe.solidImage(width: 3200, height: 2560, color: NSColor.white.cgColor)
        source.size = NSSize(width: 200, height: 160)
        let projection = try XCTUnwrap(StitchAccordionProjection(document: accordionDocument()))
        var config = wallpaperConfig(padding: 12)
        config.cornerRadius = 12
        let prepared = try XCTUnwrap(ScreenshotPresentation(beautify: config, projection: projection).prepare(source))
        let texture = try XCTUnwrap(prepared.animationTexture(maxDimension: 2000))
        XCTAssertEqual(texture.width, 1600)
        XCTAssertEqual(texture.height, 1280)
        let bitmap = NSBitmapImageRep(cgImage: texture)
        XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 1, accuracy: 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 800, y: 100)).redComponent, 0.99,
                             "Animation textures retain the flat composite without a background or folded shading")
        for limit in [CGFloat.nan, .infinity, 0, -1] { XCTAssertNil(prepared.animationTexture(maxDimension: limit)) }
    }

    func testUnfoldedPresentationRestoresRemovedPaperAtNativeDensity() throws {
        let document = try accordionDocument()
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document, progress: 0))
        let source = ImageProbe.solidImage(width: 400, height: 320, color: NSColor.white.cgColor)
        source.size = NSSize(width: 200, height: 160)
        let prepared = try XCTUnwrap(ScreenshotPresentation(projection: projection).prepare(source))
        let output = try XCTUnwrap(prepared.renderCGImage())
        XCTAssertTrue(projection.hasProjectedOutput, "Unfolded omitted bands still need their paper material")
        XCTAssertEqual(prepared.sourceSize, NSSize(width: 200, height: 160))
        XCTAssertEqual(prepared.projectedSize, NSSize(width: 200, height: 180))
        XCTAssertEqual(prepared.imageSize, prepared.projectedSize)
        XCTAssertEqual(output.width, 400)
        XCTAssertEqual(output.height, 360)
        XCTAssertEqual(CGFloat(output.width) / prepared.imageSize.width, 2)
        XCTAssertEqual(CGFloat(output.height) / prepared.imageSize.height, 2)
    }

    func testAnimationBackgroundUsesFrozenChoiceAtTheRequestedEnvelope() throws {
        let source = ImageProbe.solidImage(width: 200, height: 160)
        let projection = try XCTUnwrap(StitchAccordionProjection(document: accordionDocument()))
        var config = wallpaperConfig(padding: 12)
        let original = try XCTUnwrap(config.customBackgroundImage)
        let prepared = try XCTUnwrap(ScreenshotPresentation(beautify: config, projection: projection).prepare(source))
        original.size = NSSize(width: 1, height: 1000)
        config.customBackgroundImage = ImageProbe.solidImage(width: 40, height: 40, color: NSColor.red.cgColor)
        let envelope = NSSize(width: 300, height: 220)
        let background = try XCTUnwrap(prepared.animationBackground(contentSize: envelope,
            pixelWidth: 600, pixelHeight: 440))
        XCTAssertEqual(background.contentSize, envelope)
        XCTAssertEqual(background.imageSize, NSSize(width: 324, height: 244))
        XCTAssertEqual(background.pixels.width, 648)
        XCTAssertEqual(background.pixels.height, 488)
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: background.pixels).colorAt(x: 2, y: 90))
        XCTAssertEqual(color.blueComponent, 0.8, accuracy: 0.02)
        XCTAssertEqual(color.redComponent, 0.1, accuracy: 0.02)
    }

    private func wallpaperConfig(padding: CGFloat) -> BeautifyConfig {
        BeautifyConfig(mode: .window, padding: padding, cornerRadius: 0, shadowRadius: 0, bgRadius: 0,
            customBackgroundImage: ImageProbe.solidImage(width: 40, height: 40,
                color: CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1)))
    }

    private func trapezoid() -> NSImage {
        ImageProbe.makeImage(width: 200, height: 160) { context in
            context.move(to: CGPoint(x: 0, y: 0))
            context.addLine(to: CGPoint(x: 200, y: 0))
            context.addLine(to: CGPoint(x: 160, y: 160))
            context.addLine(to: CGPoint(x: 40, y: 160))
            context.closePath()
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.8, blue: 0.2, alpha: 1))
            context.fillPath()
        }
    }

    private func accordionDocument() throws -> StitchDocument {
        let source = try XCTUnwrap(ImageProbe.solidImage(width: 200, height: 180,
            color: NSColor.white.cgColor).cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: source)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 60, to: 80))
        document.style.transition = .accordion
        return document
    }
}
