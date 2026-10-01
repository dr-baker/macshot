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

    func testAutomaticFillPreservesSourcesAndMatchesBackgroundLayer() throws {
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
                    XCTAssertGreaterThan(output[3], 0)
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
        for x in 4..<12 {
            for channel in 0..<4 {
                let expected = (Double(pixel(full, width: 32, x: x * 2, y: 4)[channel])
                                + Double(pixel(full, width: 32, x: x * 2 + 1, y: 4)[channel])) / 2
                XCTAssertEqual(Double(pixel(reduced, width: 16, x: x, y: 2)[channel]), expected, accuracy: 1)
            }
        }
        XCTAssertGreaterThan(pixel(full, width: 32, x: 10, y: 4)[0], pixel(full, width: 32, x: 20, y: 4)[0])
    }

    func testAutomaticFillRejectsTextAndBorderStreaks() throws {
        let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                                bytesPerRow: 1024, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 24 / 255.0, green: 32 / 255.0, blue: 40 / 255.0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        // Text-like rows run right into the cropped edge, plus a full-height border.
        for y in stride(from: 8, to: 256, by: 16) {
            context.fill(CGRect(x: 12, y: y, width: 244, height: 2))
        }
        context.fill(CGRect(x: 254, y: 0, width: 2, height: 256))
        let source = try XCTUnwrap(context.makeImage())
        var document = StitchDocument(pieces: [StitchPiece(image: source),
            StitchPiece(image: source, origin: CGPoint(x: 512, y: 256))])
        document.style.visible = false
        let rendered = try XCTUnwrap(StitchRenderer.render(document))
        let output = bytes(rendered)
        for y in 0..<rendered.height {
            for x in 256..<512 {
                let color = pixel(output, width: rendered.width, x: x, y: y)
                for (actual, expected) in zip(color, [24, 32, 40, 255]) {
                    XCTAssertEqual(Double(actual), Double(expected), accuracy: 1, "Foreground leaked into gap at \(x),\(y)")
                }
            }
        }
    }

    func testPackedGridClosesSlotsAndReordersAcrossRows() {
        let source = image(100, 80)
        let pieces = [(0, 0), (160, 0), (0, 130), (160, 130)].map {
            StitchPiece(image: source, origin: CGPoint(x: $0.0, y: $0.1))
        }
        var document = StitchDocument(pieces: pieces)
        XCTAssertTrue(document.pack())
        XCTAssertEqual(document.placement, .packed)
        XCTAssertEqual(document.pieces.map(\.origin), [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 80), CGPoint(x: 100, y: 80)])
        XCTAssertTrue(document.movePacked(id: pieces[0].id, proposed: CGPoint(x: 100, y: 80)))
        XCTAssertEqual(document.pieces.map(\.id), [pieces[1].id, pieces[2].id, pieces[3].id, pieces[0].id])
        document.pieces.remove(at: 1)
        XCTAssertTrue(document.reflowPacked())
        XCTAssertEqual(document.pieces.map(\.origin), [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 80)])
        let packed = document.pieces.map(\.origin)
        XCTAssertTrue(document.setPlacement(.free))
        XCTAssertEqual(document.pieces.map(\.origin), packed)
    }

    func testPackedUnequalPiecesKeepCropsAndNeverOverlap() {
        let source = image(120, 100)
        var pieces = [StitchPiece(image: source), StitchPiece(image: source, origin: CGPoint(x: 150, y: 0)),
                      StitchPiece(image: source, origin: CGPoint(x: 0, y: 150)), StitchPiece(image: source, origin: CGPoint(x: 150, y: 150))]
        pieces[1].source = CGRect(x: 20, y: 10, width: 70, height: 65)
        pieces[2].source = CGRect(x: 5, y: 10, width: 80, height: 90)
        var document = StitchDocument(pieces: pieces)
        XCTAssertTrue(document.pack())
        for point in [CGPoint(x: -200, y: 70), CGPoint(x: 1000, y: 1000), CGPoint(x: 80, y: 5)] {
            XCTAssertTrue(document.movePacked(id: pieces[2].id, proposed: point))
            for i in document.pieces.indices {
                let piece = document.pieces[i]
                let original = pieces.first { $0.id == piece.id }!
                XCTAssertEqual(piece.source, original.source)
                XCTAssertTrue(piece.image === original.image)
                for j in document.pieces.indices where j > i {
                    XCTAssertTrue(piece.frame.intersection(document.pieces[j].frame).isEmpty)
                }
            }
            XCTAssertTrue(document.canRender)
            let once = document.pieces.map(\.origin)
            XCTAssertTrue(document.reflowPacked())
            XCTAssertEqual(document.pieces.map(\.origin), once)
        }
    }

    func testCutInPackedModePreservesRowsInsteadOfReflowingFragments() {
        let source = image(100, 80)
        var document = StitchDocument(pieces: [(0, 0), (100, 0), (0, 80), (100, 80)].map {
            StitchPiece(image: source, origin: CGPoint(x: $0.0, y: $0.1))
        })
        XCTAssertTrue(document.pack())
        XCTAssertTrue(document.collapse(axis: .vertical, from: 40, to: 60))
        XCTAssertEqual(document.bounds, CGRect(x: 0, y: 0, width: 180, height: 160))
        XCTAssertEqual(document.pieces.map(\.origin), [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0), CGPoint(x: 80, y: 0),
                                                      CGPoint(x: 0, y: 80), CGPoint(x: 40, y: 80), CGPoint(x: 80, y: 80)])
        XCTAssertEqual(document.placement, .packed)
    }

    func testRejectedPackingAndInvalidDropsDoNotMutateDocument() {
        let source = image(1000, 1000)
        let pieces = (0..<128).map { _ in StitchPiece(image: source) }
        var document = StitchDocument(pieces: pieces)
        XCTAssertFalse(document.pack())
        XCTAssertEqual(document.placement, .free)
        XCTAssertEqual(document.pieces.map(\.origin), pieces.map(\.origin))
        document = StitchDocument(pieces: Array(pieces.prefix(2)))
        XCTAssertTrue(document.pack())
        let origins = document.pieces.map(\.origin)
        XCTAssertFalse(document.movePacked(id: pieces[0].id, proposed: CGPoint(x: CGFloat.nan, y: 10)))
        XCTAssertFalse(document.movePacked(id: UUID(), proposed: .zero))
        XCTAssertEqual(document.pieces.map(\.origin), origins)
    }
}
