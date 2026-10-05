import AppKit
import XCTest

@MainActor
final class ScreenshotAppearanceSettingsTests: XCTestCase {
    func testChangingTintAndFinishKeepsStrengthAndMountedControls() throws {
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            var style = ScreenshotPanelStyle()
            style.tintOpacity = 0.42
            style.save()
            let pane = ScreenshotAppearanceSettingsView(themeControls: NSView())
            let material: NSSegmentedControl = try control("material", in: pane)
            let color: NSColorWell = try control("tint.color", in: pane)
            let strength: NSSlider = try control("tint.strength", in: pane)
            let identities = mountedControls(in: pane).map(ObjectIdentifier.init)

            color.color = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            try send(color)
            let chosenTint = try XCTUnwrap(ScreenshotPanelStyle.Tint(color: color.color))
            XCTAssertEqual(ScreenshotPanelStyle.load().tint, chosenTint)
            XCTAssertEqual(ScreenshotPanelStyle.load().tintOpacity, 0.42)
            strength.doubleValue = 0.63
            try send(strength)

            for selectedSegment in [2, 0, 1, 2] {
                material.selectedSegment = selectedSegment
                try send(material)
                let saved = ScreenshotPanelStyle.load()
                XCTAssertEqual(saved.material, ScreenshotPanelStyle.Material.allCases[selectedSegment])
                XCTAssertEqual(saved.tint, chosenTint)
                XCTAssertEqual(saved.tintOpacity, 0.63)
                XCTAssertFalse(saved.tintUsesTheme)
                XCTAssertEqual(mountedControls(in: pane).map(ObjectIdentifier.init), identities)
            }

            let reopened = ScreenshotAppearanceSettingsView(themeControls: NSView())
            let reopenedMaterial: NSSegmentedControl = try control("material", in: reopened)
            let reopenedSource: NSPopUpButton = try control("tint.source", in: reopened)
            let reopenedStrength: NSSlider = try control("tint.strength", in: reopened)
            XCTAssertEqual(reopenedMaterial.selectedSegment, 2)
            XCTAssertEqual(reopenedSource.indexOfSelectedItem, 1)
            XCTAssertEqual(reopenedStrength.doubleValue, 0.63)
        }
    }

    func testThemeCustomAndNoneActionsPreserveAnIntentionalZeroStrength() throws {
        defer {
            NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil)
            NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
        }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil, "toolbarAccentColor": nil, "toolbarBgColor": nil, "toolbarIconColor": nil, "toolbarThemePreset": nil, "toolbarUsesSystemAccent": nil]) {
            var style = ScreenshotPanelStyle(material: .classic)
            style.tint = .init(red: 0.2, green: 0.4, blue: 0.8)
            style.tintOpacity = 0
            style.save()
            let pane = ScreenshotAppearanceSettingsView(themeControls: NSView())
            let source: NSPopUpButton = try control("tint.source", in: pane)
            let color: NSColorWell = try control("tint.color", in: pane)
            let strength: NSSlider = try control("tint.strength", in: pane)

            source.selectItem(at: 0)
            try send(source)
            XCTAssertTrue(ScreenshotPanelStyle.load().tintUsesTheme)
            XCTAssertEqual(ScreenshotPanelStyle.load().tintOpacity, 0)
            XCTAssertFalse(color.isEnabled)
            XCTAssertFalse(color.isHidden)
            let savedThemePreference = UserDefaults.standard.data(forKey: ScreenshotPanelStyle.defaultsKey)
            ToolbarLayout.saveBgColor(NSColor(srgbRed: 0.1, green: 0.7, blue: 0.4, alpha: 1))
            NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil)
            XCTAssertEqual(UserDefaults.standard.data(forKey: ScreenshotPanelStyle.defaultsKey), savedThemePreference)
            XCTAssertEqual(ScreenshotPanelStyle.Tint(color: color.color),
                ScreenshotPanelStyle.Tint(color: ToolbarLayout.bgColor))

            source.selectItem(at: 1)
            try send(source)
            XCTAssertFalse(ScreenshotPanelStyle.load().tintUsesTheme)
            XCTAssertEqual(ScreenshotPanelStyle.load().tint, style.tint)
            XCTAssertEqual(ScreenshotPanelStyle.load().tintOpacity, 0)
            XCTAssertTrue(color.isEnabled)

            source.selectItem(at: 2)
            try send(source)
            XCTAssertNil(ScreenshotPanelStyle.load().resolvedTint(themeColor: ToolbarLayout.bgColor))
            XCTAssertFalse(ScreenshotPanelStyle.load().tintUsesTheme)
            XCTAssertEqual(ScreenshotPanelStyle.load().tintOpacity, 0)
            XCTAssertTrue(color.isHidden)
            XCTAssertFalse(strength.isEnabled)

            source.selectItem(at: 1)
            try send(source)
            XCTAssertNotNil(ScreenshotPanelStyle.load().tint)
            XCTAssertEqual(ScreenshotPanelStyle.load().tintOpacity, 0)
            XCTAssertTrue(strength.isEnabled)
        }
    }

    func testPreviewCannotReceiveInputOrMutateAnnotationDefaults() throws {
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([
            ScreenshotPanelStyle.defaultsKey: nil,
            "lastUsedTool": AnnotationTool.arrow.rawValue,
            "currentStrokeWidth": 7.0,
            "currentLineStyle": LineStyle.dashed.rawValue,
            "lastUsedColor": nil,
        ]) {
            let keys = ["lastUsedTool", "currentStrokeWidth", "currentLineStyle", "lastUsedColor"]
            let originalDefaults = keys.map { FieldDescriber.describe(UserDefaults.standard.object(forKey: $0) as Any) }
            let pane = ScreenshotAppearanceSettingsView(themeControls: NSView())
            pane.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
            let preview: NSView = try control("preview", in: pane)
            let root = NSView(frame: pane.frame)
            let focus = AppearanceFocusView(frame: .zero)
            root.addSubview(pane)
            root.addSubview(focus)
            let window = ScreenshotGlassWindow(contentRect: root.frame, styleMask: .borderless,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            defer { window.close() }
            pane.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.makeFirstResponder(focus))
            let windows = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))

            XCTAssertNil(preview.hitTest(NSPoint(x: preview.frame.midX, y: preview.frame.midY)))
            XCTAssertTrue(preview.isAccessibilityElement())
            XCTAssertEqual(preview.accessibilityRole(), .image)
            XCTAssertEqual(preview.accessibilityChildren()?.count, 0)
            let previewControls = descendants(of: preview).compactMap { $0 as? NSControl }
            XCTAssertFalse(previewControls.isEmpty)
            XCTAssertTrue(previewControls.allSatisfy { !$0.acceptsFirstResponder })
            for material in ScreenshotPanelStyle.Material.allCases {
                ScreenshotPanelStyle(material: material).save()
                pane.refreshControls()
                XCTAssertTrue(window.firstResponder === focus)
                XCTAssertEqual(Set(NSApplication.shared.windows.map(ObjectIdentifier.init)), windows)
            }
            XCTAssertEqual(keys.map { FieldDescriber.describe(UserDefaults.standard.object(forKey: $0) as Any) },
                originalDefaults)
        }
    }

    func testReconstructingAfterPreferenceChangesReadsThemWithoutOverwritingThem() throws {
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            let original = ScreenshotAppearanceSettingsView(themeControls: NSView())
            var imported = ScreenshotPanelStyle(material: .classic)
            imported.tintUsesTheme = true
            imported.tintOpacity = 0.7
            imported.save()
            let importedData = try XCTUnwrap(UserDefaults.standard.data(forKey: ScreenshotPanelStyle.defaultsKey))
            let rebuilt = ScreenshotAppearanceSettingsView(themeControls: NSView())
            for pane in [original, rebuilt] {
                pane.refreshControls()
                let material: NSSegmentedControl = try control("material", in: pane)
                let source: NSPopUpButton = try control("tint.source", in: pane)
                let strength: NSSlider = try control("tint.strength", in: pane)
                XCTAssertEqual(material.selectedSegment, 2)
                XCTAssertEqual(source.indexOfSelectedItem, 0)
                XCTAssertEqual(strength.doubleValue, 0.7)
            }
            XCTAssertEqual(UserDefaults.standard.data(forKey: ScreenshotPanelStyle.defaultsKey), importedData)

            let reset: NSButton = try control("reset", in: rebuilt)
            reset.performClick(nil)
            XCTAssertEqual(ScreenshotPanelStyle.load(), ScreenshotPanelStyle())
            let material: NSSegmentedControl = try control("material", in: rebuilt)
            let source: NSPopUpButton = try control("tint.source", in: rebuilt)
            let strength: NSSlider = try control("tint.strength", in: rebuilt)
            XCTAssertEqual(material.selectedSegment, 0)
            XCTAssertEqual(source.indexOfSelectedItem, 0)
            XCTAssertEqual(strength.doubleValue, 0.70)
        }
    }

    func testUnavailableClearExplainsTheClassicFallback() throws {
        defer { NotificationCenter.default.post(name: ScreenshotPanelStyle.didChange, object: nil) }
        try withDefaults([ScreenshotPanelStyle.defaultsKey: nil]) {
            let pane = ScreenshotAppearanceSettingsView(themeControls: NSView())
            let note: NSTextField = try control("note", in: pane)
            XCTAssertFalse(note.stringValue.isEmpty)
            if !ScreenshotGlassAvailability.isAvailable {
                XCTAssertTrue(note.stringValue.contains(L("Classic")))
            } else {
                XCTAssertFalse(note.stringValue.contains(L("unavailable")))
            }
        }
    }

    func testAppearanceAndSystemAccentControlsPreserveStoredPaletteAndMountedPreview() throws {
        defer { NotificationCenter.default.post(name: .toolbarColorsDidChange, object: nil) }
        try withDefaults(["toolbarColorMode": nil, "toolbarUsesSystemAccent": nil,
                          "toolbarThemePreset": "sunset"]) {
            let pane = ScreenshotAppearanceSettingsView(themeControls: NSView())
            let mode: NSSegmentedControl = try control("colorMode", in: pane)
            let system: NSButton = try control("systemAccent", in: pane)
            let identities = mountedControls(in: pane).map(ObjectIdentifier.init)
            for index in [1, 2, 0] {
                mode.selectedSegment = index
                try send(mode)
                XCTAssertEqual(ToolbarLayout.colorMode, ToolbarLayout.ColorMode.allCases[index])
            }
            for state in [NSControl.StateValue.on, .off] {
                system.state = state
                try send(system)
                XCTAssertEqual(ToolbarLayout.usesSystemAccent, state == .on)
                XCTAssertEqual(ToolbarLayout.selectedThemePreset?.id, "sunset")
                XCTAssertEqual(mountedControls(in: pane).map(ObjectIdentifier.init), identities)
            }
        }
    }

    private func control<T: NSView>(_ name: String, in pane: NSView) throws -> T {
        try XCTUnwrap(descendants(of: pane).first {
            $0.identifier?.rawValue == "screenshot.appearance.\(name)"
        } as? T)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func mountedControls(in view: NSView) -> [NSView] {
        descendants(of: view).filter { $0 is NSControl || $0 is ToolbarButtonView || $0 is ScreenshotPanelView }
    }

    private func send(_ control: NSControl) throws {
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(control.action),
            to: try XCTUnwrap(control.target), from: control))
    }
}

private final class AppearanceFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
