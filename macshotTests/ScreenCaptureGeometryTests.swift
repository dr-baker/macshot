import CoreGraphics
import XCTest

final class ScreenCaptureGeometryTests: XCTestCase {
    func testCropUsesDisplayLocalTopLeftPointsOnEveryDisplayPosition() {
        let frames = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                      CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                      CGRect(x: 400, y: 900, width: 1280, height: 720),
                      CGRect(x: -100, y: -1080, width: 1920, height: 1080)]
        for screenFrame in frames {
            let selection = CGRect(x: screenFrame.minX + 25.25,
                                   y: screenFrame.maxY - 375.75,
                                   width: 333.5, height: 200.25)
            XCTAssertEqual(ScreenCaptureGeometry.sourceRect(captureRect: selection, screenFrame: screenFrame),
                           CGRect(x: 25.25, y: 175.5, width: 333.5, height: 200.25))
            XCTAssertEqual(ScreenCaptureGeometry.sourceRect(captureRect: screenFrame, screenFrame: screenFrame),
                           CGRect(origin: .zero, size: screenFrame.size))
        }
    }

    func testCropRejectsRegionsOutsideTheSelectedDisplay() {
        let screenFrame = CGRect(x: -1920, y: 900, width: 1920, height: 1080)
        for selection in [CGRect(x: -1921, y: 1000, width: 10, height: 10),
                          CGRect(x: -5, y: 1000, width: 10, height: 10),
                          CGRect(x: -1800, y: 895, width: 10, height: 10),
                          CGRect(x: -1800, y: 1975, width: 10, height: 10),
                          CGRect(x: -1800, y: 1000, width: 0, height: 10),
                          CGRect.null, CGRect.infinite] {
            XCTAssertNil(ScreenCaptureGeometry.sourceRect(captureRect: selection, screenFrame: screenFrame))
        }
    }

    func testOutputSizeScalesTheExactSelectionBeforeRounding() {
        XCTAssertEqual(ScreenCaptureGeometry.pixelSize(pointSize: CGSize(width: 333.5, height: 200.25), scale: 2),
                       ScreenCaptureGeometry.PixelSize(width: 667, height: 401))
        XCTAssertEqual(ScreenCaptureGeometry.pixelSize(pointSize: CGSize(width: 333.5, height: 200.25), scale: 1),
                       ScreenCaptureGeometry.PixelSize(width: 334, height: 200))
    }

    func testInvalidOrUnrepresentablePixelSizesFailWithoutIntegerConversion() {
        for size in [CGSize(width: 0, height: 10), CGSize(width: -1, height: 10),
                     CGSize(width: CGFloat.infinity, height: 10), CGSize(width: CGFloat.nan, height: 10),
                     CGSize(width: CGFloat(Int.max), height: 10)] {
            XCTAssertNil(ScreenCaptureGeometry.pixelSize(pointSize: size, scale: 2))
        }
        for scale: CGFloat in [0, -1, .infinity, .nan] {
            XCTAssertNil(ScreenCaptureGeometry.pixelSize(pointSize: CGSize(width: 100, height: 100), scale: scale))
        }
    }

    func testPartialProgressRetriesOnlyMissingDisplaysAndRequiresCompleteCoverage() {
        let expected: [CGDirectDisplayID] = [101, 202, 303]
        let rectCaptures: [CGDirectDisplayID] = [202]
        XCTAssertEqual(ScreenCaptureCoverage.missingDisplayIDs(expected: expected, captured: rectCaptures), [101, 303])
        XCTAssertFalse(ScreenCaptureCoverage.isComplete(expected: expected, captured: rectCaptures))
        XCTAssertFalse(ScreenCaptureCoverage.isComplete(expected: expected, captured: rectCaptures + [101]))
        XCTAssertTrue(ScreenCaptureCoverage.isComplete(expected: expected, captured: rectCaptures + [303, 101]))
        // A duplicate or an unrelated display must not stand in for the failed display.
        XCTAssertFalse(ScreenCaptureCoverage.isComplete(expected: expected, captured: [202, 202, 101, 404]))
        XCTAssertFalse(ScreenCaptureCoverage.isComplete(expected: [], captured: []))
    }
}
