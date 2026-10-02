import AppKit
import XCTest

final class StitchRendererBlurTests: XCTestCase {
    func testBlurIsStrongAtCenterFadesSymmetricallyAndStopsAtBandEdgesOnBothAxes() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = fixture(axis: axis)
            let rendered = try XCTUnwrap(StitchRenderer.render(document))
            document.style.visible = false
            let baseline = try XCTUnwrap(StitchRenderer.render(document))
            let center = difference(baseline, rendered, axis: axis, coordinate: 100)
            let inner = difference(baseline, rendered, axis: axis, coordinate: 115)
            let outer = difference(baseline, rendered, axis: axis, coordinate: 127)
            XCTAssertGreaterThan(center, 85)
            XCTAssertGreaterThan(center, inner * 1.7)
            XCTAssertGreaterThan(inner, outer * 5)
            XCTAssertLessThan(outer, 7)
            for distance in [0, 8, 16, 24, 31] {
                XCTAssertEqual(difference(baseline, rendered, axis: axis, coordinate: 99 - distance),
                               difference(baseline, rendered, axis: axis, coordinate: 100 + distance), accuracy: 1)
            }
            for coordinate in [40, 67, 68, 132, 133, 180] {
                XCTAssertEqual(difference(baseline, rendered, axis: axis, coordinate: coordinate), 0)
            }
        }
    }

    func testFadeWidthMeansTotalWidthAndDoesNotChangePeakBlur() throws {
        var document = fixture(axis: .horizontal)
        let wide = try XCTUnwrap(StitchRenderer.render(document))
        document.style.feather = 32
        let narrow = try XCTUnwrap(StitchRenderer.render(document))
        document.style.visible = false
        let baseline = try XCTUnwrap(StitchRenderer.render(document))
        XCTAssertEqual(difference(baseline, narrow, axis: .horizontal, coordinate: 120), 0)
        XCTAssertGreaterThan(difference(baseline, wide, axis: .horizontal, coordinate: 120), 20)
        XCTAssertEqual(difference(baseline, narrow, axis: .horizontal, coordinate: 100),
                       difference(baseline, wide, axis: .horizontal, coordinate: 100), accuracy: 1)
    }

    func testBlurRadiusChangesStrengthWithoutExtendingFadeWidth() throws {
        var document = fixture(axis: .horizontal)
        let strong = try XCTUnwrap(StitchRenderer.render(document))
        document.style.blur = 0.5
        let light = try XCTUnwrap(StitchRenderer.render(document))
        document.style.visible = false
        let baseline = try XCTUnwrap(StitchRenderer.render(document))
        XCTAssertGreaterThan(difference(baseline, strong, axis: .horizontal, coordinate: 101),
                             difference(baseline, light, axis: .horizontal, coordinate: 101) + 30)
        XCTAssertEqual(difference(baseline, light, axis: .horizontal, coordinate: 133), 0)
    }

    func testEndpointTaperDoesNotLeaveAFullStrengthBlurCap() throws {
        var document = fixture(axis: .horizontal)
        let rendered = try XCTUnwrap(StitchRenderer.render(document))
        document.style.visible = false
        let baseline = try XCTUnwrap(StitchRenderer.render(document))
        let first = NSBitmapImageRep(cgImage: baseline), second = NSBitmapImageRep(cgImage: rendered)
        func delta(_ x: Int) -> Double {
            abs(first.colorAt(x: x, y: 100)!.redComponent - second.colorAt(x: x, y: 100)!.redComponent) * 255
        }
        XCTAssertLessThan(delta(0), 1)
        XCTAssertLessThan(delta(7), delta(23))
        XCTAssertGreaterThan(delta(40), 50)
        XCTAssertLessThan(delta(319), 1)
    }

    func testFineDarkCenterLineHasNoBrightOutline() throws {
        var document = fixture(axis: .horizontal, solid: true)
        document.style.lineWidth = StitchStyle().lineWidth
        document.style.wave = StitchStyle().wave
        let rendered = try XCTUnwrap(StitchRenderer.render(document))
        document.style.visible = false
        let baseline = try XCTUnwrap(StitchRenderer.render(document))
        let first = NSBitmapImageRep(cgImage: baseline), second = NSBitmapImageRep(cgImage: rendered)
        var darkPixels = 0
        for y in 90..<110 {
            for x in 40..<280 {
                let before = first.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let after = second.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                XCTAssertLessThanOrEqual(after.redComponent, before.redComponent + 1 / 255)
                XCTAssertLessThanOrEqual(after.greenComponent, before.greenComponent + 1 / 255)
                XCTAssertLessThanOrEqual(after.blueComponent, before.blueComponent + 1 / 255)
                if after.redComponent < before.redComponent - 0.1 { darkPixels += 1 }
            }
        }
        XCTAssertGreaterThan(darkPixels, 200)
        XCTAssertLessThan(darkPixels, 700)
    }

    func testPreviewScalesBandWidthWithDocumentPixels() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = fixture(axis: axis)
            let preview = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: 160))
            document.style.visible = false
            let baseline = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: 160))
            XCTAssertGreaterThan(difference(baseline, preview, axis: axis, coordinate: 50, samples: 32..<80), 60)
            XCTAssertEqual(difference(baseline, preview, axis: axis, coordinate: 67, samples: 32..<80), 0)
        }
    }

    func testWaveMovesTheBlurBandAndKeepsPixelsBeyondItsRadiusUntouched() throws {
        var document = fixture(axis: .horizontal)
        document.style.wave = 10
        document.style.feather = 16
        let rendered = try XCTUnwrap(StitchRenderer.render(document))
        document.style.visible = false
        let baseline = try XCTUnwrap(StitchRenderer.render(document))
        let first = NSBitmapImageRep(cgImage: baseline), second = NSBitmapImageRep(cgImage: rendered)
        // At x=63 the wave crest is 10px below the nominal seam.
        XCTAssertGreaterThan(abs(first.colorAt(x: 63, y: 110)!.redComponent
                                 - second.colorAt(x: 63, y: 110)!.redComponent) * 255, 80)
        XCTAssertEqual(first.colorAt(x: 63, y: 119), second.colorAt(x: 63, y: 119))
    }

    private func fixture(axis: StitchAxis, solid: Bool = false) -> StitchDocument {
        let width = 320, height = 320
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8 = solid ? 170 : ((x / 4 + y / 4) % 2 == 0 ? 45 : 235)
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = value }
            }
        }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        var document = StitchDocument(pieces: [StitchPiece(image: image)])
        document.collapse(axis: axis, from: 100, to: 116)
        document.style.wave = 0
        document.style.lineWidth = 0
        return document
    }

    private func difference(_ first: CGImage, _ second: CGImage, axis: StitchAxis,
                            coordinate: Int, samples: Range<Int> = 64..<256) -> Double {
        let a = NSBitmapImageRep(cgImage: first), b = NSBitmapImageRep(cgImage: second)
        return samples.reduce(0.0) { result, along in
            let x = axis == .horizontal ? along : coordinate
            let y = axis == .horizontal ? coordinate : along
            return result + abs(a.colorAt(x: x, y: y)!.redComponent - b.colorAt(x: x, y: y)!.redComponent) * 255
        } / Double(samples.count)
    }
}
