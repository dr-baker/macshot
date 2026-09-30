import XCTest
import AppKit

final class StitchTests: XCTestCase {
    private func image(_ width: Int = 120, _ height: Int = 100) -> CGImage {
        ImageProbe.quadrantImage(width: width, height: height).cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }
    private func texture(width: Int, height: Int) -> CGImage {
        var data = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt64 = 1234567
        for i in 0..<(width * height) {
            seed = seed &* 6364136223846793005 &+ 1
            let value = UInt8((seed >> 32) & 255)
            data[i * 4] = value; data[i * 4 + 1] = value; data[i * 4 + 2] = value
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    func testDifferentSizedRegionsMatchAtTheirScreenPositions() throws {
        let source = texture(width: 600, height: 500)
        let first = source.cropping(to: CGRect(x: 20, y: 40, width: 360, height: 300))!
        let second = source.cropping(to: CGRect(x: 140, y: 120, width: 250, height: 200))!
        let match = try XCTUnwrap(StitchAlignment.matchRegions(previous: first, current: second,
                                                              expectedOffset: CGPoint(x: 120, y: 80)))
        XCTAssertEqual(match.offset, CGPoint(x: 120, y: 80))
        XCTAssertEqual(match.error, 0)
        let reverse = try XCTUnwrap(StitchAlignment.matchRegions(previous: second, current: first,
                                                                expectedOffset: CGPoint(x: -120, y: -80)))
        XCTAssertEqual(reverse.offset, CGPoint(x: -120, y: -80))
    }

    func testDifferentSizedRegionsCorrectAnInexactScrollEstimate() throws {
        let source = texture(width: 800, height: 1100)
        let first = source.cropping(to: CGRect(x: 20, y: 40, width: 700, height: 650))!
        let second = source.cropping(to: CGRect(x: 50, y: 203, width: 650, height: 600))!
        let match = try XCTUnwrap(StitchAlignment.matchRegions(previous: first, current: second,
                                                              expectedOffset: CGPoint(x: 30, y: 150)))
        XCTAssertEqual(match.offset.x, 30, accuracy: 1)
        XCTAssertEqual(match.offset.y, 163, accuracy: 1)
    }

    func testSmallLowerRegionCorrectsInexactScrollWithoutLosingOverlap() throws {
        let source = texture(width: 400, height: 800)
        let first = source.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 700))!
        let second = source.cropping(to: CGRect(x: 0, y: 400, width: 400, height: 200))!
        let result = try XCTUnwrap(StitchAlignment.matchRegions(previous: first, current: second,
                                                               expectedOffset: CGPoint(x: 0, y: 300)))
        XCTAssertEqual(result.offset, CGPoint(x: 0, y: 400))
    }

