import CoreGraphics
import XCTest

final class StitchSelectionRecommendationsTests: XCTestCase {
    func testIdleUsesRecentCaptureAndKeepsBothAxesAvailable() {
        let result = recommend([rect(0, 0, 100, 80), rect(100, 0, 140, 90)])
        XCTAssertEqual(result.widths.first?.value, 140)
        XCTAssertEqual(result.heights.first?.value, 90)
        XCTAssertTrue(result.widths.contains { $0.value == 240 && $0.reason == .row })
        XCTAssertTrue(result.widths.contains { $0.value == 100 })
    }

    func testVerticalContinuationRanksNearbyColumnOverRecentUnrelatedCapture() {
        let frames = [rect(0, 0, 160, 100), rect(0, 100, 160, 120), rect(700, 0, 350, 90)]
        let result = recommend(frames, origin: CGPoint(x: 0, y: 220))
        XCTAssertEqual(result.widths.first?.value, 160)
        XCTAssertEqual(result.widths.first?.reason, .column)
        XCTAssertTrue(result.heights.contains { $0.value == 220 && $0.reason == .column })
        XCTAssertTrue(result.widths.contains { $0.value == 350 })
    }

    func testHorizontalContinuationRanksRowHeightAndRetainsOtherWidths() {
        let frames = [rect(0, 0, 100, 160), rect(100, 0, 120, 160), rect(0, 700, 90, 350)]
        let result = recommend(frames, origin: CGPoint(x: 220, y: 0))
        XCTAssertEqual(result.heights.first?.value, 160)
        XCTAssertEqual(result.heights.first?.reason, .row)
        XCTAssertTrue(result.widths.contains { $0.value == 220 && $0.reason == .row })
        XCTAssertTrue(result.heights.contains { $0.value == 350 })
    }

    func testChangingProposedOriginChangesNearestColumnAndRowRecommendations() {
        let frames = [rect(0, 0, 100, 80), rect(500, 500, 200, 140)]
        let nearFirst = recommend(frames, origin: CGPoint(x: 0, y: 80))
        let nearSecond = recommend(frames, origin: CGPoint(x: 500, y: 640))
        XCTAssertEqual(nearFirst.widths.first?.value, 100)
        XCTAssertEqual(nearSecond.widths.first?.value, 200)
        XCTAssertEqual(recommend(frames, origin: CGPoint(x: 100, y: 0)).heights.first?.value, 80)
        XCTAssertEqual(recommend(frames, origin: CGPoint(x: 700, y: 500)).heights.first?.value, 140)
    }

    func testContiguousRowsAndColumnsMergeButGapsDoNot() {
        let row = [rect(0, 0, 100, 80), rect(100, 0, 60, 80), rect(161, 0, 40, 80)]
        let widths = recommend(row).widths.map(\.value)
        XCTAssertTrue(widths.contains(160))
        XCTAssertFalse(widths.contains(201))
        let column = row.map { rect($0.minY, $0.minX, $0.height, $0.width) }
        let heights = recommend(column).heights.map(\.value)
        XCTAssertTrue(heights.contains(160))
        XCTAssertFalse(heights.contains(201))
    }

    func testOverlapsUseUnionLengthAndZigzagCannotInventFullSpan() {
        let overlap = recommend([rect(0, 0, 100, 80), rect(60, 0, 100, 80)])
        XCTAssertTrue(overlap.widths.contains { $0.value == 160 })
        XCTAssertFalse(overlap.widths.contains { $0.value == 200 })
        let zigzag = recommend([rect(0, 0, 100, 100), rect(100, 50, 100, 100), rect(200, 100, 100, 100)])
        XCTAssertTrue(zigzag.widths.contains { $0.value == 200 })
        XCTAssertFalse(zigzag.widths.contains { $0.value == 300 })
    }

    func testPreferredCaptureAndReverseContinuationWorkWithNegativeCoordinates() {
        let frames = [rect(-250, -100, 150, 90), rect(300, 400, 220, 130)]
        XCTAssertEqual(recommend(frames, preferred: 0).widths.first?.value, 150)
        XCTAssertEqual(recommend(frames, origin: CGPoint(x: -250, y: -250), preferred: 0).widths.first?.value, 150)
        XCTAssertEqual(recommend(frames, origin: CGPoint(x: -400, y: -100), preferred: 0).heights.first?.value, 90)
    }

