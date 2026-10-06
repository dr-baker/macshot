import AppKit
import ObjectiveC

/// Screenshot commands sit before the window in AppKit's responder chain.
/// Native controls handle their own input first; unhandled keys reach the same
/// scene regardless of which toolbar control currently owns focus.
@MainActor
final class ScreenshotCommandResponder: NSResponder {
    private static var associationKey: UInt8 = 0
    private weak var screenshotWindow: NSWindow?
    private weak var chainPredecessor: NSResponder?
    private(set) weak var editor: OverlayView?
    private weak var stitchCanvas: StitchCanvasView?
    private weak var linkedParent: NSWindow?
    private weak var transientOwner: NSView?
    private var cancelTransient: (() -> Void)?

    static func forWindow(_ window: NSWindow?) -> ScreenshotCommandResponder? {
        guard let window else { return nil }
        return objc_getAssociatedObject(window, &associationKey) as? ScreenshotCommandResponder
    }

    @discardableResult
    static func install(in window: NSWindow, editor: OverlayView?, startingAt host: NSView? = nil) -> ScreenshotCommandResponder {
        let commands: ScreenshotCommandResponder
        if let existing = forWindow(window) {
            commands = existing
        } else {
            commands = ScreenshotCommandResponder()
            NotificationCenter.default.addObserver(commands, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window)
        }
        commands.screenshotWindow = window
        if let editor {
            commands.editor = editor
            commands.linkedParent = nil
        }
        // A content view can be backed by an NSViewController or NSPopover.
        // Splice after the actual predecessor of the window, preserving those
        // owners instead of assigning contentView.nextResponder directly.
        var responder: NSResponder? = window.contentView ?? host ?? editor
        var visited: Set<ObjectIdentifier> = []
        while let current = responder, current !== window,
              visited.insert(ObjectIdentifier(current)).inserted {
            if current === commands { break }
            if current.nextResponder === window {
                if let old = commands.chainPredecessor, old.nextResponder === commands {
                    old.nextResponder = commands.nextResponder
                }
                commands.nextResponder = window
                current.nextResponder = commands
                commands.chainPredecessor = current
                break
            }
            responder = current.nextResponder
        }
        objc_setAssociatedObject(window, &associationKey, commands, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return commands
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func detachFromChain() {
        // nextResponder is unsafe_unretained. Restore the native chain while
        // its window is alive, including when a controller outlives the window.
        var responder: NSResponder? = screenshotWindow?.contentView
        var visited: Set<ObjectIdentifier> = []
        while let current = responder, current !== screenshotWindow,
              visited.insert(ObjectIdentifier(current)).inserted {
            if current.nextResponder === self {
                current.nextResponder = nextResponder
                break
            }
            responder = current.nextResponder
        }
        nextResponder = nil
        chainPredecessor = nil
    }

    @objc private func windowWillClose(_ notification: Notification) {
        detachFromChain()
        editor = nil
        stitchCanvas = nil
        transientOwner = nil
        cancelTransient = nil
        linkedParent = nil
    }

    static func uninstallEditor(_ editor: OverlayView, in window: NSWindow?) {
        guard let commands = forWindow(window), commands.editor === editor else { return }
        commands.editor = nil
    }

    static func installStitchCanvas(_ canvas: StitchCanvasView, in window: NSWindow) {
        install(in: window, editor: nil).stitchCanvas = canvas
    }

    static func uninstallStitchCanvas(_ canvas: StitchCanvasView, in window: NSWindow?) {
        guard let commands = forWindow(window), commands.stitchCanvas === canvas else { return }
        commands.stitchCanvas = nil
    }

    /// Native popovers have their own AppKit window but edit the parent scene.
    func linkEditor(from parent: NSWindow?) {
        linkedParent = parent
        editor = Self.forWindow(parent)?.editor
    }

    var hasTransientScope: Bool { transientOwner?.window != nil && cancelTransient != nil }

    func setTransientScope(owner: NSView, cancel: @escaping () -> Void) {
        transientOwner = owner
        cancelTransient = cancel
    }

    func removeTransientScope(owner: NSView) {
        guard transientOwner === owner else { return }
        transientOwner = nil
        cancelTransient = nil
        if linkedParent != nil {
            editor = nil
            linkedParent = nil
        }
        if editor == nil, stitchCanvas == nil { detachFromChain() }
    }

    private var activeEditor: OverlayView? {
        guard let editor, let window = screenshotWindow else { return nil }
        if editor.window === window { return editor }
        guard hasTransientScope, let parent = linkedParent, editor.window === parent,
              Self.forWindow(parent)?.editor === editor else { return nil }
        return editor
    }

    private var isNativeTextEditing: Bool {
        guard let textView = screenshotWindow?.firstResponder as? NSTextView else { return false }
        return textView !== activeEditor?.textEditView
    }

    private var activeStitchCanvas: StitchCanvasView? {
        guard let editor = activeEditor, let canvas = stitchCanvas, canvas.window === screenshotWindow,
              canvas.inlineEditor === editor, !canvas.isHiddenOrHasHiddenAncestor else { return nil }
        return canvas
    }

    @discardableResult
    func dispatchKeyEvent(_ event: NSEvent) -> Bool {
        if event.keyCode == 53, hasTransientScope {
            cancelTransient?()
            return true
        }
        guard !isNativeTextEditing else { return false }
        if EditorCommandShortcutManager.action(for: event) != nil,
           performEditorKeyEquivalent(event) { return true }
        if activeStitchCanvas?.handleStitchInteractionKeyEvent(event) == true { return true }
        return activeEditor?.handleEditorKeyEvent(event) ?? false
    }

    func performEditorKeyEquivalent(_ event: NSEvent) -> Bool {
        guard !isNativeTextEditing else { return false }
        return activeEditor?.handleEditorKeyEquivalent(event) ?? false
    }

    override func keyDown(with event: NSEvent) {
        if !dispatchKeyEvent(event) { super.keyDown(with: event) }
    }

    func dispatchKeyRelease(_ event: NSEvent) -> Bool {
        activeEditor?.handleEditorKeyRelease(event) ?? false
    }

    func dispatchModifierEvent(_ event: NSEvent) -> Bool {
        guard !isNativeTextEditing else { return false }
        if activeStitchCanvas?.handleStitchModifierEvent(event) == true { return true }
        guard let editor = activeEditor else { return false }
        editor.handleEditorModifierEvent(event)
        return true
    }

    override func keyUp(with event: NSEvent) {
        if !dispatchKeyRelease(event) { super.keyUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        if !dispatchModifierEvent(event) { super.flagsChanged(with: event) }
    }

    func handleCancellation() -> Bool {
        guard let window = screenshotWindow,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                  modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                  charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53) else { return false }
        return dispatchKeyEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        if !handleCancellation() {
            nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
        }
    }
}

/// Move focus before removing or hiding the view that currently owns it.
@MainActor
enum ScreenshotKeyboardFocus {
    static func editingView(in window: NSWindow) -> NSView? {
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
            return editor.delegate as? NSView
        }
        return window.firstResponder as? NSView
    }

    @discardableResult
    static func moveIfOwned(by owner: NSView, to fallback: NSResponder) -> Bool {
        guard let window = owner.window,
              editingView(in: window)?.isDescendant(of: owner) == true else { return false }
        if let view = fallback as? NSView, view.window !== window { return false }
        return window.makeFirstResponder(fallback)
    }
}
