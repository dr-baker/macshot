import AppKit
import XCTest

final class StitchLayoutAndBackgroundTests: XCTestCase {
    private func image(_ width: Int, _ height: Int, alpha: UInt8 = 255) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8((x * 31 + y * 7) % (Int(alpha) + 1))
                pixels[i + 1] = UInt8((x * 3 + y * 43) % (Int(alpha) + 1))
                pixels[i + 2] = UInt8((x * 17 + y * 13) % (Int(alpha) + 1))
                pixels[i + 3] = alpha
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        Array(image.dataProvider!.data! as Data)
    }
    private func pixel(_ data: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        Array(data[(y * width + x) * 4..<(y * width + x + 1) * 4])
    }

    func testAutomaticFillMatchesNearestCoveredPixelsAndPreservesSources() throws {
        var cropped = StitchPiece(image: image(9, 8), origin: CGPoint(x: -3, y: 1))
        cropped.source = CGRect(x: 2, y: 1, width: 4, height: 5)
        let pieces = [cropped,
                      StitchPiece(image: image(5, 4, alpha: 100), origin: CGPoint(x: 7, y: -2)),
                      StitchPiece(image: image(3, 5), origin: CGPoint(x: 4, y: 9)),
                      StitchPiece(image: image(2, 3), origin: CGPoint(x: 8, y: 0))]
        var document = StitchDocument(pieces: pieces)
        document.style.visible = false
        document.background = .transparent
        let source = try XCTUnwrap(StitchRenderer.render(document))
        let sourceBytes = bytes(source)
        document.background = .automatic
        let rendered = try XCTUnwrap(StitchRenderer.render(document))
        let result = bytes(rendered)
        let background = bytes(try XCTUnwrap(StitchRenderer.renderBackground(document)))
        let b = document.bounds.integral
        let covered = (0..<source.height).flatMap { y in
            (0..<source.width).compactMap { x -> CGPoint? in
                let p = CGPoint(x: b.minX + CGFloat(x) + 0.5, y: b.minY + CGFloat(y) + 0.5)
                return pieces.contains { $0.frame.contains(p) } ? CGPoint(x: x, y: y) : nil
            }
        }
        for y in 0..<source.height {
            for x in 0..<source.width {
                let p = CGPoint(x: x, y: y)
                let output = pixel(result, width: source.width, x: x, y: y)
                if covered.contains(p) {
                    XCTAssertEqual(output, pixel(sourceBytes, width: source.width, x: x, y: y))
                    XCTAssertEqual(pixel(background, width: source.width, x: x, y: y), [0, 0, 0, 0])
                } else {
                    let distance = covered.map { pow($0.x - p.x, 2) + pow($0.y - p.y, 2) }.min()!
                    let closest = covered.filter { pow($0.x - p.x, 2) + pow($0.y - p.y, 2) == distance }
                    XCTAssertTrue(closest.contains {
                        pixel(sourceBytes, width: source.width, x: Int($0.x), y: Int($0.y)) == output
                    }, "Gap pixel \(x),\(y) must copy one of its nearest covered neighbors")
                    XCTAssertEqual(output, pixel(background, width: source.width, x: x, y: y))
                }
            }
        }
    }

    func testSolidAndTransparentBackgroundOnlyChangeUncoveredPixels() throws {
        var document = StitchDocument(pieces: [
            StitchPiece(image: image(4, 4, alpha: 90)),
            StitchPiece(image: image(4, 4), origin: CGPoint(x: 8, y: 0)),
        ], background: .transparent)
        document.style.visible = false
        let original = try XCTUnwrap(StitchRenderer.render(document))
        let originalBytes = bytes(original)
        XCTAssertEqual(pixel(originalBytes, width: 12, x: 6, y: 2), [0, 0, 0, 0])
        document.background = .color(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.5))
        let filled = bytes(try XCTUnwrap(StitchRenderer.render(document)))
        let gap = pixel(filled, width: 12, x: 6, y: 2)
        XCTAssertEqual(gap[0], 0)
        XCTAssertGreaterThan(gap[1], 120)
        XCTAssertEqual(gap[2], 0)
        XCTAssertEqual(Double(gap[3]), 128, accuracy: 1)
        for y in 0..<4 {
            for x in Array(0..<4) + Array(8..<12) {
                XCTAssertEqual(pixel(filled, width: 12, x: x, y: y), pixel(originalBytes, width: 12, x: x, y: y))
            }
        }
    }

    func testAutomaticBackgroundPreviewUsesSameNeighborColors() throws {
        let red = ImageProbe.solidImage(width: 8, height: 8, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let blue = ImageProbe.solidImage(width: 8, height: 8, color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var document = StitchDocument(pieces: [StitchPiece(image: red), StitchPiece(image: blue, origin: CGPoint(x: 24, y: 0))])
        document.style.visible = false
        let full = bytes(try XCTUnwrap(StitchRenderer.render(document)))
        let preview = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: 16))
        let reduced = bytes(preview)
        XCTAssertEqual(preview.width, 16)
        XCTAssertEqual(preview.height, 4)
        XCTAssertEqual(pixel(reduced, width: 16, x: 5, y: 2), pixel(full, width: 32, x: 10, y: 4))
        XCTAssertEqual(pixel(reduced, width: 16, x: 10, y: 2), pixel(full, width: 32, x: 20, y: 4))
    }

}
