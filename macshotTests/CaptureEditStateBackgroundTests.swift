import Cocoa
import ImageIO
import XCTest

@MainActor
final class CaptureEditStateBackgroundTests: XCTestCase {
    func testRepeatedStateReadsEncodeNativeBackgroundPixelsOnce() throws {
        let image = try countedBackground()
        let view = editor(background: image)
        let requests = image.nativePixelRequests
        let first = try XCTUnwrap(view.captureEditState().customBeautifyBackgroundPNG)
        XCTAssertEqual(image.nativePixelRequests, requests + 1)
        for _ in 0..<10 {
            XCTAssertEqual(view.captureEditState().customBeautifyBackgroundPNG, first)
        }
        XCTAssertEqual(image.nativePixelRequests, requests + 1,
            "Repeated state reads must reuse the prepared PNG rather than request image pixels again")
        XCTAssertEqual(image.tiffRequests, 0)
        let restored = try XCTUnwrap(SavedCaptureValidation.image(first))
        XCTAssertEqual(FieldDescriber.describe(restored), FieldDescriber.describe(image))
    }

    func testBackgroundReplacementAndNilDiscardPreviousBytes() throws {
        let firstImage = try countedBackground(color: .red)
        let secondImage = try countedBackground(color: .blue)
        let view = editor(background: firstImage)
        let first = try XCTUnwrap(view.captureEditState().customBeautifyBackgroundPNG)
        view.customBeautifyBackground = secondImage
        let requests = secondImage.nativePixelRequests
        let second = try XCTUnwrap(view.captureEditState().customBeautifyBackgroundPNG)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(secondImage.nativePixelRequests, requests + 1)
        XCTAssertEqual(view.captureEditState().customBeautifyBackgroundPNG, second)
        XCTAssertEqual(secondImage.nativePixelRequests, requests + 1)
        view.customBeautifyBackground = nil
        XCTAssertNil(view.captureEditState().customBeautifyBackgroundPNG)
        view.replaceCustomBeautifyBackground(nil, originalPNG: first)
        XCTAssertNil(view.captureEditState().customBeautifyBackgroundPNG)
        view.customBeautifyBackground = firstImage
        let restoredRequests = firstImage.nativePixelRequests
        XCTAssertEqual(view.captureEditState().customBeautifyBackgroundPNG, first)
        XCTAssertEqual(firstImage.nativePixelRequests, restoredRequests + 1)
    }

    func testBlurFrameEffectsAndStyleChangesRetainOriginalBytes() throws {
        let image = try countedBackground()
        let view = editor(background: image)
        let original = try XCTUnwrap(view.captureEditState().customBeautifyBackgroundPNG)
        view.beautifyBackgroundBlur = 12
        view.beautifyPadding = 48
        view.beautifyCornerRadius = 20
        view.beautifyEnabled = true
        view.effectsPreset = .vivid
        let requests = image.nativePixelRequests
        let blurredState = view.captureEditState()
        XCTAssertEqual(blurredState.customBeautifyBackgroundPNG, original)
        XCTAssertEqual(blurredState.beautifyBackgroundBlur, 12)
        XCTAssertEqual(image.nativePixelRequests, requests)
        view.beautifyStyleIndex = 0
        XCTAssertNil(view.captureEditState().customBeautifyBackgroundPNG)
        view.beautifyStyleIndex = -1
        XCTAssertEqual(view.captureEditState().customBeautifyBackgroundPNG, original)
        XCTAssertEqual(image.nativePixelRequests, requests,
            "A gradient switch does not replace the source image by itself")
        let restored = try XCTUnwrap(blurredState.customBeautifyBackground)
        XCTAssertEqual(FieldDescriber.describe(restored), FieldDescriber.describe(image),
            "Editable history needs the sharp original, not the blurred drawing cache")
    }

