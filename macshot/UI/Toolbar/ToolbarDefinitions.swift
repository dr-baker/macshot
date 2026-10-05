import Cocoa

extension Notification.Name {
    static let toolbarColorsDidChange = Notification.Name("toolbarColorsDidChange")
    static let toolbarVisibilityDidChange = Notification.Name("toolbarVisibilityDidChange")
}

// Toolbar buttons drawn directly in the OverlayView (not a separate window).
// This avoids window-level z-order issues and matches Flameshot's look.

enum ToolbarButtonAction: Equatable {
    case tool(AnnotationTool)
    case color
    case sizeDisplay
    case undo
    case redo
    case copy
    case save
    case pin
    case ocr
    case autoRedact
    case beautify
    case beautifyStyle
    case cancel
    case moveSelection
    case adjustSelection
    case delayCapture
    case upload
    case share
    case removeBackground
    case invertColors
    case loupe
    case translate
    case record  // enters recording mode (shows recording toolbar)
    case startRecord  // actually starts recording
    case stopRecord
    case mouseHighlight
    case systemAudio
    case micAudio
    case detach
    case scrollCapture
    case addCapture  // editor only: capture a new region and append to the canvas
    case showKeystrokes
    case webcam
    case recordSettings  // recording mode: open format/FPS/when-done popover
    case effects  // image effects (CIFilter adjustments + presets)
}

struct ToolbarButton {
    let action: ToolbarButtonAction
    let sfSymbol: String?
    let tooltip: String
    var isSelected: Bool = false
    var tintColor: NSColor = ToolbarLayout.iconColor
    var selectedTintColor: NSColor? = nil  // optional status tint that remains visible while selected
    var bgColor: NSColor? = nil  // for color swatches
    var hasContextMenu: Bool = false  // draw small corner triangle to indicate right-click options
}

enum ToolbarCustomAction: Int {
    #if !OFFLINE
    case upload = 1001
    #endif
    case pin = 1002
    case ocr = 1003
    case beautify = 1004
    case removeBackground = 1005
    case autoRedact = 1006
    case reserved1007 = 1007
    case translate = 1008
    case record = 1009
    case scrollCapture = 1010
    case invertColors = 1011
    case share = 1012
    case effects = 1013

