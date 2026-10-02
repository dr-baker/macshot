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

    func testStitchDoesNotOverwriteRememberedDrawingToolOrEnterCaptureWithoutHandoff() {
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

    func testSelectedCaptureHandsRawImageAndAnnotationsToExistingEditorRouteInStitch() throws {
        try withDefaults(["rememberLastTool": true]) {
            let view = OverlayView(frame: CGRect(x: 0, y: 0, width: 160, height: 120))
            let screenshot = ImageProbe.quadrantImage(width: 160, height: 120)
            view.screenshotImage = screenshot
            view.applySelection(CGRect(x: 20, y: 10, width: 100, height: 80))
            view.currentTool = .rectangle
            let annotation = Annotation(tool: .arrow, startPoint: CGPoint(x: 30, y: 20),
                endPoint: CGPoint(x: 80, y: 60), color: .red, strokeWidth: 3)
            view.annotations = [annotation]
            view.undoStack = [.added(annotation)]
            view.effectsBrightness = 0.15
            let delegate = StitchHandoffDelegate()
            view.overlayDelegate = delegate
            var handoff: OverlayEditorState?
            delegate.onDetach = { handoff = view.snapshotEditorState() }
            view.handleToolbarAction(.tool(.stitch))
            let snapshot = try XCTUnwrap(handoff)
            XCTAssertEqual(delegate.detachRequests, 1)
            XCTAssertEqual(snapshot.currentTool, .stitch)
            XCTAssertTrue(snapshot.screenshotImage === screenshot)
            XCTAssertEqual(snapshot.selectionRect, CGRect(x: 20, y: 10, width: 100, height: 80))
            XCTAssertTrue(snapshot.annotations[0] === annotation)
            XCTAssertEqual(snapshot.undoStack.count, 1)
            XCTAssertEqual(snapshot.effectsBrightness, 0.15)
            XCTAssertEqual(UserDefaults.standard.integer(forKey: "lastUsedTool"), AnnotationTool.rectangle.rawValue)
            view.currentTool = .arrow
        }
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
        XCTAssertEqual(modes.segmentCount, 2)
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
        XCTAssertEqual(options.count, 3)
        if case .seams = options[0] {} else { XCTFail("Wrong seam action") }
        if case .pieces = options[1] {} else { XCTFail("Wrong piece action") }
        if case .canvas = options[2] {} else { XCTFail("Wrong canvas action") }
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

    func testHiddenSeamsDisableInspectorControlsAndNativeColorOffersVisibilityChoice() throws {
        let (view, controller, canvas, window) = try stitchFixture()
        defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
        canvas.selectedID = view.stitchDocument?.pieces.first?.id
        let options = controller.makeSeamOptions()
        let toggle = try XCTUnwrap(options.subviews.compactMap { $0 as? NSButton }.first)
        let color = try XCTUnwrap(options.subviews.compactMap { $0 as? NSColorWell }.first)
        let sliders = options.subviews.compactMap { $0 as? NSSlider }
        XCTAssertEqual(sliders.count, 4)
        toggle.state = .off
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
        XCTAssertFalse(try XCTUnwrap(view.stitchDocument).style.visible)
        XCTAssertFalse(color.isEnabled)
        XCTAssertTrue(sliders.allSatisfy { !$0.isEnabled && $0.alphaValue < 1 })
        XCTAssertTrue(options.subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.alphaValue < 1 })
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(view.bottomButtons.first { $0.action == .color }?.tooltip, L("Show seams to edit color"))
        var offeredVisibilityChoice = false
        view.onStitchOptions = { action, anchor in
            offeredVisibilityChoice = action == .seams && anchor.identifier?.rawValue == "stitch.seams"
        }
        PopoverHelper.dismiss()
        view.handleToolbarAction(.color)
        XCTAssertTrue(offeredVisibilityChoice)
        view.undo()
        XCTAssertTrue(try XCTUnwrap(view.stitchDocument).style.visible)
        XCTAssertTrue(color.isEnabled)
        XCTAssertTrue(sliders.allSatisfy { $0.isEnabled && $0.alphaValue == 1 })
        XCTAssertEqual(view.bottomButtons.first { $0.action == .color }?.tooltip, L("Seam color"))
        XCTAssertEqual(canvas.selectedID, view.stitchDocument?.pieces.first?.id)
    }

    func testNativeColorDragPreviewsWithoutPublishingAndCommitsExactlyOnceOnRelease() throws {
        try withDefaults(["customColors": nil, "rememberLastTool": false]) {
            let (view, controller, canvas, window) = try stitchFixture()
            defer { controller.suspend(); view.onStitchDocumentChanged = nil; window.orderOut(nil) }
            canvas.selectedID = view.stitchDocument?.pieces.first?.id
            let selected = canvas.selectedID
            let original = try XCTUnwrap(view.stitchDocument?.style.color)
            let rawImage = view.screenshotImage
            var published = 0
            view.onStitchDocumentChanged = { [weak controller, weak view] in
                published += 1
                if let document = view?.stitchDocument { controller?.restore(document) }
            }
            let picker = view.makeColorPicker(target: .stitchSeam)
            picker.beginEditingGesture()
            for index in 1...20 {
                picker.onColorChanged?(NSColor(calibratedRed: CGFloat(index) / 20, green: 0.3, blue: 0.2, alpha: 1))
            }
            picker.onOpacityChanged?(0.4)
            XCTAssertEqual(published, 0, "Drag events must not invoke full image rendering/publishing")
            XCTAssertTrue(view.screenshotImage === rawImage)
            XCTAssertEqual(view.stitchDocument?.style.color, original)
            XCTAssertTrue(view.undoStack.isEmpty)
            XCTAssertEqual(view.toolbarColor, try XCTUnwrap(view.stitchSeamColorPreview))
            let finalColor = try XCTUnwrap(view.stitchSeamColorPreview)
            picker.mouseUp(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)))
            XCTAssertEqual(published, 1)
            XCTAssertEqual(view.undoStack.count, 1)
            XCTAssertEqual(view.stitchDocument?.style.color, finalColor)
            XCTAssertNil(view.stitchSeamColorPreview)
            XCTAssertEqual(canvas.selectedID, selected)
            view.undo()
            XCTAssertEqual(view.stitchDocument?.style.color, original)
            XCTAssertEqual(canvas.selectedID, selected)
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

    func testConfigurableNativeShortcutMapsToStitchWithoutChangingExistingDefaults() {
        let old = ToolShortcutManager.key(for: .stitch)
        defer { ToolShortcutManager.setKey(old, for: .stitch) }
        XCTAssertEqual(ToolShortcutManager.Action.stitch.defaultKey, "")
        XCTAssertEqual(ToolShortcutManager.Action.rectangle.defaultKey, "r")
        ToolShortcutManager.setKey("v", for: .stitch)
        XCTAssertEqual(ToolShortcutManager.lookupAction(for: "v"), .tool(.stitch))
        XCTAssertEqual(ToolShortcutManager.tooltipShortcut(for: .tool(.stitch)), "v")
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
