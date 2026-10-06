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

    func testEveryToolOptionsRowRetainsControlsAndFocusAfterAppearanceUpdate() throws {
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
                        XCTAssertTrue(control.superview === row, "\(tool), \(controlType)")
                        XCTAssertTrue(window.firstResponder === control, "\(tool), \(controlType)")
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
                XCTAssertTrue(window.firstResponder === slider)
                XCTAssertTrue(slider.superview === row)
            }
        }
    }

    func testSpotlightCommitRetainsControlsAndKeyboardCommands() throws {
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

                    XCTAssertTrue(control.superview === row)
                    XCTAssertTrue(window.firstResponder === control,
                                  "Committing Spotlight must retain the focused control")
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

    func testToolChangeUnmountsOnlyObsoleteControlsAndRestoresTheirFocus() throws {
        try withSpotlightWindow(detached: true) { view, row, window, _ in
            let slider = try XCTUnwrap(row.subviews.compactMap { $0 as? NSSlider }.first)
            XCTAssertTrue(window.makeFirstResponder(slider))
            view.currentTool = .arrow
            view.rebuildToolbarLayout()
            XCTAssertNil(slider.superview)
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

    func testWindowKeyReleaseEndsKeyboardSelectionMoveAfterFocusChanges() throws {
        try withSpotlightWindow(detached: false) { view, _, window, _ in
            func descendants(_ parent: NSView) -> [NSView] {
                parent.subviews.flatMap { [$0] + descendants($0) }
            }
            let move = try XCTUnwrap(descendants(view).compactMap { $0 as? ToolbarButtonView }.first { $0.action == .moveSelection })
            XCTAssertTrue(view.startKeyboardMoveSelection())
            XCTAssertTrue(move.isPressed)
            XCTAssertTrue(window.makeFirstResponder(nil))
            let shortcut = ToolShortcutManager.key(for: .moveSelection)
            let release = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: shortcut, charactersIgnoringModifiers: shortcut, isARepeat: false, keyCode: 49))
            window.sendEvent(release)
            XCTAssertFalse(move.isPressed, "Releasing the move shortcut must end the held interaction")
        }
    }

    func testRetainedMarkerControlsUpdateValuesAndRestoreEnabledState() throws {
        try withSpotlightWindow(detached: true) { view, row, window, _ in
            view.smartMarkerEnabled = false
            view.currentTool = .marker
            row.rebuild(for: .marker)
            let slider = try XCTUnwrap(row.subviews.first { $0.identifier?.rawValue == "options.strokeSlider" } as? NSSlider)
            let title = try XCTUnwrap(row.subviews.first { $0.identifier?.rawValue == "options.strokeTitle" })
            XCTAssertTrue(window.makeFirstResponder(slider))
            view.currentMarkerSize = 12
            row.rebuild(for: .marker)
            XCTAssertEqual(slider.doubleValue, 12)
            XCTAssertTrue(window.firstResponder === slider)
            view.smartMarkerEnabled = true
            row.rebuild(for: .marker)
            XCTAssertFalse(slider.isEnabled)
            XCTAssertEqual(title.alphaValue, 0.35)
            view.smartMarkerEnabled = false
            row.rebuild(for: .marker)
            XCTAssertTrue(slider.isEnabled)
            XCTAssertEqual(title.alphaValue, 1)
            XCTAssertEqual(slider.alphaValue, 1)
            XCTAssertTrue(slider.superview === row)
        }
    }

    func testUntrackedSiblingControlsAndWindowFallbackUseSceneCommands() throws {
        for detached in [false, true] {
            try withSpotlightWindow(detached: detached) { view, _, window, delegate in
                let sibling = NSView(frame: .zero)
                let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
                sibling.addSubview(slider)
                try XCTUnwrap(window.contentView).addSubview(sibling)
                XCTAssertTrue(window.makeFirstResponder(slider))
                window.sendEvent(try keyEvent("a", code: 0, in: window))
                XCTAssertEqual(view.currentTool, .arrow)
                // Exercise AppKit's window fallback without a panel-specific repair.
                XCTAssertTrue(window.makeFirstResponder(slider))
                sibling.removeFromSuperview()
                XCTAssertTrue(window.makeFirstResponder(nil))
                window.sendEvent(try keyEvent("i", code: 34, in: window))
                XCTAssertEqual(view.currentTool, .colorSampler)
                XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent("c", code: 8, modifiers: .command, in: window)))
                XCTAssertEqual(delegate.confirmRequests, 1)
                window.sendEvent(try keyEvent("\u{1B}", code: 53, in: window))
                XCTAssertEqual(delegate.dismissRequests, 1)
            }
        }
    }

    func testNativeSiblingTextEditingKeepsTypingAndCopy() throws {
        try withSpotlightWindow(detached: true) { view, _, window, delegate in
            let field = NSTextField(string: "")
            try XCTUnwrap(window.contentView).addSubview(field)
            field.selectText(nil)
            let text = try XCTUnwrap(window.firstResponder as? NSTextView)
            window.sendEvent(try keyEvent("a", code: 0, in: window))
            XCTAssertEqual(text.string, "a")
            XCTAssertEqual(view.currentTool, .highlight)
            _ = window.performKeyEquivalent(with: try keyEvent("c", code: 8, modifiers: .command, in: window))
            XCTAssertEqual(delegate.confirmRequests, 0)
            XCTAssertTrue(window.firstResponder === text)
        }
    }

    func testUnhandledKeyReachesOriginalResponderOnce() throws {
        try withSpotlightWindow(detached: true) { view, _, window, _ in
            let commands = try XCTUnwrap(ScreenshotCommandResponder.forWindow(window))
            let original = commands.nextResponder
            let downstream = ScreenshotUnhandledKeyProbe()
            commands.nextResponder = downstream
            defer { commands.nextResponder = original }
            let predecessor = try XCTUnwrap(window.contentView)
            let interposer = NSResponder()
            interposer.nextResponder = commands
            predecessor.nextResponder = interposer
            defer { predecessor.nextResponder = commands }
            XCTAssertTrue(ScreenshotCommandResponder.install(in: window, editor: view) === commands)
            XCTAssertTrue(predecessor.nextResponder === interposer)
            XCTAssertTrue(commands.nextResponder === downstream)
            XCTAssertTrue(window.makeFirstResponder(nil))
            XCTAssertTrue(window.makeFirstResponder(view))
            window.sendEvent(try keyEvent("§", code: 255, in: window))
            XCTAssertEqual(downstream.events, 1)
        }
    }

    func testControllerBackedWindowPreservesOwnersAndReleasesCommandsOnClose() throws {
        try withSpotlightWindow(detached: true) { view, _, window, delegate in
            let root = try XCTUnwrap(window.contentView)
            let controller = NSViewController()
            controller.view = root
            window.contentViewController = controller
            let commands = try XCTUnwrap(ScreenshotCommandResponder.forWindow(window))
            XCTAssertTrue(root.nextResponder === controller)
            XCTAssertTrue(controller.nextResponder === commands)
            XCTAssertTrue(commands.nextResponder === window)
            let sibling = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
            root.addSubview(sibling)
            XCTAssertTrue(window.makeFirstResponder(sibling))
            window.sendEvent(try keyEvent("a", code: 0, in: window))
            XCTAssertEqual(view.currentTool, .arrow)
            window.sendEvent(try keyEvent("\u{1B}", code: 53, in: window))
            XCTAssertEqual(delegate.dismissRequests, 1)
            window.close()
            XCTAssertNil(commands.editor)
            XCTAssertFalse(controller.nextResponder === commands)
            XCTAssertFalse(commands.dispatchKeyEvent(try keyEvent("\u{1B}", code: 53, in: window)))
            XCTAssertEqual(delegate.dismissRequests, 1)
        }
    }

    func testMovingEditorUnbindsOldWindowAndPreservesItsResponderChain() throws {
        try withSpotlightWindow(detached: true) { view, _, oldWindow, delegate in
            let oldCommands = try XCTUnwrap(ScreenshotCommandResponder.forWindow(oldWindow))
            let next = oldCommands.nextResponder
            let newWindow = OverlayWindow(contentRect: oldWindow.frame, styleMask: .borderless, backing: .buffered, defer: false)
            newWindow.isReleasedWhenClosed = false
            newWindow.contentView = NSView(frame: view.frame)
            defer { newWindow.close() }
            view.removeFromSuperview()
            try XCTUnwrap(newWindow.contentView).addSubview(view)
            XCTAssertNil(oldCommands.editor)
            XCTAssertTrue(oldCommands.nextResponder === next)
            XCTAssertFalse(oldCommands.dispatchKeyEvent(try keyEvent("\u{1B}", code: 53, in: oldWindow)))
            XCTAssertEqual(delegate.dismissRequests, 0)
            XCTAssertTrue(newWindow.makeFirstResponder(nil))
            newWindow.sendEvent(try keyEvent("\u{1B}", code: 53, in: newWindow))
            XCTAssertEqual(delegate.dismissRequests, 1)
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

@MainActor
private final class ScreenshotUnhandledKeyProbe: NSResponder {
    var events = 0
    override func keyDown(with event: NSEvent) { events += 1 }
}
