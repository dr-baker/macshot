import CoreGraphics
import Foundation
import XCTest

final class StitchCaptureImageCropTests: XCTestCase {
    func testOddReferenceDimensionAtMixedDensityStaysExactly101Pixels() throws {
        let source = image(width: 100, height: 100) { _, _ in [40, 90, 130, 255] }
        let result = try XCTUnwrap(StitchCaptureImageCrop.copy(image: source,
            rect: CGRect(x: 10.25, y: 12.5, width: 50.5, height: 35.5), scale: 2))
        XCTAssertEqual(result.width, 101)
        XCTAssertEqual(result.height, 71)
        XCTAssertEqual(pixel(result, x: 100, y: 70), [40, 90, 130, 255])
    }

    func testTopDownCropUsesCorrectRowsAndColumns() throws {
        let source = image(width: 8, height: 8) { x, y in [UInt8(x * 20), UInt8(y * 20), 10, 255] }
        let result = try XCTUnwrap(StitchCaptureImageCrop.copy(image: source,
            rect: CGRect(x: 2, y: 1, width: 3, height: 2), scale: 1))
        XCTAssertEqual(pixel(result, x: 0, y: 0), [40, 20, 10, 255])
        XCTAssertEqual(pixel(result, x: 2, y: 1), [80, 40, 10, 255])
    }

    func testFractionalAnchorSamplesExactRegionWithoutIntegralExpansion() throws {
        let source = image(width: 8, height: 8) { x, y in [UInt8(x * 30), UInt8(y * 30), 0, 255] }
        // At 2x scale, these destination pixel centers land on source centers (1.5, 2.5), etc.
        let result = try XCTUnwrap(StitchCaptureImageCrop.copy(image: source,
            rect: CGRect(x: 1.25, y: 2.25, width: 2.5, height: 1.5), scale: 2))
        XCTAssertEqual(result.width, 5)
        XCTAssertEqual(result.height, 3)
        let first = pixel(result, x: 0, y: 0), last = pixel(result, x: 4, y: 2)
        XCTAssertEqual(Int(first[0]), 30, accuracy: 2)
        XCTAssertEqual(Int(first[1]), 60, accuracy: 2)
        XCTAssertEqual(Int(last[0]), 90, accuracy: 2)
        XCTAssertEqual(Int(last[1]), 90, accuracy: 2)
    }

    func testClipsToSourceBoundsBeforeSizingAndPreservesAlpha() throws {
        let source = image(width: 8, height: 8) { _, _ in [30, 40, 50, 128] }
        let result = try XCTUnwrap(StitchCaptureImageCrop.copy(image: source,
            rect: CGRect(x: -1.5, y: 6.5, width: 5, height: 3), scale: 2))
        XCTAssertEqual(result.width, 7)
        XCTAssertEqual(result.height, 3)
        XCTAssertEqual(pixel(result, x: 3, y: 1), [30, 40, 50, 128])
        XCTAssertFalse(result === source)
    }

    func testInvalidOrEmptyGeometryReturnsNil() {
        let source = image(width: 4, height: 4) { _, _ in [0, 0, 0, 255] }
        for scale: CGFloat in [0, -1, .nan, .infinity, .greatestFiniteMagnitude] {
            XCTAssertNil(StitchCaptureImageCrop.copy(image: source, rect: CGRect(x: 0, y: 0, width: 4, height: 4), scale: scale))
        }
        for rect in [CGRect.zero, CGRect.null, CGRect.infinite, CGRect(x: 5, y: 5, width: 2, height: 2), CGRect(x: 0, y: 0, width: -1, height: 2)] {
            XCTAssertNil(StitchCaptureImageCrop.copy(image: source, rect: rect, scale: 1))
        }
    }

    private func image(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) -> CGImage {
        var data: [UInt8] = []
        for y in 0..<height { for x in 0..<width { data += pixel(x, y) } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = Array(image.dataProvider!.data! as Data)
        let start = y * image.bytesPerRow + x * 4
        return Array(data[start..<start + 4])
    }
}
