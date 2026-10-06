import Cocoa
import XCTest

@MainActor
final class ScrollCaptureInputTests: XCTestCase {
    func testSwitchingToAToolWithoutOptionsKeepsKeyboardCommands() throws {
        for detached in [false, true] {
            try withSpotlightWindow(detached: detached) { view, row, window, delegate in
                let slider = try XCTUnwrap(row.subviews.compactMap { $0 as? NSSlider }.first)
                XCTAssertTrue(window.makeFirstResponder(slider))
                window.sendEvent(try keyEvent("i", code: 34, in: window))
                XCTAssertEqual(view.currentTool, .colorSampler)
                XCTAssertTrue(row.isHidden)
                XCTAssertTrue(window.firstResponder === view)
                window.sendEvent(try keyEvent("\u{1B}", code: 53, in: window))
                XCTAssertEqual(delegate.dismissRequests, 1)
            }
        }
    }

    func testHidingToolbarsReturnsFocusFromOptions() throws {
        for detached in [false, true] {
            try withSpotlightWindow(detached: detached) { view, row, window, delegate in
                let slider = try XCTUnwrap(row.subviews.compactMap { $0 as? NSSlider }.first)
                XCTAssertTrue(window.makeFirstResponder(slider))
                view.showToolbars = false
                XCTAssertTrue(row.isHidden)
                XCTAssertTrue(window.firstResponder === view)
                window.sendEvent(try keyEvent("\u{1B}", code: 53, in: window))
                XCTAssertEqual(delegate.dismissRequests, 1)
            }
        }
    }

