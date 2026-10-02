import AppKit
import XCTest

final class StitchBandContentSafetyTests: XCTestCase {
    func testSmallNativeTextAndLowContrastDividersNeverBecomeBlankBands() {
        for scale in [1, 2] {
            for dark in [false, true] {
                for kind in ["bullets", "numbers", "labels", "edge", "dividers"] {
                    autoreleasepool {
                        let doc = fixture(kind: kind, scale: scale, dark: dark)
                        let guides = contentGuides(doc, axis: .horizontal)
                        if kind == "labels" {
                            // A genuine blank interval below the last label may remain useful.
                            XCTAssertEqual(guides.count % 2, 0)
                            for index in stride(from: 0, to: max(0, guides.count - 1), by: 2) {
                                for top in [190, 260, 330] {
                                    let lower = CGFloat(top * scale), upper = CGFloat((top + 20) * scale)
                                    XCTAssertFalse(guides[index] < upper && guides[index + 1] > lower,
                                                   "Suggested band intersects a 13pt label: \(scale)x, dark=\(dark)")
                                }
                            }
                        } else {
                            XCTAssertEqual(guides, [], "\(kind), \(scale)x, dark=\(dark)")
                        }
                    }
                }
                autoreleasepool {
                    let doc = fixture(kind: "column-edge", scale: scale, dark: dark)
                    XCTAssertEqual(contentGuides(doc, axis: .vertical), [], "top-edge labels, \(scale)x, dark=\(dark)")
                }
            }
        }
    }

    func testMixedAdjacentCaptureCannotHideNarrowTextInItsNeighbor() {
        for scale in [1, 2] {
            for kind in ["edge", "bullets"] {
                autoreleasepool {
                    var doc = fixture(kind: "blank", scale: scale, dark: false)
                    var neighbor = fixture(kind: kind, scale: scale, dark: true).pieces[0]
                    neighbor.origin.x = CGFloat(1600 * scale)
                    doc.pieces.append(neighbor)
                    XCTAssertEqual(contentGuides(doc, axis: .horizontal), [], "\(kind), \(scale)x")
                }
            }
        }
    }

    func testRecommendedBlankBandsCollapseAndRenderWithoutChangingProtectedText() throws {
        for scale in [1, 2] {
            for dark in [false, true] {
                for axis in [StitchAxis.horizontal, .vertical] {
                    try autoreleasepool {
                        var doc = fixture(kind: axis == .horizontal ? "blank" : "column-blank", scale: scale, dark: dark)
                        let guides = contentGuides(doc, axis: axis)
                        XCTAssertEqual(guides.count, 2)
                        guard guides.count == 2 else { return }
                        let before = try XCTUnwrap(StitchRenderer.render(doc))
                        let lo = Int(guides[0].rounded()), hi = Int(guides[1].rounded())
                        XCTAssertTrue(doc.collapse(axis: axis, from: guides[0], to: guides[1]))
                        let after = try XCTUnwrap(StitchRenderer.render(doc))
                        XCTAssertEqual(axis == .horizontal ? after.height : after.width,
                                       (axis == .horizontal ? before.height : before.width) - hi + lo)
                        let source = rgba(before), result = rgba(after)
                        let background = Array(source[0..<4])
                        var changed = 0, foreground = 0, compared = 0
                        // Check both retained sides outside the entire seam fade, including real glyph pixels.
                        for y in stride(from: 0, to: before.height, by: 2) {
                            for x in stride(from: 0, to: before.width, by: 2) {
                                let coordinate = axis == .horizontal ? y : x
                                guard coordinate < lo - 48 || coordinate > hi + 48 else { continue }
                                let px = axis == .vertical && x >= hi ? x - hi + lo : x
                                let py = axis == .horizontal && y >= hi ? y - hi + lo : y
                                let a = (y * before.width + x) * 4, b = (py * after.width + px) * 4
                                if (0..<3).contains(where: { abs(Int(source[a + $0]) - Int(background[$0])) > 40 }) { foreground += 1 }
                                if (0..<4).contains(where: { abs(Int(source[a + $0]) - Int(result[b + $0])) > 1 }) { changed += 1 }
                                compared += 1
                            }
                        }
                        XCTAssertGreaterThan(compared, 10_000)
                        XCTAssertGreaterThan(foreground, 100, "The comparison must cover actual text")
                        XCTAssertEqual(changed, 0, "\(axis), \(scale)x, dark=\(dark)")
                    }
                }
            }
        }
    }

