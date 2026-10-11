import AppKit
import XCTest

@MainActor
final class StitchPaperBackdropTests: XCTestCase {
    func testNarrowedPaperCoversFlatCanvasWithoutStretchingTheWallpaper() throws {
        let pixels = try XCTUnwrap(ImageProbe.solidImage(width: 400, height: 400,
            color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var document = StitchDocument(pieces: [StitchPiece(image: pixels)])
        XCTAssertTrue(document.collapse(axis: .horizontal, from: 180, to: 196))
        document.style.transition = .accordion
        document.style.accordionPerspective = 0
        document.style.accordionYaw = 35
        let editor = EditorView(frame: CGRect(origin: .zero, size: document.bounds.size))
        editor.screenshotImage = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(document)),
            size: document.bounds.size)
        editor.applySelection(editor.bounds)
        editor.installStitchDocument(document)
        editor.currentTool = .stitch
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = editor
        let controller = StitchEditorController(document: document, window: window)
        defer { controller.suspend(); window.orderOut(nil) }
        controller.attach(to: editor)
        let preview = try XCTUnwrap(editor.subviews.compactMap { $0 as? StitchPaperPreviewView }.first)
        let presentation = try XCTUnwrap(editor.stitchPaperPresentationFrame)
        XCTAssertLessThan(presentation.width, editor.selectionRect.width)
        XCTAssertTrue(preview.frame.contains(editor.selectionRect))
        XCTAssertTrue(preview.frame.contains(presentation))
        XCTAssertEqual(preview.convert(preview.presentationRect, to: editor), presentation)
        XCTAssertEqual(preview.presentationRect.width, presentation.width)
        XCTAssertTrue(preview.isOpaque)
        preview.image = ImageProbe.solidImage(width: 20, height: 20,
            color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        let bitmap = try XCTUnwrap(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
        preview.cacheDisplay(in: preview.bounds, to: bitmap)
        let margin = try XCTUnwrap(bitmap.colorAt(x: 1, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertEqual(margin.redComponent, 0.15, accuracy: 0.03)
        XCTAssertEqual(margin.greenComponent, margin.redComponent, accuracy: 0.001)
        XCTAssertEqual(margin.blueComponent, margin.redComponent, accuracy: 0.001)
        XCTAssertEqual(margin.alphaComponent, 1)
        let center = try XCTUnwrap(bitmap.colorAt(x: Int(preview.presentationRect.midX),
            y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(center.blueComponent, 0.95)
        XCTAssertLessThan(center.redComponent, 0.05)
        // Presentation must not replace the editable or exported source pixels.
        let raw = try XCTUnwrap(editor.captureSelectedRegion()?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let source = NSBitmapImageRep(cgImage: raw)
        XCTAssertGreaterThan(try XCTUnwrap(source.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB)).redComponent, 0.95)
        editor.stitchPreviewEnabled = false
        editor.onStitchPreviewChanged?()
        XCTAssertTrue(preview.isHidden)
        XCTAssertNotNil(editor.screenshotImage)
    }

}
