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

    func testNativeDensityCopyOwnsOnlySelectedBackingBytes() throws {
        let source = image(width: 16, height: 14) { x, y in [UInt8(x * 10), UInt8(y * 12), 10, 255] }
        let result = try XCTUnwrap(StitchCaptureImageCrop.copy(image: source,
            rect: CGRect(x: 3, y: 5, width: 4, height: 3), scale: 1))
        XCTAssertFalse(result === source)
        XCTAssertEqual((result.dataProvider?.data as Data?)?.count, 4 * 3 * 4)
        for y in 0..<3 {
            for x in 0..<4 {
                XCTAssertEqual(pixel(result, x: x, y: y), [UInt8((x + 3) * 10), UInt8((y + 5) * 12), 10, 255])
            }
        }
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

    func testEveryOutputPixelIsIndependentOfUnselectedContentAtMixedDensities() throws {
        let regions = [CGRect(x: 4, y: 3, width: 8, height: 7),
                       CGRect(x: 3.25, y: 2.75, width: 8.5, height: 6.25),
                       CGRect(x: 3.8, y: 2.1, width: 0.4, height: 0.4)]
        for region in regions {
            for scale: CGFloat in [0.6, 1, 2, 10] where region.width * scale >= 0.5 && region.height * scale >= 0.5 {
                let first = selectedImage(rect: region, outside: [0, 0, 0, 255])
                let second = selectedImage(rect: region, outside: [255, 240, 230, 255])
                let a = try XCTUnwrap(StitchCaptureImageCrop.copy(image: first, rect: region, scale: scale))
                let b = try XCTUnwrap(StitchCaptureImageCrop.copy(image: second, rect: region, scale: scale))
                XCTAssertEqual(a.width, Int((region.width * scale).rounded()))
                XCTAssertEqual(a.height, Int((region.height * scale).rounded()))
                XCTAssertEqual(b.width, a.width)
                XCTAssertEqual(b.height, a.height)
                for y in 0..<a.height {
                    for x in 0..<a.width {
                        XCTAssertEqual(pixel(a, x: x, y: y), pixel(b, x: x, y: y),
                                       "Outside content influenced pixel \(x),\(y), region \(region), scale \(scale)")
                        XCTAssertEqual(pixel(a, x: x, y: y)[3], 255)
                    }
                }
            }
        }
    }

    func testConstantSelectedPixelsPreserveColorAndAlphaAtEveryScaledBoundary() throws {
        let region = CGRect(x: 3.25, y: 2.75, width: 8.5, height: 6.25)
        let color: [UInt8] = [30, 40, 50, 128]
        let source = image(width: 16, height: 14) { x, y in
            Self.overlaps(region, x: x, y: y) ? color : [200, 0, 180, 255]
        }
        for scale: CGFloat in [0.6, 1, 2] {
            let result = try XCTUnwrap(StitchCaptureImageCrop.copy(image: source, rect: region, scale: scale))
            for y in 0..<result.height {
                for x in 0..<result.width {
                    XCTAssertEqual(pixel(result, x: x, y: y), color, "Pixel \(x),\(y), scale \(scale)")
                }
            }
        }
    }

    func testDownsamplingUsesOnlyExactSelectedFractionalCoverage() throws {
        let source = image(width: 8, height: 8) { x, _ in [UInt8(x * 20), 0, 0, 255] }
        let region = CGRect(x: 1.25, y: 2.25, width: 2.5, height: 1.5)
        let result = try XCTUnwrap(StitchCaptureImageCrop.copy(image: source, rect: region, scale: 0.4))
        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
        // The selected footprint covers 0.75 of column 1, all of 2, and 0.75 of 3.
        XCTAssertEqual(pixel(result, x: 0, y: 0), [40, 0, 0, 255])
    }

    func testLinearRGBAndPremultipliedTransparentPixelsKeepTheirComponents() throws {
        let linear = try XCTUnwrap(CGColorSpace(name: CGColorSpace.linearSRGB))
        let source = image(width: 2, height: 2, space: linear) { x, _ in
            x == 0 ? [0, 0, 0, 0] : [100, 60, 20, 128]
        }
        let result = try XCTUnwrap(StitchCaptureImageCrop.copy(image: source,
            rect: CGRect(x: 0, y: 0, width: 2, height: 2), scale: 0.5))
        XCTAssertEqual(result.colorSpace?.name, linear.name)
        XCTAssertEqual(pixel(result, x: 0, y: 0), [50, 30, 10, 64])
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

    func testFiniteScalingBeyondCanvasDimensionsOrPixelBudgetReturnsNil() {
        let source = image(width: 4, height: 4) { _, _ in [0, 0, 0, 255] }
        XCTAssertNil(StitchCaptureImageCrop.copy(image: source,
            rect: CGRect(x: 0, y: 0, width: 4, height: 4), scale: 5_000))
        XCTAssertNil(StitchCaptureImageCrop.copy(image: source,
            rect: CGRect(x: 0, y: 0, width: 1, height: 4), scale: 10_000))
    }

    private func selectedImage(rect: CGRect, outside: [UInt8]) -> CGImage {
        image(width: 16, height: 14) { x, y in
            Self.overlaps(rect, x: x, y: y)
                ? [UInt8(x * 10), UInt8(y * 12), UInt8((x + y) * 6), 255] : outside
        }
    }

    private static func overlaps(_ rect: CGRect, x: Int, y: Int) -> Bool {
        let cell = CGRect(x: x, y: y, width: 1, height: 1).intersection(rect)
        return !cell.isNull && cell.width > 0 && cell.height > 0
    }

    private func image(width: Int, height: Int, space: CGColorSpace = CGColorSpaceCreateDeviceRGB(),
                       pixel: (Int, Int) -> [UInt8]) -> CGImage {
        var data: [UInt8] = []
        for y in 0..<height { for x in 0..<width { data += pixel(x, y) } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = Array(image.dataProvider!.data! as Data)
        let start = y * image.bytesPerRow + x * 4
        return Array(data[start..<start + 4])
    }
}
