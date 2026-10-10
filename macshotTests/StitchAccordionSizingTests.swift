import AppKit
import XCTest

@MainActor
final class StitchAccordionSizingTests: XCTestCase {
    func testFoldBandUsesRemovedLengthInBothDirections() throws {
        let image = try pixels(width: 1000, height: 1000)
        for axis in [StitchAxis.horizontal, .vertical] {
            for length in [CGFloat(12), 48, 120] {
                var document = StitchDocument(pieces: [StitchPiece(image: image)])
                document.style.transition = .accordion
                XCTAssertTrue(document.collapse(axis: axis, from: 320, to: 320 + length))
                for manualWidth in [CGFloat(0), 8, 80] {
                    document.style.accordionWidth = manualWidth
                    let projection = try XCTUnwrap(StitchAccordionProjection(document: document, progress: 0))
                    let coordinates = normalCoordinates(projection, axis: axis).filter {
                        $0 > (axis == .horizontal ? document.bounds.minY : document.bounds.minX)
                            && $0 < (axis == .horizontal ? document.bounds.maxY : document.bounds.maxX)
                    }
                    XCTAssertEqual(try XCTUnwrap(coordinates.first), 320 - length / 2, accuracy: 0.000001)
                    XCTAssertEqual(try XCTUnwrap(coordinates.last), 320 + length / 2, accuracy: 0.000001)
                    XCTAssertTrue(document.hasAccordionFolds)
                }
            }
        }
    }

