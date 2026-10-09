import AppKit
import XCTest

@MainActor
final class ScreenshotPanelViewTests: XCTestCase {
    func testNativePiecesMenuKeepsKeyboardOwnershipWhenItsSelectedButtonIsRebuilt() throws {
        let (editor, controller, canvas, parent) = try stitchMenuFixture()
        let options = controller.makePieceOptions()
        let wrapper = ArrowCursorView(frame: options.frame)
        wrapper.parentWindow = parent
        wrapper.addSubview(options)
        let menuWindow = NSWindow(contentRect: wrapper.frame, styleMask: .borderless, backing: .buffered, defer: false)
        menuWindow.isReleasedWhenClosed = false
        menuWindow.contentView = wrapper
        wrapper.beginCommandScope()
        defer { controller.suspend(); editor.reset(); menuWindow.close(); parent.close() }
        let scroll = try XCTUnwrap(options.subviews.compactMap { $0 as? NSScrollView }.first)
        let stack = try XCTUnwrap(scroll.documentView as? NSStackView)
        let button = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSButton }.first)
        XCTAssertTrue(menuWindow.makeFirstResponder(button))
        button.performClick(nil)
        XCTAssertNil(button.superview, "Selecting a piece rebuilds the menu's source buttons")
        XCTAssertNotNil(canvas.selectedID)
        XCTAssertTrue(menuWindow.firstResponder === wrapper, "The stable native menu must own focus before removing the source button")
        var dismissals = 0
        wrapper.onCancel = { dismissals += 1 }
        menuWindow.sendEvent(try escape(in: menuWindow))
        XCTAssertEqual(dismissals, 1)

        let delete = try XCTUnwrap(options.subviews.compactMap { $0 as? NSButton }.first {
            $0.toolTip == L("Delete piece")
        })
        XCTAssertTrue(menuWindow.makeFirstResponder(delete))
        delete.performClick(nil)
        XCTAssertFalse(delete.isEnabled)
        XCTAssertTrue(menuWindow.firstResponder === wrapper, "An action disabled by deleting its piece must release menu focus")
        menuWindow.sendEvent(try escape(in: menuWindow))
        XCTAssertEqual(dismissals, 2)

        let otherField = NSTextField(string: "Keep this edit")
        wrapper.addSubview(otherField)
        otherField.selectText(nil)
        let fieldEditor = try XCTUnwrap(menuWindow.firstResponder as? NSTextView)
        XCTAssertTrue(fieldEditor.isFieldEditor)
        controller.restore(try XCTUnwrap(editor.stitchDocument))
        XCTAssertTrue(menuWindow.firstResponder === fieldEditor, "Refreshing pieces must preserve editing outside their list")
    }

    func testNativeSeamModeChangesKeepEscapeWorkingWhenTheFocusedSliderDisappears() throws {
        let (editor, controller, _, parent) = try stitchMenuFixture()
        let options = controller.makeSeamOptions()
        let wrapper = ArrowCursorView(frame: options.frame)
        wrapper.parentWindow = parent
        wrapper.addSubview(options)
        let menuWindow = NSWindow(contentRect: wrapper.frame, styleMask: .borderless, backing: .buffered, defer: false)
        menuWindow.isReleasedWhenClosed = false
        menuWindow.contentView = wrapper
        wrapper.beginCommandScope()
        defer { controller.suspend(); editor.reset(); menuWindow.close(); parent.close() }
        let blur = try XCTUnwrap(options.subviews.first { $0.identifier?.rawValue == "stitch.seam.blur" } as? NSSlider)
        let picker = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchSeamStylePicker }.first)
        func select(_ transition: StitchTransition) throws {
            let choice = try XCTUnwrap(picker.subviews.compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "stitch.transition.\(transition.rawValue)"
            })
            choice.performClick(nil)
        }
        var dismissals = 0
        wrapper.onCancel = { dismissals += 1 }
        for transition in [StitchTransition.torn, .fold] {
            try select(.wave)
            XCTAssertFalse(blur.isHidden)
            XCTAssertTrue(menuWindow.makeFirstResponder(blur))
            try select(transition)
            XCTAssertTrue(blur.isHidden)
            XCTAssertTrue(menuWindow.firstResponder === wrapper, "A hidden seam slider must release focus to its menu")
            menuWindow.sendEvent(try escape(in: menuWindow))
        }
        XCTAssertEqual(dismissals, 2)

        try select(.wave)
        XCTAssertTrue(menuWindow.makeFirstResponder(blur))
        try select(.blend)
        XCTAssertTrue(menuWindow.firstResponder === blur, "Changing styles must keep a slider that remains available")
        let otherField = NSTextField(string: "Keep this edit")
        wrapper.addSubview(otherField)
        otherField.selectText(nil)
        let fieldEditor = try XCTUnwrap(menuWindow.firstResponder as? NSTextView)
        try select(.torn)
        XCTAssertTrue(menuWindow.firstResponder === fieldEditor, "Hiding seam controls must preserve another field's editing")

        try select(.wave)
        XCTAssertTrue(menuWindow.makeFirstResponder(blur))
        let visibility = try XCTUnwrap(options.subviews.first { $0.identifier?.rawValue == "stitch.seam.visibility" } as? NSButton)
        visibility.performClick(nil)
        XCTAssertFalse(blur.isEnabled)
        XCTAssertTrue(menuWindow.firstResponder === wrapper, "Turning seams off must release focus from their disabled slider")
        menuWindow.sendEvent(try escape(in: menuWindow))
        XCTAssertEqual(dismissals, 3)
    }

    func testAttachedPiecesTrayReturnsEscapeToTheCaptureAfterSelectingAPiece() throws {
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            ScreenshotPanelStyle(material: .clear).save()
            let (editor, controller, canvas, window) = try stitchMenuFixture()
            defer { controller.suspend(); editor.reset(); window.close() }
            let anchor = NSButton(frame: NSRect(x: 320, y: 40, width: 32, height: 32))
            editor.addSubview(anchor)
            XCTAssertTrue(window.makeFirstResponder(canvas))
            controller.showOptions(.pieces, at: anchor)
            let wrapper = try XCTUnwrap(editor.subviews.first { $0.identifier?.rawValue == "screenshot.toolbar-tray" })
            let viewport = try XCTUnwrap(wrapper.subviews.compactMap { $0 as? NSScrollView }.first)
            let options = try XCTUnwrap(viewport.documentView as? StitchOptionsView)
            let scroll = try XCTUnwrap(options.subviews.compactMap { $0 as? NSScrollView }.first)
            let stack = try XCTUnwrap(scroll.documentView as? NSStackView)
            let button = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSButton }.first)
            XCTAssertTrue(window.makeFirstResponder(button))
            button.performClick(nil)
            XCTAssertTrue(window.firstResponder === wrapper)
            XCTAssertTrue(PopoverHelper.isVisible)
            window.sendEvent(try escape(in: window))
            XCTAssertFalse(PopoverHelper.isVisible, "Escape after rebuilding the pieces list must close its tray")
            XCTAssertTrue(window.firstResponder === canvas)
        }
    }

    func testAnglePadReleasesFocusWhenHiddenOrDisabledAndEscapeStillClosesItsMenu() throws {
        let (editor, controller, _, parent) = try stitchMenuFixture()
        let options = controller.makeSeamOptions()
        let wrapper = ArrowCursorView(frame: options.frame)
        wrapper.parentWindow = parent
        wrapper.addSubview(options)
        let menu = NSWindow(contentRect: wrapper.frame, styleMask: .borderless, backing: .buffered, defer: false)
        menu.isReleasedWhenClosed = false
        menu.contentView = wrapper
        wrapper.beginCommandScope()
        defer { controller.suspend(); editor.reset(); menu.close(); parent.close() }
        let angle = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchPaperAngleControl }.first)
        let picker = try XCTUnwrap(options.subviews.compactMap { $0 as? StitchSeamStylePicker }.first)
        let toggle = try XCTUnwrap(options.subviews.first { $0.identifier?.rawValue == "stitch.seam.visibility" } as? NSButton)
        func select(_ transition: StitchTransition) throws {
            try XCTUnwrap(picker.subviews.compactMap { $0 as? NSButton }.first {
                $0.identifier?.rawValue == "stitch.transition.\(transition.rawValue)"
            }).performClick(nil)
        }
        var cancellations = 0
        wrapper.onCancel = { cancellations += 1 }
        try select(.accordion)
        XCTAssertTrue(menu.makeFirstResponder(angle))
        try select(.torn)
        XCTAssertTrue(angle.isHidden)
        XCTAssertTrue(menu.firstResponder === wrapper)
        menu.sendEvent(try escape(in: menu))
        try select(.accordion)
        XCTAssertTrue(menu.makeFirstResponder(angle))
        toggle.performClick(nil)
        XCTAssertFalse(angle.isEnabled)
        XCTAssertTrue(angle.subviews.compactMap { $0 as? NSButton }.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(menu.firstResponder === wrapper)
        menu.sendEvent(try escape(in: menu))
        XCTAssertEqual(cancellations, 2)
    }

    private func escape(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53))
    }

    private func stitchMenuFixture() throws -> (ImageEditingView, StitchEditorController, StitchCanvasView, OverlayWindow) {
        _ = NSApplication.shared
        let pixels = try XCTUnwrap(ImageProbe.quadrantImage(width: 80, height: 60)
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        let document = StitchDocument(pieces: [StitchPiece(image: pixels),
            StitchPiece(image: pixels, origin: CGPoint(x: 80, y: 0))])
        let editor = ImageEditingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        editor.screenshotImage = NSImage(cgImage: try XCTUnwrap(StitchRenderer.render(document)), size: document.bounds.size)
        editor.applySelection(editor.bounds)
        editor.installStitchDocument(document)
        editor.currentTool = .stitch
        editor.stitchMode = .move
        let window = OverlayWindow(contentRect: editor.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        let controller = StitchEditorController(document: document, window: window)
        controller.onDocumentChanged = { value, registerUndo in editor.applyStitchDocument(value, registerUndo: registerUndo) }
        controller.attach(to: editor)
        let canvas = try XCTUnwrap(editor.subviews.compactMap { $0 as? StitchCanvasView }.first)
        return (editor, controller, canvas, window)
    }

    func testNativePopoverWindowCommandsReachCaptureAndPreserveFieldEditing() throws {
        _ = NSApplication.shared
        let parent = ScreenshotFocusProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: .borderless, backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let capture = ScreenshotCommandProbeView(frame: root.bounds)
        root.addSubview(capture)
        parent.contentView = root
        let wrapper = ArrowCursorView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        wrapper.parentWindow = parent
        let popoverWindow = NSWindow(contentRect: wrapper.frame, styleMask: .borderless,
            backing: .buffered, defer: false)
        popoverWindow.isReleasedWhenClosed = false
        popoverWindow.contentView = wrapper
        wrapper.beginCommandScope()
        defer { popoverWindow.close(); parent.close() }
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        wrapper.addSubview(slider)
        XCTAssertTrue(popoverWindow.makeFirstResponder(slider))
        let copy = TestKeyEvent.keyDown(characters: "c", keyCode: 8, modifiers: .command)
        XCTAssertTrue(popoverWindow.performKeyEquivalent(with: copy))
        XCTAssertEqual(capture.copyRequests, 1)

        let field = NSTextField(string: "320")
        wrapper.addSubview(field)
        field.selectText(nil)
        let editor = try XCTUnwrap(popoverWindow.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        _ = popoverWindow.performKeyEquivalent(with: copy)
        XCTAssertEqual(capture.copyRequests, 1, "Copy in the submenu field must not copy the screenshot")
        XCTAssertTrue(popoverWindow.firstResponder === editor)
        // AppKit may retain a closed popover's window and content view.
        wrapper.endCommandScope()
        XCTAssertTrue(popoverWindow.makeFirstResponder(nil))
        XCTAssertFalse(popoverWindow.performKeyEquivalent(with: copy))
        XCTAssertEqual(capture.copyRequests, 1)
        XCTAssertFalse(ScreenshotCommandResponder.forWindow(parent)?.hasTransientScope ?? true)
    }

    func testNativeMenuEscapeDispatchClosesFromItsControlsAndDefaultResponder() throws {
        _ = NSApplication.shared
        let wrapper = ArrowCursorView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let window = NSWindow(contentRect: wrapper.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = wrapper
        wrapper.beginCommandScope()
        defer { window.close() }
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        let button = NSButton(title: "Wave", target: nil, action: nil)
        wrapper.addSubview(slider)
        wrapper.addSubview(button)
        var dismissals = 0
        wrapper.onCancel = { dismissals += 1 }
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        for responder in [wrapper, slider, button] {
            XCTAssertTrue(window.makeFirstResponder(responder))
            window.sendEvent(escape)
        }
        XCTAssertEqual(dismissals, 3, "Escape must survive native control focus and close the menu")
    }

    func testNativePopoverCloseRestoresCaptureFocusAndPreservesAnotherActiveField() throws {
        _ = NSApplication.shared
        let parent = ScreenshotFocusProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: .borderless, backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let capture = ScreenshotCommandProbeView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        parent.contentView = capture
        let menu = ScreenshotFocusProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: .borderless, backing: .buffered, defer: false)
        menu.isReleasedWhenClosed = false
        menu.keyForTest = true
        defer { menu.close(); parent.close() }
        XCTAssertTrue(parent.makeFirstResponder(capture))
        let focus = ScreenshotPopoverFocus(parentWindow: parent)
        focus.popoverWindow = menu
        XCTAssertTrue(parent.makeFirstResponder(nil))
        focus.prepareToClose()
        focus.restore(currentKeyWindow: menu)
        XCTAssertEqual(parent.makeKeyRequests, 1)
        XCTAssertTrue(parent.firstResponder === capture)

        let field = NSTextField(string: "640")
        capture.addSubview(field)
        let nextFocus = ScreenshotPopoverFocus(parentWindow: parent)
        nextFocus.popoverWindow = menu
        field.selectText(nil)
        let editor = try XCTUnwrap(parent.firstResponder as? NSTextView)
        XCTAssertTrue(editor.isFieldEditor)
        nextFocus.prepareToClose()
        nextFocus.restore(currentKeyWindow: parent)
        XCTAssertTrue(parent.firstResponder === editor, "Closing a menu must retain an already focused screenshot field")
    }

    func testNativePopoverCloseDoesNotReclaimFocusFromAnotherWindowOrApp() {
        _ = NSApplication.shared
        let parent = ScreenshotFocusProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: .borderless, backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let menu = ScreenshotFocusProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: .borderless, backing: .buffered, defer: false)
        menu.isReleasedWhenClosed = false
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close(); menu.close(); parent.close() }
        menu.keyForTest = true
        let focus = ScreenshotPopoverFocus(parentWindow: parent)
        focus.popoverWindow = menu
        focus.prepareToClose()
        focus.restore(currentKeyWindow: other)
        XCTAssertEqual(parent.makeKeyRequests, 0)

        let appFocus = ScreenshotPopoverFocus(parentWindow: parent)
        appFocus.popoverWindow = menu
        appFocus.prepareToClose()
        let anotherProcess = (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) + 1
        appFocus.restore(currentKeyWindow: nil, frontmostProcessID: anotherProcess)
        XCTAssertEqual(parent.makeKeyRequests, 0)

        let outsideClickFocus = ScreenshotPopoverFocus(parentWindow: parent)
        outsideClickFocus.popoverWindow = menu
        outsideClickFocus.prepareToClose(restoreFocus: false)
        outsideClickFocus.restore(currentKeyWindow: menu)
        XCTAssertEqual(parent.makeKeyRequests, 0)
    }

    func testClassicPreviewUsesTheActualToolbarColorsInBothAppearances() throws {
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            var style = ScreenshotPanelStyle(material: .classic)
            style.setTint(nil)
            style.save()
            let panel = ScreenshotPanelView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
            let background = try XCTUnwrap(panel.subviews.first)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                panel.panelAppearanceOverride = NSAppearance(named: appearance)
                let expected = try XCTUnwrap(ToolbarLayout.palette(for: NSAppearance(named: appearance)!).bg.usingColorSpace(.sRGB))
                XCTAssertTrue(panel.panelForegroundColor.isEqual(ScreenshotPanelContrast.foregroundColor(on: expected)))
                XCTAssertEqual(panel.appearance?.name, ScreenshotPanelContrast.resolve(style: style, baseColor: expected).appearanceName)
                let bitmap = try XCTUnwrap(background.bitmapImageRepForCachingDisplay(in: background.bounds))
                background.cacheDisplay(in: background.bounds, to: bitmap)
                let actual = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.01)
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.01)
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.01)
                XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.01)
            }
        }
    }

    func testClassicPaintsTintAndThemeChangesWithoutReplacingControls() throws {
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            var style = ScreenshotPanelStyle(material: .classic)
            style.setTint(.init(red: 1, green: 0, blue: 0))
            style.tintOpacity = 0.5
            style.save()
            let panel = ScreenshotPanelView(frame: NSRect(x: 0, y: 0, width: 80, height: 60))
            let background = try XCTUnwrap(panel.subviews.first)
            let base = try XCTUnwrap(ToolbarLayout.bgColor.usingColorSpace(.sRGB))
            for usesTheme in [false, true] {
                style.tintUsesTheme = usesTheme
                style.save()
                let tint = try XCTUnwrap((usesTheme ? ToolbarLayout.bgColor : NSColor.red).usingColorSpace(.sRGB))
                let bitmap = try XCTUnwrap(background.bitmapImageRepForCachingDisplay(in: background.bounds))
                background.cacheDisplay(in: background.bounds, to: bitmap)
                let actual = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                XCTAssertEqual(actual.redComponent, (base.redComponent + tint.redComponent) / 2, accuracy: 0.01)
                XCTAssertEqual(actual.greenComponent, (base.greenComponent + tint.greenComponent) / 2, accuracy: 0.01)
                XCTAssertEqual(actual.blueComponent, (base.blueComponent + tint.blueComponent) / 2, accuracy: 0.01)
                XCTAssertEqual(actual.alphaComponent, 1, accuracy: 0.01)
                XCTAssertTrue(panel.subviews.first === background)
            }
        }
    }

    func testEnabledSecondaryLabelsKeepContrastAcrossAppearanceChanges() throws {
        let panel = ScreenshotPanelView(frame: .zero)
        let caption = NSTextField(labelWithString: "Line style")
        caption.textColor = NSColor.white.withAlphaComponent(0.35)
        panel.addSubview(caption)
        for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            panel.panelAppearanceOverride = NSAppearance(named: appearance)
            XCTAssertEqual(caption.textColor, panel.panelForegroundColor)
            XCTAssertEqual(caption.textColor?.alphaComponent, 1)
        }
    }

    func testMaterialChangesPreserveControlsFocusAndWindowCount() throws {
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            let canvas = ImageEditingView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
            canvas.screenshotImage = ImageProbe.quadrantImage(width: 640, height: 480)
            canvas.applySelection(canvas.bounds)
            let window = OverlayWindow(contentRect: canvas.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = canvas
            defer { canvas.reset(); window.close() }
            let panels = canvas.subviews.compactMap { $0 as? ScreenshotPanelView }
            XCTAssertTrue(panels.contains { $0 is ToolbarStripView })
            let dimensions = try XCTUnwrap(panels.first { $0 is ResolutionBoxView })
            let controls = dimensions.subviews.compactMap { $0 as? NSTextField }
            let dimensionValues = controls.map(\.stringValue)
            XCTAssertEqual(dimensionValues.count, 2)
            XCTAssertTrue(dimensionValues.allSatisfy { (Int($0) ?? 0) > 0 })
            XCTAssertTrue(window.makeFirstResponder(canvas))
            let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
            let identities = panels.map { $0.subviews.map(ObjectIdentifier.init) }
            let selection = canvas.selectionRect
            for material in ScreenshotPanelStyle.Material.allCases {
                ScreenshotPanelStyle(material: material).save()
                XCTAssertEqual(Set(NSApp.windows.map(ObjectIdentifier.init)), windows)
                XCTAssertEqual(panels.map { $0.subviews.map(ObjectIdentifier.init) }, identities)
                XCTAssertTrue(window.firstResponder === canvas)
                XCTAssertEqual(canvas.selectionRect, selection)
                XCTAssertEqual(controls.map(\.stringValue), dimensionValues)
            }
        }
    }

    func testOptionsRetainDecorationAndLiveControlsAcrossAppearanceChanges() throws {
        let canvas = ImageEditingView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
        canvas.screenshotImage = ImageProbe.quadrantImage(width: 200, height: 160)
        canvas.applySelection(canvas.bounds)
        canvas.currentTool = .stitch
        defer { canvas.reset() }
        let options = ToolOptionsRowView(frame: .zero)
        options.overlayView = canvas
        options.rebuild(for: .stitch)
        let mode = try XCTUnwrap(options.subviews.first { $0.identifier?.rawValue == "stitch.mode" } as? NSSegmentedControl)
        let placement = try XCTUnwrap(options.subviews.first { $0.identifier?.rawValue == "stitch.placement" } as? NSPopUpButton)
        mode.selectedSegment = 1
        placement.selectItem(at: 1)
        let identities = options.subviews.map(ObjectIdentifier.init)
        options.panelAppearanceOverride = NSAppearance(named: .aqua)
        options.refreshPanelAppearance()
        options.panelAppearanceOverride = NSAppearance(named: .darkAqua)
        XCTAssertEqual(options.subviews.map(ObjectIdentifier.init), identities)
        XCTAssertEqual(mode.selectedSegment, 1)
        XCTAssertEqual(placement.indexOfSelectedItem, 1)
        let decoration = try XCTUnwrap(options.subviews.first)
        options.rebuild(for: .line)
        let enabledLabels = options.subviews.compactMap { $0 as? NSTextField }.filter(\.isEnabled)
        XCTAssertFalse(enabledLabels.isEmpty)
        XCTAssertTrue(enabledLabels.allSatisfy { $0.textColor?.alphaComponent == 1 })
        XCTAssertTrue(options.subviews.first === decoration)
        XCTAssertFalse(options.subviews.contains { $0 === mode })
        let content = options.subviews.dropFirst().map(ObjectIdentifier.init)
        options.refreshPanelAppearance()
        XCTAssertEqual(options.subviews.dropFirst().map(ObjectIdentifier.init), content)
    }

    func testDecorationDoesNotInterceptButtonsOrToolbarGapRouting() throws {
        let strip = ToolbarStripView(orientation: .horizontal)
        strip.setButtons([
            ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: "Copy"),
        ])
        strip.layoutSubtreeIfNeeded()
        let decoration = try XCTUnwrap(strip.subviews.first)
        XCTAssertFalse(decoration.isAccessibilityElement())
        XCTAssertNil(decoration.hitTest(NSPoint(x: 5, y: 5)))
        let button = try XCTUnwrap(strip.buttonViews.first)
        let point = NSPoint(x: button.frame.midX, y: button.frame.midY)
        XCTAssertTrue(strip.hitTest(point) === button)
        let gap = NSPoint(x: 1, y: 1)
        XCTAssertTrue(strip.hitTest(gap) === strip)
        strip.passesThrough = true
        XCTAssertNil(strip.hitTest(gap))

    }

    func testHoverAndInstructionPanelsPassThroughInput() {
        let tooltip = ScreenshotTooltipView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        tooltip.text = "Stitch (S)"
        XCTAssertNil(tooltip.hitTest(NSPoint(x: 40, y: 12)))
        let instructions = ScreenshotTextPanelView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        XCTAssertNil(instructions.hitTest(NSPoint(x: 40, y: 12)))
    }

    func testToolbarClickSurvivesTrackingExitDuringAdjacentMenuDismissal() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let strip = ToolbarStripView(orientation: .horizontal)
        strip.setButtons([ToolbarButton(action: .tool(.line), sfSymbol: "line.diagonal", tooltip: "Line")])
        strip.setFrameOrigin(NSPoint(x: 24, y: 24))
        container.addSubview(strip)
        let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        let button = try XCTUnwrap(strip.buttonViews.first)
        var actions: [ToolbarButtonAction] = []
        strip.onClick = { actions.append($0) }

        func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: button.convert(point, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        let exit = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited,
            location: button.convert(center, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        button.mouseDown(with: try mouse(.leftMouseDown, at: center))
        strip.mouseExited(with: exit)
        button.mouseUp(with: try mouse(.leftMouseUp, at: center))
        XCTAssertEqual(actions, [.tool(.line)], "Closing adjacent glass must leave the original click active")

        button.mouseDown(with: try mouse(.leftMouseDown, at: center))
        strip.mouseExited(with: exit)
        button.mouseUp(with: try mouse(.leftMouseUp, at: NSPoint(x: -8, y: -8)))
        XCTAssertEqual(actions, [.tool(.line)], "Releasing outside the button still cancels activation")
        XCTAssertFalse(button.isPressed)
    }

    func testTooltipFittingSizeIncludesTheNativeTextCellAndShortcutSuffix() throws {
        let tooltip = ScreenshotTooltipView(frame: .zero)
        let label = try XCTUnwrap(tooltip.subviews.compactMap { $0 as? NSTextField }.first)
        for text in ["Stitch (S)", "Capture selected area (⇧⌘S)", "Horizontale Bereiche entfernen (⌥)"] {
            tooltip.text = text
            tooltip.setFrameSize(tooltip.preferredSize)
            tooltip.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(label.frame.width, label.intrinsicContentSize.width)
            XCTAssertGreaterThanOrEqual(label.frame.height, label.intrinsicContentSize.height)
            XCTAssertEqual(label.stringValue, text)
        }
    }

    func testCaptureInstructionsHideForRemoteSelectionsAndRespectTheirPreference() throws {
        try withDefaults(["hideCaptureInstructions": false]) {
            let canvas = OverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
            func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil),
                    modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
            }
            XCTAssertFalse(canvas.shouldShowCaptureInstructions, "Wait for the frozen screenshot")
            canvas.screenshotImage = ImageProbe.quadrantImage(width: 200, height: 160)
            XCTAssertTrue(canvas.shouldShowCaptureInstructions)
            canvas.remoteSelectionRect = NSRect(x: 30, y: 30, width: 100, height: 80)
            XCTAssertFalse(canvas.shouldShowCaptureInstructions, "Keep a remote capture's content clear")
            canvas.remoteSelectionRect = .zero
            XCTAssertTrue(canvas.shouldShowCaptureInstructions)
            canvas.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 10, y: 10)))
            XCTAssertFalse(canvas.shouldShowCaptureInstructions)
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 110, y: 90)))
            XCTAssertTrue(canvas.shouldShowCaptureInstructions)
            UserDefaults.standard.set(true, forKey: "hideCaptureInstructions")
            XCTAssertFalse(canvas.shouldShowCaptureInstructions)
            canvas.reset()
        }
    }

    func testPreviewAppearanceUsesReadableNeutralColorsAndKeepsSemanticTint() throws {
        let strip = ToolbarStripView(orientation: .horizontal)
        strip.setButtons([
            ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: "Copy"),
            ToolbarButton(action: .save, sfSymbol: "square.and.arrow.down", tooltip: "Save", tintColor: .systemGreen),
        ])
        let identities = strip.buttonViews.map(ObjectIdentifier.init)
        strip.panelAppearanceOverride = NSAppearance(named: .aqua)
        let light = try XCTUnwrap(strip.panelForegroundColor.usingColorSpace(.sRGB))
        strip.panelAppearanceOverride = NSAppearance(named: .darkAqua)
        let dark = try XCTUnwrap(strip.panelForegroundColor.usingColorSpace(.sRGB))
        XCTAssertLessThan(light.redComponent, 0.4)
        XCTAssertGreaterThan(dark.redComponent, 0.6)
        XCTAssertEqual(strip.buttonViews.map(ObjectIdentifier.init), identities)
        XCTAssertTrue(strip.buttonViews[1].tintColor.isEqual(NSColor.systemGreen))
    }

    func testCaptureOutputContainsOnlySourcePixelsWithChromePresent() throws {
        let canvas = ImageEditingView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        canvas.screenshotImage = ImageProbe.quadrantImage(width: 100, height: 80)
        canvas.applySelection(canvas.bounds)
        let chrome = ScreenshotTooltipView(frame: canvas.bounds)
        chrome.text = "Must not appear in an export"
        canvas.addSubview(chrome)
        defer { canvas.reset() }
        let before = try XCTUnwrap(canvas.captureSelectedRegionRaw())
        chrome.panelAppearanceOverride = NSAppearance(named: .aqua)
        let after = try XCTUnwrap(canvas.captureSelectedRegionRaw())
        XCTAssertEqual(FieldDescriber.describe(before), FieldDescriber.describe(after))
    }
}

@MainActor
private final class ScreenshotFocusProbeWindow: NSWindow {
    var keyForTest = false
    var makeKeyRequests = 0
    override var isVisible: Bool { true }
    override var isKeyWindow: Bool { keyForTest }
    override func makeKey() { makeKeyRequests += 1; keyForTest = true }
}

@MainActor
private final class ScreenshotCommandProbeView: OverlayView {
    var copyRequests = 0
    override var acceptsFirstResponder: Bool { true }
    override func handleEditorKeyEquivalent(_ event: NSEvent) -> Bool {
        guard KeyboardShortcutMatcher.matches(event, character: "c", modifiers: .command) else {
            return false
        }
        copyRequests += 1
        return true
    }
}
