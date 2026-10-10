import AppKit
import XCTest

@MainActor
final class StitchPaperBackgroundTests: XCTestCase {
    func testProjectedOverlayUsesChosenBackgroundWithBeautifyOff() throws {
        let view = EditorView(frame: CGRect(x: 0, y: 0, width: 200, height: 160))
        let composite = ImageProbe.makeImage(width: 200, height: 160) { context in
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 90, y: 20, width: 20, height: 20))
        }
        view.screenshotImage = composite
        view.applySelection(view.bounds)
        let document = try accordionDocument()
        view.installStitchDocument(document)
        view.beautifyEnabled = false
        view.beautifyMode = .window
        view.beautifyPadding = 96
        view.beautifyCornerRadius = 30
        view.beautifyShadowRadius = 100
        view.beautifyStyleIndex = -1
        view.beautifyBackgroundBlur = 0
        view.customBeautifyBackground = wallpaper()

        let presentation = ScreenshotPresentation(view: view)
        XCTAssertFalse(view.beautifyEnabled, "Paper presentation must not turn the frame feature on")
        view.reset()
        let result = try XCTUnwrap(presentation.render(composite))
        let projection = try XCTUnwrap(presentation.projection)
        XCTAssertEqual(result.size, NSSize(width: projection.outputBounds.width + 24,
                                          height: projection.outputBounds.height + 24))
        let margin = try XCTUnwrap(ImageProbe.pixelColor(result, x: 2, y: 90))
        XCTAssertEqual(margin.blueComponent, 0.8, accuracy: 0.02)
        XCTAssertEqual(margin.redComponent, 0.1, accuracy: 0.02)

        let redaction = try XCTUnwrap(projection.project(CGPoint(x: 100, y: 130)))
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(result.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let mark = try XCTUnwrap(bitmap.colorAt(x: Int((redaction.x - projection.outputBounds.minX + 12).rounded()),
            y: Int((redaction.y - projection.outputBounds.minY + 12).rounded())))
        XCTAssertLessThan(mark.redComponent, 0.05, "Only the fully composited redaction may be projected")
        XCTAssertEqual(mark.alphaComponent, 1, accuracy: 0.01)
    }

    func testFrameSettingsCannotChangePaperGeometryOrDecoration() throws {
        let source = ImageProbe.quadrantImage(width: 200, height: 160)
        let projection = try XCTUnwrap(StitchAccordionProjection(document: accordionDocument()))
        let baseline = try XCTUnwrap(ScreenshotPresentation(beautify: wallpaperConfig(), projection: projection).render(source))
        let expectedPixels = try rgbaPixels(baseline)
        for value in [CGFloat(0), 96, .nan, .infinity, -1, 100_000] {
            var config = wallpaperConfig()
            config.mode = .window
            config.isWindowSnap = true
            config.padding = value
            config.cornerRadius = value
            config.shadowRadius = value
            config.bgRadius = value
            let output = try XCTUnwrap(ScreenshotPresentation(beautify: config, projection: projection).render(source))
            XCTAssertEqual(output.size, baseline.size)
            XCTAssertEqual(try rgbaPixels(output), expectedPixels,
                "Window chrome, border rounding, frame spacing, and user shadows must not decorate folded paper")
        }
    }

    func testAnimationTextureKeepsTheCompleteSheetCorners() throws {
        let source = ImageProbe.solidImage(width: 200, height: 160, color: NSColor.white.cgColor)
        var config = wallpaperConfig()
        config.cornerRadius = 30
        let projection = try XCTUnwrap(StitchAccordionProjection(document: accordionDocument()))
        let prepared = try XCTUnwrap(ScreenshotPresentation(beautify: config, projection: projection).prepare(source))
        let texture = try XCTUnwrap(prepared.animationTexture(maxDimension: 1600))
        let bitmap = NSBitmapImageRep(cgImage: texture)
        for point in [(0, 0), (199, 0), (0, 159), (199, 159)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1))
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
            XCTAssertEqual(color.redComponent, 1, accuracy: 0.001)
        }
    }

    func testBackgroundChoicesAndBlurSurviveFrameStripping() throws {
        let linearIndex = BeautifyRenderer.styles.count - 1
        let gradient = BeautifyConfig(styleIndex: linearIndex, padding: 96, cornerRadius: 30, shadowRadius: 100)
        let gradientBackground = try XCTUnwrap(BeautifyRenderer.prepareStitchPaperBackground(
            imageSize: NSSize(width: 200, height: 160), pixelWidth: 200, pixelHeight: 160, config: gradient))
        let gradientColor = try color(gradientBackground.pixels, x: 2, y: 2)
        XCTAssertLessThan(gradientColor.greenComponent, 0.2)
        XCTAssertEqual(gradientColor.alphaComponent, 1, accuracy: 0.001)

        if #available(macOS 15.0, *), let meshIndex = BeautifyRenderer.styles.firstIndex(where: { $0.meshDef != nil }) {
            let mesh = try XCTUnwrap(BeautifyRenderer.prepareStitchPaperBackground(
                imageSize: NSSize(width: 200, height: 160), pixelWidth: 200, pixelHeight: 160,
                config: BeautifyConfig(styleIndex: meshIndex)))
            XCTAssertNotEqual(try rgbaPixels(mesh.pixels), try rgbaPixels(gradientBackground.pixels))
        }

        let checker = ImageProbe.makeImage(width: 100, height: 100) { context in
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        }
        let sharp = try XCTUnwrap(BeautifyRenderer.prepareStitchPaperBackground(
            imageSize: NSSize(width: 200, height: 160), pixelWidth: 200, pixelHeight: 160,
            config: BeautifyConfig(customBackgroundImage: checker)))
        let blurred = try XCTUnwrap(BeautifyRenderer.prepareStitchPaperBackground(
            imageSize: NSSize(width: 200, height: 160), pixelWidth: 200, pixelHeight: 160,
            config: BeautifyConfig(customBackgroundImage: checker, backgroundBlur: 12)))
        let sharpEdge = try color(sharp.pixels, x: 106, y: 92)
        let blurredEdge = try color(blurred.pixels, x: 106, y: 92)
        XCTAssertGreaterThan(sharpEdge.redComponent, 0.9)
        XCTAssertLessThan(blurredEdge.redComponent, sharpEdge.redComponent - 0.1)
        XCTAssertGreaterThan(blurredEdge.redComponent, 0.5)
    }

    func testEffectsApplyToThePaperAndKeepBackgroundColor() throws {
        let source = ImageProbe.solidImage(width: 200, height: 160, color: NSColor.red.cgColor)
        let projection = try XCTUnwrap(StitchAccordionProjection(document: accordionDocument()))
        let presentation = ScreenshotPresentation(effects: ImageEffectsConfig(preset: .mono),
            beautify: wallpaperConfig(), projection: projection)
        let prepared = try XCTUnwrap(presentation.prepare(source))
        let paperColor = try color(prepared.pixels, x: 100, y: 80)
        XCTAssertEqual(paperColor.redComponent, paperColor.greenComponent, accuracy: 0.02)
        XCTAssertEqual(paperColor.greenComponent, paperColor.blueComponent, accuracy: 0.02)
        let background = try XCTUnwrap(prepared.paperBackground)
        let backgroundColor = try color(background.pixels, x: 2, y: 90)
        XCTAssertEqual(backgroundColor.blueComponent, 0.8, accuracy: 0.02)
        XCTAssertEqual(backgroundColor.redComponent, 0.1, accuracy: 0.02)
    }

    func testPaperBackgroundPreservesRetinaScaleAndRejectsInvalidBackgrounds() throws {
        let source = ImageProbe.solidImage(width: 200, height: 160, color: NSColor.white.cgColor)
        source.size = NSSize(width: 100, height: 80)
        let projection = try XCTUnwrap(StitchAccordionProjection(document: accordionDocument()))
        let output = try XCTUnwrap(ScreenshotPresentation(beautify: wallpaperConfig(), projection: projection).render(source))
        let pixels = try XCTUnwrap(output.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(output.size, NSSize(width: projection.outputBounds.width / 2 + 24,
                                          height: projection.outputBounds.height / 2 + 24))
        XCTAssertEqual(CGFloat(pixels.width) / output.size.width, 2)
        XCTAssertEqual(CGFloat(pixels.height) / output.size.height, 2)
        for invalid in [CGFloat.nan, .infinity, -1, 51] {
            var config = wallpaperConfig()
            config.backgroundBlur = invalid
            XCTAssertNil(ScreenshotPresentation(beautify: config, projection: projection).render(source))
        }
    }

    func testBackgroundOnlyGalleryContainsBlurWithoutFramePresets() throws {
        let picker = BeautifyBackgroundPickerView(styleIndex: -1, wallpaperID: nil,
            padding: 96, radius: 30, shadow: 100, backgroundOnly: true, backgroundBlur: 18, wallpapers: [])
        let labels = picker.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        XCTAssertTrue(labels.contains(L("Background blur")))
        XCTAssertFalse(labels.contains(L("Frame")))
        let segments = picker.subviews.compactMap { $0 as? NSSegmentedControl }
        XCTAssertFalse(segments.contains { $0.label(forSegment: 0) == L("Compact") })
        let slider = try XCTUnwrap(picker.subviews.compactMap { $0 as? NSSlider }.first)
        XCTAssertTrue(slider.isEnabled)
        XCTAssertEqual(slider.doubleValue, 18)
        var changes: [CGFloat] = []
        picker.onChangeBackgroundBlur = { changes.append($0) }
        slider.doubleValue = 24
        _ = NSApplication.shared.sendAction(try XCTUnwrap(slider.action), to: slider.target, from: slider)
        XCTAssertEqual(changes, [24])

        let gradientPicker = BeautifyBackgroundPickerView(styleIndex: 0, wallpaperID: nil,
            padding: 12, radius: 12, shadow: 12, backgroundOnly: true, wallpapers: [])
        XCTAssertFalse(try XCTUnwrap(gradientPicker.subviews.compactMap { $0 as? NSSlider }.first).isEnabled)
        let ordinary = BeautifyBackgroundPickerView(styleIndex: 0, wallpaperID: nil,
            padding: 12, radius: 12, shadow: 12, wallpapers: [])
        XCTAssertTrue(ordinary.subviews.compactMap { $0 as? NSSegmentedControl }.contains {
            $0.label(forSegment: 0) == L("Compact")
        })
        XCTAssertFalse(ordinary.subviews.contains { $0 is NSSlider })
    }

    private func wallpaper() -> NSImage {
        ImageProbe.solidImage(width: 40, height: 40,
            color: CGColor(srgbRed: 0.1, green: 0.3, blue: 0.8, alpha: 1))
    }

    private func wallpaperConfig() -> BeautifyConfig {
        BeautifyConfig(mode: .window, padding: 96, cornerRadius: 30, shadowRadius: 100,
            bgRadius: 30, customBackgroundImage: wallpaper())
    }

    private func accordionDocument() throws -> StitchDocument {
        let source = try XCTUnwrap(ImageProbe.solidImage(width: 200, height: 180,
            color: NSColor.white.cgColor).cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: source)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 60, to: 80))
        document.style.transition = .accordion
        return document
    }

    private func color(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y))
    }

    private func rgbaPixels(_ image: NSImage) throws -> Data {
        try rgbaPixels(XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    }

    private func rgbaPixels(_ image: CGImage) throws -> Data {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
    }
}
