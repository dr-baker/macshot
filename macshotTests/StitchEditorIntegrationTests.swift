import AppKit
import XCTest

@MainActor
final class StitchEditorIntegrationTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testEmbeddedPaneUsesHostWindowAndSharedAnnotationUndo() throws {
        let image = ImageProbe.quadrantImage(width: 120, height: 100)
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let doc = StitchDocument(pieces: [StitchPiece(image: pixels)])
        let editor = EditorView(frame: NSRect(origin: .zero, size: image.size))
        editor.screenshotImage = image
        editor.applySelection(editor.bounds)
        editor.installStitchDocument(doc)
        let mark = Annotation(tool: .filledRectangle, startPoint: NSPoint(x: 10, y: 10),
            endPoint: NSPoint(x: 25, y: 25), color: .red, strokeWidth: 2)
        editor.annotations = [mark]
        editor.undoStack = [.added(mark)]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        let pane = StitchEditorController(document: doc, window: window)
        pane.onCheckpoint = { editor.checkpointStitchDocument() }
        pane.onDocumentChanged = { editor.applyStitchDocument($0, registerUndo: false) }
        pane.onUndo = { editor.undo() }
        pane.onRedo = { editor.redo() }
        pane.canUndo = { !editor.undoStack.isEmpty }
        pane.canRedo = { !editor.redoStack.isEmpty }
        let root = pane.makeView()
        window.contentView = root
        defer { pane.suspend(); editor.onStitchDocumentChanged = nil; window.orderOut(nil) }
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? StitchCanvasView }.first)
        XCTAssertTrue(canvas.window === window)
        editor.onStitchDocumentChanged = { [weak pane, weak editor] in
            if let doc = editor?.stitchDocument { pane?.restore(doc) }
        }
        canvas.onCut?(.horizontal, 40, 60)
        XCTAssertEqual(editor.stitchDocument?.bounds.height, 80)
        XCTAssertEqual(editor.undoStack.count, 2)
        XCTAssertEqual(editor.annotations.count, 1)
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "z", keyCode: 6, modifiers: .command))
        XCTAssertEqual(editor.stitchDocument?.bounds.height, 100)
        XCTAssertEqual(editor.annotations.count, 1)
        XCTAssertTrue(editor.annotations[0] === mark)
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "z", keyCode: 6, modifiers: .command))
        XCTAssertTrue(editor.annotations.isEmpty)
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "z", keyCode: 6, modifiers: [.command, .shift]))
        XCTAssertTrue(editor.annotations[0] === mark)
    }

    func testCaptureAppendAndNativeOutputsRouteThroughHost() throws {
        let image = ImageProbe.quadrantImage(width: 120, height: 100)
        let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        let pane = StitchEditorController(document: StitchDocument(pieces: [StitchPiece(image: pixels)]), window: window)
        var latest: StitchDocument?
        pane.onDocumentChanged = { latest = $0; return true }
        var actions: [ToolbarButtonAction] = []
        pane.onAction = { action, _ in actions.append(action) }
        let root = pane.makeView()
        window.contentView = root
        defer { pane.suspend(); window.orderOut(nil) }
        pane.append([image])
        XCTAssertEqual(latest?.pieces.count, 2)
        XCTAssertEqual(latest?.bounds.size, NSSize(width: 120, height: 200))
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? StitchCanvasView }.first)
        canvas.copy(nil)
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "s", keyCode: 1, modifiers: .command))
        XCTAssertEqual(actions, [.copy, .save])
        let nativeOutputs = descendants(root).compactMap { $0 as? ToolbarButtonView }.map(\.action)
        for action in ToolbarLayout.rightButtons(isEditorMode: true).map(\.action) {
            XCTAssertTrue(nativeOutputs.contains(action))
        }
        var contextual: ToolbarButtonAction?
        pane.onContextAction = { action, _ in contextual = action }
        let save = try XCTUnwrap(descendants(root).compactMap { $0 as? ToolbarButtonView }.first { $0.action == .save })
        let strip = try XCTUnwrap(save.superview as? ToolbarStripView)
        strip.onRightClick?(.save, save)
        XCTAssertEqual(contextual, .save)
        XCTAssertEqual(actions.count, 2, "Right-click must not export")
    }
}
