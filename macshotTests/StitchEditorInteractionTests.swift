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

    func testRowAndColumnModesCutDocumentCoordinates() {
        let view = StitchCanvasView(frame: .zero)
        view.refresh(StitchDocument(pieces: [StitchPiece(image: image())]), preview: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        view.onMode = { view.mode = $0 }
        var cuts: [(StitchAxis, CGFloat, CGFloat)] = []
        view.onCut = { cuts.append(($0, $1, $2)) }
        view.keyDown(with: TestKeyEvent.keyDown(characters: "r", keyCode: 15))
        drag(view, from: CGPoint(x: 20, y: 25), to: CGPoint(x: 100, y: 65))
        XCTAssertEqual(cuts.count, 1)
        if case .horizontal = cuts[0].0 {} else { XCTFail("Rows must collapse horizontally") }
        XCTAssertEqual(cuts[0].1, 25, accuracy: 0.01)
        XCTAssertEqual(cuts[0].2, 65, accuracy: 0.01)

        view.keyDown(with: TestKeyEvent.keyDown(characters: "c", keyCode: 8))
        drag(view, from: CGPoint(x: 80, y: 15), to: CGPoint(x: 30, y: 90))
        XCTAssertEqual(cuts.count, 2)
        if case .vertical = cuts[1].0 {} else { XCTFail("Columns must collapse vertically") }
        XCTAssertEqual(cuts[1].1, 80, accuracy: 0.01)
        XCTAssertEqual(cuts[1].2, 30, accuracy: 0.01)
        view.onMode = nil
    }

    func testEscapeCancelsPendingBandWithoutCutting() {
        let view = StitchCanvasView(frame: .zero)
        view.refresh(StitchDocument(pieces: [StitchPiece(image: image())]), preview: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        view.mode = .rows
        view.onCut = { _, _, _ in XCTFail("Cancelled band must not cut") }
        view.mouseDown(with: mouse(.leftMouseDown, view: view, point: CGPoint(x: 20, y: 20)))
        view.mouseDragged(with: mouse(.leftMouseDragged, view: view, point: CGPoint(x: 50, y: 60)))
        view.keyDown(with: TestKeyEvent.keyDown(characters: "\u{1B}", keyCode: 53))
        view.mouseUp(with: mouse(.leftMouseUp, view: view, point: CGPoint(x: 50, y: 60)))
        XCTAssertEqual(view.document.pieces.count, 1)
    }

    private func drag(_ view: StitchCanvasView, from: CGPoint, to: CGPoint) {
        view.mouseDown(with: mouse(.leftMouseDown, view: view, point: from))
        view.mouseDragged(with: mouse(.leftMouseDragged, view: view, point: to))
        view.mouseUp(with: mouse(.leftMouseUp, view: view, point: to))
    }
    private func mouse(_ type: NSEvent.EventType, view: StitchCanvasView, point: CGPoint) -> NSEvent {
        let location = view.convert(CGPoint(x: point.x + 80, y: point.y + 80), to: nil)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                 windowNumber: view.window?.windowNumber ?? 0, context: nil,
                                 eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