    func testWallpaperSelectionSeedsOriginalPNGWithoutReencoding() throws {
        let image = try countedBackground()
        let png = try pngWithMetadata(image)
        try withDefaults(["beautifyCustomBgImageData": nil, "beautifyWallpaperID": nil,
                          "beautifyStyleIndex": 0]) {
            let view = editor(background: nil)
            view.setBeautifyBackground(image, pngData: png, wallpaperID: "fixture")
            let requests = image.nativePixelRequests
            XCTAssertEqual(view.captureEditState().customBeautifyBackgroundPNG, png)
            XCTAssertEqual(view.captureEditState().beautifyWallpaperID, "fixture")
            XCTAssertEqual(image.nativePixelRequests, requests)
            XCTAssertEqual(image.tiffRequests, 0)
        }
    }

    func testSavedStateSeedsItsPNGAndKeepsTheOriginalThroughBlurChanges() throws {
        let png = try pngWithMetadata(XCTUnwrap(ImageProbe.quadrantImage().cgImage(
            forProposedRect: nil, context: nil, hints: nil)))
        var state = CaptureEditState()
        state.beautifyStyleIndex = -1
        state.customBeautifyBackgroundPNG = png
        state.beautifyWallpaperID = "history-wallpaper"
        state.beautifyBackgroundBlur = 8
        let decoded = try JSONDecoder().decode(CaptureEditState.self, from: JSONEncoder().encode(state))
        let view = editor(background: nil)
        view.applyCaptureEditState(decoded)
        XCTAssertEqual(view.captureEditState().customBeautifyBackgroundPNG, png,
            "Reopening an unchanged capture must preserve the original sidecar bytes exactly")
        view.beautifyBackgroundBlur = 20
        XCTAssertEqual(view.captureEditState().customBeautifyBackgroundPNG, png)
        XCTAssertEqual(view.captureEditState().beautifyWallpaperID, "history-wallpaper")
    }

    func testDefaultsLoadAndResetSeedTheCurrentlySelectedSource() throws {
        let first = try pngWithMetadata(ImageProbe.quadrantImage())
        let second = try pngWithMetadata(ImageProbe.solidImage(color: NSColor.blue.cgColor))
        try withDefaults(["beautifyCustomBgImageData": first, "beautifyStyleIndex": -1,
                          "beautifyWallpaperID": "first"]) {
            let view = editor(background: nil)
            view.ensureCustomBeautifyBackgroundLoaded()
            XCTAssertEqual(view.captureEditState().customBeautifyBackgroundPNG, first)
            UserDefaults.standard.set(second, forKey: "beautifyCustomBgImageData")
            UserDefaults.standard.set("second", forKey: "beautifyWallpaperID")
            view.reset()
            XCTAssertEqual(view.captureEditState().customBeautifyBackgroundPNG, second)
            XCTAssertEqual(view.captureEditState().beautifyWallpaperID, "second")
            view.customBeautifyBackground = nil
            view.loadCustomBeautifyBackground()
            XCTAssertEqual(view.captureEditState().customBeautifyBackgroundPNG, second)
        }
    }

    func testNonPNGAndIncompleteSeedDataUseAValidNativePNGInstead() throws {
        let image = try countedBackground()
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let jpeg = try XCTUnwrap(ImageEncoder.encodeWithCGImageDestination(
            cgImage: pixels, type: "public.jpeg", lossyQuality: 0.9))
        let png = try pngWithMetadata(pixels)
        let missingIEND = Data(png.dropLast(12))
        XCTAssertNotEqual(missingIEND.suffix(12), png.suffix(12),
            "The truncated fixture must actually remove the PNG terminator")
        let seeds = [("JPEG", jpeg), ("non-image bytes", Data("invalid".utf8)),
                     ("incomplete PNG header", Data(png.prefix(40))), ("missing IEND", missingIEND)]
        for (name, invalid) in seeds {
            let view = editor(background: nil)
            view.replaceCustomBeautifyBackground(image, originalPNG: invalid)
            let requests = image.nativePixelRequests
            let saved = try XCTUnwrap(view.captureEditState().customBeautifyBackgroundPNG)
            XCTAssertNotEqual(saved, invalid, "The \(name) seed must not enter editable history")
            XCTAssertNotNil(SavedCaptureValidation.image(saved), "The \(name) fallback must be a valid PNG")
            XCTAssertEqual(image.nativePixelRequests, requests + 1, "The \(name) seed must request native pixels")
            XCTAssertEqual(view.captureEditState().customBeautifyBackgroundPNG, saved)
            XCTAssertEqual(image.nativePixelRequests, requests + 1, "The \(name) fallback must be cached")
        }
        XCTAssertEqual(image.tiffRequests, 0)
    }