    static var allKnownActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = []
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [
            .pin, .ocr, .beautify, .removeBackground, .autoRedact, .reserved1007,
            .translate, .record, .scrollCapture, .invertColors, .share, .effects,
        ])
        return actions
    }

    static var bottomToolbarActions: [ToolbarCustomAction] {
        [.invertColors, .effects, .beautify, .removeBackground]
    }

    static var rightToolbarActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = [.share]
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [.pin, .ocr, .translate, .scrollCapture, .record])
        return actions
    }

    static var bottomSettingsActions: [ToolbarCustomAction] {
        bottomToolbarActions
    }

    static var rightSettingsActions: [ToolbarCustomAction] {
        var actions: [ToolbarCustomAction] = []
        #if !OFFLINE
        actions.append(.upload)
        #endif
        actions.append(contentsOf: [.pin, .ocr, .autoRedact, .translate, .record, .scrollCapture, .share])
        return actions
    }

    var settingsLabel: String {
        switch self {
        #if !OFFLINE
        case .upload: return L("Upload")
        #endif
        case .pin: return L("Pin (floating window)")
        case .ocr: return L("OCR & QR")
        case .beautify: return L("Beautify")
        case .removeBackground: return L("Remove Background")
        case .autoRedact: return L("Auto-Redact sensitive data")
        case .reserved1007: return ""
        case .translate: return L("Translate")
        case .record: return L("Record screen")
        case .scrollCapture: return L("Scroll Capture")
        case .invertColors: return L("Invert Colors")
        case .share: return L("Share")
        case .effects: return L("Adjust (Image Effects)")
        }
    }

    func makeToolbarButton(
        beautifyEnabled: Bool = false,
        translateEnabled: Bool = false,
        effectsActive: Bool = false,
        isRecording: Bool = false,
        isEditorMode: Bool = false
    ) -> ToolbarButton? {
        switch self {
        #if !OFFLINE
        case .upload:
            var button = ToolbarButton(action: .upload, sfSymbol: "icloud.and.arrow.up", tooltip: L("Upload"))
            button.hasContextMenu = true
            return button
        #endif
        case .pin:
            return ToolbarButton(action: .pin, sfSymbol: "pin.fill", tooltip: L("Pin"))
        case .ocr:
            return ToolbarButton(action: .ocr, sfSymbol: "doc.text.viewfinder", tooltip: L("OCR & QR"))
        case .beautify:
            var button = ToolbarButton(action: .beautify, sfSymbol: "sparkles", tooltip: L("Beautify"))
            if beautifyEnabled {
                let enabledColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
                button.tintColor = enabledColor
                button.selectedTintColor = enabledColor
            }
            return button
        case .removeBackground:
            if #available(macOS 14.0, *) {
                return ToolbarButton(
                    action: .removeBackground,
                    sfSymbol: "person.crop.circle.dashed",
                    tooltip: L("Remove Background")
                )
            }
            return nil
        case .autoRedact, .reserved1007:
            return nil
        case .translate:
            var button = ToolbarButton(action: .translate, sfSymbol: "translate", tooltip: L("Translate"))
            button.isSelected = translateEnabled
            button.hasContextMenu = true
            return button
        case .record:
            guard !isEditorMode else { return nil }
            var button = ToolbarButton(action: .record, sfSymbol: "video.fill", tooltip: L("Record"))
            button.tintColor = ToolbarLayout.iconColor
            return button
        case .scrollCapture:
            guard !isRecording && !isEditorMode else { return nil }
            return ToolbarButton(action: .scrollCapture, sfSymbol: "scroll", tooltip: L("Scroll Capture"))
        case .invertColors:
            return ToolbarButton(
                action: .invertColors,
                sfSymbol: "circle.righthalf.filled.inverse",
                tooltip: L("Invert Colors")
            )
        case .share:
            return ToolbarButton(action: .share, sfSymbol: "square.and.arrow.up", tooltip: L("Share"))
        case .effects:
            var button = ToolbarButton(action: .effects, sfSymbol: "slider.horizontal.3", tooltip: L("Adjust"))
            if effectsActive {
                button.tintColor = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.2, alpha: 1.0)
            }
            return button
        }
    }
}

enum ToolbarActionPreferences {
    static let enabledDefaultsKey = "enabledActions"
    static let knownDefaultsKey = "knownActionTags"

    static var allKnownRawValues: [Int] {
        ToolbarCustomAction.allKnownActions.map(\.rawValue)
    }

    static var defaultEnabledRawValues: [Int] {
        allKnownRawValues
    }

    static func enabledRawValuesAfterMigration() -> [Int]? {
        var enabledActions = UserDefaults.standard.array(forKey: enabledDefaultsKey) as? [Int]
        let knownActionTags = UserDefaults.standard.array(forKey: knownDefaultsKey) as? [Int]
        let newTags = allKnownRawValues.filter { !(knownActionTags ?? []).contains($0) }

        if !newTags.isEmpty {
            if enabledActions == nil {
                enabledActions = allKnownRawValues
            } else if knownActionTags == nil {
                // Upgrading from a version before knownActionTags tracking was added.
            } else {
                enabledActions = enabledActions! + newTags
            }
            UserDefaults.standard.set(enabledActions, forKey: enabledDefaultsKey)
            UserDefaults.standard.set(allKnownRawValues, forKey: knownDefaultsKey)
        }

        return enabledActions
    }

    static func isEnabled(_ action: ToolbarCustomAction, in enabledActions: [Int]?) -> Bool {
        enabledActions == nil || enabledActions!.contains(action.rawValue)
    }
}

class ToolbarLayout {

    // Default theme colors (Flameshot purple style)
    static let defaultAccentColor = NSColor(calibratedRed: 0.55, green: 0.30, blue: 0.85, alpha: 1.0)
    static let defaultIconColor = NSColor.white
    static let defaultBgColor = NSColor(white: 0.12, alpha: 1.0)

    typealias ColorMode = ToolbarThemeColorMode

