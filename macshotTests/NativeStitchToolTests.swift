import AppKit
import XCTest

@MainActor
final class NativeStitchToolTests: XCTestCase {
    private func editor() -> EditorView {
        let view = EditorView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
        view.screenshotImage = ImageProbe.quadrantImage(width: 100, height: 80)
        view.applySelection(view.bounds)
        view.currentTool = .arrow
        return view
    }

    func testSSelectsStitchInTheEditorAndKeepsSelectedCapturesInTheOverlay() {
        withDefaults(["overlayToolShortcuts": nil]) {
            // Invalidate the cached lookup after replacing the test preferences.
            ToolShortcutManager.setKey("p", for: .pencil)
            let key = TestKeyEvent.keyDown(characters: "s", keyCode: 1)
            let view = editor()
            view.keyDown(with: key)
            XCTAssertEqual(view.currentTool, .stitch)

            let capture = ImageEditingView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
            capture.screenshotImage = ImageProbe.quadrantImage(width: 100, height: 80)
            capture.applySelection(capture.bounds)
            capture.currentTool = .arrow
            let delegate = StitchHandoffDelegate()
            capture.overlayDelegate = delegate
            capture.onStitchToolChanged = { enabled in if enabled { XCTAssertTrue(capture.beginStitchEditing()) } }
            capture.keyDown(with: key)
            XCTAssertEqual(capture.currentTool, .stitch)
            XCTAssertEqual(delegate.detachRequests, 0)
            XCTAssertNotNil(capture.stitchDocument)
        }
    }

    func testNativeToolAppearsInCaptureAndEditorAndRespectsVisibilityPreference() {
        withDefaults(["enabledTools": [AnnotationTool.arrow.rawValue, AnnotationTool.stitch.rawValue],
            "knownToolRawValues": AnnotationTool.allCases.map(\.rawValue)]) {
            let overlay = ToolbarLayout.bottomButtons(selectedTool: .arrow, selectedColor: .red)
            XCTAssertTrue(overlay.contains { $0.action == .tool(.stitch) })
            let editor = ToolbarLayout.bottomButtons(selectedTool: .stitch, selectedColor: .red)
            XCTAssertEqual(editor.filter { $0.action == .tool(.stitch) }.count, 1)
            XCTAssertTrue(editor.first { $0.action == .tool(.stitch) }!.isSelected)
            UserDefaults.standard.set([AnnotationTool.arrow.rawValue], forKey: "enabledTools")
            let hidden = ToolbarLayout.bottomButtons(selectedTool: .arrow, selectedColor: .red)
            XCTAssertFalse(hidden.contains { $0.action == .tool(.stitch) })
            let hiddenCapture = ToolbarLayout.bottomButtons(selectedTool: .arrow, selectedColor: .red)
            XCTAssertFalse(hiddenCapture.contains { $0.action == .tool(.stitch) })
            XCTAssertTrue(ToolbarLayout.bottomButtons(selectedTool: .arrow, selectedColor: .red,
                isRecording: true).isEmpty)
        }
    }

    func testStitchDoesNotOverwriteRememberedDrawingToolOrEnterAnUnselectedCapture() {
        withDefaults(["rememberLastTool": true, "lastUsedTool": AnnotationTool.arrow.rawValue]) {
            let view = editor()
            view.currentTool = .rectangle
            view.handleToolbarAction(.tool(.stitch))
            XCTAssertEqual(view.currentTool, .stitch)
            XCTAssertEqual(UserDefaults.standard.integer(forKey: "lastUsedTool"), AnnotationTool.rectangle.rawValue)
            let overlay = OverlayView()
            XCTAssertEqual(overlay.currentTool, .rectangle)
            overlay.handleToolbarAction(.tool(.stitch))
            XCTAssertEqual(overlay.currentTool, .rectangle)
            view.currentTool = .arrow
        }
    }

    func testSelectedCaptureKeepsRawImageAnnotationsAndSettingsInItsOverlay() throws {
        let view = ImageEditingView(frame: CGRect(x: 0, y: 0, width: 160, height: 120))
        let screenshot = ImageProbe.quadrantImage(width: 160, height: 120)
        view.screenshotImage = screenshot
        let selection = CGRect(x: 20, y: 10, width: 100, height: 80)
        view.applySelection(selection)
        view.currentTool = .rectangle
        let annotation = Annotation(tool: .arrow, startPoint: CGPoint(x: 30, y: 20),
            endPoint: CGPoint(x: 80, y: 60), color: .red, strokeWidth: 3)
        view.annotations = [annotation]
        view.undoStack = [.added(annotation)]
        view.effectsBrightness = 0.15
        let delegate = StitchHandoffDelegate()
        view.overlayDelegate = delegate
        view.onStitchToolChanged = { enabled in if enabled { XCTAssertTrue(view.beginStitchEditing()) } }
        view.handleToolbarAction(.tool(.stitch))
        XCTAssertEqual(delegate.detachRequests, 0)
        XCTAssertEqual(view.currentTool, .stitch)
        XCTAssertFalse(view.isEditorMode)
        XCTAssertTrue(view.stitchCaptureBackdrop === screenshot)
        XCTAssertEqual(view.screenshotImage?.size, selection.size)
        XCTAssertEqual(view.selectionRect, selection)
        XCTAssertEqual(view.frame.size, screenshot.size)
        XCTAssertTrue(view.annotations[0] === annotation)
        XCTAssertEqual(view.undoStack.count, 1)
        XCTAssertEqual(view.effectsBrightness, 0.15)
        XCTAssertNotNil(view.stitchDocument)
    }

