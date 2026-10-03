import CoreGraphics
import XCTest

final class StitchSelectionGuideGeometryTests: XCTestCase {
    private let screen = CGRect(x: -1200, y: 250, width: 1000, height: 800)
    private let anchor = CGRect(x: 0, y: 0, width: 400, height: 300)

    func testRetinaCropUsesGlobalScreenOriginAndTopDownSourcePixels() throws {
        let source = try XCTUnwrap(StitchCaptureSource.fromPixels(screenFrame: screen,
            pixelRect: CGRect(x: 200, y: 100, width: 400, height: 300),
            pixelsPerPoint: CGSize(width: 2, height: 2), scrollOffset: .zero))
        XCTAssertEqual(source.screenRect, CGRect(x: -1100, y: 850, width: 200, height: 150))
        XCTAssertEqual(source.estimatedPosition(referenceScale: 2), CGPoint(x: -2200, y: -2000))
        let result = guides(source: source)
        XCTAssertEqual(result.screenReferenceRect, CGRect(x: 100, y: 600, width: 200, height: 150))
        XCTAssertEqual(result.vertical.map(\.position), [100, 300])
        XCTAssertEqual(result.horizontal.map(\.position), [600, 750])
    }

    func testPixelAxesAreConvertedIndependentlyAndReferenceDensityDoesNotMoveTheCrop() throws {
        let source = try XCTUnwrap(StitchCaptureSource.fromPixels(screenFrame: screen,
            pixelRect: CGRect(x: 200, y: 75, width: 400, height: 225),
            pixelsPerPoint: CGSize(width: 2, height: 1.5), scrollOffset: .zero))
        XCTAssertEqual(source.screenRect, CGRect(x: -1100, y: 850, width: 200, height: 150))
        let lowDensity = StitchSelectionGuideGeometry.guides(frames: [CGRect(x: 0, y: 0, width: 200, height: 150)],
            anchor: CGRect(x: 0, y: 0, width: 200, height: 150), source: source, screenFrame: screen,
            scrollOffset: .zero)
        XCTAssertEqual(lowDensity, guides(source: source))
        let unevenDensity = CGRect(x: 0, y: 0, width: 400, height: 225)
        XCTAssertEqual(StitchSelectionGuideGeometry.guides(frames: [unevenDensity], anchor: unevenDensity,
            source: source, screenFrame: screen, scrollOffset: .zero), guides(source: source))
    }

    func testAnInitialSingleAxisDragStillHasAContentPositionForDimensionRecommendations() {
        let point = CGPoint(x: -1100, y: 1000)
        XCTAssertEqual(StitchCaptureSource.estimatedPosition(screenTopLeft: point,
            scrollOffset: CGPoint(x: 10, y: 80), referenceScale: 2), CGPoint(x: -2180, y: -1840))
        XCTAssertNil(StitchCaptureSource.estimatedPosition(screenTopLeft: CGPoint(x: CGFloat.infinity, y: 1000),
            scrollOffset: .zero, referenceScale: 2))
        XCTAssertNil(StitchCaptureSource.estimatedPosition(screenTopLeft: point,
            scrollOffset: .zero, referenceScale: 0))
    }

    func testPhysicalCropRemainsAvailableAfterContentScrollsOffscreenInEitherDirection() {
        let source = StitchCaptureSource(screenRect: CGRect(x: -1100, y: 850, width: 200, height: 150), scrollOffset: .zero)
        for offset in [CGPoint(x: 0, y: 1000), CGPoint(x: 0, y: -1000),
                       CGPoint(x: 1500, y: 0), CGPoint(x: -1500, y: 0)] {
            let result = guides(source: source, offset: offset)
            XCTAssertEqual(result.vertical.map(\.position), [100, 300])
            XCTAssertEqual(result.horizontal.map(\.position), [600, 750])
            XCTAssertTrue(result.vertical.allSatisfy(\.isScreenReference))
            XCTAssertTrue(result.horizontal.allSatisfy(\.isScreenReference))
        }
    }