    func testCancellationInsideNativeValidationReturnsOnlyGeometry() {
        let doc = solidGap(width: 240, height: 240, margin: 40)
        XCTAssertEqual(contentGuides(doc, axis: .horizontal).count, 2)
        // One piece check, 240 row checks, 240 column checks, candidate check,
        // tile entry, pre-draw check, then first native row. No timer or scheduling dependency.
        let firstNativeRow = 1 + 240 + 240 + 4
        var calls = 0
        let result = StitchBandGuides.analyze(document: doc) {
            calls += 1
            return calls >= firstNativeRow
        }
        XCTAssertGreaterThanOrEqual(calls, firstNativeRow)
        XCTAssertLessThan(calls, firstNativeRow + 10)
        XCTAssertEqual(result, StitchBandGuides.geometry(document: doc))
    }

    func testNativeBudgetExhaustionRejectsUnknownBandBeforeScanningPixels() {
        // Discovery is only 768 x 85 pixels, but native proof would require over 9M.
        let doc = solidGap(width: 10_000, height: 1100, margin: 50)
        var calls = 0
        let result = StitchBandGuides.analyze(document: doc) { calls += 1; return false }
        let sampleHeight = Int(ceil(1100.0 * 768 / 10_000))
        XCTAssertGreaterThan(10_000 * 970, StitchBandGuides.maximumValidationPixels)
        XCTAssertGreaterThan(calls, 768 + sampleHeight)
        XCTAssertLessThan(calls, 768 + sampleHeight + 10, "Native row scans must not start after proof budget is exhausted")
        XCTAssertEqual(result, StitchBandGuides.geometry(document: doc))
    }

    private func contentGuides(_ doc: StitchDocument, axis: StitchAxis) -> [CGFloat] {
        let edges = StitchBandGuides.geometry(document: doc).values(for: axis)
        return StitchBandGuides.analyze(document: doc).values(for: axis).filter { !edges.contains($0) }
    }

    private func fixture(kind: String, scale: Int, dark: Bool) -> StitchDocument {
        let s = CGFloat(scale), width = 1600, height = 600
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedWhite: dark ? 0.10 : 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width) * s, height: CGFloat(height) * s).fill()
        func text(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat) {
            (value as NSString).draw(at: CGPoint(x: x * s, y: (CGFloat(height) - top - size * 1.3) * s),
                withAttributes: [.font: NSFont.systemFont(ofSize: size * s),
                                 .foregroundColor: NSColor(calibratedWhite: dark ? 0.95 : 0.08, alpha: 1)])
        }
        if kind.hasPrefix("column") {
            text("Left", x: 40, top: 100, size: 26)
            text("Right", x: 1450, top: 100, size: 26)
            if kind == "column-edge" {
                text("ID", x: 650, top: 1, size: 13)
                text("ON", x: 900, top: 1, size: 13)
            }
        } else {
            text("Account settings and captured page content", x: 80, top: 40, size: 26)
            text("Next section: keep this information", x: 80, top: 510, size: 26)
            switch kind {
            case "bullets":
                for (i, label) in ["• A", "• B", "• C", "• D"].enumerated() { text(label, x: 80, top: 170 + CGFloat(i) * 50, size: 13) }
            case "numbers":
                for i in 1...5 { text(String(i), x: 80, top: 160 + CGFloat(i) * 40, size: 13) }
            case "labels", "edge":
                for (i, label) in ["ID", "ON", "OFF"].enumerated() { text(label, x: kind == "edge" ? 4 : 80, top: 190 + CGFloat(i) * 70, size: 13) }
            case "dividers":
                NSColor(calibratedWhite: dark ? 0.16 : 0.91, alpha: 1).setFill()
                for y in [230, 330] { NSRect(x: 80 * s, y: CGFloat(height - y - 1) * s, width: 1440 * s, height: s).fill() }
            default: break
            }
        }
        return StitchDocument(pieces: [StitchPiece(image: bitmap.cgImage!)])
    }

    private func solidGap(width: Int, height: Int, margin: Int) -> StitchDocument {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: margin))
        context.fill(CGRect(x: 0, y: height - margin, width: width, height: margin))
        return StitchDocument(pieces: [StitchPiece(image: context.makeImage()!)])
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