    func testRemovingResolutionFieldsReturnsFocusToCanvas() throws {
        try withSpotlightWindow(detached: false) { view, _, window, delegate in
            let box = try XCTUnwrap(view.subviews.compactMap { $0 as? ResolutionBoxView }.first)
            let field = try XCTUnwrap(box.subviews.compactMap { $0 as? NSTextField }.first)
            field.selectText(nil)
            XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true)
            view.showToolbars = false
            XCTAssertNil(box.superview)
            XCTAssertTrue(window.firstResponder === view)
            window.sendEvent(try keyEvent("\u{1B}", code: 53, in: window))
            XCTAssertEqual(delegate.dismissRequests, 1)
        }
    }

    func testClearingSelectionDiscardsUnfinishedResolutionEdit() throws {
        try withSpotlightWindow(detached: false) { view, _, window, delegate in
            let box = try XCTUnwrap(view.subviews.compactMap { $0 as? ResolutionBoxView }.first)
            let field = try XCTUnwrap(box.subviews.compactMap { $0 as? NSTextField }.first)
            field.selectText(nil)
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            editor.string = "640"
            view.clearSelection()
            XCTAssertNil(box.superview)
            XCTAssertEqual(view.selectionRect, .zero)
            XCTAssertEqual(view.state, .idle)
            XCTAssertTrue(window.firstResponder === view)
            window.sendEvent(try keyEvent("\u{1B}", code: 53, in: window))
            XCTAssertEqual(delegate.dismissRequests, 1)
        }
    }

    func testResolutionCommitImmediatelyRestoresCanvasKeyboardCommands() throws {
        for (characters, code): (String, UInt16) in [("\r", 36), ("\u{1B}", 53)] {
            try withSpotlightWindow(detached: false) { view, _, window, delegate in
                let box = try XCTUnwrap(view.subviews.compactMap { $0 as? ResolutionBoxView }.first)
                let field = try XCTUnwrap(box.subviews.compactMap { $0 as? NSTextField }.first)
                field.selectText(nil)
                window.sendEvent(try keyEvent(characters, code: code, in: window))
                XCTAssertTrue(window.firstResponder === view)
                XCTAssertEqual(delegate.dismissRequests, 0)
                XCTAssertEqual(delegate.quickSaveRequests, 0)
                window.sendEvent(try keyEvent("a", code: 0, in: window))
                XCTAssertEqual(view.currentTool, .arrow)
                window.sendEvent(try keyEvent("\u{1B}", code: 53, in: window))
                XCTAssertEqual(delegate.dismissRequests, 1)
            }
        }
    }

    func testEditorTopBarControlsForwardCanvasKeys() throws {
        try withSpotlightWindow(detached: true) { view, _, window, delegate in
            let topBar = EditorTopBarView(frame: NSRect(x: 0, y: 568, width: 800, height: 32))
            topBar.overlayView = view
            try XCTUnwrap(window.contentView).addSubview(topBar)
            for button in topBar.subviews.compactMap({ $0 as? NSButton }) {
                view.currentTool = .highlight
                XCTAssertTrue(window.makeFirstResponder(button))
                window.sendEvent(try keyEvent("a", code: 0, in: window))
                XCTAssertEqual(view.currentTool, .arrow)
                let previousRequests = delegate.dismissRequests
                window.sendEvent(try keyEvent("\u{1B}", code: 53, in: window))
                XCTAssertEqual(delegate.dismissRequests, previousRequests + 1)
            }
        }
    }

    func testRemovingFocusedDoneButtonReturnsFocusToCanvas() throws {
        try withSpotlightWindow(detached: true) { view, _, window, delegate in
            let topBar = EditorTopBarView(frame: NSRect(x: 0, y: 568, width: 800, height: 32))
            topBar.overlayView = view
            try XCTUnwrap(window.contentView).addSubview(topBar)
            topBar.showDoneButton()
            let button = try XCTUnwrap(topBar.subviews.compactMap { $0 as? NSButton }.first { $0.title == L("Done") })
            XCTAssertTrue(window.makeFirstResponder(button))
            topBar.hideDoneButton()
            XCTAssertNil(button.superview)
            XCTAssertTrue(window.firstResponder === view)
            window.sendEvent(try keyEvent("\u{1B}", code: 53, in: window))
            XCTAssertEqual(delegate.dismissRequests, 1)
        }
    }

    func testEveryToolOptionsRowRecoversFocusAfterAppearanceRebuild() throws {
        for detached in [false, true] {
            try withSpotlightWindow(detached: detached) { view, row, window, delegate in
                for tool in AnnotationTool.allCases {
                    view.currentTool = tool
                    guard view.toolHasOptionsRow else { continue }
                    row.rebuild(for: tool)
                    let controlTypes = Set(row.subviews.compactMap { child -> String? in
                        guard let control = child as? NSControl, control.isEnabled,
                              control.acceptsFirstResponder else { return nil }
                        return String(describing: type(of: control))
                    })
                    XCTAssertFalse(controlTypes.isEmpty, "Missing focusable controls for \(tool)")
                    for controlType in controlTypes {
                        row.rebuild(for: tool)
                        let control = try XCTUnwrap(row.subviews.compactMap { $0 as? NSControl }.first {
                            $0.isEnabled && $0.acceptsFirstResponder
                                && String(describing: type(of: $0)) == controlType
                        })
                        XCTAssertTrue(window.makeFirstResponder(control))
                        NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
                        XCTAssertTrue(window.firstResponder === view, "\(tool), \(controlType)")
                        let previousRequests = delegate.dismissRequests
                        window.sendEvent(try keyEvent("\u{1B}", code: 53, in: window))
                        XCTAssertEqual(delegate.dismissRequests, previousRequests + 1, "\(tool), \(controlType)")
                    }
                }
                view.showBeautifyInOptionsRow = true
                view.currentTool = .select
                row.rebuild(for: .select)
                let slider = try XCTUnwrap(row.subviews.compactMap { $0 as? NSSlider }.first)
                XCTAssertTrue(window.makeFirstResponder(slider))
                NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
                XCTAssertTrue(window.firstResponder === view)
            }
        }
    }

    func testSpotlightCommitRestoresKeyboardAfterReplacingFocusedControls() throws {
        for detached in [false, true] {
            for useBorderControl in [false, true] {
                try withSpotlightWindow(detached: detached) { view, row, window, delegate in
                    let control: NSControl = try useBorderControl
                        ? XCTUnwrap(row.subviews.compactMap { $0 as? NSSegmentedControl }.first)
                        : XCTUnwrap(row.subviews.compactMap { $0 as? NSSlider }.first)
                    XCTAssertTrue(window.makeFirstResponder(control))
                    let handler = HighlightToolHandler()
                    view.activeAnnotation = handler.start(at: NSPoint(x: 150, y: 150), canvas: view)
                    handler.update(to: NSPoint(x: 220, y: 220), shiftHeld: false, canvas: view)
                    handler.finish(canvas: view)

                    XCTAssertNil(control.superview)
                    XCTAssertTrue(window.firstResponder === view,
                                  "Replacing Spotlight controls must return focus to the canvas")
                    window.sendEvent(try keyEvent("a", code: 0, in: window))
                    XCTAssertEqual(view.currentTool, .arrow)
                    XCTAssertTrue(window.performKeyEquivalent(with:
                        try keyEvent("c", code: 8, modifiers: .command, in: window)))
                    XCTAssertEqual(delegate.confirmRequests, 1)
                    window.sendEvent(try keyEvent("\u{1B}", code: 53, in: window))
                    XCTAssertEqual(delegate.dismissRequests, 1)
                }
            }
        }
    }

    func testSpotlightDimActionKeepsItsControlAndFocus() throws {
        let original = UserDefaults.standard.object(forKey: HighlightToolHandler.dimOpacityKey)
        defer { UserDefaults.standard.set(original, forKey: HighlightToolHandler.dimOpacityKey) }
        try withSpotlightWindow(detached: false) { _, row, window, _ in
            let slider = try XCTUnwrap(row.subviews.compactMap { $0 as? NSSlider }.first)
            XCTAssertTrue(window.makeFirstResponder(slider))
            slider.doubleValue = 0.7
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(slider.action), to: slider.target, from: slider))
            XCTAssertTrue(slider.superview === row)
            XCTAssertTrue(window.firstResponder === slider)
            XCTAssertEqual(UserDefaults.standard.double(forKey: HighlightToolHandler.dimOpacityKey), 0.7)
        }
    }

    func testOptionsRebuildReturnsFocusFromItsOwnFieldEditor() throws {
        try withSpotlightWindow(detached: true) { view, row, window, _ in
            let field = NSTextField(string: "320")
            row.addSubview(field)
            field.selectText(nil)
            XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true)
            row.rebuild(for: .highlight)
            XCTAssertTrue(window.firstResponder === view)
        }
    }

    func testSpotlightControlsForwardEscapeWhileStillFocused() throws {
        for detached in [false, true] {
            for useBorderControl in [false, true] {
                try withSpotlightWindow(detached: detached) { view, row, window, delegate in
                    let control: NSControl = try useBorderControl
                        ? XCTUnwrap(row.subviews.compactMap { $0 as? NSSegmentedControl }.first)
                        : XCTUnwrap(row.subviews.compactMap { $0 as? NSSlider }.first)
                    XCTAssertTrue(window.makeFirstResponder(control))
                    window.sendEvent(try keyEvent("\u{1B}", code: 53, in: window))
                    XCTAssertEqual(delegate.dismissRequests, 1)
                    window.sendEvent(try keyEvent("a", code: 0, in: window))
                    XCTAssertEqual(view.currentTool, .arrow)
                }
            }
        }
    }

    func testOptionsRebuildPreservesFocusOutsideItsControls() throws {
        try withSpotlightWindow(detached: true) { _, row, window, _ in
            let field = NSTextField(string: "Another inspector")
            try XCTUnwrap(window.contentView).addSubview(field)
            field.selectText(nil)
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
            XCTAssertTrue(editor.isFieldEditor)
            row.rebuild(for: .highlight)
            XCTAssertTrue(window.firstResponder === editor)
        }
    }

    private func withSpotlightWindow(detached: Bool,
        body: (OverlayView, ToolOptionsRowView, OverlayWindow, ScrollCaptureInputDelegate) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let view: OverlayView = detached ? EditorView(frame: frame) : ImageEditingView(frame: frame)
        let root = NSView(frame: frame)
        if detached { view.chromeParentView = root }
        root.addSubview(view)
        let window = OverlayWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        let delegate = ScrollCaptureInputDelegate()
        view.overlayDelegate = delegate
        defer { view.reset(); window.close() }
        view.currentTool = .highlight
        view.applySelection(NSRect(x: 100, y: 100, width: 300, height: 200))
        view.showToolbars = true
        let parent = detached ? root : view
        let row = try XCTUnwrap(parent.subviews.compactMap { $0 as? ToolOptionsRowView }.first)
        try body(view, row, window, delegate)
    }

    private func keyEvent(_ characters: String, code: UInt16,
        modifiers: NSEvent.ModifierFlags = [], in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    func testWindowCommandsStillWorkAfterFocusingAnInspectorSlider() throws {
        _ = NSApplication.shared
        let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = ScrollCaptureInputDelegate()
        view.overlayDelegate = delegate
        view.applySelection(NSRect(x: 100, y: 100, width: 300, height: 200))
        let window = OverlayWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.reset(); window.close() }
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        view.addSubview(slider)
        XCTAssertTrue(window.makeFirstResponder(slider))
        let copy = TestKeyEvent.keyDown(characters: "c", keyCode: 8, modifiers: .command)
        XCTAssertTrue(window.performKeyEquivalent(with: copy))
        XCTAssertEqual(delegate.confirmRequests, 1)
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)))
        XCTAssertEqual(delegate.dismissRequests, 1)
    }

    func testCopyInAnInspectorTextFieldDoesNotConfirmTheScreenshot() {
        _ = NSApplication.shared
        let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = ScrollCaptureInputDelegate()
        view.overlayDelegate = delegate
        view.applySelection(NSRect(x: 100, y: 100, width: 300, height: 200))
        let window = OverlayWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { view.reset(); window.close() }
        let field = NSTextField(string: "320")
        view.addSubview(field)
        field.selectText(nil)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.isFieldEditor == true)
        _ = window.performKeyEquivalent(with: TestKeyEvent.keyDown(characters: "c", keyCode: 8, modifiers: .command))
        XCTAssertEqual(delegate.confirmRequests, 0)
    }

    func testEnterStopsScrollCaptureWithoutCopyingOrDismissingAfterCleanupClearsMode() {
        for code: UInt16 in [36, 76] {
            let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            let delegate = ScrollCaptureInputDelegate()
            view.overlayDelegate = delegate
            view.applySelection(NSRect(x: 100, y: 100, width: 300, height: 200))
            view.isScrollCapturing = true
            // The real stop callback tears down the HUD and clears this flag.
            // Key routing must still consume Enter after that synchronous cleanup.
            delegate.onStop = { [weak view] in view?.isScrollCapturing = false }

            view.keyDown(with: TestKeyEvent.keyDown(characters: "\r", keyCode: code))

            XCTAssertEqual(delegate.stopRequests, 1)
            XCTAssertEqual(delegate.quickSaveRequests, 0)
            XCTAssertEqual(delegate.dismissRequests, 0)
            XCTAssertEqual(delegate.confirmRequests, 0)
            XCTAssertEqual(delegate.cancelScrollRequests, 0)
            XCTAssertFalse(view.isScrollCapturing)
        }
    }

    func testScrollKeyMonitorConsumesEnterAndEscapeWithoutScreenshotRequests() {
        let view = OverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = ScrollCaptureInputDelegate()
        view.overlayDelegate = delegate
        view.isScrollCapturing = true
        for code: UInt16 in [36, 76, 53] {
            XCTAssertTrue(view.handleScrollCaptureKey(TestKeyEvent.keyDown(characters: "", keyCode: code)))
        }
        XCTAssertEqual(delegate.stopRequests, 2)
        XCTAssertEqual(delegate.cancelScrollRequests, 1)
        XCTAssertEqual(delegate.quickSaveRequests, 0)
        XCTAssertEqual(delegate.dismissRequests, 0)
        XCTAssertFalse(view.handleScrollCaptureKey(TestKeyEvent.keyDown(characters: "", keyCode: 124)))
    }

    func testOrdinaryCaptureAndEditorEnterStillRequestQuickSave() {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let views: [OverlayView] = [OverlayView(frame: frame), EditorView(frame: frame)]
        for view in views {
            let delegate = ScrollCaptureInputDelegate()
            view.overlayDelegate = delegate
            view.applySelection(NSRect(x: 100, y: 100, width: 300, height: 200))
            for code: UInt16 in [36, 76] {
                let event = TestKeyEvent.keyDown(characters: "\r", keyCode: code)
                XCTAssertFalse(view.handleScrollCaptureKey(event))
                view.keyDown(with: event)
            }
            XCTAssertEqual(delegate.quickSaveRequests, 2)
            XCTAssertEqual(delegate.stopRequests, 0)
            XCTAssertEqual(delegate.cancelScrollRequests, 0)
            XCTAssertEqual(delegate.dismissRequests, 0)
        }
    }
}

