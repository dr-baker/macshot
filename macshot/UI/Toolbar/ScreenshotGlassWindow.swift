import AppKit
import ObjectiveC

/// Keeps native Clear glass active without changing keyboard focus, activation,
/// window ordering, or event routing. The private appearance queries are validated
/// on macOS 26; other releases retain AppKit behavior and use Classic chrome.
class ScreenshotGlassWindow: NSWindow {
    var glassAlwaysActive = false {
        didSet {
            if oldValue != glassAlwaysActive { ScreenshotGlassAppearanceBridge.refresh(self) }
        }
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
