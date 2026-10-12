import AppKit
import XCTest

@MainActor
final class StitchPaperGuardedTextureTests: XCTestCase {
    func testAnimationFallbackBoundsRetainedStripsAndKeepsEveryFace() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pixels = try XCTUnwrap(ImageProbe.solidImage(width: 2400, height: 64)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: pixels)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 10, to: 50))
        document.style.transition = .accordion
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        XCTAssertTrue(projection.faces.contains { ($0.paperTexture?.image.width ?? 0) > 1600 })
        let texture = try XCTUnwrap(StitchRenderer.render(document, maximumPreviewDimension: 1200))
        let effect = try XCTUnwrap(StitchAccordionCollapseView(texture: texture, document: document,
            frame: CGRect(x: 0, y: 0, width: 600, height: 80)))
        effect.play { }
        defer { effect.layer?.sublayers?.forEach { $0.removeAllAnimations() } }
        let faces = try XCTUnwrap(effect.layer?.sublayers)
        XCTAssertEqual(faces.count, projection.faces.count)
        for face in faces {
            if let contents = face.sublayers?.first?.contents {
                let printed = contents as! CGImage
                XCTAssertLessThanOrEqual(printed.width, 1600 + StitchPaperGuardedTexture.padding * 2)
            }
        }
    }

    func testGuardTexelsClampOpaqueEdgesWithoutFillingRealTransparency() throws {
        let source = try XCTUnwrap(ImageProbe.makeImage(width: 4, height: 4) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            context.clear(CGRect(x: 1, y: 1, width: 1, height: 1))
        }.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let material = try XCTUnwrap(StitchPaperGuardedTexture(source))
        let original = NSBitmapImageRep(cgImage: source), padded = NSBitmapImageRep(cgImage: material.image)
        let border = StitchPaperGuardedTexture.padding
        for y in 0..<padded.pixelsHigh {
            for x in 0..<padded.pixelsWide {
                let expected = try XCTUnwrap(original.colorAt(x: max(0, min(3, x - border)),
                    y: max(0, min(3, y - border)))?.usingColorSpace(.sRGB))
                let actual = try XCTUnwrap(padded.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001)
                if expected.alphaComponent > 0 {
                    XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
                }
            }
        }
        // A sample outside the original face still lands in opaque guard pixels.
        let crop = material.contentsRect(for: CGRect(x: -1, y: -1, width: 6, height: 6))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(crop))
        XCTAssertEqual(try XCTUnwrap(padded.colorAt(x: border - 1, y: border - 1)).alphaComponent, 1)
        XCTAssertTrue((0..<4).contains { y in (0..<4).contains { x in
            padded.colorAt(x: x + border, y: y + border)?.alphaComponent == 0
        } })
    }
}