    func testPleatsDivideTheRemovedLengthAndSetRidgeHeight() throws {
        let image = try pixels(width: 1000, height: 1000)
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = StitchDocument(pieces: [StitchPiece(image: image)])
            document.style.transition = .accordion
            document.style.accordionPerspective = 0
            document.style.accordionYaw = 0
            XCTAssertTrue(document.collapse(axis: axis, from: 320, to: 400))
            for pleats in 2...6 {
                document.style.accordionPleats = CGFloat(pleats)
                let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
                let band = normalCoordinates(projection, axis: axis).filter { (280...360).contains($0) }
                XCTAssertEqual(band.count, pleats * 2 + 1)
                for (first, next) in zip(band, band.dropFirst()) {
                    XCTAssertEqual(next - first, 80 / CGFloat(pleats * 2), accuracy: 0.000001)
                }
                let depths = projection.faces.flatMap(\.vertices).map(\.depth)
                let height = try XCTUnwrap(depths.max()) - XCTUnwrap(depths.min())
                XCTAssertEqual(height, 80 / CGFloat(pleats * 2) * sqrt(1 - 0.45 * 0.45), accuracy: 0.000001)
            }
        }
    }

    func testIndependentCutSegmentsAtOneSeamKeepDifferentFoldSizes() throws {
        let image = try pixels(width: 500, height: 800)
        var left = StitchDocument(pieces: [StitchPiece(image: image)])
        var right = StitchDocument(pieces: [StitchPiece(image: image)])
        XCTAssertTrue(left.collapse(axis: .horizontal, from: 320, to: 360))
        XCTAssertTrue(right.collapse(axis: .horizontal, from: 320, to: 440))
        for index in right.pieces.indices { right.pieces[index].origin.x += 500 }
        var document = StitchDocument(pieces: left.pieces + right.pieces)
        document.style.transition = .accordion
        document.style.accordionPerspective = 0
        document.style.accordionYaw = 0
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        for (edge, length) in [(CGFloat(0), CGFloat(40)), (1000, 120)] {
            let depths = projection.faces.flatMap(\.vertices).filter { $0.source.x == edge }.map(\.depth)
            let height = try XCTUnwrap(depths.max()) - XCTUnwrap(depths.min())
            XCTAssertEqual(height, length / 6 * sqrt(1 - 0.45 * 0.45), accuracy: 0.000001,
                "Different source cuts meeting at one canvas seam must keep their own pleat heights")
        }
    }

    func testManualWidthOnlyControlsJoinsWithoutMeasuredCuts() throws {
        let image = try pixels(width: 400, height: 400)
        var document = StitchDocument(pieces: [StitchPiece(image: image),
            StitchPiece(image: image, origin: CGPoint(x: 0, y: 400))])
        document.style.transition = .accordion
        XCTAssertTrue(document.joins.allSatisfy { $0.trimmedLength == nil })
        document.style.accordionWidth = 0
        XCTAssertFalse(document.hasAccordionFolds)
        XCTAssertFalse(try XCTUnwrap(StitchAccordionProjection(document: document)).hasProjectedOutput)
        for width in [CGFloat(8), 20] {
            document.style.accordionWidth = width
            let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
            let band = normalCoordinates(projection, axis: .horizontal).filter { $0 > 0 && $0 < 800 }
            XCTAssertEqual(try XCTUnwrap(band.last) - XCTUnwrap(band.first), width * 4, accuracy: 0.000001)
        }
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 390, to: 410))
        document.style.accordionWidth = 0
        XCTAssertTrue(document.hasAccordionFolds)
        let view = ImageEditingView(frame: document.bounds)
        view.installStitchDocument(document)
        XCTAssertTrue(view.canPreviewStitchPaper)
        XCTAssertTrue(try XCTUnwrap(StitchAccordionProjection(document: document)).hasProjectedOutput)
    }

    func testInspectorHidesManualWidthForAutomaticFolds() throws {
        let image = try pixels(width: 400, height: 400)
        var measured = StitchDocument(pieces: [StitchPiece(image: image)])
        measured.style.transition = .accordion
        XCTAssertTrue(measured.collapse(axis: .horizontal, from: 160, to: 200))
        var unmeasured = StitchDocument(pieces: [StitchPiece(image: image),
            StitchPiece(image: image, origin: CGPoint(x: 0, y: 400))])
        unmeasured.style.transition = .accordion
        for (document, widthIsHidden) in [(measured, true), (unmeasured, false)] {
            let window = NSWindow(contentRect: document.bounds, styleMask: .borderless,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let controller = StitchEditorController(document: document, window: window)
            let options = controller.makeSeamOptions()
            let width = try XCTUnwrap(options.subviews.first {
                $0.identifier?.rawValue == "stitch.seam.accordionWidth"
            } as? NSSlider)
            let pleats = try XCTUnwrap(options.subviews.first {
                $0.identifier?.rawValue == "stitch.seam.accordionPleats"
            } as? NSSlider)
            XCTAssertEqual(width.isHidden, widthIsHidden)
            XCTAssertEqual(width.isEnabled, !widthIsHidden)
            XCTAssertFalse(pleats.isHidden)
            XCTAssertTrue(pleats.isEnabled)
        }
    }

    func testLargeAndNearbyRemovalsKeepThePaperBounded() throws {
        let image = try pixels(width: 1000, height: 1000)
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = StitchDocument(pieces: [StitchPiece(image: image)])
            document.style.transition = .accordion
            XCTAssertTrue(document.collapse(axis: axis, from: 250, to: 450))
            XCTAssertTrue(document.collapse(axis: axis, from: 300, to: 500))
            for progress in [CGFloat(0), 0.5, 1] {
                let projection = try XCTUnwrap(StitchAccordionProjection(document: document, progress: progress))
                XCTAssertTrue(document.bounds.contains(projection.paperPath.boundingBoxOfPath))
                XCTAssertTrue(projection.faces.flatMap(\.vertices).allSatisfy {
                    $0.projected.x.isFinite && $0.projected.y.isFinite && $0.depth.isFinite && $0.depth > 0
                })
            }
        }
    }

    func testProjectedOutputNeverUsesTrimmedPixels() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let image = try XCTUnwrap(ImageProbe.makeImage(width: 320, height: 320) { context in
                context.setFillColor(NSColor(white: 0.25, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
                context.setFillColor(NSColor.red.cgColor)
                context.fill(axis == .horizontal ? CGRect(x: 0, y: 140, width: 320, height: 40)
                    : CGRect(x: 140, y: 0, width: 40, height: 320))
            }.cgImage(forProposedRect: nil, context: nil, hints: nil))
            var document = StitchDocument(pieces: [StitchPiece(image: image)], background: .transparent)
            XCTAssertTrue(document.collapse(axis: axis, from: 140, to: 180))
            document.style.transition = .accordion
            let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
            let flat = try XCTUnwrap(StitchRenderer.render(document))
            let warped = try XCTUnwrap(StitchAccordionWarp.render(flat, projection: projection))
            let pixels = try XCTUnwrap(warped.dataProvider?.data) as Data
            var coloredPixels = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let red: UInt8 = pixels[offset]
                let green: UInt8 = pixels[offset + 1]
                let blue: UInt8 = pixels[offset + 2]
                if red != green || green != blue { coloredPixels += 1 }
            }
            XCTAssertEqual(coloredPixels, 0, "The omitted red strip must never appear on a folded face")
        }
    }

    private func pixels(width: Int, height: Int) throws -> CGImage {
        try XCTUnwrap(ImageProbe.solidImage(width: width, height: height)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private func normalCoordinates(_ projection: StitchAccordionProjection, axis: StitchAxis) -> [CGFloat] {
        Array(Set(projection.faces.flatMap(\.vertices).map {
            axis == .horizontal ? $0.source.y : $0.source.x
        })).sorted()
    }
}
