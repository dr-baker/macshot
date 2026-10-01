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
        XCTAssertEqual(modes.segmentCount, 3)
        var modeChanges: [StitchCanvasView.Mode] = []
        view.onStitchModeChanged = { modeChanges.append($0) }
        modes.selectedSegment = 1
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(modes.action), to: modes.target, from: modes))
        XCTAssertEqual(view.stitchMode, .columns)
        XCTAssertEqual(modeChanges, [.columns])
        modes.selectedSegment = 2
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(modes.action), to: modes.target, from: modes))
        XCTAssertEqual(view.stitchMode, .move)

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
        view.stitchMode = .columns
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
