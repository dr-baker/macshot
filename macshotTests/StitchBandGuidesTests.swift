import AppKit
import XCTest

final class StitchBandGuidesTests: XCTestCase {
    func testGeometryAvailableWithoutAnalysisPreservesCloseDistinctEdges() {
        var doc = document(width: 80, height: 100) { _, _ in true }
        var second = doc.pieces[0]
        second.id = UUID(); second.origin = CGPoint(x: 80.25, y: 100.25)
        doc.pieces.append(second)
        let geometry = StitchBandGuides.geometry(document: doc)
        XCTAssertEqual(geometry.rows, [0, 100, 100.25, 200.25])
        XCTAssertEqual(geometry.columns, [0, 80, 80.25, 160.25])
        XCTAssertEqual(StitchBandGuides.analyze(document: doc), geometry)
    }

    func testBlankRowsAndColumnsProduceOnlyGapEndpointsAndEdges() {
        let horizontal = document(width: 240, height: 200) { _, y in y >= 40 && y < 160 }
        XCTAssertEqual(StitchBandGuides.analyze(document: horizontal).rows, [0, 76, 124, 200])
        let vertical = document(width: 200, height: 240) { x, _ in x >= 40 && x < 160 }
        XCTAssertEqual(StitchBandGuides.analyze(document: vertical).columns, [0, 76, 124, 200])
    }

    func testNonuniformSparseMarksRejectAnOtherwiseBlankColoredGap() {
        let solid = document(width: 300, height: 220, background: [40, 90, 120, 255]) { _, y in y >= 50 && y < 170 }
        XCTAssertEqual(StitchBandGuides.analyze(document: solid).rows, [0, 86, 134, 220])
        let noisy = document(width: 300, height: 220, background: [40, 90, 120, 255], noise: true) { _, y in y >= 50 && y < 170 }
        XCTAssertEqual(StitchBandGuides.analyze(document: noisy).rows, [0, 220])
    }

    func testCropAndNegativeOriginMapBackIntoDocumentPixels() {
        var doc = document(width: 240, height: 240) { _, y in y >= 60 && y < 180 }
        doc.pieces[0].source = CGRect(x: 20, y: 40, width: 180, height: 160)
        doc.pieces[0].origin = CGPoint(x: -70, y: -100)
        let result = StitchBandGuides.analyze(document: doc)
        XCTAssertEqual(result.rows, [-100, -44, 4, 60])
        XCTAssertEqual(result.columns, [-70, 110])
    }

    func testTextLineWhitespaceIsSuppressedButSectionGapSurvives() {
        let doc = document(width: 300, height: 420) { _, y in
            (y >= 150 && y < 270) || y % 20 >= 12
        }
        let rows = StitchBandGuides.analyze(document: doc).rows
        XCTAssertEqual(rows, [0, 186, 234, 420])
    }

    func testHighDetailImageHasNoContentGuides() {
        let doc = document(width: 240, height: 200, textured: true) { _, _ in false }
        let result = StitchBandGuides.analyze(document: doc)
        XCTAssertEqual(result.rows, [0, 200])
        XCTAssertEqual(result.columns, [0, 240])
    }

    func testBudgetStillPreservesEveryGeometryEdgeAndLimitsContentCandidates() {
        let base = document(width: 160, height: 180) { _, y in y >= 60 && y < 110 }.pieces[0]
        var pieces: [StitchPiece] = []
        for index in 0..<128 {
            var piece = base
            piece.id = UUID()
            piece.origin = CGPoint(x: index * 200, y: index * 200)
            pieces.append(piece)
        }
        let result = StitchBandGuides.analyze(document: StitchDocument(pieces: pieces))
        for piece in pieces {
            XCTAssertTrue(result.rows.contains(piece.frame.minY))
            XCTAssertTrue(result.rows.contains(piece.frame.maxY))
        }
        XCTAssertLessThanOrEqual(result.rows.count, pieces.count * 2 + StitchBandGuides.maximumContentGapsPerAxis * 2)
    }