    func testFailedPreparationIsCachedUntilTheImageIsReassigned() throws {
        let image = try countedBackground()
        image.refuseNativePixels = true
        let view = editor(background: image)
        let requests = image.nativePixelRequests
        XCTAssertNil(view.captureEditState().customBeautifyBackgroundPNG)
        XCTAssertNil(view.captureEditState().customBeautifyBackgroundPNG)
        XCTAssertEqual(image.nativePixelRequests, requests + 1)
        image.refuseNativePixels = false
        view.customBeautifyBackground = image
        XCTAssertNotNil(view.captureEditState().customBeautifyBackgroundPNG)
        XCTAssertEqual(image.nativePixelRequests, requests + 2)
    }

    func testNativePreparationKeepsRetinaPixelsAndDisplayP3Alpha() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8,
            bytesPerRow: 96 * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let color = try XCTUnwrap(CGColor(colorSpace: space, components: [0.85, 0.3, 0.6, 0.5]))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        let source = try XCTUnwrap(context.makeImage())
        let image = NSImage(cgImage: source, size: NSSize(width: 48, height: 32))
        let data = try XCTUnwrap(editor(background: image).captureEditState().customBeautifyBackgroundPNG)
        let png = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let restored = try XCTUnwrap(CGImageSourceCreateImageAtIndex(png, 0, nil))
        XCTAssertEqual(restored.width, 96)
        XCTAssertEqual(restored.height, 64)
        XCTAssertEqual(restored.colorSpace?.name, CGColorSpace.displayP3)
        let pixel = try XCTUnwrap(NSBitmapImageRep(cgImage: restored).colorAt(x: 10, y: 10))
        XCTAssertEqual(pixel.alphaComponent, 0.5, accuracy: 0.01)
        XCTAssertEqual(pixel.redComponent, 0.85, accuracy: 0.01)
    }

    private func editor(background: NSImage?) -> OverlayView {
        let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 120, height: 80))
        view.showToolbars = false
        view.beautifyStyleIndex = -1
        view.beautifyBackgroundBlur = 0
        view.customBeautifyBackground = background
        return view
    }

    private func countedBackground(color: NSColor? = nil) throws -> CountingBackground {
        let image = color.map { ImageProbe.solidImage(width: 64, height: 48, color: $0.cgColor) }
            ?? ImageProbe.quadrantImage()
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let counted = CountingBackground(size: NSSize(width: pixels.width, height: pixels.height))
        counted.addRepresentation(NSBitmapImageRep(cgImage: pixels))
        return counted
    }

    private func pngWithMetadata(_ image: NSImage) throws -> Data {
        try pngWithMetadata(XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
    }

    private func pngWithMetadata(_ pixels: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, pixels, [
            kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private final class CountingBackground: NSImage {
        var nativePixelRequests = 0
        var tiffRequests = 0
        var refuseNativePixels = false

        override var tiffRepresentation: Data? {
            tiffRequests += 1
            return super.tiffRepresentation
        }

        override func cgImage(forProposedRect proposedDestRect: UnsafeMutablePointer<NSRect>?,
                              context referenceContext: NSGraphicsContext?,
                              hints: [NSImageRep.HintKey: Any]?) -> CGImage? {
            nativePixelRequests += 1
            return refuseNativePixels ? nil : super.cgImage(forProposedRect: proposedDestRect,
                context: referenceContext, hints: hints)
        }
    }
}
