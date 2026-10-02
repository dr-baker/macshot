import CoreGraphics
import Foundation
import XCTest

final class ScreenCaptureWindowExclusionsTests: XCTestCase {
    func testCombinesHUDAndCurrentThumbnailsWithoutDuplicateOrNullIDs() {
        XCTAssertEqual(ScreenCaptureWindowExclusions.combining([10], [20, 21, 20, 0], [10, 22]),
                       [10, 20, 21, 22])
    }

    func testMacOS13WindowListExcludesHUDAndThumbnailsAndKeepsDesktopAndWindowOrder() throws {
        let windowNumbers: [CGWindowID] = [10, 30, 21, 20, 40, 50]
        let windows: [[String: Any]] = windowNumbers.map {
            [kCGWindowNumber as String: NSNumber(value: $0),
             kCGWindowLayer as String: $0 == 50 ? -2_147_483_623 : 0,
             kCGWindowOwnerName as String: $0 == 50 ? "Window Server" : "An app"]
        }
        let exclusions = ScreenCaptureWindowExclusions.combining([10], [20, 21])
        let included = try XCTUnwrap(ScreenCaptureWindowExclusions.includedWindowNumbers(
            in: windows, excluding: exclusions))
        XCTAssertEqual(included, [30, 40, 50])
        let array = try XCTUnwrap(ScreenCaptureWindowExclusions.windowArray(for: included))
        XCTAssertEqual(CFArrayGetCount(array), 3)
        for index in included.indices {
            // Verify the actual representation given to CGImage's macOS 13 API.
            let value = try XCTUnwrap(CFArrayGetValueAtIndex(array, index))
            XCTAssertEqual(UInt(bitPattern: value), UInt(included[index]))
        }
    }

    func testInvalidWindowMetadataFailsClosed() {
        for invalid: [String: Any] in [[:], [kCGWindowNumber as String: "20"],
                                      [kCGWindowNumber as String: NSNumber(value: -1)],
                                      [kCGWindowNumber as String: NSNumber(value: UInt64.max)],
                                      [kCGWindowNumber as String: NSNumber(value: 0)]] {
            XCTAssertNil(ScreenCaptureWindowExclusions.includedWindowNumbers(
                in: [[kCGWindowNumber as String: NSNumber(value: 30)], invalid], excluding: [10, 20]))
        }
    }

    func testExcludingEveryWindowDoesNotFallBackToUnfilteredCapture() throws {
        let included = try XCTUnwrap(ScreenCaptureWindowExclusions.includedWindowNumbers(
            in: [[kCGWindowNumber as String: NSNumber(value: 10)]], excluding: [10]))
        XCTAssertTrue(included.isEmpty)
        XCTAssertNil(ScreenCaptureWindowExclusions.windowArray(for: included))
    }
}
