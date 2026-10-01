import AppKit
import XCTest

@MainActor
final class StitchInlineCanvasTests: XCTestCase {
    private final class KeyEditor: EditorView {
        var keys: [UInt16] = []
        override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
    }

    func testInlineRefreshAndParentResizePreservePixelProjection() {
        let (editor, canvas) = fixture()
        XCTAssertEqual(canvas.frame, editor.selectionRect)
        XCTAssertEqual(canvas.bounds, CGRect(x: 0, y: 0, width: 400, height: 200))
        editor.applySelection(CGRect(x: 15, y: 25, width: 100, height: 50))
        canvas.syncInlineGeometry()
        XCTAssertEqual(canvas.frame, editor.selectionRect)
        XCTAssertEqual(canvas.bounds.size, CGSize(width: 400, height: 200))
        canvas.refresh(canvas.document, preview: nil)
        XCTAssertEqual(canvas.frame, editor.selectionRect)
    }

    func testRowsAndColumnsUseTopDownPixelsIncludingNegativeDocumentOrigin() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        var cuts: [(StitchAxis, CGFloat, CGFloat)] = []
        canvas.onCut = { cuts.append(($0, $1, $2)) }
        canvas.mode = .rows
        drag(canvas, from: CGPoint(x: 40, y: 30), to: CGPoint(x: 150, y: 80))
        XCTAssertEqual(cuts[0].1, -20)
        XCTAssertEqual(cuts[0].2, 30)
        canvas.mode = .columns
        drag(canvas, from: CGPoint(x: 40, y: 30), to: CGPoint(x: 150, y: 80))
        XCTAssertEqual(cuts[1].1, -60)
        XCTAssertEqual(cuts[1].2, 50)
        if case .horizontal = cuts[0].0 {} else { XCTFail("Rows axis") }
        if case .vertical = cuts[1].0 {} else { XCTFail("Columns axis") }
    }

    func testEscapeCancelsInlineBandThenReturnsToNativeEditor() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        canvas.mode = .rows
        canvas.onCut = { _, _, _ in XCTFail("Cancelled band applied") }
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 40, y: 30)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 150, y: 80)))
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 150, y: 80)))
        XCTAssertTrue(editor.keys.isEmpty)
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
        XCTAssertEqual(editor.keys, [53], "Idle Escape uses the native editor's close behavior")
    }

    func testInlineMoveUsesProjectedSnapRadiusAndDragThreshold() {
        let (editor, canvas) = fixture(twoPieces: true)
        let window = host(editor)
        defer { window.orderOut(nil) }
        var moves: [CGPoint] = []
        canvas.onMove = { _, point, _ in moves.append(point) }
        // 2 source pixels per point: four pixels are only two screen points.
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, CGPoint(x: 260, y: 20)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 256, y: 20)))
        XCTAssertTrue(moves.isEmpty)
        // Proposed x=120 is 20 pixels (10 points) from the first piece's right edge 100.
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, CGPoint(x: 230, y: 20)))
        XCTAssertEqual(moves.last, CGPoint(x: 100, y: -50))
        XCTAssertTrue(canvas.alignmentGuides.contains { $0.start.x == 100 && $0.start.y == -66 })
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, CGPoint(x: 230, y: 20)))
        XCTAssertEqual(moves.last, CGPoint(x: 100, y: -50))
    }

    func testNativeToolAndCommandKeysForwardButMoveKeysStayLocal() {
        let (editor, canvas) = fixture()
        let window = host(editor)
        defer { window.orderOut(nil) }
        var deleted = 0, moved = 0
        canvas.onDelete = { deleted += 1 }
        canvas.onMove = { _, _, _ in moved += 1 }
        canvas.selectedID = canvas.document.pieces[0].id
        for (characters, code) in [("r", UInt16(15)), ("c", UInt16(8)), ("v", UInt16(9))] {
            canvas.keyDown(with: TestKeyEvent.keyDown(characters: characters, keyCode: code))
        }
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "s", keyCode: 1, modifiers: .command))
        XCTAssertEqual(editor.keys, [15, 8, 9, 1])
        XCTAssertEqual(canvas.mode, .move)
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "", keyCode: 124))
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "", keyCode: 51))
        XCTAssertEqual(moved, 2)
        XCTAssertEqual(deleted, 1)
        canvas.mode = .rows
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "", keyCode: 51))
        XCTAssertEqual(editor.keys.last, 51)
        XCTAssertEqual(deleted, 1)
    }

    private func fixture(twoPieces: Bool = false) -> (KeyEditor, StitchCanvasView) {
        let editor = KeyEditor(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        editor.applySelection(CGRect(x: 10, y: 20, width: 200, height: 100))
        let image = ImageProbe.quadrantImage(width: 400, height: 200).cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var first = StitchPiece(image: image, origin: CGPoint(x: -100, y: -50))
        var pieces = [first]
        if twoPieces {
            first.source.size.width = 200
            var second = first
            second.id = UUID(); second.origin.x = 150; second.source.size.width = 150
            pieces = [first, second]
        }
        let canvas = StitchCanvasView(frame: .zero)
        editor.addSubview(canvas)
        canvas.inlineEditor = editor
        canvas.refresh(StitchDocument(pieces: pieces), preview: nil)
        return (editor, canvas)
    }
    private func host(_ editor: NSView) -> NSWindow {
        let window = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = editor
        return window
    }
    private func mouse(_ type: NSEvent.EventType, _ canvas: NSView, _ point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    private func drag(_ canvas: StitchCanvasView, from: CGPoint, to: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, canvas, from))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, canvas, to))
        canvas.mouseUp(with: mouse(.leftMouseUp, canvas, to))
    }
}