    static var colorMode: ColorMode {
        get { ColorMode(rawValue: UserDefaults.standard.string(forKey: "toolbarColorMode") ?? "system") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "toolbarColorMode") }
    }

    static var usesSystemAccent: Bool {
        get { UserDefaults.standard.bool(forKey: "toolbarUsesSystemAccent") }
        set { UserDefaults.standard.set(newValue, forKey: "toolbarUsesSystemAccent") }
    }

    /// Material appearance follows the chosen app mode, independently of panel
    /// foreground overrides and the brightness of explicitly customized colors.
    static var appearance: NSAppearance? { resolvedAppearance }
    private static var resolvedAppearance: NSAppearance { colorMode.appearance(system: NSApp?.effectiveAppearance) }

    static func palette(for appearance: NSAppearance) -> ToolbarThemePreset.Palette {
        ToolbarThemePreferences.shared.palette(for: appearance, usesSystemAccent: usesSystemAccent)
    }

    private static var currentPalette: ToolbarThemePreset.Palette { palette(for: resolvedAppearance) }
    static var accentColor: NSColor { currentPalette.accent }
    static var iconColor: NSColor { currentPalette.icon }
    static var bgColor: NSColor { currentPalette.bg }
    static var handleColor: NSColor { accentColor }
    static let cornerRadius: CGFloat = 6

    static var selectedThemePreset: ToolbarThemePreset? { ToolbarThemePreferences.shared.selectedPreset }
    static func applyThemePreset(_ preset: ToolbarThemePreset) { ToolbarThemePreferences.shared.apply(preset) }

    /// Editing any color freezes the displayed palette and leaves system-accent
    /// mode. Later Light/Dark changes preserve those explicit color choices.
    static func saveAccentColor(_ color: NSColor) { saveCustomColors(accent: color) }
    static func saveIconColor(_ color: NSColor) { saveCustomColors(icon: color) }
    static func saveBgColor(_ color: NSColor) { saveCustomColors(background: color) }

    private static func saveCustomColors(accent: NSColor? = nil, icon: NSColor? = nil, background: NSColor? = nil) {
        let palette = currentPalette
        var colors = [accent ?? palette.accent, icon ?? palette.icon, background ?? palette.bg]
        resolvedAppearance.performAsCurrentDrawingAppearance {
            colors = colors.map { $0.usingColorSpace(.sRGB) ?? $0 }
        }
        ToolbarThemePreferences.shared.saveCustom(.init(accent: colors[0], icon: colors[1], bg: colors[2]))
    }

    static func resetColors() { ToolbarThemePreferences.shared.reset() }

    // Bottom toolbar items (drawing tools + colors + undo/redo + processing actions)
    static func bottomButtons(
        selectedTool: AnnotationTool, selectedColor: NSColor, beautifyEnabled: Bool = false,
        beautifyStyleIndex: Int = 0, hasAnnotations: Bool = false, isRecording: Bool = false,
        effectsActive: Bool = false, stitchSeamsVisible: Bool = true, stitchTransition: StitchTransition = .wave
    ) -> [ToolbarButton] {
        // Hide the bottom bar entirely while recording
        if isRecording { return [] }

        var buttons: [ToolbarButton] = []

        // Get enabled tools from UserDefaults — migrate: only add tools that are brand-new.
        // Track introduced tools in `knownToolRawValues` so user-disabled tools are never re-enabled.
        let allKnownToolRawValues = AnnotationTool.allCases
            .filter { $0 != .select && $0 != .translateOverlay }
            .map { $0.rawValue }
        var enabledRawValues = UserDefaults.standard.array(forKey: "enabledTools") as? [Int]
        let knownToolRawValues = UserDefaults.standard.array(forKey: "knownToolRawValues") as? [Int]
        let newToolRaws = allKnownToolRawValues.filter { !(knownToolRawValues ?? []).contains($0) }
        if !newToolRaws.isEmpty {
            if enabledRawValues == nil {
                // Fresh install: enable everything.
                enabledRawValues = allKnownToolRawValues
            } else if knownToolRawValues == nil {
                // Upgrading from a version before knownToolRawValues tracking was added.
                // Respect the existing enabledTools as-is; just mark all current tools as known.
            } else {
                // Normal upgrade: new tools introduced — add them enabled by default.
                enabledRawValues = (enabledRawValues! + newToolRaws)
            }
            UserDefaults.standard.set(enabledRawValues, forKey: "enabledTools")
            UserDefaults.standard.set(allKnownToolRawValues, forKey: "knownToolRawValues")
        }

        let tools: [(AnnotationTool, String, String)] = [
            (.pencil, "scribble", L("Pencil (Draw)")),
            (.line, "line.diagonal", L("Line")),
            (.arrow, "arrow.up.right", L("Arrow")),
            (.rectangle, "rectangle", L("Rectangle")),
            (.ellipse, "oval", L("Ellipse")),
            (.marker, {
                if #available(macOS 14.0, *) { return "highlighter" }
                return "paintbrush.pointed.fill"
            }(), L("Marker")),
            (.text, "textformat", L("Text")),
            (.number, "1.circle.fill", L("Number")),
            (.pixelate, "_custom.checkerboard", L("Censor (Pixelate / Blur / Solid)")),
            (.highlight, "sun.max", L("Highlight (Spotlight)")),
            (.loupe, "magnifyingglass", L("Magnify (Loupe)")),
            (.stamp, "face.smiling", L("Stamp / Emoji")),
            (.colorSampler, "eyedropper", L("Color Picker")),
            (.measure, "ruler", L("Measure (px)")),
            (.stitch, "scissors", L("Stitch")),
        ]

        for (tool, symbol, tip) in tools {
            // Skip if disabled
            if let enabledRawValues = enabledRawValues, !enabledRawValues.contains(tool.rawValue) {
                continue
            }
            var btn = ToolbarButton(action: .tool(tool), sfSymbol: symbol, tooltip: tip)
            btn.isSelected = (tool == selectedTool)
            switch tool {
            case .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .number, .loupe:
                break  // options shown in the tool options row, not via right-click
            default:
                break
            }
            buttons.append(btn)
        }

        // Color button
        let colorTooltip: String
        if selectedTool == .stitch {
            if !stitchSeamsVisible {
                colorTooltip = stitchTransition.hasEditableColor ? L("Show seams to edit color") : L("Show seams to edit appearance")
            } else {
                colorTooltip = stitchTransition.hasEditableColor ? L("Seam color") : L("Seam appearance")
            }
        } else { colorTooltip = L("Color") }
        var colorBtn = ToolbarButton(action: .color, sfSymbol: nil, tooltip: colorTooltip)
        colorBtn.bgColor = selectedTool == .stitch && stitchSeamsVisible && !stitchTransition.hasEditableColor
            ? selectedColor.withAlphaComponent(selectedColor.alphaComponent * 0.3) : selectedColor
        buttons.append(colorBtn)

        // Undo / Redo
        buttons.append(
            ToolbarButton(
                action: .undo, sfSymbol: "arrow.uturn.backward", tooltip: L("Undo")))
        buttons.append(
            ToolbarButton(
                action: .redo, sfSymbol: "arrow.uturn.forward", tooltip: L("Redo")))

        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()
        for action in ToolbarCustomAction.bottomToolbarActions {
            guard ToolbarActionPreferences.isEnabled(action, in: enabledActions) else { continue }
            if let button = action.makeToolbarButton(
                beautifyEnabled: beautifyEnabled,
                effectsActive: effectsActive,
                isRecording: isRecording
            ) {
                buttons.append(button)
            }
        }

        return buttons
    }

    // Right toolbar items (output actions + cancel + delay)
    static func rightButtons(
        beautifyEnabled: Bool = false, beautifyStyleIndex: Int = 0, hasAnnotations: Bool = false,
        translateEnabled: Bool = false, isRecording: Bool = false,
        isEditorMode: Bool = false
    ) -> [ToolbarButton] {
        var buttons: [ToolbarButton] = []

        // Recording setup mode — show start button + toggles, then return early
        if isRecording {
            var startBtn = ToolbarButton(
                action: .startRecord, sfSymbol: "record.circle", tooltip: L("Start Recording"))
            startBtn.tintColor = .systemRed
            buttons.append(startBtn)

            // Stop/cancel button to exit recording mode without starting
            buttons.append(
                ToolbarButton(action: .stopRecord, sfSymbol: "xmark", tooltip: L("Cancel Recording")))

            let mouseHighlightOn = UserDefaults.standard.bool(forKey: "recordMouseHighlight")
            var mouseBtn = ToolbarButton(
                action: .mouseHighlight, sfSymbol: "cursorarrow.click.2", tooltip: L("Highlight Mouse Clicks"))
            mouseBtn.isSelected = mouseHighlightOn
            buttons.append(mouseBtn)

            let keystrokesOn = UserDefaults.standard.bool(forKey: "recordKeystroke")
            var keystrokeBtn = ToolbarButton(
                action: .showKeystrokes, sfSymbol: "keyboard", tooltip: L("Show Keystrokes"))
            keystrokeBtn.isSelected = keystrokesOn
            keystrokeBtn.hasContextMenu = true
            buttons.append(keystrokeBtn)

            let audioOn = UserDefaults.standard.bool(forKey: "recordSystemAudio")
            var audioBtn = ToolbarButton(
                action: .systemAudio, sfSymbol: audioOn ? "speaker.wave.2.fill" : "speaker.slash",
                tooltip: L("Record System Audio"))
            audioBtn.isSelected = audioOn
            buttons.append(audioBtn)

            let micOn = UserDefaults.standard.bool(forKey: "recordMicAudio")
            var micBtn = ToolbarButton(
                action: .micAudio, sfSymbol: micOn ? "mic.fill" : "mic.slash", tooltip: L("Record Microphone"))
            micBtn.isSelected = micOn
            micBtn.hasContextMenu = true
            buttons.append(micBtn)

            let webcamOn = UserDefaults.standard.bool(forKey: "recordWebcam")
            let webcamSymbol: String = {
                if #available(macOS 14.0, *) {
                    return webcamOn ? "web.camera.fill" : "web.camera"
                }
                return webcamOn ? "camera.fill" : "camera"
            }()
            var webcamBtn = ToolbarButton(
                action: .webcam, sfSymbol: webcamSymbol, tooltip: L("Webcam Overlay"))
            webcamBtn.isSelected = webcamOn
            webcamBtn.hasContextMenu = true
            buttons.append(webcamBtn)

            // Recording settings gear
            buttons.append(
                ToolbarButton(
                    action: .recordSettings, sfSymbol: "gearshape",
                    tooltip: L("Recording Settings")))

            // Allow moving the selection before starting
            buttons.append(
                ToolbarButton(
                    action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right",
                    tooltip: L("Move Selection")))

            return buttons
        }

        let enabledActions = ToolbarActionPreferences.enabledRawValuesAfterMigration()

        // Cancel, move-selection, editor — not shown in editor window
        if !isEditorMode {
            buttons.append(
                ToolbarButton(action: .cancel, sfSymbol: "xmark", tooltip: L("Cancel")))
            buttons.append(
                ToolbarButton(
                    action: .moveSelection, sfSymbol: "arrow.up.and.down.and.arrow.left.and.right",
                    tooltip: L("Move Selection")))
            buttons.append(
                ToolbarButton(
                    action: .detach, sfSymbol: "arrow.up.forward.app",
                    tooltip: L("Open in Editor Window")))
        }
        // Copy and save are always present
        buttons.append(
            ToolbarButton(action: .copy, sfSymbol: "doc.on.doc", tooltip: L("Copy")))
        let saveTooltip: String = {
            switch SaveActionPreference.current {
            case .saveToFolder:
                return "\(L("Save to")) \(URL(fileURLWithPath: SaveDirectoryAccess.displayPath).lastPathComponent)"
            case .askWhereToSave:
                return L("Ask where to save")
            }
        }()
        var saveBtn = ToolbarButton(
            action: .save, sfSymbol: "square.and.arrow.down.fill",
            tooltip: saveTooltip
        )
        saveBtn.hasContextMenu = true
        buttons.append(saveBtn)

        for action in ToolbarCustomAction.rightToolbarActions {
            guard ToolbarActionPreferences.isEnabled(action, in: enabledActions) else { continue }
            if let button = action.makeToolbarButton(
                translateEnabled: translateEnabled,
                isRecording: isRecording,
                isEditorMode: isEditorMode
            ) {
                buttons.append(button)
            }
        }

        return buttons
    }
}