    func testLargeImageSamplingReturnsSourcePixelCoordinates() {
        let doc = document(width: 1000, height: 2000) { _, y in y >= 700 && y < 1100 }
        let rows = StitchBandGuides.analyze(document: doc).rows
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.first, 0)
        XCTAssertEqual(rows.last, 2000)
        guard rows.count == 4 else { return }
        // Discovery, boundary erosion, and integral native validation may each
        // consume a sampled pixel. The seam must still retain its full padding.
        let padding = StitchBandGuides.contentPadding(document: doc)
        let maximumSamplingInset = ceil(3 * 2000 / CGFloat(StitchBandGuides.maximumSampleDimension)) + 1
        XCTAssertGreaterThanOrEqual(rows[1], 700 + padding)
        XCTAssertLessThanOrEqual(rows[1], 700 + padding + maximumSamplingInset)
        XCTAssertLessThanOrEqual(rows[2], 1100 - padding)
        XCTAssertGreaterThanOrEqual(rows[2], 1100 - padding - maximumSamplingInset)
    }

    func testGapPaddingTracksVisibleBlurAndRejectsTooNarrowWhitespace() {
        var doc = document(width: 240, height: 240) { _, y in y >= 60 && y < 180 }
        XCTAssertEqual(StitchBandGuides.contentPadding(document: doc), 36)
        XCTAssertEqual(StitchBandGuides.analyze(document: doc).rows, [0, 96, 144, 240])
        doc.style.feather = 120
        XCTAssertEqual(StitchBandGuides.contentPadding(document: doc), 64)
        XCTAssertEqual(StitchBandGuides.analyze(document: doc).rows, [0, 240])
        doc.style.visible = false
        XCTAssertEqual(StitchBandGuides.contentPadding(document: doc), 16)
        XCTAssertEqual(StitchBandGuides.analyze(document: doc).rows, [0, 76, 164, 240])
        doc.style.visible = true; doc.style.blur = 0
        XCTAssertEqual(StitchBandGuides.contentPadding(document: doc), 16)
    }

    func testLocalGapCannotSuggestFullWidthCutThroughNeighborText() {
        var left = document(width: 240, height: 240) { _, y in y >= 60 && y < 180 }
        var right = document(width: 240, height: 240) { _, _ in false }.pieces[0]
        right.origin.x = 240
        left.pieces.append(right)
        XCTAssertEqual(StitchBandGuides.analyze(document: left).rows, [0, 240])
        left.pieces[1] = left.pieces[0]
        left.pieces[1].id = UUID(); left.pieces[1].origin.x = 240
        XCTAssertEqual(StitchBandGuides.analyze(document: left).rows, [0, 96, 144, 240])
    }

    func testLocalColumnGapCannotCutTextInVerticallyAdjacentPiece() {
        var upper = document(width: 240, height: 240) { x, _ in x >= 60 && x < 180 }
        var lower = document(width: 240, height: 240) { _, _ in false }.pieces[0]
        lower.origin.y = 240
        upper.pieces.append(lower)
        XCTAssertEqual(StitchBandGuides.analyze(document: upper).columns, [0, 240])
    }

    func testUnanalyzedIntersectingPieceSuppressesContentGuides() {
        let base = document(width: 768, height: 768) { _, y in y >= 200 && y < 500 }.pieces[0]
        let pieces = (0..<4).map { index -> StitchPiece in
            var piece = base
            piece.id = UUID(); piece.origin.x = CGFloat(index * 768)
            return piece
        }
        // Three samples consume most of the budget; the fourth piece remains unknown.
        XCTAssertEqual(StitchBandGuides.analyze(document: StitchDocument(pieces: pieces)).rows, [0, 768])
    }

    private func document(width: Int, height: Int, background: [UInt8] = [245, 245, 245, 255],
                          noise: Bool = false, textured: Bool = false,
                          blank: (Int, Int) -> Bool) -> StitchDocument {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value: [UInt8]
                if blank(x, y) { value = noise && x == width / 2 ? [0, 0, 0, 255] : background }
                else if textured { value = [UInt8((x * 31 + y * 17) % 220), UInt8((x * 13 + y * 37) % 220), 0, 255] }
                else { value = (x + y) % 16 < 8 ? [15, 15, 15, 255] : background }
                bytes.replaceSubrange((y * width + x) * 4..<(y * width + x + 1) * 4, with: value)
            }
        }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return StitchDocument(pieces: [StitchPiece(image: image)])
    }
}
