import AppKit
import XCTest

@MainActor
final class StitchTrimProvenanceTests: XCTestCase {
    func testBothAxesRecordActualRemovedDistanceWithoutRetainingRemovedSlices() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = try singleCapture()
            XCTAssertTrue(document.collapse(axis: axis, from: 90, to: 110))
            let join = try XCTUnwrap(document.joins.first)
            XCTAssertEqual(join.trimmedLength, 20)
            XCTAssertEqual(document.pieces.count, 2)
            XCTAssertEqual(document.pieces.flatMap(\.trimStamps).count, 2)
            for piece in document.pieces {
                XCTAssertTrue(piece.hasValidTrimStamps)
                let low = axis == .horizontal ? piece.source.minY : piece.source.minX
                let high = axis == .horizontal ? piece.source.maxY : piece.source.maxX
                XCTAssertTrue(high <= 90 || low >= 110)
            }
            document.style.accordionWidth = 0
            XCTAssertTrue(document.hasAccordionFolds)
        }
    }

    func testIndependentCapturesKeepCumulativeDistanceAcrossTheirOriginalContact() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = try independentCaptures(axis: axis)
            XCTAssertNil(try XCTUnwrap(document.joins.first).trimmedLength)
            XCTAssertTrue(document.collapse(axis: axis, from: 90, to: 110))
            XCTAssertEqual(try XCTUnwrap(document.joins.first).trimmedLength, 20)
            XCTAssertTrue(document.collapse(axis: axis, from: 80, to: 100))
            XCTAssertEqual(try XCTUnwrap(document.joins.first).trimmedLength, 40)
            XCTAssertEqual(document.pieces.count, 2)
            XCTAssertNotEqual(document.pieces[0].lineageID, document.pieces[1].lineageID)
        }
    }

    func testCutsBeginningAndEndingAtPriorSeamAbsorbItsOmittedLength() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            for nextBand in [(CGFloat(80), CGFloat(90)), (CGFloat(90), CGFloat(100))] {
                var document = try independentCaptures(axis: axis)
                XCTAssertTrue(document.collapse(axis: axis, from: 90, to: 110))
                XCTAssertTrue(document.collapse(axis: axis, from: nextBand.0, to: nextBand.1))
                XCTAssertEqual(try XCTUnwrap(document.joins.first).trimmedLength, 30)
            }
        }
    }

    func testDisjointCutsStaySeparateAndACrossingCutAccumulatesBoth() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = try singleCapture()
            XCTAssertTrue(document.collapse(axis: axis, from: 90, to: 110))
            XCTAssertTrue(document.collapse(axis: axis, from: 150, to: 170))
            XCTAssertEqual(document.joins.count, 2)
            XCTAssertTrue(document.joins.allSatisfy { $0.trimmedLength == 20 })
            XCTAssertTrue(document.collapse(axis: axis, from: 80, to: 160))
            XCTAssertEqual(try XCTUnwrap(document.joins.first).trimmedLength, 120)
            XCTAssertEqual(document.joins.count, 1)
        }
    }

    func testRemovingAboveASeamMovesItsStampWithTheSurvivingEdge() throws {
        var document = try singleCapture()
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 90, to: 110))
        let firstCut = try XCTUnwrap(document.pieces.first?.trimStamps.first?.cutID)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 20, to: 40))
        let joins = document.joins.sorted { $0.position < $1.position }
        XCTAssertEqual(joins.map(\.position), [20, 70])
        XCTAssertEqual(joins.map(\.trimmedLength), [20, 20])
        XCTAssertEqual(document.pieces.flatMap(\.trimStamps).filter { $0.cutID == firstCut }.count, 2)
    }

    func testCoincidentContactRecordsDoNotDoubleCountCrossedSeams() throws {
        let imageA = try image(width: 120, height: 100)
        let imageB = try image(width: 120, height: 100)
        var document = StitchDocument(pieces: [
            StitchPiece(image: imageA), StitchPiece(image: imageA),
            StitchPiece(image: imageB, origin: CGPoint(x: 0, y: 100)),
            StitchPiece(image: imageB, origin: CGPoint(x: 0, y: 100))
        ])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 90, to: 110))
        XCTAssertEqual(document.joins.count, 4)
        XCTAssertTrue(document.joins.allSatisfy { $0.trimmedLength == 20 })
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 80, to: 100))
        XCTAssertEqual(document.joins.count, 4)
        XCTAssertTrue(document.joins.allSatisfy { $0.trimmedLength == 40 })
        XCTAssertTrue(document.pieces.allSatisfy { $0.trimStamps.count == 1 })
    }

    func testCumulativeLengthIsPartitionedAcrossPartialPriorSeams() throws {
        var left = StitchDocument(pieces: [StitchPiece(image: try image(width: 100, height: 200))])
        XCTAssertTrue(left.collapse(axis: .horizontal, from: 90, to: 110))
        let right = StitchPiece(image: try image(width: 100, height: 180), origin: CGPoint(x: 100, y: 0))
        let rightTop = right.slice(CGRect(x: 100, y: 0, width: 100, height: 90), shift: .zero)
        let rightBottom = right.slice(CGRect(x: 100, y: 90, width: 100, height: 90), shift: .zero)
        var document = StitchDocument(pieces: left.pieces + [rightTop, rightBottom])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 80, to: 100))
        let joins = document.joins.filter { $0.axis == .horizontal }.sorted { $0.start < $1.start }
        XCTAssertEqual(joins.count, 2)
        XCTAssertEqual(joins[0].start, 0)
        XCTAssertEqual(joins[0].end, 100)
        XCTAssertEqual(joins[0].trimmedLength, 40)
        XCTAssertEqual(joins[1].start, 100)
        XCTAssertEqual(joins[1].end, 200)
        XCTAssertEqual(joins[1].trimmedLength, 20)
    }

    func testPairContactPartitionsOnlyTheMatchingStampedInterval() throws {
        var document = try independentCaptures(axis: .horizontal)
        let id = UUID()
        document.pieces[0].trimStamps = [StitchTrimStamp(cutID: id, edge: .bottom,
            start: 10, end: 70, removedLength: 30)]
        document.pieces[1].trimStamps = [StitchTrimStamp(cutID: id, edge: .top,
            start: 10, end: 70, removedLength: 30)]
        XCTAssertEqual(document.joins.count, 3)
        XCTAssertEqual(document.joins.map(\.start), [0, 10, 70])
        XCTAssertEqual(document.joins.map(\.end), [10, 70, 120])
        XCTAssertEqual(document.joins.map(\.trimmedLength), [nil, 30, nil])
        document.style.transition = .accordion
        document.style.accordionWidth = 0
        XCTAssertTrue(document.hasAccordionFolds)
    }

    func testCrossAxisCutsClipOlderStampsWithoutAddingTheirLengthToTheNewAxis() throws {
        var document = try singleCapture()
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 90, to: 110))
        XCTAssertTrue(document.collapse(axis: .vertical, from: 100, to: 130))
        XCTAssertEqual(document.pieces.count, 4)
        let horizontal = document.joins.filter { $0.axis == .horizontal }
        let vertical = document.joins.filter { $0.axis == .vertical }
        XCTAssertEqual(horizontal.count, 2)
        XCTAssertEqual(vertical.count, 2)
        XCTAssertTrue(horizontal.allSatisfy { $0.trimmedLength == 20 })
        XCTAssertTrue(vertical.allSatisfy { $0.trimmedLength == 30 })
        XCTAssertTrue(document.pieces.allSatisfy(\.hasValidTrimStamps))
    }

    func testSlicingClipsTangentsAndDropsStampOnNewInteriorSourceEdges() throws {
        var piece = StitchPiece(image: try image(width: 100, height: 100))
        piece.trimStamps = StitchTrimStamp.Edge.allCases.map {
            StitchTrimStamp(cutID: UUID(), edge: $0, start: 0, end: 100, removedLength: 20)
        }
        let sliced = piece.slice(CGRect(x: 20, y: 0, width: 60, height: 50), shift: .zero)
        XCTAssertEqual(sliced.trimStamps.count, 1)
        let stamp = try XCTUnwrap(sliced.trimStamps.first)
        XCTAssertEqual(stamp.edge, .top)
        XCTAssertEqual(stamp.start, 20)
        XCTAssertEqual(stamp.end, 80)
        XCTAssertEqual(stamp.removedLength, 20)
        XCTAssertTrue(sliced.hasValidTrimStamps)
    }

    func testFlipsAndCropPreserveSourceMappingAcrossDifferentCaptureSizes() throws {
        var original = StitchDocument(pieces: [
            StitchPiece(image: try image(width: 100, height: 100), origin: CGPoint(x: 20, y: 0)),
            StitchPiece(image: try image(width: 150, height: 100), origin: CGPoint(x: 0, y: 100))
        ])
        original.style.transition = .accordion
        XCTAssertTrue(original.collapse(axis: .horizontal, from: 90, to: 110))
        XCTAssertEqual(try XCTUnwrap(original.joins.first).trimmedLength, 20)
        for horizontal in [true, false] {
            let mirrored = try XCTUnwrap(original.flipped(horizontal: horizontal))
            XCTAssertEqual(try XCTUnwrap(mirrored.joins.first).trimmedLength, 20)
            XCTAssertTrue(mirrored.pieces.allSatisfy(\.hasValidTrimStamps))
            let twice = try XCTUnwrap(mirrored.flipped(horizontal: horizontal))
            XCTAssertEqual(twice.pieces.map(\.trimStamps), original.pieces.map(\.trimStamps))
        }
        let cropped = try XCTUnwrap(original.cropped(to: CGRect(x: 30, y: 10, width: 70, height: 140)))
        let join = try XCTUnwrap(cropped.joins.first)
        XCTAssertEqual(join.position, 80)
        XCTAssertEqual(join.start, 0)
        XCTAssertEqual(join.end, 70)
        XCTAssertEqual(join.trimmedLength, 20)
        XCTAssertTrue(cropped.pieces.allSatisfy(\.hasValidTrimStamps))
        let withoutSeam = try XCTUnwrap(original.cropped(to: CGRect(x: 30, y: 0, width: 70, height: 80)))
        XCTAssertTrue(withoutSeam.pieces.flatMap(\.trimStamps).isEmpty)
        XCTAssertFalse(withoutSeam.hasAccordionFolds)
    }

    func testHistoryRoundTripPreservesIndependentCaptureCutAndItsCumulativeLength() throws {
        var document = try independentCaptures(axis: .horizontal)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 90, to: 110))
        let saved = try XCTUnwrap(SavedStitchDocument(document))
        let decoded = try JSONDecoder().decode(SavedStitchDocument.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(saved, decoded)
        var restored = try XCTUnwrap(decoded.restore())
        XCTAssertEqual(restored.pieces.map(\.trimStamps), document.pieces.map(\.trimStamps))
        XCTAssertEqual(try XCTUnwrap(restored.joins.first).trimmedLength, 20)
        XCTAssertTrue(restored.collapse(axis: .horizontal, from: 80, to: 100))
        XCTAssertEqual(try XCTUnwrap(restored.joins.first).trimmedLength, 40)
    }

    func testOlderUnstampedSameSourceHistoryInfersGapAndIndependentHistoryStaysUnknown() throws {
        for independent in [false, true] {
            var document = try (independent ? independentCaptures(axis: .horizontal) : singleCapture())
            XCTAssertTrue(document.collapse(axis: .horizontal, from: 90, to: 110))
            let saved = try XCTUnwrap(SavedStitchDocument(document))
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
            var pieces = try XCTUnwrap(json["pieces"] as? [[String: Any]])
            for index in pieces.indices { pieces[index].removeValue(forKey: "trimStamps") }
            json["pieces"] = pieces
            let old = try JSONDecoder().decode(SavedStitchDocument.self,
                from: JSONSerialization.data(withJSONObject: json))
            let restored = try XCTUnwrap(old.restore())
            XCTAssertTrue(restored.pieces.flatMap(\.trimStamps).isEmpty)
            XCTAssertEqual(try XCTUnwrap(restored.joins.first).trimmedLength, independent ? nil : 20)
        }
    }

    func testSourceGapInferenceRequiresLineageImageAlignmentAndNonnegativeGap() throws {
        let original = StitchPiece(image: try image(width: 120, height: 200))
        let before = original.slice(CGRect(x: 0, y: 0, width: 120, height: 80), shift: .zero)
        var after = original.slice(CGRect(x: 0, y: 120, width: 120, height: 80), shift: CGPoint(x: 0, y: -40))
        var document = StitchDocument(pieces: [before, after])
        XCTAssertEqual(try XCTUnwrap(document.joins.first).trimmedLength, 40)
        after.origin.x = 1
        document.pieces = [before, after]
        XCTAssertNil(try XCTUnwrap(document.joins.first).trimmedLength)
        after.origin.x = 0
        after.lineageID = UUID()
        document.pieces = [before, after]
        XCTAssertNil(try XCTUnwrap(document.joins.first).trimmedLength)
        var upper = original.slice(CGRect(x: 0, y: 100, width: 120, height: 100), shift: CGPoint(x: 0, y: -100))
        var lower = original.slice(CGRect(x: 0, y: 0, width: 120, height: 100), shift: CGPoint(x: 0, y: 100))
        document.pieces = [upper, lower]
        XCTAssertNil(try XCTUnwrap(document.joins.first).trimmedLength)
        upper = original.slice(CGRect(x: 0, y: 0, width: 120, height: 100), shift: .zero)
        lower = original.slice(CGRect(x: 0, y: 100, width: 120, height: 100), shift: .zero)
        document.pieces = [upper, lower]
        document.style.transition = .accordion
        XCTAssertEqual(try XCTUnwrap(document.joins.first).trimmedLength, 0)
        XCTAssertFalse(document.hasAccordionFolds)
    }

    func testMovedOrReorderedStampedFacesCannotBorrowAnUnmatchedCut() throws {
        var first = try independentCaptures(axis: .horizontal)
        XCTAssertTrue(first.collapse(axis: .horizontal, from: 90, to: 110))
        first.pieces[1].origin.x += 10
        XCTAssertNil(try XCTUnwrap(first.joins.first).trimmedLength)
        first.pieces[0].origin.x += 10
        XCTAssertEqual(try XCTUnwrap(first.joins.first).trimmedLength, 20)
        var second = try independentCaptures(axis: .horizontal)
        XCTAssertTrue(second.collapse(axis: .horizontal, from: 90, to: 110))
        var mismatched = second.pieces[1]
        mismatched.origin = CGPoint(x: 10, y: 90)
        let reordered = StitchDocument(pieces: [first.pieces[0], mismatched])
        XCTAssertNil(try XCTUnwrap(reordered.joins.first).trimmedLength)
        var altered = first
        altered.pieces[1].trimStamps[0].removedLength += 1
        XCTAssertNil(try XCTUnwrap(altered.joins.first).trimmedLength)
        XCTAssertFalse(first.isIdentical(to: altered))
    }

    func testHistoryRejectsInvalidLengthsIntervalsMappingsAndStampCounts() throws {
        var document = try independentCaptures(axis: .horizontal)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 90, to: 110))
        let saved = try XCTUnwrap(SavedStitchDocument(document))
        let valid = try XCTUnwrap(saved.pieces[0].trimStamps.first)
        for length in [CGFloat(-1), 0, .nan, .infinity] {
            var invalid = saved
            invalid.pieces[0].trimStamps[0].removedLength = length
            XCTAssertNil(invalid.restore())
        }
        for interval in [(CGFloat(-1), CGFloat(120)), (0, 121), (50, 50), (90, 70), (.nan, 100)] {
            var invalid = saved
            invalid.pieces[0].trimStamps[0].start = interval.0
            invalid.pieces[0].trimStamps[0].end = interval.1
            XCTAssertNil(invalid.restore())
        }
        var invalid = saved
        invalid.pieces[0].trimStamps[0].tangentOffset = .infinity
        XCTAssertNil(invalid.restore())
        invalid = saved
        invalid.pieces[0].trimStamps[0].edge = .left
        XCTAssertNil(invalid.restore(), "The 120px interval exceeds this piece's 90px left edge")
        invalid = saved
        invalid.pieces[0].trimStamps = Array(repeating: valid, count: StitchPiece.maximumTrimStamps + 1)
        XCTAssertNil(invalid.restore())
        invalid = saved
        invalid.pieces = (0..<(StitchDocument.maximumTrimStamps / StitchPiece.maximumTrimStamps + 1)).map { _ in
            var piece = saved.pieces[0]
            piece.id = UUID()
            piece.trimStamps = Array(repeating: valid, count: StitchPiece.maximumTrimStamps)
            return piece
        }
        XCTAssertNil(invalid.restore())
    }

    func testMalformedHistoryStampArrayFailsDecoding() throws {
        var document = try independentCaptures(axis: .horizontal)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 90, to: 110))
        let saved = try XCTUnwrap(SavedStitchDocument(document))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var pieces = try XCTUnwrap(json["pieces"] as? [[String: Any]])
        pieces[0]["trimStamps"] = "invalid geometry"
        json["pieces"] = pieces
        XCTAssertThrowsError(try JSONDecoder().decode(SavedStitchDocument.self,
            from: JSONSerialization.data(withJSONObject: json)))
    }

    func testAccordionEligibilityHonorsKnownZeroUnknownAndPositiveCutLengths() throws {
        var unknown = try independentCaptures(axis: .horizontal)
        unknown.style.transition = .accordion
        XCTAssertTrue(unknown.hasAccordionFolds)
        unknown.style.accordionWidth = 0
        XCTAssertFalse(unknown.hasAccordionFolds)
        XCTAssertTrue(unknown.collapse(axis: .horizontal, from: 90, to: 110))
        XCTAssertTrue(unknown.hasAccordionFolds)
        unknown.style.visible = false
        XCTAssertFalse(unknown.hasAccordionFolds)
        unknown.style.visible = true
        unknown.style.transition = .wave
        XCTAssertFalse(unknown.hasAccordionFolds)
    }

    func testValidPathologicalOverlappingContactsFailBeforeStampSubdivision() throws {
        let pixels = try image(width: 512, height: 8)
        let ids = (0..<512).map { _ in UUID() }
        var document = StitchDocument(pieces: (0..<32).map { index in
            let upper = index < 16
            var piece = StitchPiece(image: pixels, origin: CGPoint(x: 0, y: upper ? 0 : 8))
            piece.trimStamps = (0..<512).map { offset in
                StitchTrimStamp(cutID: ids[offset], edge: upper ? .bottom : .top,
                    start: CGFloat(offset), end: CGFloat(offset + 1), removedLength: 20)
            }
            return piece
        })
        document.style.transition = .accordion
        XCTAssertTrue(document.pieces.allSatisfy(\.hasValidTrimStamps))
        XCTAssertEqual(document.pieces.reduce(0) { $0 + $1.trimStamps.count }, StitchDocument.maximumTrimStamps)
        let started = CFAbsoluteTimeGetCurrent()
        XCTAssertFalse(document.canRender)
        XCTAssertTrue(document.joins.isEmpty)
        XCTAssertFalse(document.hasAccordionFolds)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - started, 1,
                          "Reject before expanding hundreds of thousands of contacts")
        XCTAssertNil(SavedStitchDocument(document))
    }

    func testOrdinaryRichProvenanceStillPreparesAndRestoresEveryContact() throws {
        let pixels = try image(width: 256, height: 20)
        let ids = (0..<64).map { _ in UUID() }
        var pieces: [StitchPiece] = []
        for index in 0..<2 {
            var piece = StitchPiece(image: pixels, origin: CGPoint(x: 0, y: CGFloat(index * 20)))
            let edge: StitchTrimStamp.Edge = index == 0 ? .bottom : .top
            for offset in 0..<64 {
                let start = CGFloat(offset * 4)
                let end = CGFloat((offset + 1) * 4)
                let length = CGFloat(20 + offset % 3)
                let stamp = StitchTrimStamp(cutID: ids[offset], edge: edge,
                                           start: start, end: end, removedLength: length)
                piece.trimStamps.append(stamp)
            }
            pieces.append(piece)
        }
        var document = StitchDocument(pieces: pieces)
        document.style.transition = .accordion
        document.style.accordionWidth = 0
        XCTAssertTrue(document.canRender)
        XCTAssertTrue(document.hasAccordionFolds)
        XCTAssertEqual(document.joins.count, 64)
        let expected: [CGFloat?] = (0..<64).map { CGFloat(20 + $0 % 3) }
        XCTAssertEqual(document.joins.map(\.trimmedLength), expected)
        let saved = try XCTUnwrap(SavedStitchDocument(document))
        let restored = try XCTUnwrap(saved.restore())
        XCTAssertTrue(restored.canRender)
        XCTAssertEqual(restored.joins.map(\.trimmedLength), document.joins.map(\.trimmedLength))
    }

    func testUnstampedContactFanoutHasABoundedPreparationPathToo() throws {
        let pixels = try image(width: 120, height: 8)
        var document = StitchDocument(pieces: (0..<64).map { index in
            StitchPiece(image: pixels, origin: CGPoint(x: 0, y: index < 32 ? 0 : 8))
        })
        document.style.transition = .accordion
        XCTAssertTrue(document.pieces.allSatisfy { $0.trimStamps.isEmpty })
        XCTAssertFalse(document.canRender)
        XCTAssertTrue(document.joins.isEmpty)
        XCTAssertFalse(document.hasAccordionFolds)
        document.pieces = Array(document.pieces.prefix(StitchDocument.maximumPieces))
        document.pieces += Array(repeating: document.pieces[0], count: StitchDocument.maximumPieces)
        XCTAssertFalse(document.canRender)
        XCTAssertTrue(document.joins.isEmpty)
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        try XCTUnwrap(ImageProbe.solidImage(width: width, height: height)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private func singleCapture() throws -> StitchDocument {
        var document = StitchDocument(pieces: [StitchPiece(image: try image(width: 300, height: 300))])
        document.style.transition = .accordion
        return document
    }

    private func independentCaptures(axis: StitchAxis) throws -> StitchDocument {
        let horizontal = axis == .horizontal
        let first = try image(width: horizontal ? 120 : 100, height: horizontal ? 100 : 120)
        let second = try image(width: horizontal ? 120 : 100, height: horizontal ? 100 : 120)
        var document = StitchDocument(pieces: [StitchPiece(image: first),
            StitchPiece(image: second, origin: horizontal ? CGPoint(x: 0, y: 100) : CGPoint(x: 100, y: 0))])
        document.style.transition = .accordion
        return document
    }
}