    func testStitchHandoffIsBlockedForIdleRecordingSelectionOnlyAndPendingPixels() {
        for captureMode in 0..<4 {
            let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 100, height: 80))
            view.screenshotImage = ImageProbe.quadrantImage(width: 100, height: 80)
            view.currentTool = .arrow
            if captureMode != 0 { view.applySelection(view.bounds) }
            if captureMode == 1 { view.isRecording = true }
            if captureMode == 2 { view.selectionOnlyMode = true }
            if captureMode == 3 { view.screenshotImage = nil }
            let delegate = StitchHandoffDelegate()
            view.overlayDelegate = delegate
            view.handleToolbarAction(.tool(.stitch))
            XCTAssertEqual(delegate.detachRequests, 0)
            XCTAssertEqual(view.currentTool, .arrow)
        }
    }

    func testVisibilityPreferenceNotificationUpdatesExistingCaptureAndEditorToolbars() {
        withDefaults(["enabledTools": [AnnotationTool.arrow.rawValue],
            "knownToolRawValues": AnnotationTool.allCases.map(\.rawValue)]) {
            let capture = OverlayView(frame: CGRect(x: 0, y: 0, width: 120, height: 100))
            capture.applySelection(capture.bounds)
            let editor = self.editor()
            let captureWindow = NSWindow(contentRect: capture.frame, styleMask: .borderless, backing: .buffered, defer: false)
            let editorWindow = NSWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
            captureWindow.contentView = capture
            editorWindow.contentView = editor
            defer { captureWindow.orderOut(nil); editorWindow.orderOut(nil) }
            for view in [capture, editor] {
                XCTAssertFalse(view.bottomButtons.contains { $0.action == .tool(.stitch) })
            }
            UserDefaults.standard.set([AnnotationTool.arrow.rawValue, AnnotationTool.stitch.rawValue], forKey: "enabledTools")
            NotificationCenter.default.post(name: .toolbarVisibilityDidChange, object: nil)
            for view in [capture, editor] {
                XCTAssertTrue(view.bottomButtons.contains { $0.action == .tool(.stitch) })
                XCTAssertTrue(view.subviews.compactMap { $0 as? ToolbarStripView }.contains {
                    $0.buttonViews.contains { $0.action == .tool(.stitch) }
                })
            }
            UserDefaults.standard.set([AnnotationTool.arrow.rawValue], forKey: "enabledTools")
            NotificationCenter.default.post(name: .toolbarVisibilityDidChange, object: nil)
            for view in [capture, editor] {
                XCTAssertFalse(view.bottomButtons.contains { $0.action == .tool(.stitch) })
            }
        }
    }

    func testNativeToolTransitionsNotifyOnceWithoutChangingUndoHistory() {
        let view = editor()
        var changes: [Bool] = []
        view.onStitchToolChanged = { changes.append($0) }
        view.handleToolbarAction(.tool(.stitch))
        view.handleToolbarAction(.tool(.stitch))
        view.handleToolbarAction(.tool(.rectangle))
        XCTAssertEqual(changes, [true, false])
        XCTAssertTrue(view.undoStack.isEmpty)
        XCTAssertEqual(view.currentTool, .rectangle)
        view.currentTool = .arrow
    }

    func testContextualOptionsChangeModeAndForwardPlacementAndAnchors() throws {
        let view = editor()
        view.handleToolbarAction(.tool(.stitch))
        XCTAssertTrue(view.toolHasOptionsRow)
        let row = ToolOptionsRowView(frame: .zero)
        row.overlayView = view
        row.rebuild(for: .stitch)
        let modes = try XCTUnwrap(row.subviews.first { $0.identifier?.rawValue == "stitch.mode" } as? NSSegmentedControl)
        XCTAssertEqual(modes.selectedSegment, 0)
        XCTAssertEqual(view.stitchMode, .removeSpace)
        XCTAssertEqual(modes.segmentCount, 3)
        XCTAssertEqual(modes.label(forSegment: 0), L("Remove Space"))
        XCTAssertEqual(modes.label(forSegment: 1), L("Move"))
        XCTAssertEqual(modes.toolTip(forSegment: 0),
            L("Drag up or down to remove rows, or left or right to remove columns. Hold ⌥ to ignore guides."))
        for index in 0..<2 { XCTAssertTrue(modes.toolTip(forSegment: index)?.contains("⌥") == true) }
        var modeChanges: [StitchCanvasView.Mode] = []
        view.onStitchModeChanged = { modeChanges.append($0) }
        modes.selectedSegment = 1
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(modes.action), to: modes.target, from: modes))
        XCTAssertEqual(view.stitchMode, .move)
        XCTAssertEqual(modeChanges, [.move])
        modes.selectedSegment = 0
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(modes.action), to: modes.target, from: modes))
        XCTAssertEqual(view.stitchMode, .removeSpace)
        XCTAssertEqual(modeChanges, [.move, .removeSpace])

        var placements: [StitchPlacement] = []
        view.onStitchPlacementChanged = { placements.append($0) }
        let placement = try XCTUnwrap(row.subviews.first { $0.identifier?.rawValue == "stitch.placement" } as? NSPopUpButton)
        placement.selectItem(at: 1)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(placement.action), to: placement.target, from: placement))
        XCTAssertEqual(placements, [.packed])
        XCTAssertTrue(view.undoStack.isEmpty, "The controller owns committing the arrangement change")

        var options: [StitchOptionsAction] = []
        var anchors: [NSView] = []
        view.onStitchOptions = { options.append($0); anchors.append($1) }
        for name in ["stitch.seams", "stitch.pieces", "stitch.canvas"] {
            let button = try XCTUnwrap(row.subviews.first { $0.identifier?.rawValue == name } as? NSButton)
            button.performClick(nil)
            XCTAssertTrue(anchors.last === button)
        }
        let background = try XCTUnwrap(row.subviews.first { $0.identifier?.rawValue == "stitch.background" } as? NSButton)
        let animation = try XCTUnwrap(row.subviews.first { $0.identifier?.rawValue == "stitch.animation" } as? NSButton)
        XCTAssertFalse(background.isEnabled)
        XCTAssertFalse(animation.isEnabled)
        XCTAssertTrue(view.beginStitchEditing())
        var document = try XCTUnwrap(view.stitchDocument)
        document.style.transition = .accordion
        view.installStitchDocument(document)
        row.refreshStitchState()
        XCTAssertTrue(background.isEnabled, "The background can be chosen before making the first fold")
        XCTAssertFalse(animation.isEnabled, "Saving an animation requires a fold")
        background.performClick(nil)
        XCTAssertTrue(anchors.last === background)
        XCTAssertEqual(options.count, 4)
        if case .seams = options[0] {} else { XCTFail("Wrong seam action") }
        if case .pieces = options[1] {} else { XCTFail("Wrong piece action") }
        if case .canvas = options[2] {} else { XCTFail("Wrong canvas action") }
        if case .background = options[3] {} else { XCTFail("Wrong background action") }
        XCTAssertFalse(modes.isEnabled(forSegment: 2), "Preview becomes available after an Accordion join exists")
        XCTAssertEqual(row.frame.height, 34)
        view.currentTool = .arrow
    }

    func testContextualPlacementReflectsRestoredDocumentState() throws {
        let view = editor()
        var document = StitchDocument(pieces: [StitchPiece(image:
            view.screenshotImage!.cgImage(forProposedRect: nil, context: nil, hints: nil)!)])
        XCTAssertTrue(document.pack())
        view.installStitchDocument(document)
        view.currentTool = .stitch
        let row = ToolOptionsRowView(frame: .zero)
        row.overlayView = view
        row.rebuild(for: .stitch)
        let placement = try XCTUnwrap(row.subviews.first { $0.identifier?.rawValue == "stitch.placement" } as? NSPopUpButton)
        XCTAssertEqual(placement.indexOfSelectedItem, 1)
        XCTAssertTrue(document.setPlacement(.free))
        view.installStitchDocument(document)
        row.rebuild(for: .stitch)
        let restored = try XCTUnwrap(row.subviews.first { $0.identifier?.rawValue == "stitch.placement" } as? NSPopUpButton)
        XCTAssertEqual(restored.indexOfSelectedItem, 0)
        view.currentTool = .arrow
    }

    func testDocumentStyleAndUndoRefreshKeepContextualPopoverAnchorsAlive() throws {
        let view = editor()
        var document = StitchDocument(pieces: [StitchPiece(image:
            view.screenshotImage!.cgImage(forProposedRect: nil, context: nil, hints: nil)!)])
        view.installStitchDocument(document)
        view.handleToolbarAction(.tool(.stitch))
        let row = try XCTUnwrap(view.subviews.compactMap { $0 as? ToolOptionsRowView }.first)
        let identities = row.subviews.map(ObjectIdentifier.init)
        let seams = try XCTUnwrap(row.subviews.first { $0.identifier?.rawValue == "stitch.seams" } as? NSButton)
        var anchor: NSView?
        view.onStitchOptions = { _, source in anchor = source }
        seams.performClick(nil)
        XCTAssertTrue(anchor === seams)

        document.style.blur = 23
        XCTAssertTrue(view.applyStitchDocument(document))
        view.refreshStitchOptions()
        XCTAssertEqual(row.subviews.map(ObjectIdentifier.init), identities)
        XCTAssertTrue(anchor?.superview === row)
        XCTAssertTrue(document.pack())
        XCTAssertTrue(view.applyStitchDocument(document))
        view.stitchMode = .move
        let placement = try XCTUnwrap(row.subviews.first { $0.identifier?.rawValue == "stitch.placement" } as? NSPopUpButton)
        let modes = try XCTUnwrap(row.subviews.first { $0.identifier?.rawValue == "stitch.mode" } as? NSSegmentedControl)
        XCTAssertEqual(placement.indexOfSelectedItem, 1)
        XCTAssertEqual(modes.selectedSegment, 1)
        XCTAssertEqual(row.subviews.map(ObjectIdentifier.init), identities)
        view.undo()
        view.refreshStitchOptions()
        XCTAssertEqual(placement.indexOfSelectedItem, 0)
        XCTAssertEqual(row.subviews.map(ObjectIdentifier.init), identities)
        XCTAssertTrue(seams.superview === row)
        view.currentTool = .arrow
    }

    func testProcessingActionsLeaveStitchBeforeApplyingNativeControls() {
        withDefaults(["beautifyStyleIndex": 0, "rememberLastTool": false]) {
            let actions: [ToolbarButtonAction] = [.beautify, .beautifyStyle, .invertColors,
                .removeBackground, .translate, .autoRedact]
            for action in actions {
                let view = editor()
                // Avoid OCR or network work while testing the native action route.
                view.screenshotImage = nil
                view.translateEnabled = true
                view.handleToolbarAction(.tool(.stitch))
                var changes: [Bool] = []
                view.onStitchToolChanged = { changes.append($0) }
                view.handleToolbarAction(action)
                XCTAssertEqual(view.currentTool, .select, "Processing action \(action)")
                XCTAssertEqual(changes, [false])
                if action == .beautify { XCTAssertTrue(view.showBeautifyInOptionsRow) }
                if action == .translate { XCTAssertFalse(view.translateEnabled) }
            }
        }
    }

    func testUndoAndNativeOutputActionsKeepStitchSelected() {
        let view = editor()
        view.handleToolbarAction(.tool(.stitch))
        var changes: [Bool] = []
        view.onStitchToolChanged = { changes.append($0) }
        // With no delegate these output actions perform no export or clipboard write.
        let actions: [ToolbarButtonAction] = [.undo, .redo, .copy, .save, .sizeDisplay]
        for action in actions {
            view.handleToolbarAction(action)
            XCTAssertEqual(view.currentTool, .stitch)
        }
        XCTAssertTrue(changes.isEmpty)
        view.currentTool = .arrow
    }

    func testPopoverToggleBelongsToItsAnchorAcrossImmediateControlSwitches() {
        let seams = NSView(), effects = NSView()
        let now = Date()
        var state = PopoverToggleState()
        state.opened(from: seams)
        XCTAssertTrue(state.shouldClose(from: seams, isVisible: true, at: now))
        XCTAssertFalse(state.shouldClose(from: effects, isVisible: true, at: now))
        // Outside-click dismissal happens before the next toolbar action.
        state.dismissed(at: now)
        XCTAssertTrue(state.shouldClose(from: seams, isVisible: false, at: now))
        XCTAssertFalse(state.shouldClose(from: effects, isVisible: false, at: now))
        state.opened(from: effects)
        XCTAssertTrue(state.shouldClose(from: effects, isVisible: true, at: now))
        XCTAssertFalse(state.shouldClose(from: seams, isVisible: true, at: now))
        state.dismissed(at: now)
        XCTAssertFalse(state.shouldClose(from: effects, isVisible: false, at: now.addingTimeInterval(0.3)))
    }

    func testNativeSeamPickerSharesDocumentColorOpacityAndUndoWithoutChangingDrawingColor() throws {
        try withDefaults(["lastUsedColor": nil, "lastUsedColorOpacity": 0.42, "customColors": nil,
            "rememberLastTool": false]) {
            let view = editor()
            let pixels = try XCTUnwrap(view.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            var document = StitchDocument(pieces: [StitchPiece(image: pixels)])
            let original = NSColor(calibratedRed: 0.2, green: 0.3, blue: 0.6, alpha: 0.7)
            document.style.color = original
            view.installStitchDocument(document)
            view.currentColor = .orange
            view.currentTool = .stitch
            view.rebuildToolbarLayout()
            let strip = try XCTUnwrap(view.subviews.compactMap { $0 as? ToolbarStripView }.first {
                $0.buttonViews.contains { $0.action == .color }
            })
            let anchor = try XCTUnwrap(strip.buttonViews.first { $0.action == .color })
            let picker = view.makeColorPicker(target: .stitchSeam)
            XCTAssertEqual(picker.selectedColor, original)
            XCTAssertEqual(picker.opacity, 0.7, accuracy: 0.001)
            XCTAssertTrue(view.undoStack.isEmpty, "Opening the picker is not an edit")
            picker.onColorChanged?(.green)
            picker.onColorChanged?(.blue)
            picker.onOpacityChanged?(0.3)
            XCTAssertEqual(view.undoStack.count, 1, "The picker groups a continuous color/opacity edit")
            XCTAssertEqual(view.stitchDocument?.style.color, NSColor.blue.withAlphaComponent(0.3))
            XCTAssertEqual(view.currentColor, .orange)
            XCTAssertEqual(UserDefaults.standard.double(forKey: "lastUsedColorOpacity"), 0.42)
            XCTAssertEqual(view.toolbarColor, NSColor.blue.withAlphaComponent(0.3))
            XCTAssertEqual(view.bottomButtons.first { $0.action == .color }?.bgColor, view.toolbarColor)
            XCTAssertTrue(strip.buttonViews.first { $0.action == .color } === anchor)
            view.undo()
            XCTAssertEqual(view.stitchDocument?.style.color, original)
            view.redo()
            XCTAssertEqual(view.stitchDocument?.style.color, NSColor.blue.withAlphaComponent(0.3))
            view.undo()
            picker.onColorChanged?(.purple)
            XCTAssertEqual(view.undoStack.count, 1, "Picking after Undo starts a new edit branch")
            XCTAssertTrue(view.redoStack.isEmpty)
            view.undo()
            XCTAssertEqual(view.stitchDocument?.style.color, original)
        }
    }

    func testPackedPieceControlsFollowReadingOrderForBothAxes() throws {
        let pixels = try XCTUnwrap(ImageProbe.quadrantImage(width: 60, height: 40)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        for horizontal in [false, true] {
            var document = StitchDocument(pieces: (0..<3).map { index in
                StitchPiece(image: pixels, origin: horizontal
                    ? CGPoint(x: CGFloat(index * 60), y: 0) : CGPoint(x: 0, y: CGFloat(index * 40)), label: "Capture \(index + 1)")
            })
            XCTAssertTrue(document.pack())
            XCTAssertEqual(document.savedPackingState.horizontal, horizontal)
            let ids = document.pieces.map(\.id)
            let view = editor()
            view.installStitchDocument(document)
            view.currentTool = .stitch
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            let controller = StitchEditorController(document: document, window: window)
            var latest = document
            controller.onDocumentChanged = { value, _ in latest = value; return true }
            controller.attach(to: view)
            defer { controller.suspend(); window.orderOut(nil) }
            let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? StitchCanvasView }.first)
            canvas.selectedID = ids[1]
            let options = controller.makePieceOptions()
            let scroll = try XCTUnwrap(options.subviews.compactMap { $0 as? NSScrollView }.first)
            let stack = try XCTUnwrap(scroll.documentView as? NSStackView)
            XCTAssertEqual(stack.arrangedSubviews.compactMap { ($0 as? NSButton)?.tag }, [0, 1, 2])
            let earlier = try XCTUnwrap(options.subviews.compactMap { $0 as? NSButton }.first {
                $0.toolTip == L("Move earlier")
            })
            let later = try XCTUnwrap(options.subviews.compactMap { $0 as? NSButton }.first {
                $0.toolTip == L("Move later")
            })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(earlier.action), to: earlier.target, from: earlier))
            XCTAssertEqual(latest.pieces.map(\.id), [ids[1], ids[0], ids[2]])
            let selected = try XCTUnwrap(latest.pieces.first { $0.id == ids[1] })
            XCTAssertEqual(horizontal ? selected.origin.x : selected.origin.y, 0)
            XCTAssertFalse(earlier.isEnabled)
            XCTAssertTrue(later.isEnabled)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(later.action), to: later.target, from: later))
            XCTAssertEqual(latest.pieces.map(\.id), ids)
            XCTAssertEqual(canvas.selectedID, ids[1])
        }
    }

    private func stitchFixture() throws -> (EditorView, StitchEditorController, StitchCanvasView, NSWindow) {
        let pixels = try XCTUnwrap(ImageProbe.quadrantImage(width: 80, height: 60)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let document = StitchDocument(pieces: [StitchPiece(image: pixels),
            StitchPiece(image: pixels, origin: CGPoint(x: 80, y: 0))])
        let view = EditorView(frame: CGRect(origin: .zero, size: document.bounds.size))
        view.screenshotImage = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(document)), size: document.bounds.size)
        view.applySelection(view.bounds)
        view.installStitchDocument(document)
        view.currentTool = .stitch
        view.stitchMode = .move
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        let controller = StitchEditorController(document: document, window: window)
        controller.onDocumentChanged = { value, registerUndo in view.applyStitchDocument(value, registerUndo: registerUndo) }
        view.onStitchDocumentChanged = { [weak controller, weak view] in
            if let document = view?.stitchDocument { controller?.restore(document) }
        }
        controller.attach(to: view)
        let canvas = try XCTUnwrap(view.subviews.compactMap { $0 as? StitchCanvasView }.first)
        return (view, controller, canvas, window)
    }

    func testStyleRestoreAndNativeColorPreserveSelectionUntilPieceIsRemoved() throws {
        try withDefaults(["customColors": nil, "rememberLastTool": false]) {
            let (view, controller, canvas, window) = try stitchFixture()
            defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
            let selected = try XCTUnwrap(view.stitchDocument?.pieces.first?.id)
            canvas.selectedID = selected
            let picker = view.makeColorPicker(target: .stitchSeam)
            picker.onColorChanged?(.blue)
            XCTAssertEqual(canvas.selectedID, selected)
            view.undo()
            XCTAssertEqual(canvas.selectedID, selected)
            view.redo()
            XCTAssertEqual(canvas.selectedID, selected)
            var styleChange = try XCTUnwrap(view.stitchDocument)
            styleChange.style.blur += 1
            controller.restore(styleChange)
            XCTAssertEqual(canvas.selectedID, selected)
            styleChange.pieces.removeAll { $0.id == selected }
            controller.restore(styleChange)
            XCTAssertNil(canvas.selectedID)
        }
    }

    func testSeamTransitionButtonsCommitOnceAndUndoPreservesKnobsAndPieceSelection() throws {
        let (view, controller, canvas, window) = try stitchFixture()
        defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
        var initial = try XCTUnwrap(view.stitchDocument)
        initial.style.color = NSColor.blue.withAlphaComponent(0.4)
        initial.style.blur = 7
        initial.style.feather = 38
        initial.style.lineWidth = 2.5
        initial.style.wave = 6
        initial.style.tearRoughness = 9
        initial.style.breakSize = 4
        initial.style.tearWidth = 15
        initial.style.foldDepth = 23
        initial.style.foldStrength = 0.35
        XCTAssertTrue(view.applyStitchDocument(initial, registerUndo: false))
        let selected = initial.pieces[0].id
        canvas.selectedID = selected
        let options = controller.makeSeamOptions()
        let picker = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchSeamStylePicker }.first)
        let buttons = picker.subviews.compactMap { $0 as? NSButton }
        var registeredChanges = 0
        controller.onDocumentChanged = { value, registerUndo in
            if registerUndo { registeredChanges += 1 }
            return view.applyStitchDocument(value, registerUndo: registerUndo)
        }
        let choices: [StitchTransition] = [.blend, .torn, .fold, .breakLine, .wave]
        for (index, transition) in choices.enumerated() {
            let previous = try XCTUnwrap(view.stitchDocument).style.transition
            let button = try XCTUnwrap(buttons.first {
                $0.identifier?.rawValue == "stitch.transition.\(transition.rawValue)"
            })
            button.performClick(nil)
            let style = try XCTUnwrap(view.stitchDocument).style
            XCTAssertEqual(style.transition, transition)
            XCTAssertEqual(style.color, initial.style.color)
            XCTAssertEqual(style.blur, initial.style.blur)
            XCTAssertEqual(style.feather, initial.style.feather)
            XCTAssertEqual(style.lineWidth, initial.style.lineWidth)
            XCTAssertEqual(style.wave, initial.style.wave)
            XCTAssertEqual(style.tearRoughness, initial.style.tearRoughness)
            XCTAssertEqual(style.breakSize, initial.style.breakSize)
            XCTAssertEqual(style.tearWidth, initial.style.tearWidth)
            XCTAssertEqual(style.foldDepth, initial.style.foldDepth)
            XCTAssertEqual(style.foldStrength, initial.style.foldStrength)
            XCTAssertEqual(registeredChanges, index + 1)
            XCTAssertEqual(view.undoStack.count, index + 1)
            XCTAssertEqual(picker.selection, transition)
            XCTAssertEqual(button.state, .on)
            XCTAssertEqual(buttons.filter { $0.state == .on }.count, 1)
            XCTAssertEqual(canvas.selectedID, selected)
            XCTAssertTrue(controller.makeSeamOptions() === options)
            view.undo()
            XCTAssertEqual(view.stitchDocument?.style.transition, previous)
            XCTAssertEqual(picker.selection, previous)
            XCTAssertEqual(canvas.selectedID, selected)
            view.redo()
            XCTAssertEqual(view.stitchDocument?.style.transition, transition)
            XCTAssertEqual(picker.selection, transition)
            XCTAssertEqual(canvas.selectedID, selected)
            button.performClick(nil)
            XCTAssertEqual(registeredChanges, index + 1, "Clicking the selected treatment must keep its selection and history")
            XCTAssertEqual(view.undoStack.count, index + 1)
            XCTAssertEqual(button.state, .on)
        }
    }

    func testSeamTransitionInspectorShowsOnlyItsApplicableControlsAndResizesTheCachedView() throws {
        let (view, controller, _, window) = try stitchFixture()
        defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
        let options = controller.makeSeamOptions()
        let picker = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchSeamStylePicker }.first)
        let color = try XCTUnwrap(options.subviews.compactMap { $0 as? NSColorWell }.first)
        let colorLabel = try XCTUnwrap(options.subviews.first {
            $0.identifier?.rawValue == "stitch.seam.color.label"
        } as? NSTextField)
        let toggle = try XCTUnwrap(options.subviews.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "stitch.seam.visibility"
        })
        let pickerTopInset = options.bounds.maxY - picker.frame.maxY
        let toggleTopInset = options.bounds.maxY - toggle.frame.maxY
        XCTAssertGreaterThan(toggle.frame.minY, picker.frame.maxY)
        let profiles: [(StitchTransition, [String], String?)] = [
            (.wave, ["Blur", "Fade width", "Line width", "Wave height"], "Line color"),
            (.blend, ["Blur", "Fade width"], nil),
            (.torn, ["Paper width", "Roughness"], nil),
            (.fold, ["Fold depth", "Strength"], nil),
            (.breakLine, ["Blur", "Fade width", "Line width", "Break size"], "Line color"),
        ]
        var heights: [StitchTransition: CGFloat] = [:]
        for (transition, sliderTitles, colorTitle) in profiles {
            let button = try XCTUnwrap(picker.subviews.compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "stitch.transition.\(transition.rawValue)"
            })
            button.performClick(nil)
            XCTAssertEqual(options.bounds.maxY - picker.frame.maxY, pickerTopInset,
                "Treatment choices must keep a stable top inset as the attached inspector resizes")
            XCTAssertEqual(options.bounds.maxY - toggle.frame.maxY, toggleTopInset)
            let sliders = options.subviews.compactMap { $0 as? NSSlider }.filter { !$0.isHidden }
                .sorted { $0.frame.minY > $1.frame.minY }
            XCTAssertEqual(sliders.compactMap { $0.accessibilityLabel() }, sliderTitles.map { L($0) })
            XCTAssertTrue(sliders.allSatisfy { $0.isEnabled && $0.alphaValue == 1 })
            XCTAssertEqual(color.isHidden, colorTitle == nil)
            XCTAssertEqual(colorLabel.isHidden, colorTitle == nil)
            if let colorTitle {
                XCTAssertEqual(colorLabel.stringValue, L(colorTitle))
                XCTAssertEqual(color.color, view.stitchDocument?.style.color)
                XCTAssertEqual(color.accessibilityLabel(), L("Seam line color"))
                XCTAssertTrue(color.isEnabled)
            } else {
                XCTAssertFalse(color.isEnabled)
            }
            for child in options.subviews where !child.isHidden {
                XCTAssertTrue(options.bounds.contains(child.frame), "\(transition) clips \(String(describing: child.identifier))")
                if child is NSSlider || child is NSColorWell || child is NSTextField {
                    XCTAssertLessThan(child.frame.maxY, picker.frame.minY,
                        "Applicable controls must follow the treatment picker")
                }
            }
            for (upper, lower) in zip(sliders, sliders.dropFirst()) {
                XCTAssertGreaterThan(upper.frame.minY, lower.frame.maxY)
            }
            XCTAssertEqual(picker.selection, transition)
            XCTAssertTrue(controller.makeSeamOptions() === options)
            heights[transition] = options.bounds.height
        }
        XCTAssertEqual(heights[.wave], heights[.breakLine])
        XCTAssertEqual(heights[.blend], heights[.fold])
        XCTAssertEqual(heights[.blend], heights[.torn])
        XCTAssertLessThan(try XCTUnwrap(heights[.torn]), try XCTUnwrap(heights[.wave]))
    }

    func testWaveTornAndBreakRememberIndependentShapeEditsAcrossSwitchesAndUndo() throws {
        let (view, controller, canvas, window) = try stitchFixture()
        defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
        var initial = try XCTUnwrap(view.stitchDocument)
        initial.style.wave = 2
        initial.style.tearRoughness = 5
        initial.style.breakSize = 8
        XCTAssertTrue(view.applyStitchDocument(initial, registerUndo: false))
        let selected = initial.pieces.first?.id
        canvas.selectedID = selected
        let options = controller.makeSeamOptions()
        let inspectorWindow = NSWindow(contentRect: options.frame, styleMask: .borderless, backing: .buffered, defer: false)
        inspectorWindow.contentView = options
        defer { inspectorWindow.orderOut(nil) }
        let picker = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchSeamStylePicker }.first)
        let slider = try XCTUnwrap(options.subviews.compactMap { $0 as? NSSlider }.first {
            $0.identifier?.rawValue == "stitch.seam.shape"
        })
        XCTAssertTrue(inspectorWindow.makeFirstResponder(slider))
        let profiles: [(StitchTransition, String, Double)] = [
            (.wave, "Wave height", 4), (.torn, "Roughness", 11), (.breakLine, "Break size", 7),
        ]
        var remembered: [CGFloat] = [2, 5, 8]
        func shapeValues() throws -> [CGFloat] {
            let style = try XCTUnwrap(view.stitchDocument).style
            return [style.wave, style.tearRoughness, style.breakSize]
        }
        func choose(_ transition: StitchTransition) throws {
            try XCTUnwrap(picker.subviews.compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "stitch.transition.\(transition.rawValue)"
            }).performClick(nil)
            XCTAssertEqual(picker.selection, transition)
            XCTAssertTrue(inspectorWindow.firstResponder === slider)
            XCTAssertEqual(canvas.selectedID, selected)
        }
        for (index, profile) in profiles.enumerated() {
            try choose(profile.0)
            XCTAssertEqual(slider.accessibilityLabel(), L(profile.1))
            XCTAssertEqual(slider.doubleValue, Double(remembered[index]))
            let historyCount = view.undoStack.count
            slider.doubleValue = profile.2
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(slider.action), to: slider.target, from: slider))
            var edited = remembered
            edited[index] = CGFloat(profile.2)
            XCTAssertEqual(try shapeValues(), edited)
            XCTAssertEqual(view.undoStack.count, historyCount + 1)
            XCTAssertTrue(inspectorWindow.firstResponder === slider)
            XCTAssertEqual(canvas.selectedID, selected)
            view.undo()
            XCTAssertEqual(try shapeValues(), remembered)
            XCTAssertEqual(slider.doubleValue, Double(remembered[index]))
            XCTAssertEqual(picker.selection, profile.0)
            XCTAssertTrue(inspectorWindow.firstResponder === slider)
            XCTAssertEqual(canvas.selectedID, selected)
            view.redo()
            XCTAssertEqual(try shapeValues(), edited)
            XCTAssertEqual(slider.doubleValue, profile.2)
            XCTAssertTrue(inspectorWindow.firstResponder === slider)
            XCTAssertEqual(canvas.selectedID, selected)
            remembered = edited
        }
        for (index, profile) in profiles.enumerated() {
            try choose(profile.0)
            XCTAssertEqual(slider.doubleValue, Double(remembered[index]))
            XCTAssertEqual(try shapeValues(), remembered)
            XCTAssertTrue(controller.makeSeamOptions() === options)
        }
    }

    func testWaveAndBreakNativeColorWellsChangeLineColorWithUndoAndPreserveShapeSettings() throws {
        for transition in [StitchTransition.wave, .breakLine] {
            let (view, controller, canvas, window) = try stitchFixture()
            defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
            var original = try XCTUnwrap(view.stitchDocument)
            original.style.transition = transition
            original.style.color = NSColor.blue.withAlphaComponent(0.5)
            XCTAssertTrue(view.applyStitchDocument(original, registerUndo: false))
            canvas.selectedID = original.pieces.first?.id
            let selected = canvas.selectedID
            let color = try XCTUnwrap(controller.makeSeamOptions().subviews.compactMap { $0 as? NSColorWell }.first)
            XCTAssertFalse(color.isHidden)
            XCTAssertTrue(color.isEnabled)
            color.color = NSColor.orange.withAlphaComponent(0.8)
            let historyCount = view.undoStack.count
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(color.action), to: color.target, from: color))
            var expected = original
            expected.style.color = color.color
            XCTAssertTrue(try XCTUnwrap(view.stitchDocument).isIdentical(to: expected))
            XCTAssertEqual(view.undoStack.count, historyCount + 1)
            XCTAssertEqual(canvas.selectedID, selected)
            view.undo()
            XCTAssertTrue(try XCTUnwrap(view.stitchDocument).isIdentical(to: original))
            XCTAssertEqual(color.color, original.style.color)
            XCTAssertEqual(canvas.selectedID, selected)
            view.redo()
            XCTAssertTrue(try XCTUnwrap(view.stitchDocument).isIdentical(to: expected))
            XCTAssertEqual(color.color, expected.style.color)
        }
    }

    func testTornAndFoldNativeControlsChangeTheirOwnValuesWithUndoAndPercentStrength() throws {
        let (view, controller, canvas, window) = try stitchFixture()
        defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
        let options = controller.makeSeamOptions()
        let picker = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchSeamStylePicker }.first)
        let selected = view.stitchDocument?.pieces.first?.id
        canvas.selectedID = selected
        func choose(_ transition: StitchTransition) throws {
            try XCTUnwrap(picker.subviews.compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "stitch.transition.\(transition.rawValue)"
            }).performClick(nil)
        }
        let color = try XCTUnwrap(options.subviews.compactMap { $0 as? NSColorWell }.first)
        let controls: [(StitchTransition, String, WritableKeyPath<StitchStyle, CGFloat>, Double, Double, Double)] = [
            (.torn, "tearWidth", \.tearWidth, 2, 32, 18),
            (.torn, "shape", \.tearRoughness, 0, 14, 9),
            (.fold, "foldDepth", \.foldDepth, 0, 80, 25),
            (.fold, "foldStrength", \.foldStrength, 0, 2, 1.4),
        ]
        for (transition, name, keyPath, minimum, maximum, target) in controls {
            try choose(transition)
            XCTAssertTrue(color.isHidden)
            XCTAssertFalse(color.isEnabled)
            let slider = try XCTUnwrap(options.subviews.compactMap { $0 as? NSSlider }.first {
                $0.identifier?.rawValue == "stitch.seam.\(name)"
            })
            XCTAssertFalse(slider.isHidden)
            XCTAssertEqual(slider.minValue, minimum)
            XCTAssertEqual(slider.maxValue, maximum)
            let before = try XCTUnwrap(view.stitchDocument).style
            let historyCount = view.undoStack.count
            slider.doubleValue = target
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(slider.action), to: slider.target, from: slider))
            XCTAssertEqual(view.stitchDocument?.style[keyPath: keyPath], CGFloat(target))
            XCTAssertEqual(view.stitchDocument?.style.color, before.color)
            XCTAssertEqual(view.stitchDocument?.style.blur, before.blur)
            XCTAssertEqual(view.stitchDocument?.style.feather, before.feather)
            XCTAssertEqual(view.undoStack.count, historyCount + 1)
            XCTAssertEqual(canvas.selectedID, selected)
            if name == "foldStrength" {
                XCTAssertEqual((options.subviews.first {
                    $0.identifier?.rawValue == "stitch.seam.foldStrength.value"
                } as? NSTextField)?.stringValue, "70%")
            }
            view.undo()
            XCTAssertEqual(view.stitchDocument?.style[keyPath: keyPath], before[keyPath: keyPath])
            XCTAssertEqual(slider.doubleValue, Double(before[keyPath: keyPath]))
            view.redo()
            XCTAssertEqual(view.stitchDocument?.style[keyPath: keyPath], CGFloat(target))
        }
    }

    func testNativeFoldSlidersPreserveDefaultsAndRestoreMidpointAndUpperRange() throws {
        let (view, controller, canvas, window) = try stitchFixture()
        defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
        let options = controller.makeSeamOptions()
        let picker = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchSeamStylePicker }.first)
        try XCTUnwrap(picker.subviews.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "stitch.transition.fold"
        }).performClick(nil)
        let selected = try XCTUnwrap(view.stitchDocument?.pieces.first?.id)
        canvas.selectedID = selected
        func slider(_ name: String) throws -> NSSlider {
            try XCTUnwrap(options.subviews.compactMap { $0 as? NSSlider }.first {
                $0.identifier?.rawValue == "stitch.seam.\(name)"
            })
        }
        func label(_ name: String) throws -> NSTextField {
            try XCTUnwrap(options.subviews.first {
                $0.identifier?.rawValue == "stitch.seam.\(name).value"
            } as? NSTextField)
        }
        func restored(_ document: StitchDocument) throws -> StitchDocument {
            try XCTUnwrap(JSONDecoder().decode(SavedStitchDocument.self,
                from: JSONEncoder().encode(XCTUnwrap(SavedStitchDocument(document)))).restore())
        }
        let depth = try slider("foldDepth"), strength = try slider("foldStrength")
        XCTAssertEqual(view.stitchDocument?.style.foldDepth, 18)
        XCTAssertEqual(view.stitchDocument?.style.foldStrength, 1)
        XCTAssertEqual(depth.minValue, 0)
        XCTAssertEqual(depth.maxValue, 80)
        XCTAssertEqual(strength.minValue, 0)
        XCTAssertEqual(strength.maxValue, 2)
        XCTAssertEqual(depth.doubleValue, 18)
        XCTAssertEqual(strength.doubleValue, 1)
        XCTAssertEqual(try label("foldStrength").stringValue, "50%")

        let edits: [(String, WritableKeyPath<StitchStyle, CGFloat>, Double, String)] = [
            ("foldDepth", \.foldDepth, 0, "0.0 px"),
            ("foldDepth", \.foldDepth, 40, "40.0 px"),
            ("foldStrength", \.foldStrength, 0, "0%"),
            ("foldStrength", \.foldStrength, 1, "50%"),
            ("foldDepth", \.foldDepth, 80, "80.0 px"),
            ("foldStrength", \.foldStrength, 1.5, "75%"),
            ("foldStrength", \.foldStrength, 2, "100%"),
        ]
        for (name, keyPath, value, text) in edits {
            let control = try slider(name), valueLabel = try label(name)
            let before = try XCTUnwrap(view.stitchDocument).style[keyPath: keyPath]
            let beforeLabel = valueLabel.stringValue
            let historyCount = view.undoStack.count
            control.doubleValue = value
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control))
            XCTAssertEqual(view.stitchDocument?.style[keyPath: keyPath], CGFloat(value))
            XCTAssertEqual(valueLabel.stringValue, text)
            XCTAssertEqual(view.undoStack.count, historyCount + 1)
            XCTAssertEqual(canvas.selectedID, selected)
            view.undo()
            XCTAssertEqual(view.stitchDocument?.style[keyPath: keyPath], before)
            XCTAssertEqual(control.doubleValue, Double(before))
            XCTAssertEqual(valueLabel.stringValue, beforeLabel)
            view.redo()
            XCTAssertEqual(view.stitchDocument?.style[keyPath: keyPath], CGFloat(value))
            XCTAssertEqual(control.doubleValue, value)
            XCTAssertEqual(valueLabel.stringValue, text)
            if name == "foldStrength", value == 1 {
                let midpoint = try restored(XCTUnwrap(view.stitchDocument))
                XCTAssertEqual(midpoint.style.foldDepth, 40)
                XCTAssertEqual(midpoint.style.foldStrength, 1,
                    "Existing source values must survive save and restore without rescaling")
            }
        }
        let maximum = try restored(XCTUnwrap(view.stitchDocument))
        XCTAssertEqual(maximum.style.foldDepth, 80)
        XCTAssertEqual(maximum.style.foldStrength, 2)
        var reset = maximum
        reset.style.foldDepth = 18
        reset.style.foldStrength = 1
        XCTAssertTrue(view.applyStitchDocument(reset, registerUndo: false))
        XCTAssertEqual(try label("foldStrength").stringValue, "50%")
        XCTAssertTrue(view.applyStitchDocument(maximum, registerUndo: false))
        XCTAssertEqual(depth.doubleValue, 80)
        XCTAssertEqual(strength.doubleValue, 2)
        XCTAssertEqual(try label("foldDepth").stringValue, "80.0 px")
        XCTAssertEqual(try label("foldStrength").stringValue, "100%")
        XCTAssertEqual(canvas.selectedID, selected)
    }

    func testNativePopoverResizeRetainsTheInspectorControlsFocusAndPieceSelection() throws {
        let (view, controller, canvas, window) = try stitchFixture()
        defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
        let options = controller.makeSeamOptions()
        let wrapper = NSView(frame: options.frame)
        wrapper.addSubview(options)
        let contentController = NSViewController()
        contentController.view = wrapper
        let popover = NSPopover()
        popover.contentViewController = contentController
        popover.contentSize = options.frame.size
        let fixtureWindow = NSWindow(contentRect: wrapper.frame, styleMask: .borderless, backing: .buffered, defer: false)
        fixtureWindow.contentView = wrapper
        defer { fixtureWindow.orderOut(nil) }
        let picker = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchSeamStylePicker }.first)
        let selected = view.stitchDocument?.pieces.first?.id
        canvas.selectedID = selected
        for transition in [StitchTransition.blend, .torn, .fold, .breakLine, .wave] {
            let button = try XCTUnwrap(picker.subviews.compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "stitch.transition.\(transition.rawValue)"
            })
            XCTAssertTrue(fixtureWindow.makeFirstResponder(button))
            button.performClick(nil)
            PopoverHelper.resize(options, to: options.frame.size, in: popover)
            XCTAssertEqual(popover.contentSize, options.frame.size)
            XCTAssertEqual(wrapper.frame.size, options.frame.size)
            XCTAssertTrue(popover.contentViewController === contentController)
            XCTAssertTrue(options.superview === wrapper)
            XCTAssertTrue(fixtureWindow.firstResponder === button)
            XCTAssertEqual(canvas.selectedID, selected)
        }
        let size = popover.contentSize
        PopoverHelper.resize(NSView(), to: NSSize(width: 40, height: 40), in: popover)
        XCTAssertEqual(popover.contentSize, size, "An unrelated inspector must not resize the open popover")
    }

    func testSeamTransitionPickerHasDistinctRasterPreviewsAndReadableNativeLabelsInBothSystemAppearances() throws {
        try withDefaults(["toolbarBgColor": nil, "toolbarIconColor": nil, "toolbarAccentColor": nil]) {
            let (view, controller, _, window) = try stitchFixture()
            defer { controller.suspend(); window.orderOut(nil) }
            let options = controller.makeSeamOptions()
            let picker = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchSeamStylePicker }.first)
            let buttons = picker.subviews.compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.map(\.title), ["Wave", "Blend", "Torn", "Fold", "Accordion", "Break"].map { L($0) })
            XCTAssertGreaterThanOrEqual(options.bounds.width, 350)
            XCTAssertLessThanOrEqual(options.bounds.width, 380)
            picker.layoutSubtreeIfNeeded()
            var previews = Set<Data>()
            for button in buttons {
                XCTAssertNotNil(button.target)
                XCTAssertNotNil(button.action)
                XCTAssertEqual(button.accessibilityLabel(), button.title)
                XCTAssertEqual(button.focusRingType, .exterior)
                let image = try XCTUnwrap(button.image)
                XCTAssertFalse(image.isTemplate)
                let pixels = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                previews.insert(try XCTUnwrap(pixels.dataProvider?.data) as Data)
                let titleWidth = (button.title as NSString).size(withAttributes: [
                    .font: try XCTUnwrap(button.font)
                ]).width
                XCTAssertLessThan(titleWidth, button.bounds.width - 8)
                XCTAssertTrue(picker.bounds.contains(button.frame))
            }
            XCTAssertEqual(previews.count, StitchTransition.allCases.count, "Each treatment needs a preview that shows its rendered result")
            let nativePopover = NSView(frame: options.frame)
            nativePopover.addSubview(options)
            for systemAppearance in [NSAppearance.Name.aqua, .darkAqua] {
                nativePopover.appearance = NSAppearance(named: systemAppearance)
                XCTAssertEqual(options.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), systemAppearance)
                for button in buttons {
                    XCTAssertEqual(button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), systemAppearance)
                    XCTAssertEqual(button.contentTintColor, options.screenshotForegroundColor)
                    XCTAssertEqual(button.contentTintColor?.alphaComponent, 1)
                }
            }
            try exportSeamInspectorPreviewsIfRequested(view: view, options: options)
        }
    }

    private func exportSeamInspectorPreviewsIfRequested(view: EditorView, options: NSView) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MACSHOT_SEAM_INSPECTOR_PREVIEW_DIR"]
            ?? environment["TEST_RUNNER_MACSHOT_SEAM_INSPECTOR_PREVIEW_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: options.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = options
        defer { window.orderOut(nil) }
        for transition in StitchTransition.allCases {
            var document = try XCTUnwrap(view.stitchDocument)
            document.style.transition = transition
            XCTAssertTrue(view.applyStitchDocument(document, registerUndo: false))
            window.setContentSize(options.frame.size)
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "aqua"), (.darkAqua, "dark-aqua")] {
                window.appearance = NSAppearance(named: appearance)
                options.layoutSubtreeIfNeeded()
                options.displayIfNeeded()
                let bitmap = try XCTUnwrap(options.bitmapImageRepForCachingDisplay(in: options.bounds))
                options.cacheDisplay(in: options.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("inspector-\(transition.rawValue)-\(suffix).png"))
            }
        }
    }

    func testSeamColorButtonOffersLineColorOrAutomaticAppearanceByTreatmentAndOnlyAffectsStitch() throws {
        try withDefaults(["lastUsedColor": nil, "lastUsedColorOpacity": 0.42, "customColors": nil,
            "rememberLastTool": false]) {
            let view = StitchColorRoutingEditorView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
            view.screenshotImage = ImageProbe.quadrantImage(width: 100, height: 80)
            view.applySelection(view.bounds)
            let pixels = try XCTUnwrap(view.screenshotImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            var document = StitchDocument(pieces: [StitchPiece(image: pixels)])
            document.style.color = NSColor.blue.withAlphaComponent(0.6)
            view.installStitchDocument(document)
            view.currentColor = .orange
            view.currentTool = .stitch
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            defer { view.onStitchOptions = nil; window.orderOut(nil) }
            var seamRequests = 0
            view.onStitchOptions = { action, anchor in
                if case .seams = action { seamRequests += 1 }
                else { XCTFail("The color button must offer seam appearance") }
                XCTAssertEqual(anchor.identifier?.rawValue, "stitch.seams")
            }
            let treatments: [(StitchTransition, String, Bool)] = [
                (.wave, "Seam color", true), (.blend, "Seam appearance", false),
                (.torn, "Seam appearance", false), (.fold, "Seam appearance", false),
                (.breakLine, "Seam color", true),
            ]
            for (transition, tooltip, editsColor) in treatments {
                document.style.transition = transition
                view.installStitchDocument(document)
                view.rebuildToolbarLayout()
                let button = try XCTUnwrap(view.bottomButtons.first { $0.action == .color })
                XCTAssertEqual(button.tooltip, L(tooltip))
                let color = document.style.color
                XCTAssertEqual(button.bgColor, editsColor ? color : color.withAlphaComponent(color.alphaComponent * 0.3))
                let requestsBefore = seamRequests
                let colorsBefore = view.requestedColorTargets.count
                view.handleToolbarAction(.color)
                XCTAssertEqual(seamRequests, requestsBefore + (editsColor ? 0 : 1))
                XCTAssertEqual(view.requestedColorTargets.count, colorsBefore + (editsColor ? 1 : 0))
                if editsColor { XCTAssertEqual(view.requestedColorTargets.last, .stitchSeam) }
                view.previewStitchSeamColor(NSColor.purple.withAlphaComponent(0.5))
                XCTAssertEqual(view.stitchSeamColorPreview == nil, !editsColor)
                view.updateToolbarColorSwatch()
                let refreshed = try XCTUnwrap(view.bottomButtons.first { $0.action == .color }?.bgColor)
                XCTAssertEqual(refreshed, editsColor ? view.toolbarColor
                    : view.toolbarColor.withAlphaComponent(view.toolbarColor.alphaComponent * 0.3))
                let strip = try XCTUnwrap(view.subviews.compactMap { $0 as? ToolbarStripView }.first {
                    $0.buttonViews.contains { $0.action == .color }
                })
                XCTAssertEqual(strip.buttonViews.first { $0.action == .color }?.swatchColor, refreshed)
                view.previewStitchSeamColor(nil)
            }

            document.style.visible = false
            view.installStitchDocument(document)
            view.rebuildToolbarLayout()
            let hiddenButton = try XCTUnwrap(view.bottomButtons.first { $0.action == .color })
            XCTAssertEqual(hiddenButton.tooltip, L("Show seams to edit color"))
            XCTAssertEqual(hiddenButton.bgColor, document.style.color)
            let requestsBefore = seamRequests
            view.handleToolbarAction(.color)
            XCTAssertEqual(seamRequests, requestsBefore + 1)

            for transition in StitchTransition.allCases {
                document.style.visible = true
                document.style.transition = transition
                view.installStitchDocument(document)
                view.currentTool = .arrow
                view.rebuildToolbarLayout()
                let drawingButton = try XCTUnwrap(view.bottomButtons.first { $0.action == .color })
                XCTAssertEqual(drawingButton.tooltip, L("Color"))
                XCTAssertEqual(drawingButton.bgColor, view.currentColor)
                view.updateToolbarColorSwatch()
                XCTAssertEqual(view.bottomButtons.first { $0.action == .color }?.bgColor, view.currentColor)
                let requestsBefore = seamRequests
                view.handleToolbarAction(.color)
                XCTAssertEqual(seamRequests, requestsBefore)
                XCTAssertEqual(view.requestedColorTargets.last, .drawColor)
            }
        }
    }

    func testRejectedSeamTransitionRestoresPickerSelectionWithoutAddingHistory() throws {
        let (view, controller, _, window) = try stitchFixture()
        defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
        let picker = try XCTUnwrap(controller.makeSeamOptions().subviews.compactMap { $0 as? StitchSeamStylePicker }.first)
        controller.onDocumentChanged = { _, _ in false }
        let torn = try XCTUnwrap(picker.subviews.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "stitch.transition.torn"
        })
        torn.performClick(nil)
        XCTAssertEqual(picker.selection, .wave)
        XCTAssertEqual(view.stitchDocument?.style.transition, .wave)
        XCTAssertEqual(torn.state, .off)
        XCTAssertTrue(view.undoStack.isEmpty)
    }

    func testHiddenSeamsDisableOnlyTheirApplicableInspectorControlsAndOfferVisibilityChoice() throws {
        let (view, controller, canvas, window) = try stitchFixture()
        defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
        canvas.selectedID = view.stitchDocument?.pieces.first?.id
        let options = controller.makeSeamOptions()
        let toggle = try XCTUnwrap(options.subviews.compactMap { $0 as? NSButton }.first)
        let color = try XCTUnwrap(options.subviews.compactMap { $0 as? NSColorWell }.first)
        let picker = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchSeamStylePicker }.first)
        let choices = picker.subviews.compactMap { $0 as? NSButton }
        for transition in StitchTransition.allCases {
            try XCTUnwrap(choices.first {
                $0.identifier?.rawValue == "stitch.transition.\(transition.rawValue)"
            }).performClick(nil)
            let sliders = options.subviews.compactMap { $0 as? NSSlider }.filter { !$0.isHidden }
            let labels = options.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
            let size = options.bounds.size
            toggle.state = .off
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
            XCTAssertFalse(try XCTUnwrap(view.stitchDocument).style.visible)
            XCTAssertFalse(picker.isEnabled)
            XCTAssertLessThan(picker.alphaValue, 1)
            XCTAssertTrue(choices.allSatisfy { !$0.isEnabled })
            if !color.isHidden { XCTAssertFalse(color.isEnabled) }
            let historyCount = view.undoStack.count
            let other = transition == .blend ? StitchTransition.fold : .blend
            try XCTUnwrap(choices.first {
                $0.identifier?.rawValue == "stitch.transition.\(other.rawValue)"
            }).performClick(nil)
            XCTAssertEqual(view.stitchDocument?.style.transition, transition)
            XCTAssertEqual(picker.selection, transition)
            XCTAssertEqual(view.undoStack.count, historyCount)
            XCTAssertTrue(sliders.allSatisfy { !$0.isEnabled && $0.alphaValue < 1 })
            XCTAssertTrue(labels.allSatisfy { $0.alphaValue < 1 })
            XCTAssertTrue(toggle.isEnabled)
            XCTAssertEqual(options.bounds.size, size)
            XCTAssertEqual(view.bottomButtons.first { $0.action == .color }?.tooltip,
                L(transition.hasEditableColor ? "Show seams to edit color" : "Show seams to edit appearance"))
            var offeredVisibilityChoice = false
            view.onStitchOptions = { action, anchor in
                offeredVisibilityChoice = action == .seams && anchor.identifier?.rawValue == "stitch.seams"
            }
            PopoverHelper.dismiss()
            view.handleToolbarAction(.color)
            XCTAssertTrue(offeredVisibilityChoice)
            view.undo()
            XCTAssertTrue(try XCTUnwrap(view.stitchDocument).style.visible)
            XCTAssertTrue(picker.isEnabled)
            XCTAssertTrue(choices.allSatisfy(\.isEnabled))
            XCTAssertEqual(picker.selection, transition)
            XCTAssertTrue(sliders.allSatisfy { $0.isEnabled && $0.alphaValue == 1 })
            if !color.isHidden { XCTAssertTrue(color.isEnabled) }
            XCTAssertEqual(options.bounds.size, size)
            XCTAssertEqual(canvas.selectedID, view.stitchDocument?.pieces.first?.id)
        }
    }

    func testWaveAndBreakColorDragsPreviewWithoutPublishingAndCommitOnceWithOpacityAndUndo() throws {
        try withDefaults(["customColors": nil, "rememberLastTool": false, "lastUsedColor": nil,
            "lastUsedColorOpacity": 0.42]) {
            for transition in [StitchTransition.wave, .breakLine] {
                let (view, controller, canvas, window) = try stitchFixture()
                defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
                var initial = try XCTUnwrap(view.stitchDocument)
                initial.style.transition = transition
                initial.style.color = NSColor.blue.withAlphaComponent(0.8)
                XCTAssertTrue(view.applyStitchDocument(initial, registerUndo: false))
                view.currentColor = .orange
                let drawingOpacity = view.makeColorPicker(target: .drawColor).opacity
                canvas.selectedID = initial.pieces.first?.id
                let selected = canvas.selectedID
                let original = initial.style.color
                let rawImage = view.screenshotImage
                var published = 0
                view.onStitchDocumentChanged = { [weak controller, weak view] in
                    published += 1
                    if let document = view?.stitchDocument { controller?.restore(document) }
                }
                let picker = view.makeColorPicker(target: .stitchSeam)
                XCTAssertEqual(picker.selectedColor, original)
                XCTAssertEqual(picker.opacity, original.alphaComponent, accuracy: 0.001)
                picker.beginEditingGesture()
                for index in 1...20 {
                    picker.onColorChanged?(NSColor(calibratedRed: CGFloat(index) / 20, green: 0.3, blue: 0.2, alpha: 1))
                }
                picker.onOpacityChanged?(0.4)
                XCTAssertEqual(published, 0, "Drag events must not invoke full image rendering/publishing")
                XCTAssertTrue(view.screenshotImage === rawImage)
                XCTAssertEqual(view.stitchDocument?.style.color, initial.style.color)
                XCTAssertTrue(view.undoStack.isEmpty)
                let finalColor = try XCTUnwrap(view.stitchSeamColorPreview)
                XCTAssertEqual(finalColor.alphaComponent, 0.4, accuracy: 0.001)
                XCTAssertEqual(view.toolbarColor, finalColor)
                picker.mouseUp(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
                    modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)))
                XCTAssertEqual(published, 1)
                XCTAssertEqual(view.undoStack.count, 1)
                XCTAssertEqual(view.stitchDocument?.style.color, finalColor)
                XCTAssertNil(view.stitchSeamColorPreview)
                XCTAssertEqual(view.currentColor, .orange)
                XCTAssertEqual(view.makeColorPicker(target: .drawColor).opacity, drawingOpacity)
                XCTAssertEqual(UserDefaults.standard.double(forKey: "lastUsedColorOpacity"), 0.42)
                XCTAssertEqual(canvas.selectedID, selected)
                view.undo()
                XCTAssertEqual(view.stitchDocument?.style.color, initial.style.color)
                XCTAssertEqual(try XCTUnwrap(view.stitchDocument?.style.color.alphaComponent), original.alphaComponent, accuracy: 0.001)
                XCTAssertEqual(canvas.selectedID, selected)
                view.redo()
                XCTAssertEqual(view.stitchDocument?.style.color, finalColor)
            }
        }
    }

    func testNativeColorEditsIgnoreHiddenSeamsAndTreatmentsWithoutEditableColor() throws {
        try withDefaults(["customColors": nil, "rememberLastTool": false]) {
            for (transition, visible) in [(StitchTransition.wave, false), (.breakLine, false),
                (.torn, false), (.torn, true), (.blend, true), (.fold, true)] {
                let (view, controller, _, window) = try stitchFixture()
                defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
                // Keep a picker created for Wave alive while its seam profile becomes inapplicable.
                let picker = view.makeColorPicker(target: .stitchSeam)
                var document = try XCTUnwrap(view.stitchDocument)
                document.style.transition = transition
                document.style.visible = visible
                XCTAssertTrue(view.applyStitchDocument(document, registerUndo: false))
                view.previewStitchSeamColor(.orange)
                XCTAssertNil(view.stitchSeamColorPreview)
                let options = controller.makeSeamOptions()
                let color = try XCTUnwrap(options.subviews.compactMap { $0 as? NSColorWell }.first)
                view.onStitchSeamColorPreview?(.orange)
                XCTAssertEqual(color.color, document.style.color, "A stale preview callback must not update the inspector")
                picker.beginEditingGesture()
                picker.onColorChanged?(.purple)
                picker.onOpacityChanged?(0.2)
                picker.mouseUp(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
                    modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)))
                XCTAssertTrue(try XCTUnwrap(view.stitchDocument).isIdentical(to: document))
                XCTAssertTrue(view.undoStack.isEmpty)
                XCTAssertNil(view.stitchSeamColorPreview)
                color.color = .green
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(color.action), to: color.target, from: color))
                let hiddenBlur = try XCTUnwrap(options.subviews.compactMap { $0 as? NSSlider }.first {
                    $0.identifier?.rawValue == "stitch.seam.blur"
                })
                if !visible || hiddenBlur.isHidden {
                    hiddenBlur.doubleValue = 30
                    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(hiddenBlur.action), to: hiddenBlur.target, from: hiddenBlur))
                }
                XCTAssertTrue(try XCTUnwrap(view.stitchDocument).isIdentical(to: document))
                XCTAssertTrue(view.undoStack.isEmpty)
            }
        }
    }

    func testInProgressLineColorPreviewClearsWhenSeamsBecomeAutomaticOrHidden() throws {
        try withDefaults(["customColors": nil, "rememberLastTool": false]) {
            for (transition, visible) in [(StitchTransition.torn, true), (.fold, true), (.blend, true),
                (.wave, false), (.breakLine, false)] {
                let (view, controller, canvas, window) = try stitchFixture()
                defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
                var original = try XCTUnwrap(view.stitchDocument)
                if !visible { original.style.transition = transition }
                XCTAssertTrue(view.applyStitchDocument(original, registerUndo: false))
                canvas.selectedID = original.pieces.first?.id
                let selected = canvas.selectedID
                let options = controller.makeSeamOptions()
                let picker = view.makeColorPicker(target: .stitchSeam)
                picker.beginEditingGesture()
                picker.onColorChanged?(.purple)
                picker.onOpacityChanged?(0)
                XCTAssertEqual(try XCTUnwrap(view.stitchSeamColorPreview).alphaComponent, 0, accuracy: 0.001)
                XCTAssertEqual(view.stitchDocument?.style.color, original.style.color)
                var document = original
                document.style.transition = transition
                document.style.visible = visible
                if visible {
                    let stylePicker = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchSeamStylePicker }.first)
                    try XCTUnwrap(stylePicker.subviews.compactMap { $0 as? NSButton }.first {
                        $0.identifier?.rawValue == "stitch.transition.\(transition.rawValue)"
                    }).performClick(nil)
                } else {
                    let toggle = try XCTUnwrap(options.subviews.compactMap { $0 as? NSButton }.first {
                        $0.identifier?.rawValue == "stitch.seam.visibility"
                    })
                    toggle.state = .off
                    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
                }
                XCTAssertNil(view.stitchSeamColorPreview)
                XCTAssertTrue(try XCTUnwrap(view.stitchDocument).isIdentical(to: document))
                XCTAssertEqual(view.undoStack.count, 1, "Changing the treatment or visibility must not commit the preview color")
                XCTAssertEqual(view.toolbarColor, original.style.color)
                let imageAfterTransition = view.screenshotImage
                picker.onColorChanged?(.green)
                picker.onOpacityChanged?(0.2)
                picker.mouseUp(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
                    modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)))
                XCTAssertTrue(try XCTUnwrap(view.stitchDocument).isIdentical(to: document))
                XCTAssertTrue(view.screenshotImage === imageAfterTransition)
                XCTAssertEqual(view.undoStack.count, 1)
                XCTAssertNil(view.stitchSeamColorPreview)
                XCTAssertEqual(canvas.selectedID, selected)
                view.undo()
                XCTAssertTrue(try XCTUnwrap(view.stitchDocument).isIdentical(to: original))
                view.redo()
                XCTAssertTrue(try XCTUnwrap(view.stitchDocument).isIdentical(to: document))
                document.style.transition = .breakLine
                document.style.visible = true
                XCTAssertTrue(view.applyStitchDocument(document, registerUndo: false))
                XCTAssertEqual(view.stitchDocument?.style.color, original.style.color)
                XCTAssertNil(view.stitchSeamColorPreview)
            }
        }
    }

    func testNativePickerSwatchClickHasOneCompleteGesture() throws {
        let picker = ColorPickerView()
        var callbacks: [String] = []
        picker.onGestureBegan = { callbacks.append("begin") }
        picker.onColorChanged = { _ in callbacks.append("color") }
        picker.onGestureEnded = { callbacks.append("end") }
        picker.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: CGPoint(x: 10, y: picker.bounds.maxY - 10), modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        XCTAssertEqual(callbacks, ["begin", "color", "end"])
        XCTAssertFalse(picker.isEditingGesture)
    }

    func testStitchShortcutCanBeReboundWithoutChangingOtherActions() {
        let old = ToolShortcutManager.key(for: .stitch)
        defer { ToolShortcutManager.setKey(old, for: .stitch) }
        XCTAssertEqual(ToolShortcutManager.Action.stitch.defaultKey, "s")
        XCTAssertEqual(ToolShortcutManager.Action.rectangle.defaultKey, "r")
        ToolShortcutManager.setKey("v", for: .stitch)
        XCTAssertEqual(ToolShortcutManager.lookupAction(for: "v"), .tool(.stitch))
        XCTAssertEqual(ToolShortcutManager.tooltipShortcut(for: .tool(.stitch)), "v")
    }
}

