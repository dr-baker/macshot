import AppKit
import XCTest

@MainActor
final class StitchAccordionTests: XCTestCase {
    func testPleatsMeetWithoutGapsInBothOrientationsAndTaperAtEndpoints() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            for count in 2...6 {
                var style = StitchStyle()
                style.accordionWidth = 64
                style.accordionPleats = CGFloat(count)
                let join = StitchJoin(axis: axis, position: 120, start: 15, end: 255)
                let geometry = try XCTUnwrap(StitchAccordionGeometry(join: join, style: style))
                XCTAssertEqual(geometry.faces.count, count * 2)
                XCTAssertEqual(geometry.faces.first?.start, -32)
                XCTAssertEqual(try XCTUnwrap(geometry.faces.last?.end), 32, accuracy: 0.000001)
                for (a, b) in zip(geometry.faces, geometry.faces.dropFirst()) {
                    XCTAssertEqual(a.end, b.start, accuracy: 0.000001)
                    XCTAssertNotEqual(a.isReturn, b.isReturn)
                }
                let path = geometry.band(from: -32, to: 32)
                XCTAssertTrue(path.contains(geometry.point(along: 135, normal: 0)))
                XCTAssertFalse(path.contains(geometry.point(along: 16, normal: 30)))
            }
        }
    }

    func testInvalidAndShortGeometryIsBounded() throws {
        var style = StitchStyle()
        let join = StitchJoin(axis: .horizontal, position: 10, start: 0, end: 9)
        XCTAssertEqual(try XCTUnwrap(StitchAccordionGeometry(join: join, style: style)).width, 3)
        for width in [CGFloat.zero, -1, .nan, .infinity] {
            style.accordionWidth = width
            XCTAssertNil(StitchAccordionGeometry(join: join, style: style))
        }
        style.accordionWidth = 30
        style.accordionPleats = .nan
        XCTAssertNil(StitchAccordionGeometry(join: join, style: style))
    }

    func testAccordionUsesLocalPaperAndChangesOnlyItsBoundedStrip() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            for color in [NSColor(white: 0.96, alpha: 1), NSColor(white: 0.12, alpha: 1),
                          NSColor(srgbRed: 0.12, green: 0.26, blue: 0.40, alpha: 1)] {
                var doc = try fixture(axis: axis, color: color)
                doc.style.visible = false
                let original = try XCTUnwrap(StitchRenderer.render(doc))
                doc.style.visible = true
                let rendered = try XCTUnwrap(StitchRenderer.render(doc))
                XCTAssertEqual(rendered.width, original.width)
                XCTAssertEqual(rendered.height, original.height)
                let before = bytes(original), after = bytes(rendered)
                var changed = 0
                for y in 0..<rendered.height {
                    for x in 0..<rendered.width {
                        let normal = axis == .horizontal ? y : x
                        let offset = (y * rendered.width + x) * 4
                        XCTAssertEqual(after[offset + 3], before[offset + 3])
                        if abs(normal - 120) > 19 {
                            XCTAssertEqual(Array(after[offset..<offset + 4]), Array(before[offset..<offset + 4]))
                        } else if after[offset..<offset + 3] != before[offset..<offset + 3] { changed += 1 }
                    }
                }
                XCTAssertGreaterThan(changed, 1000)
                let center = NSBitmapImageRep(cgImage: rendered).colorAt(x: 128, y: 128)!.usingColorSpace(.sRGB)!
                let base = color.usingColorSpace(.sRGB)!
                XCTAssertLessThan(abs(center.redComponent - base.redComponent), 0.23)
                XCTAssertLessThan(abs(center.greenComponent - base.greenComponent), 0.23)
                XCTAssertLessThan(abs(center.blueComponent - base.blueComponent), 0.23)
            }
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
        let encoded = try JSONEncoder().encode(XCTUnwrap(SavedStitchDocument(edited)))
        let saved = try JSONDecoder().decode(SavedStitchDocument.self, from: encoded)
        let restored = try XCTUnwrap(saved.restore())
        XCTAssertEqual(restored.style.transition, .accordion)
        XCTAssertEqual(restored.style.accordionWidth, 48)
        XCTAssertEqual(restored.style.accordionPleats, 5)
        XCTAssertEqual(bytes(try XCTUnwrap(StitchRenderer.render(restored))), bytes(try XCTUnwrap(StitchRenderer.render(edited))))
        let editor = ImageEditingView(frame: CGRect(x: 0, y: 0, width: 256, height: 240))
        editor.screenshotImage = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(original)), size: original.bounds.size)
        editor.applySelection(CGRect(origin: .zero, size: original.bounds.size))
        editor.installStitchDocument(original)
        XCTAssertTrue(editor.applyStitchDocument(edited))
        editor.undo()
        XCTAssertEqual(editor.stitchDocument?.style.accordionWidth, 30)
        XCTAssertEqual(editor.stitchDocument?.style.accordionPleats, 3)
        editor.redo()
        XCTAssertEqual(editor.stitchDocument?.style.accordionWidth, 48)
        XCTAssertEqual(editor.stitchDocument?.style.accordionPleats, 5)
    }

    func testSavedAccordionRejectsInvalidSettings() throws {
        let saved = try XCTUnwrap(SavedStitchDocument(fixture(axis: .horizontal, color: .white)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        for (key, value) in [("accordionWidth", -1.0), ("accordionWidth", 81.0),
                             ("accordionPleats", 0.0), ("accordionPleats", 7.0), ("accordionPleats", 2.5)] {
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

    func testCollapseAnimationPreservesCommittedOutputAndKeyboardFocus() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let doc = try fixture(axis: axis, color: .white)
            let editor = ImageEditingView(frame: CGRect(origin: .zero, size: doc.bounds.size))
            let window = NSWindow(contentRect: editor.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = editor
            defer { window.close() }
            editor.screenshotImage = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(doc)), size: doc.bounds.size)
            editor.applySelection(editor.bounds)
            editor.installStitchDocument(doc)
            let canvas = StitchCanvasView(frame: .zero)
            canvas.inlineEditor = editor
            editor.addSubview(canvas)
            canvas.refresh(doc, preview: nil)
            window.makeFirstResponder(canvas)
            let snapshot = canvas.prepareAccordionCollapse(axis: axis, from: 50, to: 100)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                XCTAssertNil(snapshot)
                continue
            }
            XCTAssertNotNil(snapshot)
            var next = doc
            XCTAssertTrue(next.collapse(axis: axis, from: 50, to: 100))
            XCTAssertTrue(editor.applyStitchDocument(next))
            canvas.refresh(next, preview: nil)
            let output = bytes(try XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)))
            canvas.animateAccordionCollapse(snapshot)
            let effect = try XCTUnwrap(editor.subviews.compactMap { $0 as? StitchAccordionCollapseView }.first)
            XCTAssertNil(effect.hitTest(CGPoint(x: 40, y: 40)))
            XCTAssertFalse(effect.acceptsFirstResponder)
            XCTAssertTrue(window.firstResponder === canvas)
            XCTAssertEqual(bytes(try XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))), output)
            canvas.cancelEditingGesture()
            XCTAssertFalse(editor.subviews.contains { $0 is StitchAccordionCollapseView })
        }
    }

    func testAnimatedPleatsEndAtTheRealJoinInBothOrientations() throws {
        for axis in [StitchAxis.horizontal, .vertical] {
            let horizontal = axis == .horizontal
            let size = horizontal ? CGSize(width: 400, height: 600) : CGSize(width: 600, height: 400)
            let source = try XCTUnwrap(ImageProbe.solidImage(width: Int(size.width), height: Int(size.height))
                .cgImage(forProposedRect: nil, context: nil, hints: nil))
            var document = StitchDocument(pieces: [StitchPiece(image: source)])
            document.style.transition = .accordion
            let band = try XCTUnwrap(document.removalBand(axis: axis, from: 100, to: 300))
            let before = StitchAccordionCollapseView.Snapshot(image: source,
                frame: CGRect(origin: CGPoint(x: 80, y: 140), size: size),
                documentBounds: document.bounds, band: band, axis: axis, style: document.style)
            XCTAssertTrue(document.collapse(axis: axis, from: 100, to: 300))
            let parent = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 900))
            let after = CGRect(x: 80, y: horizontal ? 340 : 140, width: 400, height: 400)
            let effect = StitchAccordionCollapseView(before: before,
                afterImage: try XCTUnwrap(StitchRenderer.render(document)), afterFrame: after)
            parent.addSubview(effect)
            effect.play { }
            let root = try XCTUnwrap(effect.layer)
            let stage = try XCTUnwrap(root.sublayers?.first { $0.name == "accordion.pleats" })
            let faces = try XCTUnwrap(stage.sublayers)
            XCTAssertEqual(faces.count, 6)
            for face in faces {
                let anchor = root.convert(face.position, from: stage)
                let normal = horizontal ? anchor.y : anchor.x
                XCTAssertEqual(normal, 100, accuracy: 16,
                    "Folded panels must meet the actual seam, including in a flipped canvas inside an unflipped editor")
            }
        }
    }

    func testAnimationSkipsWhenAnnotationCompositeIsMissingAndBoundsItsTexture() throws {
        let image = try XCTUnwrap(ImageProbe.solidImage(width: 2400, height: 600)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        var doc = StitchDocument(pieces: [StitchPiece(image: image)])
        doc.style.transition = .accordion
        let editor = ImageEditingView(frame: CGRect(x: 0, y: 0, width: 1200, height: 300))
        let window = NSWindow(contentRect: editor.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        editor.screenshotImage = NSImage(cgImage: image, size: editor.bounds.size)
        editor.applySelection(editor.bounds)
        editor.installStitchDocument(doc)
        let canvas = StitchCanvasView(frame: .zero)
        canvas.inlineEditor = editor
        editor.addSubview(canvas)
        canvas.refresh(doc, preview: nil)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let snapshot = try XCTUnwrap(canvas.prepareAccordionCollapse(axis: .horizontal, from: 150, to: 450))
            XCTAssertEqual(snapshot.image.width, 1600)
            XCTAssertLessThanOrEqual(snapshot.image.height, 1600)
        }
        editor.annotations = [Annotation(tool: .rectangle, startPoint: CGPoint(x: 20, y: 20),
            endPoint: CGPoint(x: 80, y: 60), color: .red, strokeWidth: 3)]
        XCTAssertNil(canvas.prepareAccordionCollapse(axis: .horizontal, from: 150, to: 450))
    }

    func testOptionalAccordionPreviewsUseExportRenderer() throws {
        guard let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_MACSHOT_SEAM_PREVIEW_DIR"]
            ?? ProcessInfo.processInfo.environment["MACSHOT_SEAM_PREVIEW_DIR"] else { return }
        for dark in [false, true] {
            for axis in [StitchAxis.horizontal, .vertical] {
                var doc = try fixture(axis: axis, color: NSColor(white: dark ? 0.12 : 0.96, alpha: 1))
                for (index, pleats) in [CGFloat(2), 3, 5].enumerated() {
                    doc.style.accordionPleats = pleats
                    let image = try XCTUnwrap(StitchRenderer.render(doc))
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("accordion-\(dark ? "dark" : "light")-\(axis)-\(index).png")
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
                }
            }
        }
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