    func testScrollProjectsLayoutWithCorrectFlipWithoutMovingPhysicalReference() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let source = StitchCaptureSource(screenRect: CGRect(x: 100, y: 220, width: 200, height: 150),
                                        scrollOffset: CGPoint(x: 30, y: 80))
        let result = StitchSelectionGuideGeometry.guides(frames: [anchor], anchor: anchor, source: source,
            screenFrame: screen, scrollOffset: CGPoint(x: 50, y: 140), pointer: CGPoint(x: 80, y: 425))
        XCTAssertEqual(result.vertical.filter(\.isScreenReference).map(\.position), [100, 300])
        XCTAssertEqual(result.horizontal.filter(\.isScreenReference).map(\.position), [220, 370])
        XCTAssertEqual(result.vertical.first(where: { !$0.isScreenReference })?.position, 80)
        XCTAssertEqual(result.horizontal.first(where: { !$0.isScreenReference })?.position, 430)
    }

    func testDocumentRegistrationUsesRelativeLayoutRatherThanAbsoluteDocumentOrigin() {
        let registeredAnchor = CGRect(x: 5000, y: -2000, width: 400, height: 300)
        let earlier = CGRect(x: 4800, y: -2000, width: 200, height: 300)
        let source = StitchCaptureSource(screenRect: CGRect(x: 100, y: 220, width: 200, height: 150), scrollOffset: .zero)
        let result = StitchSelectionGuideGeometry.guides(frames: [earlier, registeredAnchor], anchor: registeredAnchor,
            source: source, screenFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            scrollOffset: .zero, pointer: CGPoint(x: 7, y: 230))
        XCTAssertEqual(result.vertical.map(\.position), [100, 300, 0])
        XCTAssertEqual(result.horizontal.map(\.position), [220, 370])
    }

    func testOtherDisplaysReceiveOnlyRealVisibleLayoutEdgesAndNoClampedEdges() {
        let source = StitchCaptureSource(screenRect: CGRect(x: -1100, y: 850, width: 200, height: 150), scrollOffset: .zero)
        let otherScreen = CGRect(x: -2200, y: 250, width: 1000, height: 800)
        XCTAssertTrue(guides(source: source, screen: otherScreen).isEmpty)
        let result = guides(source: source,
            frames: [CGRect(x: -400, y: 0, width: 400, height: 300), anchor], screen: otherScreen)
        XCTAssertNil(result.screenReferenceRect)
        XCTAssertEqual(result.vertical.map(\.position), [900])
        XCTAssertEqual(result.horizontal.map(\.position), [600, 750])
        XCTAssertFalse(result.vertical.contains { $0.position == 1000 || $0.isScreenReference })
    }

    func testNearbyAlternativesAreRankedAndBoundedRatherThanAnEntireLayoutGrid() {
        let source = StitchCaptureSource(screenRect: CGRect(x: 80, y: 220, width: 120, height: 100), scrollOffset: .zero)
        let anchor = CGRect(x: 0, y: 0, width: 120, height: 100)
        let frames = (0..<20).map { CGRect(x: CGFloat($0 * 30), y: 0, width: 120, height: 100) }
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let result = StitchSelectionGuideGeometry.guides(frames: frames, anchor: anchor, source: source,
            screenFrame: screen, scrollOffset: .zero, pointer: CGPoint(x: 502, y: 250))
        XCTAssertEqual(result.vertical.map(\.position), [80, 200, 500])
        XCTAssertLessThanOrEqual(result.horizontal.count, 3)
        let capped = StitchSelectionGuideGeometry.guides(frames: frames, anchor: anchor, source: source,
            screenFrame: screen, scrollOffset: .zero, limitPerAxis: 100)
        XCTAssertEqual(capped.vertical.count, 4)
    }

    func testInvalidAndOffscreenTargetsCannotCreateFalseAlignments() {
        let source = StitchCaptureSource(screenRect: CGRect(x: -1100, y: 850, width: 200, height: 150), scrollOffset: .zero)
        for anchor in [CGRect.zero, CGRect.null, CGRect.infinite,
                       CGRect(x: 0, y: 0, width: -1, height: 100)] {
            XCTAssertTrue(StitchSelectionGuideGeometry.guides(frames: [anchor], anchor: anchor,
                source: source, screenFrame: screen, scrollOffset: .zero).isEmpty)
        }
        XCTAssertTrue(guides(source: source, offset: CGPoint(x: CGFloat.nan, y: 0)).isEmpty)
        XCTAssertTrue(guides(source: source, screen: .infinite).isEmpty)
        let finite = guides(source: source, frames: [.null, .infinite, CGRect(x: CGFloat.nan, y: 0, width: 20, height: 30), anchor])
        XCTAssertEqual(finite, guides(source: source))
        XCTAssertNil(StitchCaptureSource.fromPixels(screenFrame: screen, pixelRect: anchor,
            pixelsPerPoint: CGSize(width: 2, height: 0), scrollOffset: .zero))
        XCTAssertNil(StitchCaptureSource.fromPixels(screenFrame: screen, pixelRect: anchor,
            pixelsPerPoint: CGSize(width: CGFloat.infinity, height: 2), scrollOffset: .zero))
        XCTAssertNil(StitchCaptureSource.fromPixels(screenFrame: screen,
            pixelRect: CGRect(x: 2100, y: 0, width: 100, height: 100),
            pixelsPerPoint: CGSize(width: 2, height: 2), scrollOffset: .zero))
    }

    private func guides(source: StitchCaptureSource, frames: [CGRect]? = nil, screen: CGRect? = nil,
                        offset: CGPoint = .zero) -> StitchSelectionGuideGeometry.Result {
        StitchSelectionGuideGeometry.guides(frames: frames ?? [anchor], anchor: anchor, source: source,
            screenFrame: screen ?? self.screen, scrollOffset: offset)
    }
}
