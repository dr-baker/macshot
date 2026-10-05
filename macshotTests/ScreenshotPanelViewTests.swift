import AppKit
import XCTest

@MainActor
final class ScreenshotPanelViewTests: XCTestCase {
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
