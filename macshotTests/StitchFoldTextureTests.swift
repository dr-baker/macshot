import AppKit
import XCTest

@MainActor
final class StitchFoldTextureTests: XCTestCase {
    func testEachAxisRetainsTheOriginalPatternAcrossTheCompleteRemovedStrip() throws {
        let image = try pattern()
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = StitchDocument(pieces: [StitchPiece(image: image)])
            XCTAssertTrue(document.collapse(axis: axis, from: 18, to: 30))
            let join = try XCTUnwrap(document.joins.first)
            let texture = try XCTUnwrap(join.texture)
            XCTAssertTrue(texture.isValid)
            XCTAssertEqual(join.trimmedLength, 12)
            XCTAssertEqual(texture.source.width, axis == .horizontal ? 60 : 12)
            XCTAssertEqual(texture.source.height, axis == .horizontal ? 12 : 60)
            try assertPattern(join, original: image, normalStart: 18)
        }
    }

    func testSuppliedCompositedSnapshotKeepsRedactedPixelsInTheFold() throws {
        let image = try pattern()
        let sanitized = try XCTUnwrap(ImageProbe.solidImage(width: 60, height: 60,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = StitchDocument(pieces: [StitchPiece(image: image)])
            XCTAssertTrue(document.collapse(axis: axis, from: 18, to: 30, texture: sanitized))
            let join = try XCTUnwrap(document.joins.first)
            let texture = try XCTUnwrap(join.texture)
            let bitmap = NSBitmapImageRep(cgImage: texture.image)
            for point in [(0, 0), (texture.image.width / 2, texture.image.height / 2),
                          (texture.image.width - 1, texture.image.height - 1)] {
                XCTAssertEqual(try rgba(bitmap, x: point.0, y: point.1), [0, 0, 0, 255])
            }
            XCTAssertTrue(document.pieces.allSatisfy { $0.image === image })
        }
    }

    func testRepeatedCutsInterleavePreviouslyOmittedPixelsInSourceOrder() throws {
        let image = try pattern()
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = StitchDocument(pieces: [StitchPiece(image: image)])
            XCTAssertTrue(document.collapse(axis: axis, from: 20, to: 30))
            XCTAssertTrue(document.collapse(axis: axis, from: 10, to: 32))
            let join = try XCTUnwrap(document.joins.first)
            XCTAssertEqual(join.trimmedLength, 32)
            XCTAssertEqual(document.foldTextures.count, 1, "Absorbed cut buffers are released")
            try assertPattern(join, original: image, normalStart: 10)
        }
    }

    func testCutsTouchingEitherEndOfASeamPreserveItsOriginalPixels() throws {
        let image = try pattern()
        for axis in [StitchAxis.horizontal, .vertical] {
            for band in [(CGFloat(10), CGFloat(20)), (CGFloat(20), CGFloat(30))] {
                var document = StitchDocument(pieces: [StitchPiece(image: image)])
                XCTAssertTrue(document.collapse(axis: axis, from: 20, to: 30))
                XCTAssertTrue(document.collapse(axis: axis, from: band.0, to: band.1))
                let join = try XCTUnwrap(document.joins.first)
                XCTAssertEqual(join.trimmedLength, 20)
                try assertPattern(join, original: image, normalStart: band.0)
            }
        }
    }

    func testCrossingMultiplePriorSeamsRetainsOneContinuousOriginalStrip() throws {
        let image = try pattern()
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = StitchDocument(pieces: [StitchPiece(image: image)])
            XCTAssertTrue(document.collapse(axis: axis, from: 8, to: 12))
            XCTAssertTrue(document.collapse(axis: axis, from: 24, to: 30))
            XCTAssertEqual(document.foldTextures.count, 2)
            XCTAssertTrue(document.collapse(axis: axis, from: 4, to: 32))
            let join = try XCTUnwrap(document.joins.first)
            XCTAssertEqual(join.trimmedLength, 38)
            XCTAssertEqual(document.foldTextures.count, 1)
            try assertPattern(join, original: image, normalStart: 4)
        }
    }

    func testBothMirrorsReverseTheRelevantTextureCoordinateWithoutDuplicatingTheImage() throws {
        let image = try pattern()
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = StitchDocument(pieces: [StitchPiece(image: image)])
            XCTAssertTrue(document.collapse(axis: axis, from: 18, to: 30))
            let originalTexture = try XCTUnwrap(document.joins.first?.texture)
            for horizontal in [true, false] {
                let mirrored = try XCTUnwrap(document.flipped(horizontal: horizontal))
                let join = try XCTUnwrap(mirrored.joins.first)
                let texture = try XCTUnwrap(join.texture)
                XCTAssertTrue(texture.image === originalTexture.image)
                XCTAssertEqual(texture.horizontalFlipped, horizontal)
                XCTAssertEqual(texture.verticalFlipped, !horizontal)
                try assertPattern(join, original: image, normalStart: 18,
                    horizontalFlipped: horizontal, verticalFlipped: !horizontal)
                let restored = try XCTUnwrap(mirrored.flipped(horizontal: horizontal))
                XCTAssertEqual(restored.pieces.map(\.trimStamps), document.pieces.map(\.trimStamps))
                try assertPattern(try XCTUnwrap(restored.joins.first), original: image, normalStart: 18)
            }
        }
    }

    func testRepeatedCutAfterAMirrorInterleavesInTheMirroredOrder() throws {
        let image = try pattern()
        for axis in [StitchAxis.horizontal, .vertical] {
            for horizontal in [true, false] {
                var document = StitchDocument(pieces: [StitchPiece(image: image)])
                XCTAssertTrue(document.collapse(axis: axis, from: 18, to: 30))
                document = try XCTUnwrap(document.flipped(horizontal: horizontal))
                let normalFlipped = axis == .horizontal ? !horizontal : horizontal
                let start: CGFloat = normalFlipped ? 24 : 12
                XCTAssertTrue(document.collapse(axis: axis, from: start, to: start + 12))
                let join = try XCTUnwrap(document.joins.first)
                XCTAssertEqual(join.trimmedLength, 24)
                try assertPattern(join, original: image, normalStart: start,
                    horizontalFlipped: horizontal, verticalFlipped: !horizontal,
                    fullImageMirror: true)
            }
        }
    }

    func testCroppedAndMovedContactsMapOnlyTheirSurvivingTangentRange() throws {
        let image = try pattern()
        var document = StitchDocument(pieces: [StitchPiece(image: image)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 18, to: 30))
        document = try XCTUnwrap(document.cropped(to: CGRect(x: 10, y: 5, width: 40, height: 40)))
        let join = try XCTUnwrap(document.joins.first)
        let texture = try XCTUnwrap(join.texture)
        XCTAssertEqual(texture.source, CGRect(x: 10, y: 0, width: 40, height: 12))
        try assertPattern(join, original: image, normalStart: 18, tangentStart: 10)
        for index in document.pieces.indices {
            document.pieces[index].origin.x += 70
            document.pieces[index].origin.y += 90
        }
        let moved = try XCTUnwrap(document.joins.first)
        XCTAssertTrue(try XCTUnwrap(moved.texture).image === texture.image)
        XCTAssertEqual(moved.texture?.source, texture.source)
        try assertPattern(moved, original: image, normalStart: 18, tangentStart: 10)
        for index in document.pieces.indices {
            document.pieces[index].origin.x += 0.1
            document.pieces[index].origin.y += 0.2
        }
        let fractional = try XCTUnwrap(document.joins.first)
        XCTAssertTrue(try XCTUnwrap(fractional.texture).isValid)
        try assertPattern(fractional, original: image, normalStart: 18, tangentStart: 10)
        document.pieces[1].origin.x += 1
        XCTAssertTrue(document.joins.allSatisfy { $0.texture == nil })
    }

    func testHistoryRoundTripPreservesTextureAndMirrorProvenance() throws {
        let image = try pattern()
        var document = StitchDocument(pieces: [StitchPiece(image: image)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 18, to: 30))
        document = try XCTUnwrap(document.flipped(horizontal: false))
        let saved = try XCTUnwrap(SavedStitchDocument(document))
        XCTAssertEqual(saved.images.count, 1)
        XCTAssertEqual(saved.foldTextures.count, 1)
        let restored = try XCTUnwrap(JSONDecoder().decode(SavedStitchDocument.self,
            from: JSONEncoder().encode(saved)).restore())
        XCTAssertEqual(restored.pieces.map(\.trimStamps), document.pieces.map(\.trimStamps))
        try assertPattern(try XCTUnwrap(restored.joins.first), original: image, normalStart: 18,
                          verticalFlipped: true)
    }

    func testLegacyHistoryUsesSafeMaterialInsteadOfReconstructingRemovedOriginals() throws {
        let image = try pattern()
        var document = StitchDocument(pieces: [StitchPiece(image: image)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 18, to: 30))
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with:
            JSONEncoder().encode(XCTUnwrap(SavedStitchDocument(document)))) as? [String: Any])
        encoded.removeValue(forKey: "foldTextures")
        var pieces = try XCTUnwrap(encoded["pieces"] as? [[String: Any]])
        for index in pieces.indices {
            var stamps = try XCTUnwrap(pieces[index]["trimStamps"] as? [[String: Any]])
            for stamp in stamps.indices { stamps[stamp].removeValue(forKey: "normalReversed") }
            pieces[index]["trimStamps"] = stamps
        }
        encoded["pieces"] = pieces
        document = try XCTUnwrap(JSONDecoder().decode(SavedStitchDocument.self,
            from: JSONSerialization.data(withJSONObject: encoded)).restore())
        XCTAssertEqual(document.joins.first?.trimmedLength, 12)
        XCTAssertNil(document.joins.first?.texture)
        XCTAssertTrue(document.foldTextureImages.isEmpty)
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 12, to: 24))
        XCTAssertEqual(document.joins.first?.trimmedLength, 24)
        XCTAssertNil(document.joins.first?.texture)
    }

    func testTextureIdentityInvalidatesTheNativeRenderMemo() throws {
        let image = try pattern()
        var document = StitchDocument(pieces: [StitchPiece(image: image)])
        document.style.transition = .accordion
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 18, to: 30))
        var changed = document
        changed.style.accordionPerspective += 2
        XCTAssertTrue(document.hasSameAccordionPixels(as: changed))
        let strip = try XCTUnwrap(document.foldTextures.first)
        let old = try XCTUnwrap(strip.value.first)
        let copied = try pattern(width: old.image.width, height: old.image.height)
        XCTAssertFalse(copied === old.image)
        changed.restoreFoldTextures([strip.key: [StitchFoldTexture(image: copied, axis: old.axis,
            start: old.start, end: old.end, removedLength: old.removedLength)]])
        XCTAssertFalse(document.isIdentical(to: changed))
        XCTAssertFalse(document.hasSameAccordionPixels(as: changed))
    }

    func testOrphanBuffersAreReleasedAfterCropOrDeletionWhileMovedPairsKeepThem() throws {
        let image = try pattern()
        var document = StitchDocument(pieces: [StitchPiece(image: image)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 18, to: 30))
        var separated = document
        separated.pieces[1].origin.y += 20
        separated.pruneFoldTextures()
        XCTAssertEqual(separated.foldTextures.count, 1)
        let cropped = try XCTUnwrap(document.cropped(to: CGRect(x: 0, y: 0, width: 60, height: 10)))
        XCTAssertTrue(cropped.foldTextures.isEmpty)
        document.pieces.removeLast()
        document.pruneFoldTextures()
        XCTAssertTrue(document.foldTextures.isEmpty)
    }

    func testSuppliedSnapshotMustHaveTheDocumentNativeDimensions() throws {
        var document = StitchDocument(pieces: [StitchPiece(image: try pattern())])
        let original = document
        let small = try pattern(width: 30, height: 30)
        XCTAssertFalse(document.collapse(axis: .horizontal, from: 18, to: 30, texture: small))
        XCTAssertTrue(document.isIdentical(to: original))
    }

    func testInvalidHistoryTextureGeometryAndOrphanReferencesFailClosed() throws {
        var document = StitchDocument(pieces: [StitchPiece(image: try pattern())])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 18, to: 30))
        let saved = try XCTUnwrap(SavedStitchDocument(document))
        let strip = try XCTUnwrap(saved.foldTextures.first)
        for invalid in [
            SavedStitchDocument.FoldTexture(cutID: strip.cutID, horizontal: true, start: 0,
                end: 59, removedLength: 12, image: strip.image),
            SavedStitchDocument.FoldTexture(cutID: UUID(), horizontal: true, start: 0,
                end: 60, removedLength: 12, image: strip.image),
            SavedStitchDocument.FoldTexture(cutID: strip.cutID, horizontal: true, start: 0,
                end: 60, removedLength: .infinity, image: strip.image)
        ] {
            var malformed = saved
            malformed.foldTextures = [invalid]
            XCTAssertNil(malformed.restore())
        }
        var malformed = saved
        malformed.foldTextures = Array(repeating: strip, count: StitchDocument.maximumFoldTextures + 1)
        XCTAssertNil(malformed.restore())
    }

    func testHistoryPixelBudgetReservesUniqueSourceBuffersBeforeFoldTextures() throws {
        // Sequential providers need no large allocation until an image is drawn.
        // This regression only inspects image dimensions and the model budget.
        let image = try metadataImage(width: 10_000, height: 4_000)
        let a = StitchPiece(image: image)
        let b = StitchPiece(image: image, origin: CGPoint(x: 10_000, y: 0))
        let shared = StitchDocument(pieces: [a, b])
        XCTAssertEqual(shared.foldTexturePixelBudget, min(StitchDocument.maximumFoldTexturePixels,
            SavedCaptureValidation.maximumImagePixels - 40_000_000))
        let otherImage = try metadataImage(width: 10_000, height: 4_000)
        let distinct = StitchDocument(pieces: [a,
            StitchPiece(image: otherImage, origin: CGPoint(x: 10_000, y: 0))])
        XCTAssertEqual(distinct.foldTexturePixelBudget, min(StitchDocument.maximumFoldTexturePixels,
            SavedCaptureValidation.maximumImagePixels - 80_000_000))
        XCTAssertLessThan(distinct.foldTexturePixelBudget, shared.foldTexturePixelBudget)
    }

    private func metadataImage(width: Int, height: Int) throws -> CGImage {
        var callbacks = CGDataProviderSequentialCallbacks(version: 0,
            getBytes: { _, buffer, count in
                buffer.initializeMemory(as: UInt8.self, repeating: 0, count: count)
                return count
            }, skipForward: { _, count in count }, rewind: { _ in }, releaseInfo: nil)
        let provider = try XCTUnwrap(CGDataProvider(sequentialInfo: nil, callbacks: &callbacks))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pattern(width: Int = 60, height: Int = 60) throws -> CGImage {
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            let pixels = buffer.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    pixels[offset] = UInt8((x * 3 + 13) % 256)
                    pixels[offset + 1] = UInt8((y * 4 + 19) % 256)
                    pixels[offset + 2] = UInt8((x * 2 + y * 3 + 7) % 256)
                    pixels[offset + 3] = 255
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func assertPattern(_ join: StitchJoin, original: CGImage, normalStart: CGFloat,
                               tangentStart: Int = 0, horizontalFlipped: Bool = false,
                               verticalFlipped: Bool = false, fullImageMirror: Bool = false,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let texture = try XCTUnwrap(join.texture, file: file, line: line)
        let bitmap = NSBitmapImageRep(cgImage: texture.image)
        let originalBitmap = NSBitmapImageRep(cgImage: original)
        let width = Int(texture.source.width), height = Int(texture.source.height)
        let normalLength = Int(try XCTUnwrap(join.trimmedLength, file: file, line: line))
        for y in 0..<height {
            for x in 0..<width {
                let sampleX = Int(texture.source.minX) + (texture.horizontalFlipped ? width - 1 - x : x)
                let sampleY = Int(texture.source.minY) + (texture.verticalFlipped ? height - 1 - y : y)
                var expectedX = join.axis == .horizontal ? tangentStart + x : Int(normalStart) + x
                var expectedY = join.axis == .horizontal ? Int(normalStart) + y : tangentStart + y
                if horizontalFlipped {
                    expectedX = fullImageMirror ? original.width - 1 - expectedX
                        : (join.axis == .horizontal ? original.width - 1 - x
                            : Int(normalStart) + normalLength - 1 - x)
                }
                if verticalFlipped {
                    expectedY = fullImageMirror ? original.height - 1 - expectedY
                        : (join.axis == .vertical ? original.height - 1 - y
                            : Int(normalStart) + normalLength - 1 - y)
                }
                let actual = try rgba(bitmap, x: sampleX, y: sampleY)
                let expected = try rgba(originalBitmap, x: expectedX, y: expectedY)
                for channel in 0..<4 {
                    XCTAssertLessThanOrEqual(abs(actual[channel] - expected[channel]), 1,
                        "Texture pixel \(x),\(y), channel \(channel)", file: file, line: line)
                }
            }
        }
    }

    private func rgba(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> [Int] {
        let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            .map { Int(($0 * 255).rounded()) }
    }
}
