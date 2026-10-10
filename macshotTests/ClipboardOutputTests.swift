import AppKit
import ImageIO
import XCTest

@MainActor
final class ClipboardOutputTests: XCTestCase {
    private func bytes(_ image: NSImage) throws -> Data {
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let normalized = try HistoryImageSnapshot.Image.render(pixels, width: pixels.width, height: pixels.height)
        return try XCTUnwrap(normalized.dataProvider?.data) as Data
    }

    func testCropMatchesCompositorAtNativeScaleAndFractionalSelections() throws {
        for scale: CGFloat in [1, 2] {
            let source = ImageProbe.quadrantImage(width: 80, height: 60)
            let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 80 / scale, height: 60 / scale))
            view.screenshotImage = NSImage(cgImage: try XCTUnwrap(source.cgImage(
                forProposedRect: nil, context: nil, hints: nil)), size: view.bounds.size)
            view.showToolbars = false
            for rect in [view.bounds, CGRect(x: 4.4, y: 3.4, width: 25.4, height: 20.4)] {
                view.applySelection(rect)
                view.annotations = []
                let cropped = try XCTUnwrap(view.captureSelectedRegion())
                // Force the established compositor without changing any visible pixel.
                view.annotations = [Annotation(tool: .filledRectangle,
                    startPoint: CGPoint(x: -100, y: -100), endPoint: CGPoint(x: -90, y: -90),
                    color: .black, strokeWidth: 2)]
                let composited = try XCTUnwrap(view.captureSelectedRegion())
                XCTAssertEqual(cropped.size, composited.size)
                XCTAssertEqual(try bytes(cropped), try bytes(composited))
            }
            view.reset()
        }
    }

    func testTransparentCropMatchesCompositorWithOffsetAndFractionalSourceOrigins() throws {
        for scale: CGFloat in [1, 2] {
            for offset in [CGPoint(x: 13, y: 17), CGPoint(x: 13.3, y: 17.7)] {
                let source = ImageProbe.makeImage(width: Int(80 * scale), height: Int(60 * scale)) { context in
                    context.setFillColor(CGColor(srgbRed: 1, green: 0.3, blue: 0.2, alpha: 0.4))
                    context.fill(CGRect(x: 8 * scale, y: 6 * scale, width: 40 * scale, height: 35 * scale))
                }
                source.size = CGSize(width: 80, height: 60)
                let view = ClipboardOffsetCaptureView(frame: CGRect(x: 0, y: 0, width: 140, height: 110))
                view.sourceOrigin = offset
                view.screenshotImage = source
                view.showToolbars = false
                view.applySelection(CGRect(x: offset.x + 3.4, y: offset.y + 2.4, width: 35.4, height: 26.4))
                let plain = try XCTUnwrap(view.captureSelectedRegion())
                view.annotations = [Annotation(tool: .filledRectangle, startPoint: CGPoint(x: -100, y: -100),
                    endPoint: CGPoint(x: -90, y: -90), color: .black, strokeWidth: 2)]
                let composite = try XCTUnwrap(view.captureSelectedRegion())
                XCTAssertEqual(plain.size, composite.size)
                XCTAssertEqual(try bytes(plain), try bytes(composite))
                view.reset()
            }
        }
    }

    func testRedactionNeverTakesPlainCropPathAndRawHistoryKeepsSource() throws {
        let view = EditorView(frame: CGRect(x: 0, y: 0, width: 80, height: 60))
        view.screenshotImage = ImageProbe.solidImage(width: 160, height: 120, color: NSColor.white.cgColor)
        view.screenshotImage?.size = view.bounds.size
        view.showToolbars = false
        view.applySelection(view.bounds)
        view.annotations = [Annotation(tool: .filledRectangle, startPoint: CGPoint(x: 10, y: 10),
            endPoint: CGPoint(x: 50, y: 50), color: .black, strokeWidth: 2)]
        let composite = try XCTUnwrap(view.captureSelectedRegion())
        let raw = try XCTUnwrap(view.captureSelectedRegionRaw())
        XCTAssertLessThan(try XCTUnwrap(ImageProbe.pixelColor(composite, x: 40, y: 40)).redComponent, 0.01)
        XCTAssertGreaterThan(try XCTUnwrap(ImageProbe.pixelColor(raw, x: 40, y: 40)).redComponent, 0.99)
        let prepared = try ImageEncoder.PreparedImage(composite)
        for representation in ImageEncoder.clipboardRepresentations(for: prepared, includeConfiguredFormat: false) {
            let decoded = try XCTUnwrap(NSImage(data: representation.data))
            XCTAssertLessThan(try XCTUnwrap(ImageProbe.pixelColor(decoded, x: 40, y: 40)).redComponent, 0.01)
        }
        view.reset()
    }

    func testClipboardPNGKeepsAlphaWideGamutAndPixels() throws {
        for colorSpace in [CGColorSpace(name: CGColorSpace.sRGB)!, CGColorSpace(name: CGColorSpace.displayP3)!] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
                bytesPerRow: 64 * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 0.25, 0.5, 0.4])!)
            context.fill(CGRect(x: 4, y: 6, width: 40, height: 30))
            let pixels = try XCTUnwrap(context.makeImage())
            let expected = try XCTUnwrap(ImageEncoder.encodeWithCGImageDestination(
                cgImage: pixels, type: "public.png", lossyQuality: nil))
            let actual = try XCTUnwrap(ImageEncoder.encodeClipboardPNG(pixels))
            XCTAssertEqual(try bytes(try XCTUnwrap(NSImage(data: actual))),
                           try bytes(try XCTUnwrap(NSImage(data: expected))))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(actual as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(decoded.colorSpace?.name, pixels.colorSpace?.name)
        }
    }

    private func wideGamutRetinaSource() throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8,
            bytesPerRow: 160 * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colorSpace = try XCTUnwrap(context.colorSpace)
        for (rect, color) in [
            (CGRect(x: 8, y: 6, width: 64, height: 64), [CGFloat(1), 0.2, 0.3, 0.4]),
            (CGRect(x: 60, y: 40, width: 30, height: 60), [CGFloat(0), 0.8, 0.1, 0.7]),
            (CGRect(x: 120, y: 20, width: 24, height: 40), [CGFloat(0.1), 0.2, 1, 1]),
        ] {
            context.setFillColor(try XCTUnwrap(CGColor(colorSpace: colorSpace, components: color)))
            context.fill(rect)
        }
        return NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: CGSize(width: 80, height: 60))
    }

    func testWideGamutRetinaCropAndOutsideSourcePaddingMatchCompositor() throws {
        let view = ClipboardOffsetCaptureView(frame: CGRect(x: 0, y: 0, width: 140, height: 110))
        view.sourceOrigin = CGPoint(x: 13, y: 17)
        view.screenshotImage = try wideGamutRetinaSource()
        view.showToolbars = false
        for rect in [CGRect(x: 16.5, y: 19.5, width: 35.5, height: 26.5),
                     CGRect(x: 8, y: 13, width: 95, height: 70)] {
            view.applySelection(rect)
            view.annotations = []
            let crop = try XCTUnwrap(view.captureSelectedRegion())
            view.annotations = [Annotation(tool: .filledRectangle, startPoint: CGPoint(x: -100, y: -100),
                endPoint: CGPoint(x: -90, y: -90), color: .black, strokeWidth: 2)]
            let expected = try XCTUnwrap(view.captureSelectedRegion())
            let actualPixels = try XCTUnwrap(crop.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let expectedPixels = try XCTUnwrap(expected.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(actualPixels.width, Int(rect.width * 2))
            XCTAssertEqual(actualPixels.height, Int(rect.height * 2))
            XCTAssertEqual(actualPixels.colorSpace?.name, CGColorSpace(name: CGColorSpace.displayP3)?.name)
            XCTAssertEqual(actualPixels.colorSpace?.name, expectedPixels.colorSpace?.name)
            XCTAssertEqual(try bytes(crop), try bytes(expected))
        }
        view.reset()
    }

    func testWideGamutRetinaEffectsMatchFormerTIFFInput() throws {
        let source = try wideGamutRetinaSource()
        let formerBitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(source.tiffRepresentation)))
        let formerInput = NSImage(cgImage: try XCTUnwrap(formerBitmap.cgImage), size: source.size)
        for preset in ImageEffectPreset.allCases where preset != .none {
            let config = ImageEffectsConfig(preset: preset)
            let actual = ImageEffects.apply(to: source, config: config)
            let expected = ImageEffects.apply(to: formerInput, config: config)
            let pixels = try XCTUnwrap(actual.cgImage(forProposedRect: nil, context: nil, hints: nil))
            XCTAssertEqual(actual.size, CGSize(width: 80, height: 60))
            XCTAssertEqual(pixels.width, 160)
            XCTAssertEqual(pixels.height, 120)
            XCTAssertEqual(pixels.colorSpace?.name, CGColorSpace(name: CGColorSpace.displayP3)?.name)
            let actualBytes = try bytes(actual), expectedBytes = try bytes(expected)
            XCTAssertEqual(actualBytes.count, expectedBytes.count)
            let largestDifference = zip(actualBytes, expectedBytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(largestDifference, 1, "\(preset) must match within one RGBA8 rounding step")
        }
    }

    func testCopyFreezesPixelsAndPublishesImmediatelyReadableFormats() throws {
        let board = NSPasteboard(name: .init("macshot.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let source = ImageProbe.quadrantImage(width: 64, height: 48)
        let expected = try bytes(source)
        let copied = expectation(description: "Copied")
        withDefaults(["imageFormat": "png", "clipboardIncludesImageFormat": false, "downscaleRetina": false]) {
            ImageEncoder.copyToClipboard(source, pasteboard: board) { success in
                XCTAssertTrue(success)
                for type in [NSPasteboard.PasteboardType.png, .tiff] {
                    do {
                        let decoded = try XCTUnwrap(NSImage(data: try XCTUnwrap(board.data(forType: type))))
                        XCTAssertEqual(try self.bytes(decoded), expected)
                    } catch { XCTFail("\(error)") }
                }
                copied.fulfill()
            }
            source.size = NSSize(width: 1, height: 1)
            source.removeRepresentation(source.representations[0])
            wait(for: [copied], timeout: 10)
        }
    }

    func testPendingCopyCannotOverwriteExternalPasteboardChange() {
        let board = NSPasteboard(name: .init("macshot.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let completed = expectation(description: "Abandoned")
        ImageEncoder.copyToClipboard(ImageProbe.quadrantImage(), pasteboard: board) { success in
            XCTAssertFalse(success)
            XCTAssertEqual(board.string(forType: .string), "newer user clipboard")
            completed.fulfill()
        }
        board.clearContents()
        board.setString("newer user clipboard", forType: .string)
        wait(for: [completed], timeout: 10)
    }

    func testLatestCopyWinsWhenRequestsOverlap() {
        let board = NSPasteboard(name: .init("macshot.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let old = expectation(description: "Superseded")
        let newest = expectation(description: "Newest")
        withDefaults(["imageFormat": "png", "clipboardIncludesImageFormat": false, "downscaleRetina": false]) {
            ImageEncoder.copyToClipboard(ImageProbe.quadrantImage(), pasteboard: board) { success in
                XCTAssertFalse(success)
                old.fulfill()
            }
            ImageEncoder.copyToClipboard(ImageProbe.solidImage(color: NSColor.black.cgColor), pasteboard: board) { success in
                XCTAssertTrue(success)
                let image = board.data(forType: .png).flatMap { NSImage(data: $0) }
                XCTAssertEqual(image.flatMap { ImageProbe.pixelColor($0, x: 2, y: 2) }?.redComponent, 0)
                newest.fulfill()
            }
            wait(for: [old, newest], timeout: 10)
        }
    }
}

@MainActor private final class ClipboardOffsetCaptureView: OverlayView {
    var sourceOrigin = CGPoint.zero
    override var captureDrawRect: NSRect { CGRect(origin: sourceOrigin, size: CGSize(width: 80, height: 60)) }
}
