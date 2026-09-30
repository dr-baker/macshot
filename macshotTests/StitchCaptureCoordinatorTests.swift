import AppKit
import XCTest

@MainActor
final class StitchCaptureCoordinatorTests: XCTestCase {
    func testSecondAndThirdCapturesUseLatestAcceptedImageAndAccumulateOffsets() throws {
        let fixture = Fixture(first: image())
        let second = image(), third = image()
        fixture.coordinator.requestCapture()
        fixture.captures[0](second)
        XCTAssertTrue(fixture.coordinator.busy)
        fixture.analyses[0].complete(false, match(x: 3, y: 15))
        XCTAssertFalse(fixture.coordinator.busy)

        fixture.coordinator.requestCapture()
        fixture.captures[1](third)
        XCTAssertTrue(fixture.analyses[1].previous === second)
        XCTAssertTrue(fixture.analyses[1].current === third)
        fixture.analyses[1].complete(false, match(x: -2, y: 18))
        XCTAssertEqual(fixture.coordinator.document.pieces.map(\.origin),
                       [.zero, CGPoint(x: 3, y: 15), CGPoint(x: 1, y: 33)])
        XCTAssertTrue(fixture.coordinator.active)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    func testBusyRequestsCoalesceIntoOneFreshRegionCapture() {
        let fixture = Fixture(first: image())
        fixture.coordinator.requestCapture()
        fixture.coordinator.requestCapture()
        fixture.captures[0](image())
        fixture.coordinator.requestCapture()
        fixture.coordinator.requestCapture()
        XCTAssertEqual(fixture.captures.count, 1)

        fixture.analyses[0].complete(false, match(x: 0, y: 12))
        XCTAssertEqual(fixture.captures.count, 2)
        XCTAssertTrue(fixture.coordinator.busy)
        fixture.captures[1](image(), position: CGPoint(x: 4, y: 25))
        XCTAssertEqual(fixture.analyses[1].hint, CGPoint(x: 4, y: 25))
        fixture.analyses[1].complete(false, nil)
        XCTAssertEqual(fixture.captures.count, 2)
        XCTAssertEqual(fixture.coordinator.document.pieces.count, 3)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    func testFinishDuringCaptureWaitsThroughAnalysisAndFinishesExactlyOnce() {
        let fixture = Fixture(first: image())
        fixture.coordinator.requestCapture()
        fixture.coordinator.finish()
        fixture.coordinator.finish()
        fixture.coordinator.requestCapture()
        XCTAssertTrue(fixture.finishes.isEmpty)
        XCTAssertEqual(fixture.captures.count, 1)
        fixture.captures[0](image())
        XCTAssertTrue(fixture.finishes.isEmpty)
        fixture.analyses[0].complete(false, match(x: 0, y: 12))
        XCTAssertEqual(fixture.finishes.map { $0.pieces.count }, [2])
        XCTAssertFalse(fixture.coordinator.active)
        fixture.coordinator.finish()
        fixture.coordinator.requestCapture()
        XCTAssertEqual(fixture.finishes.count, 1)
        XCTAssertEqual(fixture.captures.count, 1)
    }

    func testFinishDropsQueuedSelectionsAndWaitsForCurrentImage() {
        let fixture = Fixture(first: image())
        fixture.coordinator.requestCapture()
        fixture.coordinator.requestCapture()
        fixture.coordinator.finish()
        fixture.coordinator.requestCapture()
        fixture.captures[0](image())
        fixture.analyses[0].complete(false, nil)
        XCTAssertEqual(fixture.captures.count, 1)
        XCTAssertEqual(fixture.finishes.map { $0.pieces.count }, [2])
        XCTAssertFalse(fixture.coordinator.busy)
    }

    func testFailedCaptureCanRetryWithoutLosingLastAcceptedFrame() {
        let first = image()
        let fixture = Fixture(first: first)
        fixture.coordinator.requestCapture()
        fixture.captures[0](nil)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertTrue(fixture.coordinator.active)
        XCTAssertEqual(fixture.coordinator.document.pieces.count, 1)
        XCTAssertTrue(fixture.analyses.isEmpty)
        fixture.coordinator.requestCapture()
        fixture.captures[1](image())
        XCTAssertTrue(fixture.analyses[0].previous === first)
        fixture.analyses[0].complete(false, nil)
        XCTAssertEqual(fixture.coordinator.document.pieces.count, 2)
    }

    func testFailedSelectionFinishesWithoutOpeningQueuedSelector() {
        let fixture = Fixture(first: image())
        fixture.coordinator.requestCapture()
        fixture.coordinator.requestCapture()
        fixture.coordinator.finish()
        fixture.captures[0](nil)
        XCTAssertEqual(fixture.captures.count, 1)
        XCTAssertEqual(fixture.finishes.map { $0.pieces.count }, [1])
        XCTAssertFalse(fixture.coordinator.active)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    func testCancelDuringCaptureDiscardsQueuedRequestAndStaleImage() {
        let fixture = Fixture(first: image())
        fixture.coordinator.requestCapture()
        fixture.coordinator.requestCapture()
        fixture.coordinator.finish()
        let updateCount = fixture.updates.count
        fixture.coordinator.cancel()
        fixture.captures[0](image())
        fixture.coordinator.requestCapture()
        fixture.coordinator.finish()
        XCTAssertFalse(fixture.coordinator.active)
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertEqual(fixture.captures.count, 1)
        XCTAssertTrue(fixture.analyses.isEmpty)
        XCTAssertTrue(fixture.finishes.isEmpty)
        XCTAssertEqual(fixture.updates.count, updateCount)
        XCTAssertEqual(fixture.coordinator.document.pieces.count, 1)
    }

    func testCancelDuringAnalysisIgnoresLateMatchAndFinish() {
        let fixture = Fixture(first: image())
        fixture.coordinator.requestCapture()
        fixture.captures[0](image())
        fixture.coordinator.requestCapture()
        fixture.coordinator.finish()
        let updateCount = fixture.updates.count
        fixture.coordinator.cancel()
        fixture.analyses[0].complete(false, match(x: 0, y: 15))
        XCTAssertEqual(fixture.coordinator.document.pieces.count, 1)
        XCTAssertEqual(fixture.captures.count, 1)
        XCTAssertEqual(fixture.updates.count, updateCount)
        XCTAssertTrue(fixture.finishes.isEmpty)
        XCTAssertFalse(fixture.coordinator.busy)
    }

    func testDuplicateIsSkippedAndQueuedZeroOffsetChangedCaptureRemainsVisible() {
        let fixture = Fixture(first: image())
        fixture.coordinator.requestCapture()
        fixture.coordinator.requestCapture()
        fixture.captures[0](image())
        fixture.analyses[0].complete(true, match(x: 0, y: 0))
        XCTAssertEqual(fixture.coordinator.document.pieces.count, 1)
        XCTAssertEqual(fixture.captures.count, 2)
        fixture.captures[1](image())
        fixture.analyses[1].complete(false, match(x: 0, y: 0))
        XCTAssertEqual(fixture.coordinator.document.pieces.count, 2)
        XCTAssertEqual(fixture.coordinator.document.pieces[1].origin, CGPoint(x: 0, y: 24))
        XCTAssertFalse(fixture.coordinator.busy)
    }

    func testReverseHintsPlaceUnmatchedCapturesAboveAndToTheLeft() {
        let fixture = Fixture(first: image())
        fixture.coordinator.requestCapture()
        fixture.captures[0](image(), position: CGPoint(x: 0, y: -20))
        fixture.analyses[0].complete(false, nil)
        XCTAssertEqual(fixture.coordinator.document.pieces[1].origin, CGPoint(x: 0, y: -24))
        fixture.coordinator.requestCapture()
        fixture.captures[1](image(), position: CGPoint(x: -30, y: -19))
        fixture.analyses[1].complete(false, nil)
        XCTAssertEqual(fixture.coordinator.document.pieces[2].origin, CGPoint(x: -32, y: -24))
    }

    func testTwentyFourthCaptureDrainsPendingRequestAtLimitAndCanFinish() {
        let fixture = Fixture(first: image())
        for index in 0..<22 {
            fixture.coordinator.requestCapture()
            fixture.captures[index](image())
            fixture.analyses[index].complete(false, nil)
        }
        XCTAssertEqual(fixture.coordinator.document.pieces.count, 23)
        fixture.coordinator.requestCapture()
        fixture.coordinator.requestCapture()
        fixture.coordinator.finish()
        fixture.captures[22](image())
        fixture.analyses[22].complete(false, nil)
        XCTAssertEqual(fixture.captures.count, 23)
        XCTAssertEqual(fixture.coordinator.document.pieces.count, 24)
        XCTAssertEqual(fixture.finishes.map { $0.pieces.count }, [24])
        XCTAssertFalse(fixture.coordinator.busy)
        XCTAssertFalse(fixture.coordinator.active)
    }

    func testIdleFinishReturnsInitialCaptureWithoutStartingWork() {
        let fixture = Fixture(first: image())
        fixture.coordinator.finish()
        XCTAssertEqual(fixture.finishes.map { $0.pieces.count }, [1])
        XCTAssertTrue(fixture.captures.isEmpty)
        XCTAssertFalse(fixture.coordinator.active)
    }

    func testEdgeChangesSurviveZeroOffsetRegistrationAndFullImageDuplicateCheck() throws {
        let first = texture(changedEdge: false)
        let changed = texture(changedEdge: true)
        let registration = try XCTUnwrap(StitchAlignment.match(previous: first, current: changed))
        XCTAssertEqual(registration.offset, .zero)
        XCTAssertEqual(registration.error, 0)
        XCTAssertTrue(StitchAlignment.identical(first, texture(changedEdge: false)))
        XCTAssertFalse(StitchAlignment.identical(first, changed))

        let fixture = Fixture(first: first)
        fixture.coordinator.requestCapture()
        fixture.captures[0](changed)
        fixture.analyses[0].complete(StitchAlignment.identical(first, changed), registration)
        XCTAssertEqual(fixture.coordinator.document.pieces.count, 2)
        XCTAssertEqual(fixture.coordinator.document.pieces[1].origin, CGPoint(x: 0, y: 120))
    }

    func testVerifiedZeroOffsetOfDifferentSizedRegionExtendsOriginalCapture() {
        let first = image().cropping(to: CGRect(x: 0, y: 0, width: 20, height: 18))!
        let fixture = Fixture(first: first)
        fixture.coordinator.requestCapture()
        fixture.captures[0](image())
        fixture.analyses[0].complete(false, match(x: 0, y: 0))
        XCTAssertEqual(fixture.coordinator.document.pieces[1].origin, .zero)
        XCTAssertEqual(fixture.coordinator.document.bounds.size, CGSize(width: 32, height: 24))
    }

    func testVerifiedOnePixelMovementKeepsItsAlignment() {
        let fixture = Fixture(first: image())
        fixture.coordinator.requestCapture()
        fixture.captures[0](image())
        fixture.analyses[0].complete(false, match(x: 0, y: 1))
        XCTAssertEqual(fixture.coordinator.document.pieces[1].origin, CGPoint(x: 0, y: 1))
    }

    func testDifferentRegionSizesUseScreenDirectionWithoutKeepingEmptyDistance() {
        let fixture = Fixture(first: image())
        let small = image().cropping(to: CGRect(x: 0, y: 0, width: 20, height: 18))!
        fixture.coordinator.requestCapture()
        fixture.captures[0](small, position: CGPoint(x: 75, y: 40))
        fixture.analyses[0].complete(false, nil)
        XCTAssertEqual(fixture.coordinator.document.pieces[1].frame,
                       CGRect(x: 32, y: 0, width: 20, height: 18))
        XCTAssertEqual(fixture.coordinator.document.joins.count, 1)
        XCTAssertTrue(fixture.coordinator.document.pieces[1].image === small)
    }

    func testUnmatchedCaptureDirectionsCloseGapsAndAlignPerpendicularEdges() {
        let previous = CGRect(x: 45, y: 75, width: 300, height: 200)
        let size = CGSize(width: 300, height: 200)
        for (hint, expected) in [
            (CGPoint(x: 30, y: 900), CGPoint(x: 45, y: 275)),
            (CGPoint(x: -30, y: -900), CGPoint(x: 45, y: -125)),
            (CGPoint(x: 900, y: 30), CGPoint(x: 345, y: 75)),
            (CGPoint(x: -900, y: -30), CGPoint(x: -255, y: 75))
        ] {
            XCTAssertEqual(StitchCaptureCoordinator.adjacentOrigin(previous: previous, size: size, hint: hint), expected)
        }
    }

    func testPackedCapturesKeepWorldHintsIndependentOfTheirCanvasOrigins() {
        let fixture = Fixture(first: image())
        fixture.coordinator.requestCapture()
        fixture.captures[0](image(), position: CGPoint(x: 8, y: 800))
        fixture.analyses[0].complete(false, nil)
        fixture.coordinator.requestCapture()
        fixture.captures[1](image(), position: CGPoint(x: 10, y: 1700))
        XCTAssertEqual(fixture.analyses[1].hint, CGPoint(x: 2, y: 900))
        fixture.analyses[1].complete(false, nil)
        let document = fixture.coordinator.document
        XCTAssertEqual(document.pieces.map(\.origin), [.zero, CGPoint(x: 0, y: 24), CGPoint(x: 0, y: 48)])
        XCTAssertEqual(document.bounds, CGRect(x: 0, y: 0, width: 32, height: 72))
        XCTAssertEqual(document.joins.count, 2)
    }

    func testReliableOverlapKeepsExactOffsetEvenWhenScreenHintHasLargeGap() {
        let fixture = Fixture(first: image())
        fixture.coordinator.requestCapture()
        fixture.captures[0](image(), position: CGPoint(x: 900, y: 700))
        fixture.analyses[0].complete(false, match(x: 3, y: 12))
        XCTAssertEqual(fixture.coordinator.document.pieces[1].origin, CGPoint(x: 3, y: 12))
    }

    func testReturningAcrossPackedCapturesRetainsEveryPieceWithoutGaps() {
        for horizontal in [false, true] {
            let fixture = Fixture(first: image())
            fixture.coordinator.requestCapture()
            fixture.captures[0](image(), position: horizontal ? CGPoint(x: 900, y: 0) : CGPoint(x: 0, y: 900))
            fixture.analyses[0].complete(false, nil)
            fixture.coordinator.requestCapture()
            fixture.captures[1](image(), position: .zero)
            fixture.analyses[1].complete(false, nil)
            let document = fixture.coordinator.document
            XCTAssertEqual(document.pieces[2].origin, horizontal ? CGPoint(x: -32, y: 0) : CGPoint(x: 0, y: -24))
            XCTAssertEqual(document.bounds.width * document.bounds.height, 3 * 32 * 24)
            XCTAssertEqual(document.joins.count, 2)
            for i in document.pieces.indices {
                for j in document.pieces.indices where j > i {
                    let overlap = document.pieces[i].frame.intersection(document.pieces[j].frame)
                    XCTAssertTrue(overlap.isNull || overlap.width == 0 || overlap.height == 0)
                }
            }
        }
    }

    func testIdenticalPixelsAtDifferentScreenPositionsAreRetained() {
        let fixture = Fixture(first: image())
        fixture.coordinator.requestCapture()
        fixture.captures[0](image(), position: CGPoint(x: 32, y: 0))
        fixture.analyses[0].complete(true, nil)
        XCTAssertEqual(fixture.coordinator.document.pieces.count, 2)
        XCTAssertEqual(fixture.coordinator.document.pieces[1].origin, CGPoint(x: 32, y: 0))
    }

    func testScreenPositionIncludesScrollAndNormalizesDisplayDensity() {
        let retina = StitchCaptureFrame.estimatedPosition(screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            pixelRect: CGRect(x: 200, y: 100, width: 400, height: 300), pixelScale: 2, referenceScale: 2,
            scrollOffset: .zero)
        let moved = StitchCaptureFrame.estimatedPosition(screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            pixelRect: CGRect(x: 400, y: 300, width: 200, height: 200), pixelScale: 2, referenceScale: 2,
            scrollOffset: CGPoint(x: 0, y: 75))
        XCTAssertEqual(CGPoint(x: moved.x - retina.x, y: moved.y - retina.y), CGPoint(x: 200, y: 350))
        let external = StitchCaptureFrame.estimatedPosition(screenFrame: CGRect(x: 1000, y: 0, width: 1000, height: 800),
            pixelRect: CGRect(x: 100, y: 50, width: 200, height: 150), pixelScale: 1, referenceScale: 2,
            scrollOffset: .zero)
        XCTAssertEqual(external, CGPoint(x: retina.x + 2000, y: retina.y))
    }

    private func match(x: CGFloat, y: CGFloat) -> StitchAlignment.Match {
        StitchAlignment.Match(offset: CGPoint(x: x, y: y), error: 0)
    }

    private func image() -> CGImage {
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                                bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        return context.makeImage()!
    }

    private func texture(changedEdge: Bool) -> CGImage {
        let width = 160, height = 120
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt64 = 1234567
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 6364136223846793005 &+ 1
                let value = changedEdge && x < 10 ? UInt8(255) : UInt8((seed >> 32) & 255)
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = value }
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    @MainActor
    private final class Fixture {
        struct Analysis {
            let previous: CGImage
            let current: CGImage
            let hint: CGPoint
            let complete: (Bool, StitchAlignment.Match?) -> Void
        }
        var coordinator: StitchCaptureCoordinator!
        struct CaptureReply {
            let callback: (StitchCaptureFrame?) -> Void
            func callAsFunction(_ image: CGImage?, position: CGPoint = .zero) {
                callback(image.map { StitchCaptureFrame(image: $0, position: position) })
            }
        }
        var captures: [CaptureReply] = []
        var analyses: [Analysis] = []
        var updates: [String] = []
        var finishes: [StitchDocument] = []

        init(first: CGImage) {
            coordinator = StitchCaptureCoordinator(first: StitchCaptureFrame(image: first), capture: { [weak self] callback in
                self?.captures.append(CaptureReply(callback: callback))
            }, analyze: { [weak self] previous, current, hint, callback in
                self?.analyses.append(Analysis(previous: previous, current: current, hint: hint, complete: callback))
            })
            coordinator.onUpdate = { [weak self] in self?.updates.append($0) }
            coordinator.onFinish = { [weak self] in self?.finishes.append($0) }
        }
    }
}
