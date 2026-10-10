import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class StitchAccordionProjectionTests: XCTestCase {
    func testPerspectiveMovesThePrintedTextureAndThePaperOutlineInBothAxes() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let document = try fixture(axis: axis)
            let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
            let flat = try flatImage(document)
            let output = try XCTUnwrap(StitchAccordionWarp.render(flat, projection: projection))
            let dimensions = try XCTUnwrap(projection.outputPixelDimensions(pixelWidth: flat.width, pixelHeight: flat.height))
            XCTAssertEqual(output.width, dimensions.width)
            XCTAssertEqual(output.height, dimensions.height)
            let pixels = try bytes(output), source = try bytes(flat)
            let folded = projection.faces.filter { $0.paperSample != nil && abs($0.shade - 1) > 0.015 }
            XCTAssertGreaterThan(folded.count, 3)
            var checked = 0
            for face in projection.faces where face.paperSample == nil {
                let sourceCenter = CGPoint(x: (face.a.source.x + face.b.source.x + face.c.source.x) / 3,
                                           y: (face.a.source.y + face.b.source.y + face.c.source.y) / 3)
                let projected = try XCTUnwrap(projection.project(sourceCenter))
                let x = Int(floor(projected.x - projection.outputBounds.minX))
                let y = Int(floor(projected.y - projection.outputBounds.minY))
                guard x >= 0, x < output.width, y >= 0, y < output.height else { continue }
                let center = CGPoint(x: CGFloat(x) + projection.outputBounds.minX + 0.5,
                                     y: CGFloat(y) + projection.outputBounds.minY + 0.5)
                let original = try XCTUnwrap(projection.unproject(center))
                // Small trims make narrow faces. Rounding to a raster pixel can
                // land on the next face, whose lighting belongs to that face.
                guard face.isFrontFacing, let local = face.unproject(center),
                      hypot(local.source.x - original.x, local.source.y - original.y) < 0.000001 else { continue }
                XCTAssertGreaterThan(hypot(original.x - center.x, original.y - center.y), 1)
                let sx = original.x - projection.documentBounds.minX - 0.5
                let sy = original.y - projection.documentBounds.minY - 0.5
                for channel in 0..<3 {
                    let expected = bilinear(source, width: flat.width, height: flat.height,
                                            x: sx, y: sy, channel: channel) * face.shade
                    XCTAssertEqual(CGFloat(pixels[(y * output.width + x) * 4 + channel]), expected, accuracy: 2)
                }
                XCTAssertEqual(pixels[(y * output.width + x) * 4 + 3], 255)
                checked += 1
            }
            XCTAssertGreaterThan(checked, 3)
            XCTAssertNotEqual(pixels, source)
            var outsideCorners = 0
            for (x, y) in [(0, 0), (output.width - 1, 0), (0, output.height - 1), (output.width - 1, output.height - 1)] {
                let alpha = pixels[(y * output.width + x) * 4 + 3]
                let hit = projection.unproject(CGPoint(x: projection.outputBounds.minX + CGFloat(x) + 0.5,
                                                       y: projection.outputBounds.minY + CGFloat(y) + 0.5))
                if hit != nil { XCTAssertGreaterThan(alpha, 0) }
                else { XCTAssertLessThan(alpha, 255); outsideCorners += 1 }
            }
            XCTAssertGreaterThan(outsideCorners, 0)
            XCTAssertNil(projection.unproject(CGPoint(x: projection.outputBounds.minX - 1,
                                                      y: projection.outputBounds.midY)))
            XCTAssertTrue(projection.outputBounds.contains(projection.paperPath.boundingBoxOfPath))
        }
    }

    func testPointsRoundTripAcrossEveryFaceAtNonzeroDocumentOrigins() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let document = try fixture(axis: axis, origin: CGPoint(x: -83, y: 47))
            let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
            for face in projection.faces where face.isFrontFacing && face.paperSample == nil {
                for weights in [(CGFloat(0.2), CGFloat(0.3)), (0.45, 0.15), (0.1, 0.75)] {
                    let point = CGPoint(x: face.a.source.x * weights.0 + face.b.source.x * weights.1
                                        + face.c.source.x * (1 - weights.0 - weights.1),
                                        y: face.a.source.y * weights.0 + face.b.source.y * weights.1
                                        + face.c.source.y * (1 - weights.0 - weights.1))
                    let projected = try XCTUnwrap(projection.project(point))
                    let restored = try XCTUnwrap(projection.unproject(projected))
                    XCTAssertEqual(restored.x, point.x, accuracy: 0.000001)
                    XCTAssertEqual(restored.y, point.y, accuracy: 0.000001)
                }
            }
            XCTAssertNil(projection.project(CGPoint(x: document.bounds.minX - 1, y: document.bounds.midY)))
            XCTAssertNil(projection.unproject(CGPoint(x: CGFloat.nan, y: 0)))
            let selection = CGRect(x: document.bounds.minX + 17, y: document.bounds.minY + 31,
                                   width: document.bounds.width - 43, height: document.bounds.height - 59)
            let path = try XCTUnwrap(projection.path(for: selection))
            let center = try XCTUnwrap(projection.project(CGPoint(x: selection.midX, y: selection.midY)))
            XCTAssertTrue(path.contains(center))
            XCTAssertNil(projection.path(for: CGRect(x: document.bounds.maxX + 1, y: 0, width: 10, height: 10)))
        }
    }

    func testAnimationTopologyAndSharedCreasesAreExact() throws {
        let document = try fixture(axis: .horizontal)
        let flat = try XCTUnwrap(StitchAccordionProjection(document: document, progress: 0))
        let folded = try XCTUnwrap(StitchAccordionProjection(document: document))
        XCTAssertTrue(flat.hasProjectedOutput)
        XCTAssertTrue(folded.hasProjectedOutput)
        XCTAssertEqual(flat.faces.count, folded.faces.count)
        var vertices: [String: StitchAccordionProjection.Vertex] = [:]
        var reused = 0
        for (before, after) in zip(flat.faces, folded.faces) {
            for (a, b) in zip(before.vertices, after.vertices) {
                XCTAssertEqual(a.source, b.source)
                XCTAssertEqual(a.rest, b.rest)
                XCTAssertEqual(a.projected.x, a.rest.x + document.bounds.midX - flat.source.unfoldedBounds.midX, accuracy: 0.000001)
                XCTAssertEqual(a.projected.y, a.rest.y + document.bounds.midY - flat.source.unfoldedBounds.midY, accuracy: 0.000001)
                let key = "\(b.rest.x):\(b.rest.y)"
                if let existing = vertices[key] {
                    XCTAssertEqual(existing.projected, b.projected)
                    XCTAssertEqual(existing.depth, b.depth)
                    reused += 1
                } else { vertices[key] = b }
            }
        }
        XCTAssertGreaterThan(reused, 10)
        // A perspective quadrilateral alone has straight outer edges. Folded
        // crease vertices must deviate from the straight top-to-bottom edge.
        var deviation: CGFloat = 0
        for edge in [document.bounds.minX, document.bounds.maxX] {
            let side = vertices.values.filter { abs($0.source.x - edge) < 0.000001 }
                .sorted { $0.rest.y < $1.rest.y }
            let first = try XCTUnwrap(side.first), last = try XCTUnwrap(side.last)
            let dx = last.projected.x - first.projected.x, dy = last.projected.y - first.projected.y
            let distance = side.map {
                abs(dy * ($0.projected.x - first.projected.x) - dx * ($0.projected.y - first.projected.y)) / hypot(dx, dy)
            }.max() ?? 0
            deviation = max(deviation, distance)
        }
        XCTAssertGreaterThan(deviation, 0.25, "Even a 20px trim must bend the paper silhouette")
        XCTAssertEqual(Set(folded.drawingOrder), Set(folded.faces.indices))
    }

    func testSharedEdgesDoNotLeaveTransparentCracks() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let document = try fixture(axis: axis, solid: true)
            let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
            let output = try XCTUnwrap(StitchAccordionWarp.render(try flatImage(document), projection: projection))
            let pixels = try bytes(output)
            let paperPath = projection.paperPath
            var interior = 0, cracks = 0
            for y in 0..<output.height {
                for x in 0..<output.width {
                    let point = CGPoint(x: projection.outputBounds.minX + CGFloat(x) + 0.5,
                                        y: projection.outputBounds.minY + CGFloat(y) + 0.5)
                    if projection.unproject(point) != nil && paperPath.contains(point) {
                        interior += 1
                        if pixels[(y * output.width + x) * 4 + 3] == 0 { cracks += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(interior, output.width * output.height / 2)
            XCTAssertEqual(cracks, 0)
        }
    }

    func testTransparentPixelsAndPremultipliedAlphaSurviveTheWarp() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let document = try fixture(axis: axis, alpha: 112, hole: true)
            let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
            let output = try XCTUnwrap(StitchAccordionWarp.render(try flatImage(document), projection: projection))
            let pixels = try bytes(output)
            var opaquePaperPixels = 0, raisedAlpha = 0, invalidPremultiplication = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let alpha = pixels[offset + 3]
                if alpha > 112 { raisedAlpha += 1 }
                if alpha == 112 { opaquePaperPixels += 1 }
                for channel in 0..<3 { if pixels[offset + channel] > alpha { invalidPremultiplication += 1 } }
            }
            XCTAssertEqual(raisedAlpha, 0)
            XCTAssertEqual(invalidPremultiplication, 0)
            XCTAssertGreaterThan(opaquePaperPixels, output.width * output.height / 3)
            let hole = try XCTUnwrap(projection.project(CGPoint(x: document.bounds.minX + 54, y: document.bounds.minY + 54)))
            let x = Int(hole.x - projection.outputBounds.minX), y = Int(hole.y - projection.outputBounds.minY)
            XCTAssertEqual(pixels[(y * output.width + x) * 4 + 3], 0)
        }
    }

    func testPreviewUsesTheSameDocumentProjectionAsNativePixels() throws {
        let document = try fixture(axis: .horizontal)
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        let native = try XCTUnwrap(StitchAccordionWarp.render(try flatImage(document), projection: projection))
        let previewFlat = try flatImage(document, dimension: max(document.bounds.width, document.bounds.height) / 2)
        let preview = try XCTUnwrap(StitchAccordionWarp.render(previewFlat, projection: projection))
        let nativeBytes = try bytes(native), previewBytes = try bytes(preview)
        XCTAssertLessThanOrEqual(abs(native.width - preview.width * 2), 1)
        XCTAssertLessThanOrEqual(abs(native.height - preview.height * 2), 1)
        var checked = 0
        for face in projection.faces where face.paperSample == nil {
            let source = CGPoint(x: (face.a.source.x + face.b.source.x + face.c.source.x) / 3,
                                 y: (face.a.source.y + face.b.source.y + face.c.source.y) / 3)
            let point = try XCTUnwrap(projection.project(source))
            let x = Int((point.x - projection.outputBounds.minX) / 2)
            let y = Int((point.y - projection.outputBounds.minY) / 2)
            // A crease has a lighting discontinuity. Compare only pixels whose
            // full native sampling footprint stays on the same paper face.
            var sameFace = true
            for dy in 0..<2 {
                for dx in 0..<2 {
                    let sample = CGPoint(x: projection.outputBounds.minX + CGFloat(x * 2 + dx) + 0.5,
                                         y: projection.outputBounds.minY + CGFloat(y * 2 + dy) + 0.5)
                    if face.unproject(sample) == nil { sameFace = false }
                }
            }
            guard sameFace else { continue }
            for channel in 0..<4 {
                var value: CGFloat = 0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let index = ((y * 2 + dy) * native.width + x * 2 + dx) * 4 + channel
                        value += CGFloat(nativeBytes[index]) / 4
                    }
                }
                XCTAssertEqual(CGFloat(previewBytes[(y * preview.width + x) * 4 + channel]), value, accuracy: 3)
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 3)
    }

    func testMultipleAxesAndShortPartialJoinsHaveValidIndependentPaperPatches() throws {
        let image = try texture(width: 120, height: 100, solid: true)
        let collage = StitchDocument(pieces: [
            StitchPiece(image: image, origin: .zero),
            StitchPiece(image: image, origin: CGPoint(x: 120, y: 0)),
            StitchPiece(image: image, origin: CGPoint(x: 0, y: 100)),
            StitchPiece(image: image, origin: CGPoint(x: 120, y: 100))
        ], style: accordionStyle(), background: .transparent)
        let short = StitchDocument(pieces: [
            StitchPiece(image: try texture(width: 120, height: 30, solid: true)),
            StitchPiece(image: try texture(width: 80, height: 90, solid: true), origin: CGPoint(x: 20, y: 30))
        ], style: accordionStyle(), background: .transparent)
        for document in [collage, short] {
            let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
            XCTAssertTrue(projection.hasProjectedOutput)
            XCTAssertTrue(projection.outputBounds.contains(projection.paperPath.boundingBoxOfPath))
            let rendered = try XCTUnwrap(StitchAccordionWarp.render(try flatImage(document), projection: projection))
            let dimensions = try XCTUnwrap(projection.outputPixelDimensions(pixelWidth: Int(document.bounds.width), pixelHeight: Int(document.bounds.height)))
            XCTAssertEqual(rendered.width, dimensions.width)
            XCTAssertEqual(rendered.height, dimensions.height)
            for face in projection.faces where face.isFrontFacing && face.paperSample == nil {
                let point = CGPoint(x: (face.a.source.x + face.b.source.x + face.c.source.x) / 3,
                                    y: (face.a.source.y + face.b.source.y + face.c.source.y) / 3)
                let restored = try XCTUnwrap(projection.unproject(try XCTUnwrap(projection.project(point))))
                XCTAssertEqual(restored.x, point.x, accuracy: 0.000001)
                XCTAssertEqual(restored.y, point.y, accuracy: 0.000001)
            }
        }
    }

    func testLayerSamplerMatchesNativePaperOnAsymmetricSafePixels() throws {
        var document = StitchDocument(pieces: [StitchPiece(image: try texture(width: 360, height: 280))],
                                      style: accordionStyle(), background: .transparent)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 70, to: 90))
        document.restoreFoldTextures([:])
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document, progress: 0))
        let width = Int(document.bounds.width), height = Int(document.bounds.height)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = y < 120 ? 180 : 20
                pixels[offset + 1] = y < 120 ? 30 : 80
                pixels[offset + 2] = y < 120 ? 40 : 220
                // Contrasting glyph-sized marks should not become paper color.
                if x % 27 < 3 && y % 23 < 5 {
                    pixels[offset] = 4; pixels[offset + 1] = 4; pixels[offset + 2] = 4
                }
            }
        }
        let safe = try image(pixels, width: width, height: height)
        let output = try XCTUnwrap(StitchAccordionWarp.render(safe, projection: projection))
        let bytes = try bytes(output)
        for face in projection.faces where face.paperSample != nil {
            let sample = try XCTUnwrap(face.paperSample)
            let color = try XCTUnwrap(StitchAccordionWarp.paperColor(image: safe, sample: sample,
                                                                    documentBounds: projection.documentBounds))
            let rest = CGPoint(x: (face.a.rest.x + face.b.rest.x + face.c.rest.x) / 3,
                               y: (face.a.rest.y + face.b.rest.y + face.c.rest.y) / 3)
            let point = try XCTUnwrap(face.projectRest(rest))
            let x = Int(point.x - projection.outputBounds.minX), y = Int(point.y - projection.outputBounds.minY)
            let offset = (y * output.width + x) * 4
            XCTAssertEqual(CGFloat(bytes[offset]), color.red * 255, accuracy: 1)
            XCTAssertEqual(CGFloat(bytes[offset + 1]), color.green * 255, accuracy: 1)
            XCTAssertEqual(CGFloat(bytes[offset + 2]), color.blue * 255, accuracy: 1)
            XCTAssertEqual(CGFloat(bytes[offset + 3]), color.alpha * 255, accuracy: 1)
            XCTAssertGreaterThan(color.red, color.blue, "The top seam's red background wins over bottom blue and small dark glyphs")
        }
    }

    func testNativeDensityAndOddRemovedLengthAtNonzeroOrigin() throws {
        let original = try texture(width: 320, height: 320, solid: true)
        var document = StitchDocument(pieces: [StitchPiece(image: original, origin: CGPoint(x: -17, y: 31))],
                                      style: accordionStyle(), background: .transparent)
        document.style.accordionPerspective = 0
        document.style.accordionYaw = 0
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 131, to: 172))
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document, progress: 0))
        XCTAssertEqual(projection.source.unfoldedBounds.size, CGSize(width: 320, height: 320))
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 558,
            bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try flatImage(document), in: CGRect(x: 0, y: 0, width: 640, height: 558))
        let native = try XCTUnwrap(StitchAccordionWarp.render(try XCTUnwrap(context.makeImage()), projection: projection))
        let dimensions = try XCTUnwrap(projection.outputPixelDimensions(pixelWidth: 640, pixelHeight: 558))
        XCTAssertEqual(native.width, dimensions.width)
        XCTAssertEqual(native.height, dimensions.height)
        XCTAssertEqual(native.width, 640)
        // Integral alignment may add one transparent document point for an odd cut.
        XCTAssertTrue((640...642).contains(native.height))
        let first = try XCTUnwrap(projection.project(CGPoint(x: 3, y: 61)))
        let next = try XCTUnwrap(projection.project(CGPoint(x: 23, y: 61)))
        XCTAssertEqual((next.x - first.x) * 2, 40, accuracy: 0.000001)
    }

    func testSanitizedCutTextureCannotRecoverOriginalRemovedPixels() throws {
        var pixels = [UInt8](repeating: 255, count: 240 * 240 * 4)
        for y in 100..<140 {
            for x in 0..<240 {
                pixels[(y * 240 + x) * 4 + 1] = 0
                pixels[(y * 240 + x) * 4 + 2] = 0
            }
        }
        var document = StitchDocument(pieces: [StitchPiece(image: try image(pixels, width: 240, height: 240))],
                                      style: accordionStyle(), background: .transparent)
        let safe = try image([UInt8](repeating: 255, count: 240 * 240 * 4), width: 240, height: 240)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 100, to: 140, texture: safe))
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        let pixelsAfter = try bytes(XCTUnwrap(StitchAccordionWarp.render(try flatImage(document), projection: projection)))
        var redPixels = 0
        for offset in stride(from: 0, to: pixelsAfter.count, by: 4) {
            if pixelsAfter[offset + 3] > 0, Int(pixelsAfter[offset]) > Int(pixelsAfter[offset + 1]) + 10 { redPixels += 1 }
        }
        XCTAssertEqual(redPixels, 0)
    }

    func testUnfoldedCutTexturesRestoreTheExactPrintedPatternOnBothAxesAndMirrors() throws {
        let source = try printedTexture()
        let original = try bytes(source)
        for axis in [StitchAxis.horizontal, .vertical] {
            var cut = StitchDocument(pieces: [StitchPiece(image: source)], style: accordionStyle(), background: .transparent)
            XCTAssertTrue(cut.collapse(axis: axis, from: 80, to: 144, texture: source))
            for horizontalMirror in [false, true] {
                for verticalMirror in [false, true] {
                    var document = cut
                    if horizontalMirror { document = try XCTUnwrap(document.flipped(horizontal: true)) }
                    if verticalMirror { document = try XCTUnwrap(document.flipped(horizontal: false)) }
                    let projection = try XCTUnwrap(StitchAccordionProjection(document: document, progress: 0))
                    XCTAssertTrue(projection.faces.contains { $0.paperTexture != nil })
                    let output = try XCTUnwrap(StitchAccordionWarp.render(try flatImage(document), projection: projection))
                    XCTAssertEqual(output.width, 240); XCTAssertEqual(output.height, 240)
                    let rendered = try bytes(output)
                    var mismatches = 0
                    for y in 1..<239 {
                        for x in 1..<239 {
                            let sx = horizontalMirror ? 239 - x : x
                            let sy = verticalMirror ? 239 - y : y
                            let expected = (sy * 240 + sx) * 4, actual = (y * 240 + x) * 4
                            if (0..<4).contains(where: { abs(Int(rendered[actual + $0]) - Int(original[expected + $0])) > 1 }) {
                                mismatches += 1
                            }
                        }
                    }
                    XCTAssertEqual(mismatches, 0, "An unfolded full-size mesh must restore the original printing, including cut strips and flip orientation")
                }
            }
        }
    }

    func testFoldedPrintedStripUsesPerspectiveCorrectUVAndLightingInBothAxes() throws {
        let source = try printedTexture()
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = StitchDocument(pieces: [StitchPiece(image: source)], style: accordionStyle(), background: .transparent)
            document.style.accordionPerspective = 30
            document.style.accordionYaw = 35
            XCTAssertTrue(document.collapse(axis: axis, from: 80, to: 144, texture: source))
            let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
            let output = try XCTUnwrap(StitchAccordionWarp.render(try flatImage(document), projection: projection))
            let rendered = try bytes(output)
            var checked = 0
            for face in projection.faces where face.paperTexture != nil {
                let material = try XCTUnwrap(face.paperTexture)
                let sample = try bytes(material.image)
                let rest = CGPoint(x: (face.a.rest.x + face.b.rest.x + face.c.rest.x) / 3,
                                   y: (face.a.rest.y + face.b.rest.y + face.c.rest.y) / 3)
                let center = try XCTUnwrap(face.projectRest(rest))
                let x = Int(floor(center.x - projection.outputBounds.minX))
                let y = Int(floor(center.y - projection.outputBounds.minY))
                guard (0..<output.width).contains(x), (0..<output.height).contains(y) else { continue }
                let point = CGPoint(x: projection.outputBounds.minX + CGFloat(x) + 0.5,
                                    y: projection.outputBounds.minY + CGFloat(y) + 0.5)
                guard let local = face.unproject(point),
                      let weights = StitchAccordionProjection.Face.weights(point, face.a.projected, face.b.projected, face.c.projected),
                      min(weights.x, weights.y, weights.z) > 0.04 else { continue }
                let nearest = projection.faces.filter { $0.isFrontFacing || $0.paperSample != nil }
                    .compactMap { $0.unproject(point)?.depth }.min()
                guard let nearest, abs(nearest - local.depth) < 0.000001 else { continue }
                let auv = try XCTUnwrap(face.a.paperUV), buv = try XCTUnwrap(face.b.paperUV), cuv = try XCTUnwrap(face.c.paperUV)
                let wa = weights.x / face.a.depth, wb = weights.y / face.b.depth, wc = weights.z / face.c.depth
                let total = wa + wb + wc
                let u = (wa * auv.x + wb * buv.x + wc * cuv.x) / total
                let v = (wa * auv.y + wb * buv.y + wc * cuv.y) / total
                let sx = material.source.minX + (material.horizontalFlipped ? 1 - u : u) * material.source.width - 0.5
                let sy = material.source.minY + (material.verticalFlipped ? 1 - v : v) * material.source.height - 0.5
                let offset = (y * output.width + x) * 4
                for channel in 0..<3 {
                    let expected = min(255, bilinear(sample, width: material.image.width, height: material.image.height,
                                                    x: sx, y: sy, channel: channel) * face.shade)
                    XCTAssertEqual(CGFloat(rendered[offset + channel]), expected, accuracy: 1)
                }
                XCTAssertEqual(rendered[offset + 3], 255)
                checked += 1
            }
            XCTAssertGreaterThan(checked, 1, "Projected pleats must retain actual pattern pixels rather than one sampled color")
        }
    }

    func testMaterialEffectsMapOnceAndRemainInAnimationSourceWithoutChangingGeometry() throws {
        var document = StitchDocument(pieces: [StitchPiece(image: try printedTexture())], style: accordionStyle(), background: .transparent)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 80, to: 144))
        let original = try XCTUnwrap(StitchAccordionProjection(document: document))
        var calls = 0
        let mapped = try XCTUnwrap(original.mappingPaperTextures { image in
            calls += 1
            return image
        })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(mapped.outputBounds, original.outputBounds)
        XCTAssertEqual(mapped.drawingOrder, original.drawingOrder)
        for (a, b) in zip(original.faces, mapped.faces) {
            XCTAssertEqual(a.a.projected, b.a.projected)
            XCTAssertEqual(a.b.rest, b.b.rest)
            XCTAssertEqual(a.c.paperUV, b.c.paperUV)
            XCTAssertTrue(a.paperTexture?.image === b.paperTexture?.image)
        }
        let frame = try XCTUnwrap(mapped.source.projection(progress: 0))
        XCTAssertTrue(frame.faces.contains { $0.paperTexture?.image === mapped.faces.last?.paperTexture?.image })
        XCTAssertNil(original.mappingPaperTextures { _ in nil })
        XCTAssertNil(original.mappingPaperTextures { _ in try? self.printedTexture(width: 12, height: 12) })
    }

    func testTextureRasterStagingUsesOutputDensityAndKeepsNativeCopyPixels() throws {
        let preview = try XCTUnwrap(StitchAccordionWarp.textureRasterDimensions(width: 30_000, height: 3_000,
                                                                              outputDensity: 1_600 / 30_000.0))
        XCTAssertEqual(preview.width, 1_600)
        XCTAssertEqual(preview.height, 160)
        XCTAssertEqual(preview.width * preview.height, 256_000,
                       "A 1600px export must not allocate a 90M-pixel decoded cut strip")
        for density: CGFloat in [1, 2] {
            let native = try XCTUnwrap(StitchAccordionWarp.textureRasterDimensions(width: 30_000, height: 3_000,
                                                                                  outputDensity: density))
            XCTAssertEqual(native.width, 30_000)
            XCTAssertEqual(native.height, 3_000)
        }
        XCTAssertNil(StitchAccordionWarp.textureRasterDimensions(width: 30_000, height: 4_000, outputDensity: 0.05))
        XCTAssertNil(StitchAccordionWarp.textureRasterDimensions(width: 10, height: 10, outputDensity: .nan))
        XCTAssertNil(StitchAccordionWarp.textureRasterDimensions(width: 10, height: 10, outputDensity: 0))
        let numericalNoise = try XCTUnwrap(StitchAccordionWarp.textureRasterDimensions(width: 240, height: 64,
                                                                                     outputDensity: 0.5000000000000007))
        XCTAssertEqual(numericalNoise.width, 120); XCTAssertEqual(numericalNoise.height, 32)
        let genuineFraction = try XCTUnwrap(StitchAccordionWarp.textureRasterDimensions(width: 240, height: 64,
                                                                                      outputDensity: 0.5001))
        XCTAssertEqual(genuineFraction.width, 121); XCTAssertEqual(genuineFraction.height, 33)
    }

    func testResizedPrintedMaterialsAvoidDoubleDownsamplingAndCameraDragsRetainThem() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let image = try printedTexture()
            var document = StitchDocument(pieces: [StitchPiece(image: image)], style: accordionStyle(), background: .transparent)
            XCTAssertTrue(document.collapse(axis: axis, from: 80, to: 144, texture: image))
            let original = try XCTUnwrap(StitchAccordionProjection(document: document, progress: 0))
            let previewPixels = try flatImage(document, dimension: 120)
            let bounded = try XCTUnwrap(original.resizingPaperTextures(maxDimension: 120))
            let expected = try bytes(XCTUnwrap(StitchAccordionWarp.render(previewPixels, projection: original)))
            let actual = try bytes(XCTUnwrap(StitchAccordionWarp.render(previewPixels, projection: bounded)))
            XCTAssertEqual(actual.count, expected.count)
            XCTAssertTrue(zip(actual, expected).allSatisfy { pair in abs(Int(pair.0) - Int(pair.1)) <= 1 },
                          "Bounded cut images already match the preview's pixel density and must retain their sharp printing")
            let material = try XCTUnwrap(bounded.faces.first(where: { $0.paperTexture != nil })?.paperTexture)
            XCTAssertLessThanOrEqual(max(material.image.width, material.image.height), 120)
            XCTAssertTrue(material.isValid)
            let camera = StitchPaperCamera(perspective: -17, yaw: 23)
            let dragged = try XCTUnwrap(bounded.source.withCamera(camera).projection())
            XCTAssertEqual(dragged.source.camera, camera)
            XCTAssertEqual(dragged.source.unfoldedBounds, original.source.unfoldedBounds)
            XCTAssertTrue(dragged.faces.contains { $0.paperTexture?.image === material.image })
            XCTAssertNotEqual(dragged.faces[0].a.projected, original.faces[0].a.projected)
            let sourceOnly = try XCTUnwrap(original.source.resizingPaperTextures(maxDimension: 120).flatMap { $0.projection(progress: 0) })
            XCTAssertEqual(sourceOnly.faces.first(where: { $0.paperTexture != nil })?.paperTexture?.image.width, material.image.width)
            XCTAssertEqual(sourceOnly.faces.first(where: { $0.paperTexture != nil })?.paperTexture?.image.height, material.image.height)
            XCTAssertNil(original.resizingPaperTextures(maxDimension: 0))
        }
    }

    func testMaterialResizeHonorsItsExactPixelLimitDespiteFloatingPointScale() throws {
        let image = try printedTexture(width: 157, height: 120)
        var document = StitchDocument(pieces: [StitchPiece(image: image)], style: accordionStyle(), background: .transparent)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 40, to: 80, texture: image))
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        let bounded = try XCTUnwrap(projection.resizingPaperTextures(maxDimension: 120))
        let material = try XCTUnwrap(bounded.faces.first(where: { $0.paperTexture != nil })?.paperTexture)
        // 157 * (120 / 157) is 120.00000000000001 in CGFloat arithmetic.
        XCTAssertEqual(material.image.width, 120)
        XCTAssertEqual(material.image.height, 31)
        XCTAssertTrue(material.isValid)
    }

    func testInactivePlansAreIdentityAndInvalidActivePlansFailClosed() throws {
        var document = try fixture(axis: .horizontal)
        for value in [CGFloat.nan, .infinity, -1, 81] {
            document.style.accordionWidth = value
            XCTAssertNil(StitchAccordionProjection(document: document))
        }
        document.style.accordionWidth = 30
        for value in [CGFloat.nan, .infinity, -31, 31] {
            document.style.accordionPerspective = value
            XCTAssertNil(StitchAccordionProjection(document: document))
        }
        document.style.accordionPerspective = .nan
        document.style.accordionWidth = 0
        document.style.visible = false
        let disabled = try XCTUnwrap(StitchAccordionProjection(document: document))
        XCTAssertFalse(disabled.hasProjectedOutput)
        document.style.visible = true
        document.style.accordionWidth = .nan
        document.style.transition = .wave
        let otherTool = try XCTUnwrap(StitchAccordionProjection(document: document))
        XCTAssertFalse(otherTool.hasProjectedOutput)
        let flat = try flatImage(document)
        XCTAssertTrue(StitchAccordionWarp.render(flat, projection: otherTool) === flat)
        XCTAssertNil(StitchAccordionProjection(document: document, progress: .nan))
    }

    func testOptionalProjectedPaperFixtures() throws {
        guard let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_MACSHOT_SEAM_PREVIEW_DIR"]
            ?? ProcessInfo.processInfo.environment["MACSHOT_SEAM_PREVIEW_DIR"] else { return }
        for axis in [StitchAxis.horizontal, .vertical] {
            for dark in [false, true] {
                let source = try chart(dark: dark)
                var document = StitchDocument(pieces: [StitchPiece(image: source)], style: accordionStyle(), background: .transparent)
                document.style.accordionWidth = 44
                XCTAssertTrue(document.collapse(axis: axis, from: 290, to: 450))
                let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
                let output = try XCTUnwrap(StitchAccordionWarp.render(try flatImage(document), projection: projection))
                let url = URL(fileURLWithPath: directory).appendingPathComponent("accordion-perspective-\(axis)-\(dark ? "dark" : "light").png")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, output, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
                var config = BeautifyConfig()
                config.padding = 36
                config.cornerRadius = 4
                config.shadowRadius = 18
                if let wallpaper = MacOSWallpapers.installed.first(where: { !$0.isVideo }),
                   let pixels = MacOSWallpapers.image(for: wallpaper, maxDimension: 1600) {
                    config.customBackgroundImage = NSImage(cgImage: pixels, size: .zero)
                    config.prepareBackgroundCache()
                }
                let finished = try XCTUnwrap(ScreenshotPresentation(beautify: config, projection: projection)
                    .render(NSImage(cgImage: try flatImage(document), size: document.bounds.size)))
                let finishedPixels = try XCTUnwrap(finished.cgImage(forProposedRect: nil, context: nil, hints: nil))
                let finishedURL = url.deletingLastPathComponent().appendingPathComponent("finished-" + url.lastPathComponent)
                try XCTUnwrap(MacOSWallpapers.pngData(finishedPixels)).write(to: finishedURL)
            }
        }
    }

    private func accordionStyle() -> StitchStyle {
        var style = StitchStyle()
        style.transition = .accordion
        return style
    }

    private func fixture(axis: StitchAxis, origin: CGPoint = .zero, alpha: UInt8 = 255,
                         solid: Bool = false, hole: Bool = false) throws -> StitchDocument {
        let source = try texture(width: 360, height: 280, alpha: alpha, solid: solid, hole: hole)
        var document = StitchDocument(pieces: [StitchPiece(image: source, origin: origin)],
                                      style: accordionStyle(), background: .transparent)
        let offset = axis == .horizontal ? origin.y : origin.x
        XCTAssertTrue(document.collapse(axis: axis, from: offset + 130, to: offset + 150))
        return document
    }

    private func flatImage(_ document: StitchDocument, dimension: CGFloat? = nil) throws -> CGImage {
        var flat = document
        flat.style.visible = false
        return try XCTUnwrap(StitchRenderer.render(flat, maximumPreviewDimension: dimension))
    }

    private func texture(width: Int, height: Int, alpha: UInt8 = 255, solid: Bool = false, hole: Bool = false) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let opacity = hole && (38..<70).contains(x) && (38..<70).contains(y) ? 0 : Int(alpha)
                let colors = solid ? [220, 224, 230] : [40 + 180 * x / width, 30 + 180 * y / height, 100]
                for channel in 0..<3 { pixels[offset + channel] = UInt8((colors[channel] * opacity + 127) / 255) }
                pixels[offset + 3] = UInt8(opacity)
            }
        }
        return try image(pixels, width: width, height: height)
    }

    private func printedTexture(width: Int = 240, height: Int = 240) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(60 + x % 160)
                pixels[offset + 1] = UInt8(40 + y % 180)
                pixels[offset + 2] = (x / 11 + y / 7).isMultiple(of: 2) ? 190 : 40
            }
        }
        return try image(pixels, width: width, height: height)
    }

    private func image(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent))
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private func bilinear(_ pixels: [UInt8], width: Int, height: Int, x: CGFloat, y: CGFloat, channel: Int) -> CGFloat {
        let x = max(0, min(CGFloat(width - 1), x)), y = max(0, min(CGFloat(height - 1), y))
        let left = Int(floor(x)), top = Int(floor(y)), right = min(width - 1, left + 1), bottom = min(height - 1, top + 1)
        let fx = x - CGFloat(left), fy = y - CGFloat(top)
        let a = CGFloat(pixels[(top * width + left) * 4 + channel]) * (1 - fx)
            + CGFloat(pixels[(top * width + right) * 4 + channel]) * fx
        let b = CGFloat(pixels[(bottom * width + left) * 4 + channel]) * (1 - fx)
            + CGFloat(pixels[(bottom * width + right) * 4 + channel]) * fx
        return a * (1 - fy) + b * fy
    }

    private func chart(dark: Bool) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 760, height: 760,
            bitsPerComponent: 8, bytesPerRow: 760 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: dark ? 0.11 : 0.96, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 760, height: 760))
        context.setStrokeColor(CGColor(gray: dark ? 0.26 : 0.84, alpha: 1))
        context.setLineWidth(1)
        for coordinate in stride(from: 90, through: 670, by: 58) {
            context.move(to: CGPoint(x: 90, y: coordinate)); context.addLine(to: CGPoint(x: 670, y: coordinate))
            context.move(to: CGPoint(x: coordinate, y: 90)); context.addLine(to: CGPoint(x: coordinate, y: 670))
        }
        context.strokePath()
        context.setStrokeColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.95, alpha: 1))
        context.setLineWidth(7)
        context.move(to: CGPoint(x: 90, y: 170))
        context.addCurve(to: CGPoint(x: 300, y: 290), control1: CGPoint(x: 160, y: 170), control2: CGPoint(x: 250, y: 180))
        context.addCurve(to: CGPoint(x: 670, y: 590), control1: CGPoint(x: 390, y: 410), control2: CGPoint(x: 500, y: 270))
        context.strokePath()
        context.textPosition = CGPoint(x: 90, y: 695)
        let text = NSAttributedString(string: "Monthly growth", attributes: [
            .font: CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 25, nil),
            .foregroundColor: CGColor(gray: dark ? 0.92 : 0.17, alpha: 1)
        ])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return try XCTUnwrap(context.makeImage())
    }
}
