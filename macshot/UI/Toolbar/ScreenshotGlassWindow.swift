import AppKit
import ObjectiveC

/// Hosts screenshot command routing and native Clear glass without changing
/// keyboard focus, activation, or window ordering. Appearance queries are validated
/// on macOS 26; other releases retain AppKit behavior and use Classic chrome.
class ScreenshotGlassWindow: NSWindow {
    var glassAlwaysActive = false {
        didSet {
            if oldValue != glassAlwaysActive { ScreenshotGlassAppearanceBridge.refresh(self) }
        }
    }

    override var contentView: NSView? {
        didSet {
            // AppKit completes the root responder chain after viewDidMoveToWindow.
            if ScreenshotCommandResponder.forWindow(self) != nil {
                ScreenshotCommandResponder.install(in: self, editor: nil)
            }
        }
    }

    override var contentViewController: NSViewController? {
        didSet {
            if ScreenshotCommandResponder.forWindow(self) != nil {
                ScreenshotCommandResponder.install(in: self, editor: nil)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if firstResponder === self,
           ScreenshotCommandResponder.forWindow(self)?.dispatchKeyEvent(event) == true { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if firstResponder === self,
           ScreenshotCommandResponder.forWindow(self)?.dispatchKeyRelease(event) == true { return }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if firstResponder === self,
           ScreenshotCommandResponder.forWindow(self)?.dispatchModifierEvent(event) == true { return }
        super.flagsChanged(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if ScreenshotCommandResponder.forWindow(self)?.handleCancellation() == true { return }
        nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ScreenshotCommandResponder.forWindow(self)?.performEditorKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    static var supportedAppearance: Bool { ScreenshotGlassAppearanceBridge.supports(NSWindow.self) }

    @objc(hasKeyAppearance) private func glassKeyAppearance() -> Bool {
        ScreenshotGlassAppearanceBridge.value(glassAlwaysActive, window: self, base: NSWindow.self,
            selector: #selector(glassKeyAppearance))
    }

    @objc(_hasKeyAppearance) private func glassPrivateKeyAppearance() -> Bool {
        ScreenshotGlassAppearanceBridge.value(glassAlwaysActive, window: self, base: NSWindow.self,
            selector: #selector(glassPrivateKeyAppearance))
    }

    @objc(_hasActiveAppearance) private func glassActiveAppearance() -> Bool {
        ScreenshotGlassAppearanceBridge.value(glassAlwaysActive, window: self, base: NSWindow.self,
            selector: #selector(glassActiveAppearance))
    }

    @objc(_hasActiveAppearanceIgnoringKeyFocus) private func glassActiveAppearanceIgnoringKeyFocus() -> Bool {
        ScreenshotGlassAppearanceBridge.value(glassAlwaysActive, window: self, base: NSWindow.self,
            selector: #selector(glassActiveAppearanceIgnoringKeyFocus))
    }
}

/// Nonactivating capture panels share the appearance policy of editor windows.
/// Their existing subclasses continue to determine key and main eligibility.
class ScreenshotGlassPanel: NSPanel {
    var glassAlwaysActive = false {
        didSet {
            if oldValue != glassAlwaysActive { ScreenshotGlassAppearanceBridge.refresh(self) }
        }
    }

    override var contentView: NSView? {
        didSet {
            // AppKit completes the root responder chain after viewDidMoveToWindow.
            if ScreenshotCommandResponder.forWindow(self) != nil {
                ScreenshotCommandResponder.install(in: self, editor: nil)
            }
        }
    }

    override var contentViewController: NSViewController? {
        didSet {
            if ScreenshotCommandResponder.forWindow(self) != nil {
                ScreenshotCommandResponder.install(in: self, editor: nil)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if firstResponder === self,
           ScreenshotCommandResponder.forWindow(self)?.dispatchKeyEvent(event) == true { return }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if firstResponder === self,
           ScreenshotCommandResponder.forWindow(self)?.dispatchKeyRelease(event) == true { return }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if firstResponder === self,
           ScreenshotCommandResponder.forWindow(self)?.dispatchModifierEvent(event) == true { return }
        super.flagsChanged(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if ScreenshotCommandResponder.forWindow(self)?.handleCancellation() == true { return }
        nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ScreenshotCommandResponder.forWindow(self)?.performEditorKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    static var supportedAppearance: Bool { ScreenshotGlassAppearanceBridge.supports(NSPanel.self) }

    @objc(hasKeyAppearance) private func glassKeyAppearance() -> Bool {
        ScreenshotGlassAppearanceBridge.value(glassAlwaysActive, window: self, base: NSPanel.self,
            selector: #selector(glassKeyAppearance))
    }

    @objc(_hasKeyAppearance) private func glassPrivateKeyAppearance() -> Bool {
        ScreenshotGlassAppearanceBridge.value(glassAlwaysActive, window: self, base: NSPanel.self,
            selector: #selector(glassPrivateKeyAppearance))
    }

    @objc(_hasActiveAppearance) private func glassActiveAppearance() -> Bool {
        ScreenshotGlassAppearanceBridge.value(glassAlwaysActive, window: self, base: NSPanel.self,
            selector: #selector(glassActiveAppearance))
    }

    @objc(_hasActiveAppearanceIgnoringKeyFocus) private func glassActiveAppearanceIgnoringKeyFocus() -> Bool {
        ScreenshotGlassAppearanceBridge.value(glassAlwaysActive, window: self, base: NSPanel.self,
            selector: #selector(glassActiveAppearanceIgnoringKeyFocus))
    }
}

private enum ScreenshotGlassAppearanceBridge {
    private static let selectors = [
        "hasKeyAppearance", "_hasKeyAppearance", "_hasActiveAppearance",
        "_hasActiveAppearanceIgnoringKeyFocus"
    ].map(NSSelectorFromString)
    private static let windowSupported = supportsForcedAppearance(NSWindow.self)
    private static let panelSupported = supportsForcedAppearance(NSPanel.self)

    static func supports(_ base: AnyClass) -> Bool {
        ObjectIdentifier(base) == ObjectIdentifier(NSPanel.self) ? panelSupported : windowSupported
    }

    private static func supportsForcedAppearance(_ base: AnyClass) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        // Selector presence alone cannot establish the appearance contract on a
        // future major release. Revalidate it before extending native support.
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else { return false }
        return selectors.allSatisfy { class_getInstanceMethod(base, $0) != nil }
    }

    static func value(_ alwaysActive: Bool, window: NSWindow, base: AnyClass, selector: Selector) -> Bool {
        if alwaysActive, supports(base) { return true }
        // Invoke the base implementation. isKeyWindow does not reproduce the
        // appearance policy of a nonactivating NSPanel.
        guard let method = class_getInstanceMethod(base, selector) else { return window.isKeyWindow }
        typealias Query = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Query.self)(window, selector)
    }

    static func refresh(_ window: NSWindow) {
        func invalidate(_ view: NSView) {
            view.viewDidChangeEffectiveAppearance()
            view.needsDisplay = true
            for child in view.subviews { invalidate(child) }
        }
        if let content = window.contentView { invalidate(content) }
        window.invalidateShadow()
    }
}
