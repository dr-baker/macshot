import AppKit
import XCTest

@MainActor
private final class StitchShortcutSpyEditor: EditorView {
    var receivedSave = false
    override func keyDown(with event: NSEvent) {
        if KeyboardShortcutMatcher.matches(event, character: "s", modifiers: .command) {
            receivedSave = true
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
final class StitchEditorIntegrationTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testInlineCanvasKeepsNativeEditorAndSharesAnnotationUndo() throws {
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
        let root = NSView(frame: window.contentView!.bounds)
        root.addSubview(editor)
        window.contentView = root
        pane.attach(to: editor)
        defer { pane.suspend(); editor.onStitchDocumentChanged = nil; window.orderOut(nil) }
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? StitchCanvasView }.first)
        XCTAssertTrue(canvas.window === window)
        XCTAssertTrue(canvas.superview === editor)
        XCTAssertTrue(window.contentView === root)
        XCTAssertTrue(editor.superview === root)
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
        pane.suspend()
        XCTAssertNil(canvas.superview)
        XCTAssertTrue(window.contentView === root)
        XCTAssertTrue(editor.superview === root)
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
        let editor = StitchShortcutSpyEditor(frame: NSRect(origin: .zero, size: image.size))
        editor.screenshotImage = image
        editor.applySelection(editor.bounds)
        editor.installStitchDocument(StitchDocument(pieces: [StitchPiece(image: pixels)]))
        let root = NSView(frame: window.contentView!.bounds)
        root.addSubview(editor)
        window.contentView = root
        editor.rebuildToolbarLayout()
        let parentButtons = descendants(editor).compactMap { $0 as? ToolbarButtonView }
        pane.attach(to: editor)
        defer { pane.suspend(); window.orderOut(nil) }
        pane.append([image])
        XCTAssertEqual(latest?.pieces.count, 2)
        XCTAssertEqual(latest?.bounds.size, NSSize(width: 120, height: 200))
        let canvas = try XCTUnwrap(descendants(root).compactMap { $0 as? StitchCanvasView }.first)
        canvas.copy(nil)
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "s", keyCode: 1, modifiers: .command))
        XCTAssertEqual(actions, [.copy])
        XCTAssertTrue(editor.receivedSave, "Inline shortcuts must reach the native parent editor")
        let nativeOutputs = descendants(root).compactMap { $0 as? ToolbarButtonView }.map(\.action)
        for action in ToolbarLayout.rightButtons(isEditorMode: true).map(\.action) {
            XCTAssertTrue(nativeOutputs.contains(action))
        }
        let currentButtons = descendants(editor).compactMap { $0 as? ToolbarButtonView }
        XCTAssertEqual(currentButtons.map(ObjectIdentifier.init), parentButtons.map(ObjectIdentifier.init),
                       "Attaching Stitch must preserve the parent's native toolbar controls")
        XCTAssertFalse(descendants(canvas).contains { $0 is ToolbarStripView },
                       "The inline canvas must not create its own action toolbar")
    }

    func testTwoTimesPixelVerticalCutPublishesToNativeEditorAndUndoRestoresAnnotations() throws {
        let source = ImageProbe.quadrantImage(width: 240, height: 200)
        let pixels = try XCTUnwrap(source.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let image = NSImage(cgImage: pixels, size: NSSize(width: 120, height: 100))
        let document = StitchDocument(pieces: [StitchPiece(image: pixels)])
        let editor = EditorView(frame: NSRect(origin: .zero, size: image.size))
        editor.screenshotImage = image
        editor.applySelection(editor.bounds)
        editor.installStitchDocument(document)
        let mark = Annotation(tool: .filledRectangle, startPoint: NSPoint(x: 90, y: 20),
                              endPoint: NSPoint(x: 100, y: 30), color: .red, strokeWidth: 2)
        editor.annotations = [mark]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        let controller = StitchEditorController(document: document, window: window)
        controller.onCheckpoint = { editor.checkpointStitchDocument() }
        controller.onDocumentChanged = { editor.applyStitchDocument($0, registerUndo: false) }
        controller.onUndo = { editor.undo() }
        controller.canUndo = { !editor.undoStack.isEmpty }
        var publications = 0
        editor.onStitchDocumentChanged = { [weak controller, weak editor] in
            publications += 1
            if let value = editor?.stitchDocument { controller?.restore(value) }
        }
        controller.attach(to: editor)
        defer { controller.suspend(); editor.onStitchDocumentChanged = nil; window.orderOut(nil) }
        let canvas = try XCTUnwrap(descendants(editor).compactMap { $0 as? StitchCanvasView }.first)
        controller.setMode(.columns)
        XCTAssertEqual(canvas.mode, .columns)
        canvas.onCut?(.vertical, 80, 120)
        XCTAssertEqual(editor.stitchDocument?.bounds.size, NSSize(width: 200, height: 200))
        XCTAssertEqual(editor.screenshotImage?.size, NSSize(width: 100, height: 100))
        XCTAssertEqual(mark.startPoint.x, 70, accuracy: 0.001)
        XCTAssertGreaterThan(publications, 0)
        let annotationPixels = try XCTUnwrap(editor.stitchAnnotationPreview())
        XCTAssertEqual(annotationPixels.width, 200)
        XCTAssertEqual(annotationPixels.height, 200)
        canvas.keyDown(with: TestKeyEvent.keyDown(characters: "z", keyCode: 6, modifiers: .command))
        XCTAssertEqual(editor.stitchDocument?.bounds.size, NSSize(width: 240, height: 200))
        XCTAssertEqual(editor.screenshotImage?.size, NSSize(width: 120, height: 100))
        XCTAssertEqual(mark.startPoint.x, 90, accuracy: 0.001)
        XCTAssertTrue(editor.annotations.first === mark)
    }

    func testOpeningStitchUsesNativeEditorAndPreservesZoomAcrossToolChanges() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Opening a real editor requires a display") }
        let oldTool = UserDefaults.standard.object(forKey: "lastUsedTool")
        let oldPolicy = NSApp.activationPolicy()
        defer {
            if let oldTool { UserDefaults.standard.set(oldTool, forKey: "lastUsedTool") }
            else { UserDefaults.standard.removeObject(forKey: "lastUsedTool") }
            NSApp.setActivationPolicy(oldPolicy)
        }
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        DetachedEditorWindowController.open(image: ImageProbe.quadrantImage(width: 240, height: 200),
                                            tool: .stitch, disableBeautify: true)
        let window = try XCTUnwrap(NSApp.windows.first { window in
            !previousWindows.contains(ObjectIdentifier(window)) && window.contentView.map {
                descendants($0).contains { $0 is EditorView }
            } == true
        })
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(descendants(root).compactMap { $0 as? EditorView }.first)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let topBar = try XCTUnwrap(descendants(root).compactMap { $0 as? EditorTopBarView }.first)
        let canvas = try XCTUnwrap(descendants(editor).compactMap { $0 as? StitchCanvasView }.first)
        XCTAssertEqual(editor.currentTool, .stitch)
        XCTAssertTrue(canvas.window === window)
        XCTAssertTrue(canvas.superview === editor)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.isEmpty,
                      "Stitch is a native editor tool, without an Annotate/Stitch titlebar switch")
        scroll.setMagnification(0.75, centeredAt: NSPoint(x: 120, y: 100))
        let zoom = scroll.magnification
        canvas.onCut?(.horizontal, 60, 100)
        XCTAssertEqual(editor.stitchDocument?.bounds.size, NSSize(width: 240, height: 160))
        XCTAssertEqual(canvas.frame, editor.selectionRect, "Cuts update native geometry before the asynchronous preview")
        XCTAssertEqual(canvas.bounds.size, NSSize(width: 240, height: 160))
        let cutImage = try XCTUnwrap(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cutImage.height, 160)
        XCTAssertEqual(editor.undoStack.count, 1)
        editor.handleToolbarAction(.tool(.rectangle))
        XCTAssertNil(canvas.superview)
        XCTAssertTrue(window.contentView === root)
        XCTAssertTrue(editor.enclosingScrollView === scroll)
        XCTAssertTrue(descendants(root).contains { $0 === topBar })
        XCTAssertEqual(scroll.magnification, zoom, accuracy: 0.0001)
        editor.handleToolbarAction(.tool(.stitch))
        let resumed = try XCTUnwrap(descendants(editor).compactMap { $0 as? StitchCanvasView }.first)
        XCTAssertTrue(resumed === canvas)
        XCTAssertTrue(window.contentView === root)
        XCTAssertEqual(scroll.magnification, zoom, accuracy: 0.0001)
        resumed.keyDown(with: TestKeyEvent.keyDown(characters: "z", keyCode: 6, modifiers: .command))
        XCTAssertEqual(editor.stitchDocument?.bounds.size, NSSize(width: 240, height: 200))
        XCTAssertEqual(editor.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.height, 200)
        XCTAssertTrue(editor.undoStack.isEmpty)

        // The native flip controls replace the raster before restoring its pieces.
        // Stitch must resume on that same canvas and keep accepting both cut axes.
        editor.flipImageHorizontally()
        XCTAssertTrue(canvas.superview === editor)
        XCTAssertEqual(editor.currentTool, .stitch)
        XCTAssertEqual(scroll.magnification, zoom, accuracy: 0.0001)
        editor.stitchMode = .columns
        canvas.onCut?(.vertical, 80, 120)
        XCTAssertEqual(editor.stitchDocument?.bounds.size, NSSize(width: 200, height: 200))
        editor.undo()
        editor.flipImageVertically()
        XCTAssertTrue(canvas.superview === editor)
        editor.stitchMode = .rows
        canvas.onCut?(.horizontal, 60, 100)
        XCTAssertEqual(editor.stitchDocument?.bounds.size, NSSize(width: 240, height: 160))
        XCTAssertTrue(window.contentView === root)
    }


    func testNativeImagePasteAddsEditablePieceAndSharesUndo() throws {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Opening a real editor requires a display") }
        let board = NSPasteboard.general
        let savedItems = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let oldTool = UserDefaults.standard.object(forKey: "lastUsedTool")
        let oldPolicy = NSApp.activationPolicy()
        defer {
            board.clearContents()
            let restored = savedItems.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            board.writeObjects(restored)
            if let oldTool { UserDefaults.standard.set(oldTool, forKey: "lastUsedTool") }
            else { UserDefaults.standard.removeObject(forKey: "lastUsedTool") }
            NSApp.setActivationPolicy(oldPolicy)
        }
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        DetachedEditorWindowController.open(image: ImageProbe.quadrantImage(width: 120, height: 100),
                                            tool: .stitch, disableBeautify: true)
        let window = try XCTUnwrap(NSApp.windows.first { window in
            !previousWindows.contains(ObjectIdentifier(window)) && window.contentView.map {
                descendants($0).contains { $0 is EditorView }
            } == true
        })
        defer { window.close() }
        let editor = try XCTUnwrap(descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? EditorView }.first)
        let canvas = try XCTUnwrap(descendants(editor).compactMap { $0 as? StitchCanvasView }.first)
        board.clearContents()
        XCTAssertTrue(board.writeObjects([ImageProbe.solidImage(width: 40, height: 60)]))
        XCTAssertTrue(editor.performKeyEquivalent(with:
            TestKeyEvent.keyDown(characters: "v", keyCode: 9, modifiers: .command)))
        XCTAssertEqual(editor.stitchDocument?.pieces.count, 2)
        XCTAssertTrue(editor.annotations.isEmpty, "Pasted captures must remain pieces rather than image stamps")
        XCTAssertEqual(editor.undoStack.count, 1)
        XCTAssertTrue(canvas.superview === editor)
        XCTAssertEqual(editor.stitchMode, .move, "New captures should be ready to arrange rather than remove a band")
        XCTAssertEqual(canvas.selectedID, editor.stitchDocument?.pieces.last?.id)
        XCTAssertEqual(canvas.frame, editor.selectionRect, "Appending immediately expands the native editing canvas")
        editor.undo()
        XCTAssertEqual(editor.stitchDocument?.pieces.count, 1)
        XCTAssertEqual(editor.stitchDocument?.bounds.size, NSSize(width: 120, height: 100))
        XCTAssertEqual(editor.screenshotImage?.size, NSSize(width: 120, height: 100))
        XCTAssertTrue(canvas.superview === editor)
    }

    func testOptionalNativeStitchVisualPreview() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MACSHOT_NATIVE_STITCH_PREVIEW"]
                ?? environment["TEST_RUNNER_MACSHOT_NATIVE_STITCH_PREVIEW"], !path.isEmpty else {
            throw XCTSkip("Set MACSHOT_NATIVE_STITCH_PREVIEW to export the native editor fixture")
        }
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("Preview requires a display") }
        let oldTool = UserDefaults.standard.object(forKey: "lastUsedTool")
        let oldPolicy = NSApp.activationPolicy()
        defer {
            if let oldTool { UserDefaults.standard.set(oldTool, forKey: "lastUsedTool") }
            else { UserDefaults.standard.removeObject(forKey: "lastUsedTool") }
            NSApp.setActivationPolicy(oldPolicy)
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1100, pixelsHigh: 900,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(white: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1100, height: 900).fill()
        func text(_ string: String, top: CGFloat, size: CGFloat, bold: Bool = false) {
            (string as NSString).draw(at: NSPoint(x: 76, y: 900 - top - size * 1.3), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                .foregroundColor: NSColor(white: 0.18, alpha: 1)
            ])
        }
        text("FIELD NOTES / PRODUCT DESIGN", top: 52, size: 15, bold: true)
        text("A clearer capture workflow", top: 96, size: 36, bold: true)
        text("Synthetic page for Stitch interaction review", top: 155, size: 20)
        text("01  Keep the useful context", top: 224, size: 25, bold: true)
        text("Capture the heading and the details you want to share.", top: 273, size: 21)
        text("Remove the empty space between sections without losing either section.", top: 309, size: 21)
        text("02  Bring the next section closer", top: 624, size: 25, bold: true)
        text("The lower section remains intact when the blank band is removed.", top: 674, size: 21)
        text("Annotations and the original image stay editable in the native editor.", top: 710, size: 21)
        NSColor(srgbRed: 0.19, green: 0.43, blue: 0.67, alpha: 1).setFill()
        NSRect(x: 76, y: 78, width: 948, height: 5).fill()
        text("REVIEW COPY  ·  All content is synthetic", top: 839, size: 15)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 1100, height: 900))
        image.addRepresentation(bitmap)
        let previousWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        DetachedEditorWindowController.open(image: image, tool: .stitch, disableBeautify: true)
        let window = try XCTUnwrap(NSApp.windows.first { window in
            !previousWindows.contains(ObjectIdentifier(window)) && window.contentView.map {
                descendants($0).contains { $0 is EditorView }
            } == true
        })
        defer { window.close() }
        let root = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(descendants(root).compactMap { $0 as? EditorView }.first)
        let canvas = try XCTUnwrap(descendants(editor).compactMap { $0 as? StitchCanvasView }.first)
        editor.stitchMode = .rows
        root.layoutSubtreeIfNeeded()
        let guidesReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in canvas.bandGuideRows.count > 2 }, object: canvas)
        await fulfillment(of: [guidesReady], timeout: 5)
        let internalGuides = canvas.bandGuideRows.filter { $0 > 0 && $0 < 900 }
        let gap = try XCTUnwrap(zip(internalGuides, internalGuides.dropFirst()).max {
            $0.1 - $0.0 < $1.1 - $1.0
        }, "The real editor should suggest boundaries for the large empty section")
        let removed = gap.1.rounded() - gap.0.rounded()
        XCTAssertGreaterThan(removed, 200)
        func mouse(_ type: NSEvent.EventType, y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(NSPoint(x: 550, y: y), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func export(_ url: URL) throws {
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            let rendered = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: rendered)
            XCTAssertGreaterThan(rendered.pixelsWide, 500)
            XCTAssertGreaterThan(rendered.pixelsHigh, 400)
            let png = try XCTUnwrap(rendered.representation(using: .png, properties: [:]))
            try png.write(to: url)
        }
        canvas.mouseDown(with: try mouse(.leftMouseDown, y: gap.0 + 3))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, y: gap.1 - 3))
        XCTAssertEqual(canvas.bandGuideMatches, [gap.0, gap.1])
        let output = URL(fileURLWithPath: path)
        try export(output.deletingLastPathComponent().appendingPathComponent(output.deletingPathExtension().lastPathComponent + "-band.png"))
        canvas.mouseUp(with: try mouse(.leftMouseUp, y: gap.1 - 3))
        XCTAssertEqual(editor.stitchDocument?.bounds.size, NSSize(width: 1100, height: 900 - removed))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in canvas.preview?.height == Int(900 - removed) }, object: canvas)
        await fulfillment(of: [ready], timeout: 5)
        try export(output)
    }

}
