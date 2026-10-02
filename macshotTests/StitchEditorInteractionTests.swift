import AppKit
import XCTest

@MainActor
final class StitchEditorInteractionTests: XCTestCase {
    private func image() -> CGImage {
        ImageProbe.quadrantImage(width: 120, height: 100)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    func testLayerReorderPreservesGeometryAndIdentity() {
        let first = StitchPiece(image: image(), origin: CGPoint(x: -30, y: 10))
        let second = StitchPiece(image: image(), origin: CGPoint(x: 20, y: 50))
        let third = StitchPiece(image: image(), origin: CGPoint(x: 90, y: -20))
        var pieces = [first, second, third]
        XCTAssertTrue(StitchPieceOrder.move(first.id, in: &pieces, to: 2))
        XCTAssertEqual(pieces.map(\.id), [second.id, third.id, first.id])
        XCTAssertEqual(pieces[2].frame, first.frame)
        XCTAssertEqual(pieces[2].source, first.source)
        XCTAssertTrue(pieces[2].image === first.image)
        XCTAssertTrue(StitchPieceOrder.move(first.id, in: &pieces, to: 0))
        XCTAssertEqual(pieces.map(\.id), [first.id, second.id, third.id])
        XCTAssertFalse(StitchPieceOrder.move(first.id, in: &pieces, to: -1))
        XCTAssertFalse(StitchPieceOrder.move(first.id, in: &pieces, to: 3))
        XCTAssertFalse(StitchPieceOrder.move(UUID(), in: &pieces, to: 0))
        XCTAssertEqual(pieces.map(\.id), [first.id, second.id, third.id])
    }

    func testAutomaticVerticalAndHorizontalDragsCutDocumentCoordinates() {
        let view = StitchCanvasView(frame: .zero)
        view.refresh(StitchDocument(pieces: [StitchPiece(image: image())]), preview: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        var cuts: [(StitchAxis, CGFloat, CGFloat)] = []
        view.onCut = { cuts.append(($0, $1, $2)) }
        XCTAssertEqual(view.mode, .removeSpace)
        drag(view, from: CGPoint(x: 20, y: 25), to: CGPoint(x: 23, y: 65))
        XCTAssertEqual(cuts.count, 1)
        if case .horizontal = cuts[0].0 {} else { XCTFail("Rows must collapse horizontally") }
        XCTAssertEqual(cuts[0].1, 25, accuracy: 0.01)
        XCTAssertEqual(cuts[0].2, 65, accuracy: 0.01)

        drag(view, from: CGPoint(x: 80, y: 15), to: CGPoint(x: 30, y: 18))
        XCTAssertEqual(cuts.count, 2)
        if case .vertical = cuts[1].0 {} else { XCTFail("Columns must collapse vertically") }
        XCTAssertEqual(cuts[1].1, 80, accuracy: 0.01)
        XCTAssertEqual(cuts[1].2, 30, accuracy: 0.01)
    }

    func testEscapeCancelsPendingBandWithoutCutting() {
        let view = StitchCanvasView(frame: .zero)
        view.refresh(StitchDocument(pieces: [StitchPiece(image: image())]), preview: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        view.onCut = { _, _, _ in XCTFail("Cancelled band must not cut") }
        view.mouseDown(with: mouse(.leftMouseDown, view: view, point: CGPoint(x: 20, y: 20)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view: view, point: CGPoint(x: 50, y: 60)))
        view.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
        view.mouseUp(with: mouse(.leftMouseUp, view: view, point: CGPoint(x: 50, y: 60)))
        XCTAssertEqual(view.document.pieces.count, 1)
    }

    func testPlainClickAndSubthresholdMovementDoNotCreateMoveUndo() {
        let view = StitchCanvasView(frame: .zero)
        view.mode = .move
        view.refresh(StitchDocument(pieces: [StitchPiece(image: image())]), preview: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        view.onMove = { _, _, _ in XCTFail("A click must not begin or commit a move") }
        view.onCancelMove = { XCTFail("A click must not require rollback") }
        drag(view, from: CGPoint(x: 20, y: 20), to: CGPoint(x: 21, y: 20))
        XCTAssertEqual(view.selectedID, view.document.pieces[0].id)
        XCTAssertTrue(view.alignmentGuides.isEmpty)
    }

    func testSnapGuidesFollowActualEdgesAndOptionSuppressesThem() {
        let first = StitchPiece(image: image())
        let second = StitchPiece(image: image(), origin: CGPoint(x: 200, y: 0))
        let view = StitchCanvasView(frame: .zero)
        view.mode = .move
        view.refresh(StitchDocument(pieces: [first, second]), preview: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        var commits = 0
        view.onMove = { id, origin, finished in
            let index = view.document.pieces.firstIndex(where: { $0.id == id })!
            view.document.pieces[index].origin = origin
            if finished { commits += 1 }
        }
        defer { view.onMove = nil }
        view.mouseDown(with: mouse(.leftMouseDown, view: view, point: CGPoint(x: 220, y: 20)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view: view, point: CGPoint(x: 141, y: 20)))
        XCTAssertEqual(view.document.pieces[1].origin, CGPoint(x: 120, y: 0))
        XCTAssertTrue(view.alignmentGuides.contains(where: { $0.start.x == 120 && $0.end.x == 120 }))
        XCTAssertTrue(view.alignmentGuides.contains(where: { $0.start.y == 0 && $0.end.y == 0 }))
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58, modifiers: .option))
        XCTAssertEqual(view.document.pieces[1].origin, CGPoint(x: 121, y: 0))
        XCTAssertTrue(view.alignmentGuides.isEmpty)
        view.flagsChanged(with: TestKeyEvent.keyDown(characters: "", keyCode: 58))
        XCTAssertEqual(view.document.pieces[1].origin, CGPoint(x: 120, y: 0))
        XCTAssertFalse(view.alignmentGuides.isEmpty)
        view.mouseUp(with: mouse(.leftMouseUp, view: view, point: CGPoint(x: 141, y: 20), modifiers: .option))
        XCTAssertEqual(view.document.pieces[1].origin, CGPoint(x: 121, y: 0))
        XCTAssertEqual(commits, 1)
        XCTAssertTrue(view.alignmentGuides.isEmpty)
    }

    func testMoveReleaseReenablesSnappingWithoutAnotherPointerEvent() {
        let first = StitchPiece(image: image())
        let second = StitchPiece(image: image(), origin: CGPoint(x: 200, y: 0))
        let view = StitchCanvasView(frame: .zero)
        view.mode = .move
        view.refresh(StitchDocument(pieces: [first, second]), preview: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        var moves: [(CGPoint, Bool)] = []
        view.onMove = { _, origin, final in moves.append((origin, final)) }
        view.mouseDown(with: mouse(.leftMouseDown, view: view, point: CGPoint(x: 220, y: 20)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view: view, point: CGPoint(x: 141, y: 20), modifiers: .option))
        XCTAssertEqual(moves.last?.0, CGPoint(x: 121, y: 0))
        view.mouseUp(with: mouse(.leftMouseUp, view: view, point: CGPoint(x: 141, y: 20)))
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual(moves.last?.0, CGPoint(x: 120, y: 0))
        XCTAssertEqual(moves.last?.1, true)
        XCTAssertEqual(view.document.pieces.map(\.origin), [first.origin, second.origin])
        XCTAssertTrue(view.document.pieces[1].image === second.image)
    }

    func testHoverUsesTopmostPieceAndEscapeOrModeChangeClearsFeedback() {
        let first = StitchPiece(image: image())
        let second = StitchPiece(image: image(), origin: CGPoint(x: 20, y: 10))
        let view = StitchCanvasView(frame: .zero)
        view.mode = .move
        view.refresh(StitchDocument(pieces: [first, second]), preview: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        let event = mouse(.mouseMoved, view: view, point: CGPoint(x: 30, y: 20))
        view.mouseMoved(with: event)
        XCTAssertEqual(view.hoveredID, second.id)
        view.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
        XCTAssertNil(view.hoveredID)
        view.mouseMoved(with: event)
        view.mode = .removeSpace
        XCTAssertNil(view.hoveredID)
        view.mouseMoved(with: event)
        XCTAssertNil(view.hoveredID)
        view.mode = .move
        view.mouseMoved(with: event)
        view.mouseExited(with: event)
        XCTAssertNil(view.hoveredID)
    }

    func testModeSwitchCancelsDragAndClearsSnapGuidesWithoutCommitting() {
        let view = StitchCanvasView(frame: .zero)
        view.mode = .move
        view.refresh(StitchDocument(pieces: [StitchPiece(image: image()),
            StitchPiece(image: image(), origin: CGPoint(x: 200, y: 0))]), preview: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        var cancellations = 0
        view.onCancelMove = { cancellations += 1 }
        view.onMove = { _, _, finished in XCTAssertFalse(finished) }
        view.mouseDown(with: mouse(.leftMouseDown, view: view, point: CGPoint(x: 220, y: 20)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view: view, point: CGPoint(x: 141, y: 20)))
        XCTAssertFalse(view.alignmentGuides.isEmpty)
        view.mode = .removeSpace
        XCTAssertTrue(view.alignmentGuides.isEmpty)
        XCTAssertEqual(cancellations, 1)
        view.mouseUp(with: mouse(.leftMouseUp, view: view, point: CGPoint(x: 141, y: 20)))
        XCTAssertEqual(cancellations, 1)
    }

    func testCutPillIsCenteredAndClampedAtEveryViewportEdgeAtDifferentZooms() {
        let visible = CGRect(x: 200, y: 300, width: 400, height: 240)
        for zoom: CGFloat in [0.5, 1, 4] {
            let size = CGSize(width: 90 / zoom, height: 30 / zoom)
            let middle = CGRect(x: 350, y: 400, width: 100, height: 40)
            let centered = StitchCanvasView.cutLabelRect(size: size, band: middle, visible: visible, zoom: zoom)
            XCTAssertEqual(centered.midX, middle.midX, accuracy: 0.01)
            XCTAssertEqual(centered.midY, middle.midY, accuracy: 0.01)
            for point in [visible.origin, CGPoint(x: visible.maxX, y: visible.minY),
                          CGPoint(x: visible.minX, y: visible.maxY), CGPoint(x: visible.maxX, y: visible.maxY)] {
                let pill = StitchCanvasView.cutLabelRect(size: size, band: CGRect(origin: point, size: CGSize(width: 1, height: 1)), visible: visible, zoom: zoom)
                XCTAssertTrue(visible.contains(pill))
                XCTAssertEqual(pill.size, size)
            }
        }
    }

    func testPackedDropReportsProposedOriginWithoutMutatingDocumentDuringDrag() {
        let view = StitchCanvasView(frame: .zero)
        view.mode = .move
        let first = StitchPiece(image: image())
        let second = StitchPiece(image: image(), origin: CGPoint(x: 200, y: 0))
        view.refresh(StitchDocument(pieces: [first, second]), preview: nil)
        view.packed = true
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        var moves: [(CGPoint, Bool)] = []
        view.onMove = { _, point, final in moves.append((point, final)) }
        drag(view, from: CGPoint(x: 220, y: 20), to: CGPoint(x: 141, y: 20))
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual(moves.first?.0, CGPoint(x: 121, y: 0))
        XCTAssertEqual(moves.last?.0, CGPoint(x: 121, y: 0))
        XCTAssertEqual(moves.last?.1, true)
        XCTAssertEqual(view.document.pieces[1].origin, second.origin)
        XCTAssertTrue(view.alignmentGuides.isEmpty)
    }

    func testEscapeCancelsPackedPreviewWithoutCommittingOrMovingSource() {
        let piece = StitchPiece(image: image())
        let view = StitchCanvasView(frame: .zero)
        view.mode = .move
        view.refresh(StitchDocument(pieces: [piece]), preview: nil)
        view.packed = true
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        var cancelled = 0
        view.onCancelMove = { cancelled += 1 }
        view.onMove = { _, _, finished in XCTAssertFalse(finished) }
        view.mouseDown(with: mouse(.leftMouseDown, view: view, point: CGPoint(x: 20, y: 20)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view: view, point: CGPoint(x: 60, y: 40)))
        view.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
        view.mouseUp(with: mouse(.leftMouseUp, view: view, point: CGPoint(x: 60, y: 40)))
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(view.document.pieces[0].origin, piece.origin)
        XCTAssertEqual(view.document.pieces[0].source, piece.source)
        XCTAssertTrue(view.alignmentGuides.isEmpty)
        XCTAssertNil(view.hoveredID)
    }

    func testPackedReflowPreviewKeepsSourceUnchangedAndClearsOnEveryGestureExit() {
        for exit in 0..<4 {
            let first = StitchPiece(image: image())
            let second = StitchPiece(image: image(), origin: CGPoint(x: 120, y: 0))
            let view = StitchCanvasView(frame: .zero)
            view.mode = .move
            view.refresh(StitchDocument(pieces: [first, second]), preview: nil)
            view.packed = true
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            defer { window.orderOut(nil); view.onMove = nil }
            var commits = 0
            view.onMove = { id, _, finished in
                if finished { commits += 1; return }
                var snapshot = view.document
                snapshot.pieces[0].origin.x = 120
                snapshot.pieces[1].origin.x = 0
                view.packedPreview = snapshot
                XCTAssertEqual(id, second.id)
            }
            view.mouseDown(with: mouse(.leftMouseDown, view: view, point: CGPoint(x: 140, y: 20)))
            view.mouseDragged(with: mouse(.leftMouseDragged, view: view, point: CGPoint(x: 40, y: 20)))
            XCTAssertEqual(view.packedDropFrame, CGRect(x: 0, y: 0, width: 120, height: 100))
            XCTAssertEqual(view.packedPreview?.pieces[0].origin.x, 120)
            XCTAssertEqual(view.document.pieces.map(\.origin), [first.origin, second.origin])
            switch exit {
            case 0: view.mouseUp(with: mouse(.leftMouseUp, view: view, point: CGPoint(x: 40, y: 20)))
            case 1: view.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
            case 2: view.mode = .removeSpace
            default: view.packed = false
            }
            XCTAssertNil(view.packedPreview)
            XCTAssertNil(view.packedDropFrame)
            XCTAssertEqual(commits, exit == 0 ? 1 : 0)
            XCTAssertEqual(view.document.pieces.map(\.origin), [first.origin, second.origin])
        }
    }

    func testCanvasCompositesSemiTransparentBackgroundOnceAndPreservesCoveredAlpha() throws {
        func solid(_ color: NSColor) -> CGImage {
            let context = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8,
                                    bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            return context.makeImage()!
        }
        let source = solid(NSColor.systemBlue.withAlphaComponent(0.5))
        let pieces = [StitchPiece(image: source), StitchPiece(image: source, origin: CGPoint(x: 80, y: 0))]
        var document = StitchDocument(pieces: pieces, background: .color(NSColor.systemRed.withAlphaComponent(0.5)))
        let preview = try XCTUnwrap(StitchRenderer.render(document))
        let canvas = StitchCanvasView(frame: .zero)
        canvas.refresh(document, preview: preview)
        canvas.backgroundPreview = StitchRenderer.renderBackground(document)
        let reference = StitchSingleCompositeReference(frame: canvas.bounds)
        reference.image = preview
        func raster(_ view: NSView) -> NSBitmapImageRep {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        func assertPixel(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, x: Int, y: Int, file: StaticString = #filePath, line: UInt = #line) {
            let left = a.colorAt(x: x * a.pixelsWide / 280, y: y * a.pixelsHigh / 200)!.usingColorSpace(.deviceRGB)!
            let right = b.colorAt(x: x * b.pixelsWide / 280, y: y * b.pixelsHigh / 200)!.usingColorSpace(.deviceRGB)!
            XCTAssertEqual(left.redComponent, right.redComponent, accuracy: 0.015, file: file, line: line)
            XCTAssertEqual(left.greenComponent, right.greenComponent, accuracy: 0.015, file: file, line: line)
            XCTAssertEqual(left.blueComponent, right.blueComponent, accuracy: 0.015, file: file, line: line)
        }
        let actual = raster(canvas), expected = raster(reference)
        assertPixel(actual, expected, x: 140, y: 100) // Uncovered configured background.
        assertPixel(actual, expected, x: 100, y: 100) // Half-alpha source above the display checkerboard.

        // Automatic and opaque custom fills use the same neutral display backing.
        // Neither may introduce background color beneath covered source alpha.
        for fullPreview in [false, true] {
            document.background = .automatic
            canvas.refresh(document, preview: fullPreview ? StitchRenderer.render(document) : nil)
            canvas.backgroundPreview = StitchRenderer.renderBackground(document)
            let automatic = raster(canvas)
            document.background = .color(.systemRed)
            canvas.refresh(document, preview: fullPreview ? StitchRenderer.render(document) : nil)
            canvas.backgroundPreview = StitchRenderer.renderBackground(document)
            assertPixel(raster(canvas), automatic, x: 100, y: 100)
        }
    }

    private func drag(_ view: StitchCanvasView, from: CGPoint, to: CGPoint) {
        view.mouseDown(with: mouse(.leftMouseDown, view: view, point: from))
        view.mouseDragged(with: mouse(.leftMouseDragged, view: view, point: to))
        view.mouseUp(with: mouse(.leftMouseUp, view: view, point: to))
    }
    private func mouse(_ type: NSEvent.EventType, view: StitchCanvasView, point: CGPoint, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        let location = view.convert(CGPoint(x: point.x + 80, y: point.y + 80), to: nil)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: 0,
                                 windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                 eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

/// Independent display reference: checkerboard plus exactly one already-composited image.
@MainActor
private final class StitchSingleCompositeReference: NSView {
    var image: CGImage!
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        ToolbarLayout.bgColor.setFill()
        bounds.fill()
        for row in 6...10 {
            for column in 6...17 {
                NSColor(white: (row + column) % 2 == 0 ? 0.24 : 0.28, alpha: 1).setFill()
                CGRect(x: column * 12, y: row * 12, width: 12, height: 12).fill()
            }
        }
        NSImage(cgImage: image, size: CGSize(width: 120, height: 40)).draw(
            in: CGRect(x: 80, y: 80, width: 120, height: 40), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