@MainActor
private final class StitchColorRoutingEditorView: EditorView {
    var requestedColorTargets: [ColorPickerTarget] = []
    override func showColorPickerPopover(target: ColorPickerTarget, anchorView: NSView? = nil, anchorRect: NSRect = .zero) {
        requestedColorTargets.append(target)
    }
}

@MainActor
private final class StitchHandoffDelegate: OverlayViewDelegate {
    var detachRequests = 0
    var onDetach: (() -> Void)?
    func overlayViewDidRequestDetach() { detachRequests += 1; onDetach?() }
    func overlayViewDidFinishSelection(_ rect: NSRect) {}
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidCancel() {}
    func overlayViewDidConfirm() {}
    func overlayViewDidRequestSave() {}
    func overlayViewDidRequestSaveAs() {}
    func overlayViewDidRequestPin() {}
    func overlayViewDidRequestOCR() {}
    func overlayViewDidRequestQuickSave() {}
    func overlayViewDidRequestFileSave() {}
    func overlayViewDidRequestUpload() {}
    func overlayViewDidRequestShare(anchorView: NSView?) {}
    func overlayViewDidRequestRemoveBackground() {}
    func overlayViewDidRequestEnterRecordingMode() {}
    func overlayViewDidRequestStartRecording(rect: NSRect) {}
    func overlayViewDidRequestStopRecording() {}
    func overlayViewDidRequestScrollCapture(rect: NSRect) {}
    func overlayViewDidRequestStopScrollCapture() {}
    func overlayViewDidRequestCancelScrollCapture() {}
    func overlayViewDidRequestToggleAutoScroll() {}
    func overlayViewDidRequestAccessibilityPermission() {}
    func overlayViewDidRequestInputMonitoringPermission() {}
    func overlayViewDidBeginSelection() {}
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidChangeSnapMode() {}
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {}
    func overlayViewDidRequestAddCapture() {}
}
