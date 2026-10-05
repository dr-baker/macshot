import AppKit
import XCTest

@MainActor
final class StitchPaperSamplerTests: XCTestCase {
    private func image(width: Int, height: Int, pixel: (Int, Int) -> SIMD4<UInt8>) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = pixel(x, y), i = (y * width + x) * 4
                bytes[i] = c.x; bytes[i + 1] = c.y; bytes[i + 2] = c.z; bytes[i + 3] = c.w
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func assertColor(_ color: NSColor, _ expected: SIMD4<UInt8>,
                             file: StaticString = #filePath, line: UInt = #line) {
        let rgb = color.usingColorSpace(.sRGB)!
        XCTAssertEqual(rgb.redComponent, CGFloat(expected.x) / CGFloat(expected.w), accuracy: 1 / 255, file: file, line: line)
        XCTAssertEqual(rgb.greenComponent, CGFloat(expected.y) / CGFloat(expected.w), accuracy: 1 / 255, file: file, line: line)
        XCTAssertEqual(rgb.blueComponent, CGFloat(expected.z) / CGFloat(expected.w), accuracy: 1 / 255, file: file, line: line)
        XCTAssertEqual(rgb.alphaComponent, CGFloat(expected.w) / 255, accuracy: 1 / 255, file: file, line: line)
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        XCTAssertEqual(image.alphaInfo, .premultipliedLast)
        let data = try XCTUnwrap(image.dataProvider?.data)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(CFDataGetBytePtr(data)),
            count: image.bytesPerRow * image.height))
    }

    func testInternalCutUsesItsLocalBackgroundAndRejectsTextAndBordersOnBothAxes() throws {
        let background = SIMD4<UInt8>(38, 102, 153, 255)
        for axis in [StitchAxis.horizontal, .vertical] {
            let source = image(width: 400, height: 400) { x, y in
                let normal = axis == .horizontal ? y : x
                let along = axis == .horizontal ? x : y
                guard (150..<250).contains(normal) else { return SIMD4(224, 80, 40, 255) }
                if (normal % 12 < 2 && along % 40 < 28) || (188..<190).contains(normal)
                    || (210..<212).contains(normal) { return SIMD4(0, 0, 0, 255) }
                return background
            }
            var document = StitchDocument(pieces: [StitchPiece(image: source)])
            XCTAssertTrue(document.collapse(axis: axis, from: 190, to: 210))
            let palette = StitchPaperSampler.palette(for: try XCTUnwrap(document.joins.first), pieces: document.pieces)
            for color in palette.negative + palette.positive { assertColor(color, background) }
        }
    }

    func testDarkGrayPageKeepsItsDominantBackgroundDespiteAntialiasedLightTextAtBothSourceScales() throws {
        let background = SIMD4<UInt8>(24, 24, 24, 255)
        for axis in [StitchAxis.horizontal, .vertical] {
            for sourceScale in [1, 2] {
                let source = image(width: 384 * sourceScale, height: 384 * sourceScale) { x, y in
                    let along = (axis == .horizontal ? x : y) / sourceScale
                    let normal = (axis == .horizontal ? y : x) / sourceScale
                    if normal % 28 < 11 && along % 40 < 28 {
                        let value: UInt8 = [232, 180, 96][normal % 3]
                        return SIMD4(value, value, value, 255)
                    }
                    return background
                }
                var document = StitchDocument(pieces: [StitchPiece(image: source)])
                XCTAssertTrue(document.collapse(axis: axis, from: CGFloat(192 * sourceScale),
                    to: CGFloat(240 * sourceScale)))
                let palette = StitchPaperSampler.palette(for: try XCTUnwrap(document.joins.first), pieces: document.pieces)
                for color in palette.negative + palette.positive { assertColor(color, background) }
            }
        }
    }

    func testTornPaperUsesExactDominantPageColorWithoutWhiteningTheBandAtFullAndPreviewSizes() throws {
        for background in [SIMD4<UInt8>(24, 24, 24, 255), SIMD4(236, 232, 222, 255)] {
            for axis in [StitchAxis.horizontal, .vertical] {
                let source = image(width: 384, height: 384) { x, y in
                    let along = axis == .horizontal ? x : y, normal = axis == .horizontal ? y : x
                    if normal % 28 < 11 && along % 40 < 28 {
                        let ink: UInt8 = background.x < 128 ? 232 : 28
                        return SIMD4(ink, ink, ink, 255)
                    }
                    return background
                }
                var document = StitchDocument(pieces: [StitchPiece(image: source)])
                XCTAssertTrue(document.collapse(axis: axis, from: 192, to: 240))
                document.style.transition = .torn
                document.style.tearWidth = 24; document.style.tearRoughness = 0
                let palette = StitchPaperSampler.palette(for: try XCTUnwrap(document.joins.first), pieces: document.pieces)
                for color in palette.negative + palette.positive { assertColor(color, background) }
                for dimension: CGFloat in [384, 192, 127] {
                    let result = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension))
                    let pixels = try bytes(result), scale = dimension / 384
                    document.style.visible = false
                    let original = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension))
                    let sourcePixels = try bytes(original)
                    document.style.visible = true
                    XCTAssertEqual(result.bytesPerRow, original.bytesPerRow)
                    let environment = ProcessInfo.processInfo.environment
                    if let directory = environment["MACSHOT_SEAM_PREVIEW_DIR"]
                        ?? environment["TEST_RUNNER_MACSHOT_SEAM_PREVIEW_DIR"] {
                        try write(result, directory: directory,
                            name: "tear-exact-paper-\(background.x < 128 ? "dark" : "light")-\(axis)-\(Int(dimension)).png")
                    }
                    for along in [32, 96, 160, 224, 288, 352] {
                        let x = Int(CGFloat(axis == .horizontal ? along : 192) * scale)
                        let y = Int(CGFloat(axis == .horizontal ? 192 : along) * scale)
                        let offset = y * result.bytesPerRow + x * 4
                        let alpha = pixels[offset + 3]
                        XCTAssertGreaterThan(alpha, 0)
                        XCTAssertEqual(alpha, sourcePixels[offset + 3], "Paper must retain the captured preview alpha")
                        for (channel, expected) in [background.x, background.y, background.z].enumerated() {
                            // Fractional preview boundaries can have partial
                            // source alpha. Compare premultiplied bytes to the
                            // same background multiplied by that retained alpha.
                            let expectedByte = (Int(expected) * Int(alpha) + 127) / 255
                            XCTAssertLessThanOrEqual(abs(Int(pixels[offset + channel]) - expectedByte), 2,
                                "\(axis), background \(background), preview \(dimension), along \(along), "
                                    + "pixel (\(x), \(y)), alpha \(alpha), channel \(channel), "
                                    + "actual \(pixels[offset + channel]), expected premultiplied \(expectedByte). "
                                    + "Sparse text must not tint or lift interior paper")
                        }
                    }
                }
            }
        }
    }

    func testTornLipsContrastWithTheirOwnLightOrDarkSheetInEachLocalSection() throws {
        let light = SIMD4<UInt8>(236, 232, 222, 255), dark = SIMD4<UInt8>(24, 24, 24, 255)
        for axis in [StitchAxis.horizontal, .vertical] {
            let source = image(width: 384, height: 384) { x, y in
                let along = axis == .horizontal ? x : y, normal = axis == .horizontal ? y : x
                let upperIsLight = along / 128 != 1
                return (normal < 192) == upperIsLight ? light : dark
            }
            var document = StitchDocument(pieces: [StitchPiece(image: source)])
            XCTAssertTrue(document.collapse(axis: axis, from: 184, to: 200))
            document.style.transition = .torn
            document.style.tearWidth = 24; document.style.tearRoughness = 0
            let result = try XCTUnwrap(StitchRenderer.render(document)), pixels = try bytes(result)
            for section in 0..<3 {
                for before in [true, false] {
                    let shouldDarken = (section != 1) == before
                    let reference = shouldDarken ? light : dark
                    let range = before ? 169..<175 : 194..<201
                    let brightness = range.map { normal -> Double in
                        let along = section * 128 + 64
                        let x = axis == .horizontal ? along : normal, y = axis == .horizontal ? normal : along
                        let offset = y * result.bytesPerRow + x * 4
                        return Double(pixels[offset]) * 0.2126 + Double(pixels[offset + 1]) * 0.7152
                            + Double(pixels[offset + 2]) * 0.0722
                    }
                    let original = Double(reference.x) * 0.2126 + Double(reference.y) * 0.7152 + Double(reference.z) * 0.0722
                    if shouldDarken {
                        XCTAssertLessThan(try XCTUnwrap(brightness.min()), original - 8,
                            "Light paper needs a darker torn lip within that section and side")
                    } else {
                        XCTAssertGreaterThan(try XCTUnwrap(brightness.max()), original + 8,
                            "Dark paper needs a lighter torn lip within that section and side")
                    }
                }
            }
        }
    }

    func testTornDecorationsPreserveEverySourceAlphaByteIncludingTranslucentPixelsAndHoles() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let source = image(width: 256, height: 256) { x, y in
                let along = axis == .horizontal ? x : y, normal = axis == .horizontal ? y : x
                let alpha = [UInt8(0), 96, 160, 224, 255][(along / 32 + normal / 11) % 5]
                return SIMD4(UInt8(Int(alpha) * 40 / 255), UInt8(Int(alpha) * 60 / 255),
                    UInt8(Int(alpha) * 80 / 255), alpha)
            }
            var document = StitchDocument(pieces: [StitchPiece(image: source)], background: .transparent)
            XCTAssertTrue(document.collapse(axis: axis, from: 120, to: 136))
            document.style.transition = .torn
            document.style.tearWidth = 24; document.style.tearRoughness = 7
            for dimension: CGFloat in [256, 127] {
                document.style.visible = false
                let original = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension))
                let before = try bytes(original)
                document.style.visible = true
                let result = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension))
                let after = try bytes(result)
                XCTAssertEqual(original.bytesPerRow, result.bytesPerRow)
                for offset in stride(from: 3, to: before.count, by: 4) {
                    XCTAssertEqual(after[offset], before[offset],
                        "Torn paper, lips, fibers and shadow must preserve each captured alpha byte")
                }
            }
        }
    }

    func testCroppedOffsetPiecesAndUnrelatedCapturesDoNotChangeThePaperColor() throws {
        let background = SIMD4<UInt8>(48, 112, 64, 255)
        let source = image(width: 300, height: 300) { x, y in
            (50..<250).contains(x) && (70..<210).contains(y) ? background : SIMD4(255, 0, 255, 255)
        }
        var a = StitchPiece(image: source, origin: CGPoint(x: -110, y: 37))
        a.source = CGRect(x: 50, y: 70, width: 200, height: 70)
        var b = a
        b.id = UUID(); b.source.origin.y = 140; b.origin.y = 107
        let join = StitchJoin(axis: .horizontal, position: 107, start: -110, end: 90)
        let palette = StitchPaperSampler.palette(for: join, pieces: [a, b])
        let unrelated = StitchPiece(image: image(width: 100, height: 100) { _, _ in SIMD4(0, 0, 255, 255) },
                                    origin: CGPoint(x: -220, y: 50))
        let other = StitchPaperSampler.palette(for: join, pieces: [unrelated, a, b])
        XCTAssertEqual(palette.negative, other.negative)
        XCTAssertEqual(palette.positive, other.positive)
        for color in palette.negative + palette.positive { assertColor(color, background) }
    }

    func testSectionColorsFollowTheSeamAndEachSheetRetainsItsOwnColor() throws {
        let colors = [SIMD4<UInt8>(240, 209, 161, 255), SIMD4(20, 30, 40, 255), SIMD4(51, 143, 115, 255)]
        let source = image(width: 768, height: 80) { x, _ in colors[x / 256] }
        let bottom = image(width: 768, height: 80) { _, _ in SIMD4(64, 96, 192, 255) }
        let document = StitchDocument(pieces: [StitchPiece(image: source), StitchPiece(image: bottom, origin: CGPoint(x: 0, y: 80))])
        let palette = StitchPaperSampler.palette(for: try XCTUnwrap(document.joins.first), pieces: document.pieces)
        let steps = palette.negative.count - 1
        for (section, color) in colors.enumerated() {
            assertColor(palette.negative[steps * (section * 2 + 1) / 6], color)
        }
        for color in palette.positive { assertColor(color, SIMD4(64, 96, 192, 255)) }
    }

    func testVisibleLayerAtTheSeamDeterminesThePaperInsteadOfCoveredCaptures() throws {
        let red = image(width: 400, height: 100) { _, _ in SIMD4(224, 40, 40, 255) }
        let blue = SIMD4<UInt8>(40, 80, 200, 255)
        let cover = StitchPiece(image: image(width: 160, height: 100) { _, _ in blue }, origin: CGPoint(x: 120, y: 50))
        let pieces = [StitchPiece(image: red), StitchPiece(image: red, origin: CGPoint(x: 0, y: 100)), cover]
        let palette = StitchPaperSampler.palette(for: .init(axis: .horizontal, position: 100, start: 0, end: 400), pieces: pieces)
        let center = palette.negative.count / 2
        assertColor(palette.negative[center], blue)
        assertColor(palette.positive[center], blue)
    }

    func testThinAdjacentSheetDoesNotBorrowAnotherCapturesBackgroundOnEitherAxis() throws {
        let blue = SIMD4<UInt8>(40, 80, 200, 255), green = SIMD4<UInt8>(40, 160, 80, 255)
        for axis in [StitchAxis.horizontal, .vertical] {
            func piece(_ length: Int, _ offset: Int, _ color: SIMD4<UInt8>) -> StitchPiece {
                StitchPiece(image: image(width: axis == .horizontal ? 256 : length,
                                         height: axis == .horizontal ? length : 256) { _, _ in color },
                            origin: axis == .horizontal ? CGPoint(x: 0, y: offset) : CGPoint(x: offset, y: 0))
            }
            let pieces = [piece(100, 0, SIMD4(220, 40, 40, 255)), piece(8, 100, blue), piece(100, 108, green)]
            let palette = StitchPaperSampler.palette(for: .init(axis: axis, position: 108, start: 0, end: 256), pieces: pieces)
            for color in palette.negative { assertColor(color, blue) }
            for color in palette.positive { assertColor(color, green) }
        }
    }

    func testOpaqueOnePixelSheetAtFractionalOriginKeepsItsOwnColorOnBothAxes() throws {
        let blue = SIMD4<UInt8>(40, 80, 200, 255), green = SIMD4<UInt8>(40, 160, 80, 255)
        for axis in [StitchAxis.horizontal, .vertical] {
            func piece(_ length: Int, _ offset: CGFloat, _ color: SIMD4<UInt8>) -> StitchPiece {
                StitchPiece(image: image(width: axis == .horizontal ? 256 : length,
                    height: axis == .horizontal ? length : 256) { _, _ in color },
                    origin: axis == .horizontal ? CGPoint(x: 0, y: offset) : CGPoint(x: offset, y: 0))
            }
            let pieces = [piece(100, -99.75, SIMD4(220, 40, 40, 255)),
                          piece(1, 0.25, blue), piece(100, 1.25, green)]
            let palette = StitchPaperSampler.palette(for: .init(axis: axis, position: 1.25, start: 0, end: 256), pieces: pieces)
            for color in palette.negative { assertColor(color, blue) }
            for color in palette.positive { assertColor(color, green) }
        }
    }

    func testFractionalSourceCropsKeepTheRenderersRoundedImageMappingOnBothAxes() throws {
        let source = image(width: 400, height: 400) { x, y in
            SIMD4(UInt8((x * 7 + y * 3) % 200), UInt8((x * 5 + y * 11) % 180),
                  UInt8((x * 13 + y * 17) % 220), 255)
        }
        var piece = StitchPiece(image: source, origin: CGPoint(x: -20.25, y: 38.25))
        piece.source = CGRect(x: 17.25, y: 23.25, width: 241.5, height: 198.5)
        // The renderer first makes this integral CGImage crop, then scales it
        // to the fractional frame. Sampling a subregion must keep that scale.
        let roundedSource = try XCTUnwrap(source.cropping(to: piece.source))
        var equivalent = StitchPiece(image: roundedSource, origin: piece.origin)
        equivalent.source = CGRect(origin: .zero, size: piece.source.size)
        for axis in [StitchAxis.horizontal, .vertical] {
            let frame = piece.frame
            let join = StitchJoin(axis: axis,
                position: (axis == .horizontal ? frame.minY : frame.minX) + 100.25,
                start: axis == .horizontal ? frame.minX : frame.minY,
                end: axis == .horizontal ? frame.maxX : frame.maxY)
            let actual = StitchPaperSampler.palette(for: join, pieces: [piece])
            let expected = StitchPaperSampler.palette(for: join, pieces: [equivalent])
            XCTAssertEqual(actual.negative, expected.negative)
            XCTAssertEqual(actual.positive, expected.positive)
        }
    }

    func testTranslucentThinOverlayCompositesTheVisibleSheetOnEachSide() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            func piece(_ length: Int, _ offset: Int, _ color: SIMD4<UInt8>) -> StitchPiece {
                StitchPiece(image: image(width: axis == .horizontal ? 256 : length,
                    height: axis == .horizontal ? length : 256) { _, _ in color },
                    origin: axis == .horizontal ? CGPoint(x: 0, y: offset) : CGPoint(x: offset, y: 0))
            }
            let pieces = [piece(100, 0, SIMD4(220, 40, 40, 255)), piece(100, 100, SIMD4(40, 160, 80, 255)),
                          piece(2, 99, SIMD4(20, 40, 100, 128))]
            let palette = StitchPaperSampler.palette(for: .init(axis: axis, position: 100, start: 0, end: 256), pieces: pieces)
            for color in palette.negative { assertColor(color, SIMD4(130, 60, 120, 255)) }
            for color in palette.positive { assertColor(color, SIMD4(40, 120, 140, 255)) }
        }
    }

    func testInvisibleThinOverlayDoesNotTurnPaperIntoABorderColorOnEitherAxis() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let source = image(width: axis == .horizontal ? 256 : 100,
                               height: axis == .horizontal ? 100 : 256) { x, y in
                let normal = axis == .horizontal ? y : x
                return normal == 0 || normal == 99 ? SIMD4(0, 0, 0, 255) : SIMD4(240, 240, 240, 255)
            }
            let pieces = [StitchPiece(image: source), StitchPiece(image: source,
                origin: axis == .horizontal ? CGPoint(x: 0, y: 100) : CGPoint(x: 100, y: 0))]
            let clear = StitchPiece(image: image(width: axis == .horizontal ? 256 : 2,
                height: axis == .horizontal ? 2 : 256) { _, _ in .zero },
                origin: axis == .horizontal ? CGPoint(x: 0, y: 99) : CGPoint(x: 99, y: 0))
            let join = StitchJoin(axis: axis, position: 100, start: 0, end: 256)
            let before = StitchPaperSampler.palette(for: join, pieces: pieces)
            let after = StitchPaperSampler.palette(for: join, pieces: pieces + [clear])
            XCTAssertEqual(before.negative, after.negative)
            XCTAssertEqual(before.positive, after.positive)
            for color in after.negative + after.positive { assertColor(color, SIMD4(240, 240, 240, 255)) }
        }
    }

    func testPaperDoesNotFillTransparentHolesEvenWithNegativeDocumentOrigins() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let source = image(width: 256, height: 256) { x, y in
                let along = axis == .horizontal ? x : y
                return (33..<68).contains(along) ? .zero : SIMD4(30, 40, 50, 255)
            }
            let origin = CGPoint(x: -43, y: -57)
            var document = StitchDocument(pieces: [StitchPiece(image: source, origin: origin)], background: .transparent)
            let offset = axis == .horizontal ? origin.y : origin.x
            XCTAssertTrue(document.collapse(axis: axis, from: offset + 120, to: offset + 136))
            for transition in [StitchTransition.torn, .fold] {
                document.style.transition = transition
                let result = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document)))
                for along in 40..<60 {
                    for normal in 100..<140 {
                        let c = try XCTUnwrap(result.colorAt(x: axis == .horizontal ? along : normal,
                                                            y: axis == .horizontal ? normal : along))
                        XCTAssertEqual(c.alphaComponent, 0, "Paper and shadow must leave clear source pixels clear")
                    }
                }
                let opaque = try XCTUnwrap(result.colorAt(x: axis == .horizontal ? 180 : 115,
                                                          y: axis == .horizontal ? 115 : 180))
                XCTAssertEqual(opaque.alphaComponent, 1)
            }
        }
    }

    func testWhollyTransparentSourceDoesNotProducePaperOrShadow() throws {
        let source = image(width: 100, height: 100) { _, _ in .zero }
        var document = StitchDocument(pieces: [StitchPiece(image: source)], background: .transparent)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 40, to: 60))
        for transition in [StitchTransition.torn, .fold] {
            document.style.transition = transition
            let rendered = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document)))
            for y in 25..<55 {
                for x in 0..<100 { XCTAssertEqual(rendered.colorAt(x: x, y: y)?.alphaComponent, 0) }
            }
        }
    }

    func testRoundedPreviewsKeepPaperOutOfTransparentSourceEdgesOnBothAxes() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let source = image(width: 256, height: 256) { x, y in
                let along = axis == .horizontal ? x : y, normal = axis == .horizontal ? y : x
                return (33..<84).contains(along) && (114..<158).contains(normal) ? .zero : SIMD4(30, 40, 50, 255)
            }
            var document = StitchDocument(pieces: [StitchPiece(image: source)], background: .transparent)
            XCTAssertTrue(document.collapse(axis: axis, from: 120, to: 136))
            document.style.visible = false
            let original = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: 127)))
            document.style.visible = true
            for transition in [StitchTransition.torn, .fold] {
                document.style.transition = transition
                let output = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: 127)))
                for y in 0..<original.pixelsHigh {
                    for x in 0..<original.pixelsWide where original.colorAt(x: x, y: y)?.alphaComponent == 0 {
                        XCTAssertEqual(output.colorAt(x: x, y: y)?.alphaComponent, 0,
                            "Rounded bitmap dimensions must keep the paper mask aligned with the original")
                    }
                }
            }
        }
    }

    func testPaletteCacheReusesStyleEditsAndInvalidatesSourceCropOriginAndLayerChanges() throws {
        let green = SIMD4<UInt8>(48, 112, 64, 255), blue = SIMD4<UInt8>(64, 96, 192, 255)
        let source = image(width: 64, height: 64) { _, _ in green }
        var a = StitchPiece(image: source)
        a.source = CGRect(x: 16, y: 16, width: 32, height: 32)
        var b = a
        b.id = UUID(); b.origin.y = 32
        let original = StitchDocument(pieces: [a, b])
        let cache = original.paperPaletteCache
        let baseline = cache.snapshot(for: original.joins, pieces: original.pieces)
        var style = original
        style.style.transition = .fold; style.style.foldDepth = 28; style.pieces[0].label = "Renamed"
        XCTAssertTrue(style.paperPaletteCache === cache)
        XCTAssertTrue(cache.snapshot(for: style.joins, pieces: style.pieces) === baseline)
        for edit in 0..<4 {
            let before = cache.snapshot(for: original.joins, pieces: original.pieces)
            var changed = original
            switch edit {
            case 0: changed.pieces[0].source.origin.x += 1
            case 1: changed.pieces[0].origin.x += 8
            case 2: changed.pieces.reverse()
            default:
                changed.pieces[0] = StitchPiece(image: image(width: 32, height: 32) { _, _ in blue })
            }
            let after = cache.snapshot(for: changed.joins, pieces: changed.pieces)
            XCTAssertFalse(before === after, "A source/layout edit must recompute paper colors")
            if edit == 3 {
                for color in try XCTUnwrap(after.palettes.first).negative { assertColor(color, blue) }
            }
        }
    }

    func testLargeCollageBoundsAggregateSamplingAndReusesItWhileAdjustingSeams() throws {
        let green = SIMD4<UInt8>(48, 112, 64, 255), blue = SIMD4<UInt8>(40, 80, 200, 255)
        let source = image(width: 30_000, height: 25) { x, _ in (1_000..<2_000).contains(x) ? blue : green }
        let document = StitchDocument(pieces: (0..<128).map {
            StitchPiece(image: source, origin: CGPoint(x: 0, y: $0 * 25))
        })
        XCTAssertTrue(document.canRender)
        let joins = document.joins
        XCTAssertEqual(joins.count, 127)
        let start = Date.timeIntervalSinceReferenceDate
        let cold = document.paperPaletteCache.snapshot(for: joins, pieces: document.pieces)
        let coldTime = Date.timeIntervalSinceReferenceDate - start
        XCTAssertEqual(cold.rasterCount, joins.count * 2, "Each side must rasterize once, then share its pixels across palette stops")
        XCTAssertGreaterThan(cold.rasterPixelCount, 0)
        XCTAssertLessThanOrEqual(cold.rasterPixelCount, 3_300_000, "Long thin strips must bound actual raster work across the document")
        for palette in cold.palettes {
            XCTAssertEqual(palette.negative.count, 129); XCTAssertEqual(palette.positive.count, 129)
            // Stop 6 is at x=1406.25, inside the visible blue section near x=1500.
            assertColor(palette.negative[6], blue); assertColor(palette.positive[6], blue)
            for colors in [palette.negative, palette.positive] {
                assertColor(colors[0], green); assertColor(colors[128], green)
            }
        }
        let warmStart = Date.timeIntervalSinceReferenceDate
        for depth in 1...32 {
            var next = document
            next.style.transition = .fold; next.style.foldDepth = CGFloat(depth)
            XCTAssertTrue(next.paperPaletteCache.snapshot(for: joins, pieces: next.pieces) === cold)
        }
        print("Automatic seam paper for 128 long strips: \(cold.rasterCount) rasters, \(cold.rasterPixelCount) pixels, cold \(coldTime)s, 32 cached adjustments \(Date.timeIntervalSinceReferenceDate - warmStart)s")
        var mixed = document
        for index in 64..<128 { mixed.pieces[index].source.size.width = 64 }
        let mixedJoins = mixed.joins
        let mixedSnapshot = mixed.paperPaletteCache.snapshot(for: mixedJoins, pieces: mixed.pieces)
        XCTAssertLessThanOrEqual(mixedSnapshot.rasterPixelCount, 8_000_000,
            "A mix of short and long joins must bound raster work without discarding palette stops")
        for (join, palette) in zip(mixedJoins, mixedSnapshot.palettes) {
            let steps = max(1, min(128, Int(ceil((join.end - join.start) / 16))))
            XCTAssertEqual(palette.negative.count, steps + 1); XCTAssertEqual(palette.positive.count, steps + 1)
            if join.end == 30_000 {
                assertColor(palette.negative[6], blue); assertColor(palette.positive[6], blue)
            }
        }
    }

    func testManyClearLayersBoundRasterWorkAndKeepLocalSectionColors() throws {
        let green = SIMD4<UInt8>(48, 112, 64, 255), blue = SIMD4<UInt8>(40, 80, 200, 255)
        let source = image(width: 30_000, height: 25) { x, _ in (1_000..<2_000).contains(x) ? blue : green }
        let clear = image(width: 30_000, height: 200) { _, _ in .zero }
        let pieces = (0..<8).map { StitchPiece(image: source, origin: CGPoint(x: 0, y: $0 * 25)) }
            + (0..<120).map { _ in StitchPiece(image: clear) }
        let document = StitchDocument(pieces: pieces)
        XCTAssertTrue(document.canRender)
        let joins = document.joins
        XCTAssertEqual(joins.count, 7)
        let snapshot = document.paperPaletteCache.snapshot(for: joins, pieces: pieces)
        XCTAssertLessThanOrEqual(snapshot.rasterPixelCount, 8_000_000,
            "Many overlapping candidates must reduce raster density, keeping palette positions intact")
        for palette in snapshot.palettes {
            XCTAssertEqual(palette.negative.count, 129); XCTAssertEqual(palette.positive.count, 129)
            assertColor(palette.negative[6], blue); assertColor(palette.positive[6], blue)
            assertColor(palette.negative[128], green); assertColor(palette.positive[128], green)
        }
    }

    func testLowContrastPhotoColorsAndTranslucentSourcesAreDeterministic() throws {
        let source = image(width: 240, height: 160) { x, y in
            SIMD4(UInt8(40 + x % 71), UInt8(15 + y % 53), UInt8(30 + (x + y) % 83), 128)
        }
        var document = StitchDocument(pieces: [StitchPiece(image: source)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 70, to: 90))
        let join = try XCTUnwrap(document.joins.first)
        let a = StitchPaperSampler.palette(for: join, pieces: document.pieces)
        let b = StitchPaperSampler.palette(for: join, pieces: document.pieces)
        XCTAssertEqual(a.negative, b.negative); XCTAssertEqual(a.positive, b.positive)
        for color in a.negative + a.positive {
            let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
            XCTAssertEqual(rgb.alphaComponent, 128 / 255.0, accuracy: 1 / 255)
            XCTAssertTrue((0...1).contains(rgb.redComponent) && (0...1).contains(rgb.greenComponent)
                          && (0...1).contains(rgb.blueComponent))
        }
    }

    func testFoldReturnUsesAdjacentSheetColorsAtFullAndPreviewSizesOnBothAxes() throws {
        let warm = SIMD4<UInt8>(230, 180, 110, 255), blue = SIMD4<UInt8>(40, 90, 190, 255)
        for axis in [StitchAxis.horizontal, .vertical] {
            let source = image(width: 384, height: 384) { x, y in
                (axis == .horizontal ? y : x) < 192 ? warm : blue
            }
            var document = StitchDocument(pieces: [StitchPiece(image: source)])
            XCTAssertTrue(document.collapse(axis: axis, from: 184, to: 200))
            document.style.transition = .fold
            document.style.foldStrength = 1
            let join = try XCTUnwrap(document.joins.first)
            for dimension: CGFloat in [384, 192, 127] {
                document.style.visible = true
                let result = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension)))
                document.style.visible = false
                let original = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension)))
                let scale = dimension / 384
                func color(_ bitmap: NSBitmapImageRep, normalPixel: Int) throws -> NSColor {
                    try XCTUnwrap(bitmap.colorAt(x: axis == .horizontal ? Int(192 * scale) : normalPixel,
                        y: axis == .horizontal ? normalPixel : Int(192 * scale))).usingColorSpace(.sRGB)!
                }
                // The thin return straddles the join. At reduced sizes the pixel
                // above it can mix both sheets, while the landing stays blue.
                let lowerPixel = Int(ceil(join.position * scale))
                let upper = try color(result, normalPixel: lowerPixel - 1)
                let lower = try color(result, normalPixel: lowerPixel)
                XCTAssertGreaterThan(upper.redComponent, 0.65)
                XCTAssertGreaterThan(upper.redComponent, upper.blueComponent + 0.04,
                    "The upper edge must retain its warm sheet color through preview mixing")
                XCTAssertGreaterThan(lower.blueComponent, 0.45)
                XCTAssertLessThan(lower.redComponent, 0.4)
                if dimension == 384 {
                    let capturedUpper = try color(original, normalPixel: lowerPixel - 1)
                    let capturedLower = try color(original, normalPixel: lowerPixel)
                    XCTAssertGreaterThan(abs(upper.redComponent - capturedUpper.redComponent)
                        + abs(lower.blueComponent - capturedLower.blueComponent), 2 / 255,
                        "The returned edge must visibly use its adjacent sheet colors")
                }
            }
        }
    }

    func testFoldReturnTracksLocalSectionColorsAtExportAndPreviewSizes() throws {
        let colors = [SIMD4<UInt8>(240, 236, 225, 255), SIMD4(28, 32, 40, 255), SIMD4(50, 101, 83, 255)]
        for axis in [StitchAxis.horizontal, .vertical] {
            func document(uniform: SIMD4<UInt8>? = nil) -> StitchDocument {
                let source = image(width: 768, height: 768) { x, y in
                    uniform ?? colors[(axis == .horizontal ? x : y) / 256]
                }
                var document = StitchDocument(pieces: [StitchPiece(image: source)])
                XCTAssertTrue(document.collapse(axis: axis, from: 240, to: 528))
                document.style.transition = .fold
                document.style.foldStrength = 1
                return document
            }
            let sections = document()
            for dimension: CGFloat in [768, 384, 127] {
                let result = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(sections,
                    maximumPreviewDimension: dimension)))
                let scale = dimension / 768
                func color(_ bitmap: NSBitmapImageRep, along: Int, normal: Int) throws -> NSColor {
                    try XCTUnwrap(bitmap.colorAt(x: Int(CGFloat(axis == .horizontal ? along : normal) * scale),
                        y: Int(CGFloat(axis == .horizontal ? normal : along) * scale))?.usingColorSpace(.sRGB))
                }
                for (section, background) in colors.enumerated() {
                    let reference = NSBitmapImageRep(cgImage: try XCTUnwrap(StitchRenderer.render(document(uniform: background),
                        maximumPreviewDimension: dimension)))
                    for normal in [237, 239, 240, 242, 244] {
                        let local = try color(result, along: section * 256 + 128, normal: normal)
                        let uniform = try color(reference, along: 384, normal: normal)
                        XCTAssertEqual(local.redComponent, uniform.redComponent, accuracy: 2 / 255)
                        XCTAssertEqual(local.greenComponent, uniform.greenComponent, accuracy: 2 / 255)
                        XCTAssertEqual(local.blueComponent, uniform.blueComponent, accuracy: 2 / 255,
                            "Each fold section must match the same captured background folded on its own")
                    }
                }
            }
        }
    }

    func testTornPaperTracksSectionBoundariesWithoutMovingItsPaletteStopsOnEitherAxis() throws {
        let colors = [SIMD4<UInt8>(240, 236, 225, 255), SIMD4(28, 32, 40, 255), SIMD4(50, 101, 83, 255)]
        for axis in [StitchAxis.horizontal, .vertical] {
            let source = image(width: 768, height: 768) { x, y in colors[(axis == .horizontal ? x : y) / 256] }
            var document = StitchDocument(pieces: [StitchPiece(image: source)])
            XCTAssertTrue(document.collapse(axis: axis, from: 240, to: 528))
            document.style.transition = .torn
            document.style.tearWidth = 24; document.style.tearRoughness = 0
            for dimension: CGFloat in [768, 384, 192] {
                let result = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension))
                let data = try XCTUnwrap(result.dataProvider?.data)
                let pixels = try XCTUnwrap(CFDataGetBytePtr(data))
                XCTAssertEqual(result.alphaInfo, .premultipliedLast)
                let scale = dimension / 768
                // The first dark palette stop is exactly at the section edge.
                // Nearby plateaus must also stay within their captured sections.
                for (along, section) in [(232, 0), (256, 1), (280, 1), (536, 2)] {
                    let x = Int(CGFloat(axis == .horizontal ? along : 240) * scale)
                    let y = Int(CGFloat(axis == .horizontal ? 240 : along) * scale)
                    let offset = y * result.bytesPerRow + x * 4
                    let expected = colors[section]
                    // Read the renderer's sRGB bytes directly. colorAt returns
                    // a calibrated NSColor whose conversion changes these bytes.
                    for (channel, byte) in [expected.x, expected.y, expected.z].enumerated() {
                        let actual = CGFloat(pixels[offset + channel]) / 255
                        let background = CGFloat(byte) / 255
                        XCTAssertEqual(actual, background, accuracy: 4 / 255,
                            "Paper colors must align with source sections at full and preview sizes")
                    }
                }
            }
        }
    }

    func testOptionalLocalPaperFixtures() throws {
        let environment = ProcessInfo.processInfo.environment
        let directory = environment["MACSHOT_SEAM_PREVIEW_DIR"] ?? environment["TEST_RUNNER_MACSHOT_SEAM_PREVIEW_DIR"]
        guard let directory else { return }
        let colors = [SIMD4<UInt8>(240, 236, 225, 255), SIMD4(28, 32, 40, 255), SIMD4(50, 101, 83, 255)]
        for axis in [StitchAxis.horizontal, .vertical] {
            let source = image(width: 768, height: 768) { x, y in
                let along = axis == .horizontal ? x : y
                let normal = axis == .horizontal ? y : x
                let base = colors[along / 256]
                if normal % 32 < 3 && along % 70 < 50 && normal > 70 && normal < 700 {
                    return along / 256 == 0 ? SIMD4(65, 70, 80, 255) : SIMD4(190, 195, 205, 255)
                }
                return base
            }
            if axis == .horizontal { try write(source, directory: directory, name: "paper-source.png") }
            var document = StitchDocument(pieces: [StitchPiece(image: source)])
            XCTAssertTrue(document.collapse(axis: axis, from: 240, to: 528))
            for transition in [StitchTransition.torn, .fold] {
                document.style.transition = transition
                try write(XCTUnwrap(StitchRenderer.render(document)), directory: directory, name: "paper-\(transition.rawValue)-\(axis).png")
            }
        }
    }

    func testOptionalDominantBackgroundTearFixtures() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["MACSHOT_SEAM_PREVIEW_DIR"]
            ?? environment["TEST_RUNNER_MACSHOT_SEAM_PREVIEW_DIR"] else { return }
        for dark in [true, false] {
            let background = NSColor(srgbRed: dark ? 24 / 255.0 : 0.95,
                green: dark ? 24 / 255.0 : 0.94, blue: dark ? 24 / 255.0 : 0.92, alpha: 1)
            let ink = NSColor(srgbRed: dark ? 0.9 : 0.18, green: dark ? 0.9 : 0.19,
                blue: dark ? 0.9 : 0.21, alpha: 1)
            let source = try XCTUnwrap(ImageProbe.makeImage(width: 560, height: 320) { context in
                context.translateBy(x: 0, y: 320)
                context.scaleBy(x: 1, y: -1)
                context.setFillColor(background.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 560, height: 320))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                defer { NSGraphicsContext.restoreGraphicsState() }
                let lines = ["The torn edge follows the page background.",
                    "Thin fibers add just enough local contrast.",
                    "Sparse text must not tint the exposed paper.",
                    "Sections keep their own colors on each side."]
                for (index, text) in lines.enumerated() {
                    (text as NSString).draw(at: CGPoint(x: 28, y: 24 + index * 34),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: ink])
                }
                ("Captured detail stays sharp." as NSString).draw(at: CGPoint(x: 28, y: 268),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 15),
                        .foregroundColor: ink.withAlphaComponent(0.6)])
            }.cgImage(forProposedRect: nil, context: nil, hints: nil))
            for axis in [StitchAxis.horizontal, .vertical] {
                var document = StitchDocument(pieces: [StitchPiece(image: source)])
                XCTAssertTrue(document.collapse(axis: axis, from: axis == .horizontal ? 176 : 240,
                    to: axis == .horizontal ? 240 : 280))
                document.style.transition = .torn
                let prefix = "tear-page-\(dark ? "neutral-dark" : "light")-\(axis)"
                try write(source, directory: directory, name: "\(prefix)-source.png")
                try write(XCTUnwrap(StitchRenderer.render(document)), directory: directory, name: "\(prefix)-full.png")
                for dimension: CGFloat in [256, 127] {
                    try write(XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: dimension)),
                        directory: directory, name: "\(prefix)-preview-\(Int(dimension)).png")
                }
            }
        }
    }

    private func write(_ image: CGImage, directory: String, name: String) throws {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
    }
}
