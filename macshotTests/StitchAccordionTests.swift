import AppKit
import CoreImage
import XCTest

@MainActor
final class StitchAccordionTests: XCTestCase {
    func testEditableAccordionPixelsStayFlatInBothDirections() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = try fixture(axis: axis, color: .white)
            let editable = try XCTUnwrap(StitchRenderer.render(document))
            document.style.visible = false
            let plain = try XCTUnwrap(StitchRenderer.render(document))
            XCTAssertEqual(bytes(editable), bytes(plain))
        }
    }

    func testRemovedPixelsNeverBecomeTheSeam() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let image = ImageProbe.makeImage(width: 256, height: 256) { context in
                context.setFillColor(NSColor(white: 0.25, alpha: 1).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
                context.setFillColor(NSColor.red.cgColor)
                context.fill(axis == .horizontal ? CGRect(x: 0, y: 96, width: 256, height: 40)
                    : CGRect(x: 120, y: 0, width: 40, height: 256))
            }.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            var doc = StitchDocument(pieces: [StitchPiece(image: image)])
            XCTAssertTrue(doc.collapse(axis: axis, from: 120, to: 160))
            doc.style.transition = .accordion
            let rendered = try XCTUnwrap(StitchRenderer.render(doc))
            let pixels = bytes(rendered)
            var coloredPixels = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let red = pixels[offset], green = pixels[offset + 1], blue = pixels[offset + 2]
                if red != green || green != blue { coloredPixels += 1 }
            }
            XCTAssertEqual(coloredPixels, 0)
        }
    }

    func testHistoryRoundTripAndUndoPreserveAccordionSettings() throws {
        let original = try fixture(axis: .horizontal, color: .white)
        var edited = original
        edited.style.accordionWidth = 48
        edited.style.accordionPleats = 5
        edited.style.accordionPerspective = 22
        let encoded = try JSONEncoder().encode(XCTUnwrap(SavedStitchDocument(edited)))
        let saved = try JSONDecoder().decode(SavedStitchDocument.self, from: encoded)
        let restored = try XCTUnwrap(saved.restore())
        XCTAssertEqual(restored.style.transition, .accordion)
        XCTAssertEqual(restored.style.accordionWidth, 48)
        XCTAssertEqual(restored.style.accordionPleats, 5)
        XCTAssertEqual(restored.style.accordionPerspective, 22)
        XCTAssertEqual(bytes(try XCTUnwrap(StitchRenderer.render(restored))), bytes(try XCTUnwrap(StitchRenderer.render(edited))))
        let editor = ImageEditingView(frame: CGRect(x: 0, y: 0, width: 256, height: 240))
        editor.screenshotImage = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(original)), size: original.bounds.size)
        editor.applySelection(CGRect(origin: .zero, size: original.bounds.size))
        editor.installStitchDocument(original)
        XCTAssertTrue(editor.applyStitchDocument(edited))
        editor.undo()
        XCTAssertEqual(editor.stitchDocument?.style.accordionWidth, 30)
        XCTAssertEqual(editor.stitchDocument?.style.accordionPleats, 3)
        XCTAssertEqual(editor.stitchDocument?.style.accordionPerspective, 14)
        editor.redo()
        XCTAssertEqual(editor.stitchDocument?.style.accordionWidth, 48)
        XCTAssertEqual(editor.stitchDocument?.style.accordionPleats, 5)
        XCTAssertEqual(editor.stitchDocument?.style.accordionPerspective, 22)
    }

    func testSavedAccordionRejectsInvalidSettings() throws {
        let saved = try XCTUnwrap(SavedStitchDocument(fixture(axis: .horizontal, color: .white)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        for (key, value) in [("accordionWidth", -1.0), ("accordionWidth", 81.0),
                             ("accordionPleats", 0.0), ("accordionPleats", 7.0), ("accordionPleats", 2.5),
                             ("accordionPerspective", -1.0), ("accordionPerspective", 31.0)] {
            var invalid = object
            invalid[key] = value
            let restored = try JSONDecoder().decode(SavedStitchDocument.self, from: JSONSerialization.data(withJSONObject: invalid))
            XCTAssertNil(restored.restore())
        }
    }

    func testModeSettingsAndPickerRemainReadable() throws {
        XCTAssertFalse(StitchTransition.accordion.usesBlur)
        XCTAssertFalse(StitchTransition.accordion.hasEditableColor)
        let picker = StitchSeamStylePicker(frame: CGRect(x: 0, y: 0, width: 344, height: StitchSeamStylePicker.preferredHeight))
        picker.layout()
        let buttons = picker.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 6)
        for button in buttons {
            XCTAssertTrue(picker.bounds.contains(button.frame))
            XCTAssertGreaterThanOrEqual(button.frame.width, 100)
        }
        for (index, a) in buttons.enumerated() {
            for b in buttons.dropFirst(index + 1) { XCTAssertTrue(a.frame.intersection(b.frame).isNull) }
        }
        let button = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "stitch.transition.accordion" })
        picker.selection = .accordion
        XCTAssertEqual(button.state, .on)
    }

    func testAnimationTransformsUseTheSamePerspectiveAsExportAtEveryKeyframe() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            var document = try fixture(axis: axis, color: .white)
            for index in document.pieces.indices { document.pieces[index].origin = CGPoint(x: document.pieces[index].origin.x - 17, y: document.pieces[index].origin.y + 23) }
            let size = CGSize(width: 420, height: 330)
            let first = try XCTUnwrap(StitchAccordionProjection(document: document, progress: 0))
            let depth = try XCTUnwrap(first.faces.first).a.depth
            for progress in [CGFloat(0), 0.2, 0.45, 0.72, 1] {
                let projection = try XCTUnwrap(StitchAccordionProjection(document: document, progress: progress))
                let sx = size.width / document.bounds.width, sy = size.height / document.bounds.height
                for face in projection.faces {
                    let points = face.vertices.map { CGPoint(x: ($0.source.x - document.bounds.minX) * sx,
                                                             y: ($0.source.y - document.bounds.minY) * sy) }
                    let rect = CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
                                      width: points.map(\.x).max()! - points.map(\.x).min()!,
                                      height: points.map(\.y).max()! - points.map(\.y).min()!)
                    let transform = StitchAccordionCollapseView.transform(face: face, sourceRect: rect,
                        documentBounds: projection.documentBounds, size: size, referenceDepth: depth)
                    for (point, vertex) in zip(points, face.vertices) {
                        let local = CGPoint(x: point.x - rect.minX, y: point.y - rect.minY)
                        let w = local.x * transform.m14 + local.y * transform.m24 + transform.m44
                        XCTAssertGreaterThan(w, 0)
                        let x = (local.x * transform.m11 + local.y * transform.m21 + transform.m41) / w
                        let y = (local.x * transform.m12 + local.y * transform.m22 + transform.m42) / w
                        XCTAssertEqual(x, (vertex.projected.x - document.bounds.minX) * sx, accuracy: 0.000001)
                        XCTAssertEqual(y, (vertex.projected.y - document.bounds.minY) * sy, accuracy: 0.000001)
                    }
                }
            }
        }
    }

    func testFoldedPreviewSwitchesToFlatEditingWithoutChangingPixelsOrKeyboardOwnership() throws {
        let document = try fixture(axis: .horizontal, color: .white)
        let editor = ImageEditingView(frame: CGRect(origin: .zero, size: document.bounds.size))
        let window = NSWindow(contentRect: editor.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        editor.screenshotImage = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(document)), size: document.bounds.size)
        editor.applySelection(editor.bounds)
        editor.installStitchDocument(document)
        let controller = StitchEditorController(document: document, window: window)
        controller.attach(to: editor)
        defer { controller.suspend() }
        let paper = try XCTUnwrap(editor.subviews.compactMap { $0 as? StitchPaperPreviewView }.first)
        let canvas = try XCTUnwrap(editor.subviews.compactMap { $0 as? StitchCanvasView }.first)
        let original = bytes(try XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        XCTAssertTrue(editor.stitchPreviewEnabled)
        XCTAssertFalse(paper.isHidden)
        XCTAssertTrue(canvas.isHidden)
        controller.focus()
        XCTAssertTrue(window.firstResponder === editor)
        paper.onEdit?()
        XCTAssertFalse(editor.stitchPreviewEnabled)
        XCTAssertTrue(paper.isHidden)
        XCTAssertFalse(canvas.isHidden)
        XCTAssertTrue(window.firstResponder === canvas)
        editor.stitchPreviewEnabled = true
        XCTAssertTrue(window.firstResponder === editor, "Hiding the canvas must transfer command ownership first")
        XCTAssertEqual(bytes(try XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))), original)
    }

    func testAnimationDoesNotTakeInputAndRejectsOversizedTextures() throws {
        let document = try fixture(axis: .vertical, color: .white)
        let texture = try XCTUnwrap(StitchRenderer.render(document))
        let oversized = try XCTUnwrap(ImageProbe.solidImage(width: 1601, height: 100)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertNil(StitchAccordionCollapseView(texture: oversized, document: document, frame: document.bounds))
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            XCTAssertNil(StitchAccordionCollapseView(texture: texture, document: document, frame: document.bounds))
            return
        }
        let effect = try XCTUnwrap(StitchAccordionCollapseView(texture: texture, document: document, frame: document.bounds))
        XCTAssertNil(effect.hitTest(CGPoint(x: 40, y: 40)))
        XCTAssertFalse(effect.acceptsFirstResponder)
        XCTAssertTrue(effect.isFlipped)
        effect.play { }
        let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
        let faces = try XCTUnwrap(effect.layer?.sublayers)
        XCTAssertEqual(faces.count, projection.faces.count)
        XCTAssertTrue(faces.allSatisfy { $0.mask != nil && $0.animation(forKey: "transform") != nil })
        effect.layer?.sublayers?.forEach { $0.removeAllAnimations() }
    }

    func testAnimatedLightingMultipliesDarkPixelsAndPreservesSourceAlpha() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let source = ImageProbe.solidImage(width: 12, height: 12,
            color: NSColor(srgbRed: 0.12, green: 0.2, blue: 0.3, alpha: 0.5).cgColor)
        let pixels = try XCTUnwrap(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let before = bytes(pixels)
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        for axis in [StitchAxis.horizontal, .vertical] {
            let document = try fixture(axis: axis, color: .white)
            let effect = try XCTUnwrap(StitchAccordionCollapseView(texture: pixels, document: document, frame: document.bounds))
            effect.play { }
            let projection = try XCTUnwrap(StitchAccordionProjection(document: document))
            for layer in try XCTUnwrap(effect.layer?.sublayers) {
                let index = try XCTUnwrap(Int(try XCTUnwrap(layer.name).replacingOccurrences(of: "accordion.face.", with: "")))
                let filter = try XCTUnwrap((layer.filters?.first as? CIFilter)?.copy() as? CIFilter)
                XCTAssertNotNil(layer.animation(forKey: "filters.paperLighting.inputRVector"))
                filter.setValue(CIImage(cgImage: pixels), forKey: kCIInputImageKey)
                let lit = try XCTUnwrap(context.createCGImage(try XCTUnwrap(filter.outputImage), from: CGRect(x: 0, y: 0, width: 12, height: 12)))
                let after = bytes(lit)
                for channel in 0..<3 {
                    XCTAssertEqual(CGFloat(after[channel]), min(CGFloat(before[3]), CGFloat(before[channel]) * projection.faces[index].shade), accuracy: 1)
                }
                XCTAssertEqual(after[3], before[3], "Lighting must preserve translucent source pixels")
            }
            effect.layer?.sublayers?.forEach { $0.removeAllAnimations() }
        }
    }

    func testPreviewMarginsDoNotMoveTheEditableDocumentAndRestoreOnExit() throws {
        let document = try fixture(axis: .horizontal, color: .white)
        let editor = EditorView(frame: CGRect(origin: .zero, size: document.bounds.size))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 120, height: 100))
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 84, right: 50)
        scroll.contentView = CenteringClipView(frame: scroll.bounds)
        scroll.documentView = editor
        let window = NSWindow(contentRect: scroll.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        editor.screenshotImage = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(document)), size: document.bounds.size)
        editor.applySelection(editor.bounds)
        editor.installStitchDocument(document)
        editor.beautifyEnabled = true
        editor.beautifyPadding = 32
        let originalFrame = editor.frame, originalBounds = editor.bounds, originalSelection = editor.selectionRect
        let controller = StitchEditorController(document: document, window: window)
        controller.attach(to: editor)
        defer { controller.suspend() }
        XCTAssertEqual(scroll.contentInsets.top, 32)
        XCTAssertEqual(scroll.contentInsets.left, 32)
        XCTAssertEqual(scroll.contentInsets.bottom, 116)
        XCTAssertEqual(scroll.contentInsets.right, 82)
        XCTAssertEqual(editor.frame, originalFrame)
        XCTAssertEqual(editor.bounds, originalBounds)
        XCTAssertEqual(editor.selectionRect, originalSelection)
        editor.beautifyPadding = 48
        controller.annotationPreview = nil // The host refreshes presentation after a Background change.
        XCTAssertEqual(scroll.contentInsets.left, 48)
        editor.stitchPreviewEnabled = false
        XCTAssertEqual(scroll.contentInsets.top, 0)
        XCTAssertEqual(scroll.contentInsets.left, 0)
        XCTAssertEqual(scroll.contentInsets.bottom, 84)
        XCTAssertEqual(scroll.contentInsets.right, 50)
    }

    private func fixture(axis: StitchAxis, color: NSColor) throws -> StitchDocument {
        let image = try XCTUnwrap(ImageProbe.makeImage(width: 256, height: 256) { context in
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var doc = StitchDocument(pieces: [StitchPiece(image: image)], background: .transparent)
        XCTAssertTrue(doc.collapse(axis: axis, from: 120, to: 136))
        doc.style.transition = .accordion
        return doc
    }

    private func bytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}