    func testDisjointRegionsDoNotInventAnOverlap() {
        let source = texture(width: 600, height: 500)
        let first = source.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 180))!
        let second = source.cropping(to: CGRect(x: 350, y: 260, width: 220, height: 210))!
        XCTAssertNil(StitchAlignment.matchRegions(previous: first, current: second,
                                                  expectedOffset: CGPoint(x: 350, y: 260)))
    }

    func testRemoveRowsKeepsSourcePixelsAndAddsTouchingJoin() throws {
        var doc = StitchDocument(pieces: [StitchPiece(image: image())])
        doc.style.visible = false
        XCTAssertTrue(doc.collapse(axis: .horizontal, from: 30, to: 70))
        XCTAssertEqual(doc.bounds.size, CGSize(width: 120, height: 60))
        XCTAssertEqual(doc.pieces.count, 2)
        XCTAssertEqual(doc.pieces[1].source.minY, 70)
        XCTAssertEqual(doc.joins.count, 1)
        let output = try XCTUnwrap(StitchRenderer.render(doc))
        let bitmap = NSBitmapImageRep(cgImage: output)
        let top = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10))
        let bottom = try XCTUnwrap(bitmap.colorAt(x: 10, y: 50))
        XCTAssertGreaterThan(top.blueComponent, 0.9)
        XCTAssertGreaterThan(bottom.redComponent, 0.9)
    }
    func testRemoveColumnsInReverseDirection() throws {
        var doc = StitchDocument(pieces: [StitchPiece(image: image())])
        doc.style.visible = false
        XCTAssertTrue(doc.collapse(axis: .vertical, from: 80, to: 40))
        XCTAssertEqual(doc.bounds.width, 80)
        XCTAssertEqual(doc.pieces[1].source.minX, 80)
        let output = try XCTUnwrap(StitchRenderer.render(doc))
        let bitmap = NSBitmapImageRep(cgImage: output)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 10, y: 80)).redComponent, 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 70, y: 80)).greenComponent, 0.9)
    }
    func testCutsAcrossMultiplePiecesPreserveOffsets() {
        var doc = StitchDocument(pieces: [StitchPiece(image: image()), StitchPiece(image: image(), origin: CGPoint(x: 0, y: 100))])
        XCTAssertTrue(doc.collapse(axis: .horizontal, from: 80, to: 120))
        XCTAssertEqual(doc.pieces.count, 2)
        XCTAssertEqual(doc.pieces[0].frame.maxY, 80)
        XCTAssertEqual(doc.pieces[1].origin.y, 80)
        XCTAssertEqual(doc.pieces[1].source.minY, 20)
        XCTAssertEqual(doc.bounds.height, 160)
    }
    func testDegenerateCutsAndOversizedCanvasAreRejected() {
        var doc = StitchDocument(pieces: [StitchPiece(image: image())])
        XCTAssertFalse(doc.collapse(axis: .horizontal, from: 0, to: 100))
        XCTAssertFalse(doc.collapse(axis: .vertical, from: .nan, to: 30))
        XCTAssertFalse(doc.collapse(axis: .horizontal, from: 10, to: 10))
        doc.pieces.append(StitchPiece(image: image(), origin: CGPoint(x: 50_000, y: 0)))
        XCTAssertFalse(doc.canRender)
        XCTAssertNil(StitchRenderer.render(doc))
    }
    func testCutsRejectTooManyPiecesWithoutChangingDocument() {
        let source = image()
        var doc = StitchDocument(pieces: (0..<StitchDocument.maximumPieces).map { _ in StitchPiece(image: source) })
        XCTAssertTrue(doc.canRender)
        XCTAssertFalse(doc.collapse(axis: .horizontal, from: 30, to: 70))
        XCTAssertEqual(doc.pieces.count, StitchDocument.maximumPieces)
        XCTAssertEqual(doc.bounds.height, 100)
    }
    func testJoinMovesWithEdgesAndDisappearsWhenSeparated() {
        var doc = StitchDocument(pieces: [StitchPiece(image: image()), StitchPiece(image: image(), origin: CGPoint(x: 0, y: 100))])
        XCTAssertEqual(doc.joins.count, 1)
        doc.pieces[1].origin.y = 110
        XCTAssertTrue(doc.joins.isEmpty)
        let snapped = doc.snappedOrigin(for: doc.pieces[1].id, proposed: CGPoint(x: 4, y: 106), tolerance: 12)
        XCTAssertEqual(snapped, CGPoint(x: 0, y: 100))
    }
    func testHorizontalCaptureOverlap() throws {
        let source = texture(width: 240, height: 120)
        let first = source.cropping(to: CGRect(x: 0, y: 0, width: 160, height: 120))!
        let second = source.cropping(to: CGRect(x: 48, y: 0, width: 160, height: 120))!
        let result = try XCTUnwrap(StitchAlignment.match(previous: first, current: second, scrollHint: CGPoint(x: 40, y: 0)))
        XCTAssertEqual(result.offset.x, 48, accuracy: 1)
        XCTAssertEqual(result.offset.y, 0)
    }
    func testVerticalCaptureOverlapAndReverseScroll() throws {
        let source = texture(width: 140, height: 240)
        let first = source.cropping(to: CGRect(x: 0, y: 0, width: 140, height: 160))!
        let second = source.cropping(to: CGRect(x: 0, y: 44, width: 140, height: 160))!
        let forward = try XCTUnwrap(StitchAlignment.match(previous: first, current: second))
        let reverse = try XCTUnwrap(StitchAlignment.match(previous: second, current: first))
        XCTAssertEqual(forward.offset.y, 44, accuracy: 1)
        XCTAssertEqual(reverse.offset.y, -44, accuracy: 1)
    }
    func testLargeCaptureRegistersBothAxesAtPixelPrecision() throws {
        let source = texture(width: 850, height: 1000)
        let first = source.cropping(to: CGRect(x: 0, y: 0, width: 700, height: 700))!
        let second = source.cropping(to: CGRect(x: 37, y: 183, width: 700, height: 700))!
        let match = try XCTUnwrap(StitchAlignment.match(previous: first, current: second))
        XCTAssertEqual(match.offset.x, 37, accuracy: 1)
        XCTAssertEqual(match.offset.y, 183, accuracy: 1)
    }
    func testBlankImagesNeverProduceConfidentPlacement() {
        let blank = ImageProbe.solidImage(width: 160, height: 120).cgImage(forProposedRect: nil, context: nil, hints: nil)!
        XCTAssertNil(StitchAlignment.match(previous: blank, current: blank))
    }
    func testDuplicateTextureDetected() throws {
        let source = texture(width: 160, height: 120)
        let match = try XCTUnwrap(StitchAlignment.match(previous: source, current: source))
        XCTAssertEqual(match.offset, .zero)
    }
    func testBlurFadesAndPreviewKeepsAspectRatio() throws {
        var doc = StitchDocument(pieces: [StitchPiece(image: image())])
        XCTAssertTrue(doc.collapse(axis: .horizontal, from: 40, to: 60))
        doc.style.feather = 12
        let result = try XCTUnwrap(StitchRenderer.render(doc))
        XCTAssertEqual(result.width, 120); XCTAssertEqual(result.height, 80)
        let bitmap = NSBitmapImageRep(cgImage: result)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 10, y: 5)).blueComponent, 0.9)
        let preview = try XCTUnwrap(StitchRenderer.render(doc, maximumPreviewDimension: 60))
        XCTAssertEqual(preview.width, 60); XCTAssertEqual(preview.height, 40)
    }
}