    func testDeduplicationBoundsAndInvalidGeometry() {
        let repeated = recommend([rect(0, 0, 100, 80), rect(0, 80, 100.2, 80.2)])
        XCTAssertEqual(repeated.widths.filter { abs($0.value - 100) < 0.5 }.count, 1)
        var many: [CGRect] = []
        for index in 0..<30 {
            let value = CGFloat(index)
            many.append(rect(value * 1000, 0, 100 + value, 80 + value))
        }
        XCTAssertEqual(recommend(many).widths.count, 4)
        XCTAssertEqual(StitchSelectionRecommendations.recommendations(frames: many, limitPerAxis: 100).widths.count, 8)
        XCTAssertTrue(StitchSelectionRecommendations.recommendations(frames: many, limitPerAxis: 0).widths.isEmpty)
        let invalid = [CGRect.zero, CGRect.null, CGRect.infinite, rect(0, 0, -1, 2)]
        XCTAssertTrue(recommend(invalid).widths.isEmpty)
        XCTAssertEqual(recommend(invalid + [rect(0, 0, 120, 75)], preferred: 1).widths.first?.value, 120)
        XCTAssertEqual(recommend([rect(0, 0, 120, 75)], origin: CGPoint(x: CGFloat.nan, y: 0)).widths.first?.value, 120)
    }

    func testScalingPreservesRankReasonsAndRejectsInvalidFactors() {
        let source = recommend([rect(0, 0, 100, 80), rect(100, 0, 140, 90)])
        let scaled = source.scaled(by: 0.5)
        XCTAssertEqual(scaled.widths.map(\.value), source.widths.map { $0.value / 2 })
        XCTAssertEqual(scaled.heights.map(\.value), source.heights.map { $0.value / 2 })
        XCTAssertEqual(scaled.widths.map(\.reason), source.widths.map(\.reason))
        XCTAssertEqual(scaled.heights.map(\.reason), source.heights.map(\.reason))
        for factor: CGFloat in [0, -1, .nan, .infinity] {
            XCTAssertTrue(source.scaled(by: factor).widths.isEmpty)
            XCTAssertTrue(source.scaled(by: factor).heights.isEmpty)
        }
        XCTAssertTrue(source.scaled(by: .greatestFiniteMagnitude).widths.isEmpty)
    }

    func testMaximumFiltersBeforeLimitSoOlderFittingDimensionsRemainAvailable() {
        let frames = [rect(0, -2000, 60, 70), rect(0, -1000, 80, 90),
                      rect(0, 0, 200, 210), rect(0, 0, 220, 230),
                      rect(0, 0, 240, 250), rect(0, 0, 260, 270)]
        XCTAssertTrue(recommend(frames).widths.allSatisfy { $0.value > 100 })
        let fitting = StitchSelectionRecommendations.recommendations(frames: frames,
            maximumSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(fitting.widths.map(\.value), [80, 60])
        XCTAssertEqual(fitting.heights.map(\.value), [90, 70])
        let exact = StitchSelectionRecommendations.recommendations(frames: frames,
            maximumSize: CGSize(width: 80, height: 70))
        XCTAssertEqual(exact.widths.map(\.value), [80, 60])
        XCTAssertEqual(exact.heights.map(\.value), [70])
    }

    func testMaximumAxesAreIndependentAndNonfiniteLimitsAreUnbounded() {
        let frames = [rect(0, 0, 120, 80)]
        let result = StitchSelectionRecommendations.recommendations(frames: frames,
            maximumSize: CGSize(width: 0, height: CGFloat.infinity))
        XCTAssertTrue(result.widths.isEmpty)
        XCTAssertEqual(result.heights.map(\.value), [80])
        let other = StitchSelectionRecommendations.recommendations(frames: frames,
            maximumSize: CGSize(width: CGFloat.nan, height: -1))
        XCTAssertEqual(other.widths.map(\.value), [120])
        XCTAssertTrue(other.heights.isEmpty)
    }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
    private func recommend(_ frames: [CGRect], origin: CGPoint? = nil, preferred: Int? = nil) -> StitchSelectionRecommendations.Result {
        StitchSelectionRecommendations.recommendations(frames: frames, proposedOrigin: origin, preferredIndex: preferred)
    }
}