@MainActor
private final class ScrollCaptureInputDelegate: OverlayViewDelegate {
    var stopRequests = 0
    var cancelScrollRequests = 0
    var quickSaveRequests = 0
    var dismissRequests = 0
    var confirmRequests = 0
    var onStop: (() -> Void)?

    func overlayViewDidRequestStopScrollCapture() { stopRequests += 1; onStop?() }
    func overlayViewDidRequestCancelScrollCapture() { cancelScrollRequests += 1 }
    func overlayViewDidRequestQuickSave() { quickSaveRequests += 1 }
    func overlayViewDidCancel() { dismissRequests += 1 }
    func overlayViewDidConfirm() { confirmRequests += 1 }
    func overlayViewDidFinishSelection(_ rect: NSRect) {}
    func overlayViewSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidRequestSave() {}
    func overlayViewDidRequestSaveAs() {}
    func overlayViewDidRequestPin() {}
    func overlayViewDidRequestOCR() {}
    func overlayViewDidRequestFileSave() {}
    func overlayViewDidRequestUpload() {}
    func overlayViewDidRequestShare(anchorView: NSView?) {}
    func overlayViewDidRequestRemoveBackground() {}
    func overlayViewDidRequestEnterRecordingMode() {}
    func overlayViewDidRequestStartRecording(rect: NSRect) {}
    func overlayViewDidRequestStopRecording() {}
    func overlayViewDidRequestDetach() {}
    func overlayViewDidRequestScrollCapture(rect: NSRect) {}
    func overlayViewDidRequestToggleAutoScroll() {}
    func overlayViewDidRequestAccessibilityPermission() {}
    func overlayViewDidRequestInputMonitoringPermission() {}
    func overlayViewDidBeginSelection() {}
    func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {}
    func overlayViewDidChangeSnapMode() {}
    func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {}
    func overlayViewDidRequestAddCapture() {}
}
