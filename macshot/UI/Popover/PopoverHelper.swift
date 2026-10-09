import Cocoa

/// Track the control that opened a popover even when AppKit dismisses it before its action runs.
struct PopoverToggleState {
    private weak var activeAnchor: NSView?
    private weak var dismissedAnchor: NSView?
    private(set) var dismissedAt: Date = .distantPast

    mutating func opened(from anchor: NSView) {
        activeAnchor = anchor
        dismissedAnchor = nil
        dismissedAt = .distantPast
    }
    mutating func dismissed(at now: Date = Date()) {
        dismissedAnchor = activeAnchor
        activeAnchor = nil
        dismissedAt = now
    }
    func shouldClose(from anchor: NSView?, isVisible: Bool, at now: Date = Date()) -> Bool {
        let recent = now.timeIntervalSince(dismissedAt) < 0.25
        guard let anchor else { return isVisible || recent }
        if isVisible { return activeAnchor === anchor }
        return recent && dismissedAnchor === anchor
    }
}

/// A native popover borrows key focus from its screenshot window. Return it
/// only when closing the menu still owns that focus.
@MainActor
final class ScreenshotPopoverFocus {
    private weak var parentWindow: NSWindow?
    private weak var previousResponder: NSResponder?
    weak var popoverWindow: NSWindow?
    private let appWasActive: Bool
    private let frontmostProcessID: pid_t?
    private var shouldRestoreKey = false

    init(parentWindow: NSWindow?, previousResponder: NSResponder? = nil) {
        self.parentWindow = parentWindow
        self.previousResponder = previousResponder ?? parentWindow.flatMap(ScreenshotSubmenuPresenter.editingResponder)
        self.appWasActive = NSApp.isActive
        self.frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func prepareToClose(restoreFocus: Bool = true) {
        shouldRestoreKey = restoreFocus && popoverWindow?.isKeyWindow == true
    }

    func restore(currentKeyWindow: NSWindow? = NSApp.keyWindow,
                 frontmostProcessID: pid_t? = NSWorkspace.shared.frontmostApplication?.processIdentifier) {
        let shouldRestore = shouldRestoreKey
        shouldRestoreKey = false
        guard shouldRestore, let parentWindow, parentWindow.isVisible,
              !appWasActive || NSApp.isActive,
              frontmostProcessID == self.frontmostProcessID,
              currentKeyWindow == nil || currentKeyWindow === popoverWindow || currentKeyWindow === parentWindow else { return }
        parentWindow.makeKey()

        // An outside click within the screenshot may already have focused a
        // different control. Preserve it instead of replacing an active editor.
        let current = ScreenshotSubmenuPresenter.editingResponder(in: parentWindow)
        if let currentView = current as? NSView, currentView.window === parentWindow,
           current !== previousResponder { return }
        if let previousView = previousResponder as? NSView, previousView.window === parentWindow {
            parentWindow.makeFirstResponder(previousView)
        }
    }
}

/// Show screenshot menus beside their toolbar controls. Glass menus share the
/// existing window; native popovers handle classic panels and smaller windows.
enum PopoverHelper {

    private static var toggleState = PopoverToggleState()
    private static var activePopover: NSPopover?
    private static var anchorView: NSView?
    private static var localMouseDownMonitor: Any?
    private static var globalMouseDownMonitor: Any?
    private static var activeSubmenu: ScreenshotSubmenuPresenter?
    private static var nativeFocus: ScreenshotPopoverFocus?

    /// Show a popover with the given content view, anchored relative to a rect in the given parent view.
    static func show(_ contentView: NSView, size: NSSize, relativeTo rect: NSRect, of view: NSView, preferredEdge: NSRectEdge = .minY) {
        dismiss()
        if showInline(contentView, size: size, relativeTo: rect, of: view, preferredEdge: preferredEdge) { return }

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = size
        popover.animates = true
        popover.appearance = ToolbarLayout.appearance

        let vc = NSViewController()
        vc.view = cursorWrapped(contentView, parentWindow: view.window)
        popover.contentViewController = vc
        popover.delegate = AnchorCleanupDelegate.shared
        toggleState.opened(from: view)
        activePopover = popover
        nativeFocus = ScreenshotPopoverFocus(parentWindow: view.window)
        popover.show(relativeTo: rect, of: view, preferredEdge: preferredEdge)
        configureShownPopover(popover, parentWindow: view.window)
        installOutsideClickMonitors()
    }

    /// Expand the native options stack away from the screenshot or projected
    /// paper. The footprint belongs to `referenceView`'s coordinate space.
    static func showToolbarTray(_ contentView: NSView, size: NSSize, relativeTo rect: NSRect,
                                of view: NSView, avoiding paperRect: NSRect, in referenceView: NSView) {
        dismiss()
        if showInline(contentView, size: size, relativeTo: rect, of: view, preferredEdge: .minY,
                      avoiding: paperRect, in: referenceView) { return }
        // An anchor that is no longer mounted cannot have an attached tray.
        // Retain the existing native presentation for unsupported host windows.
        show(contentView, size: size, relativeTo: rect, of: view, preferredEdge: .minY)
    }

    /// Show a popover anchored to a specific point in a view (for overlay mode where buttons aren't real views).

    static func showAtPoint(_ contentView: NSView, size: NSSize, at point: NSPoint, in parentView: NSView, preferredEdge: NSRectEdge = .minY) {
        dismiss()
        let rect = NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        if showInline(contentView, size: size, relativeTo: rect, of: parentView, preferredEdge: preferredEdge) { return }

        // Create a tiny invisible anchor view at the point
        let anchor = NSView(frame: rect)
        parentView.addSubview(anchor)
        anchorView = anchor

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = size
        popover.animates = true
        popover.appearance = ToolbarLayout.appearance

        let vc = NSViewController()
        vc.view = cursorWrapped(contentView, parentWindow: parentView.window)
        popover.contentViewController = vc
        popover.delegate = AnchorCleanupDelegate.shared
        toggleState.opened(from: parentView)
        activePopover = popover
        nativeFocus = ScreenshotPopoverFocus(parentWindow: parentView.window)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
        configureShownPopover(popover, parentWindow: parentView.window)
        installOutsideClickMonitors()
    }

    /// Time the most recent popover was dismissed — used to implement
    /// click-the-anchor-to-toggle-closed (the outside click auto-dismisses a
    /// semitransient popover before the button handler runs, so the handler
    /// checks "was one just dismissed?" instead of "is one visible?").
    static var lastDismissedAt: Date { toggleState.dismissedAt }

    static func dismiss(restoreFocus: Bool = true) {
        let submenu = activeSubmenu
        if submenu?.isVisible == true { toggleState.dismissed() }
        activeSubmenu = nil
        submenu?.dismiss(restoreFocus: restoreFocus)
        let popover = activePopover
        if popover?.isShown == true { toggleState.dismissed() }
        let focus = nativeFocus
        focus?.prepareToClose(restoreFocus: restoreFocus)
        nativeFocus = nil
        activePopover = nil
        (popover?.contentViewController?.view as? ArrowCursorView)?.endCommandScope()
        popover?.close()
        focus?.restore()
        removeOutsideClickMonitors()
        anchorView?.removeFromSuperview()
        anchorView = nil
    }

    /// True if a popover was dismissed within the last `seconds` (default 0.25s).
    static func wasRecentlyDismissed(within seconds: TimeInterval = 0.25) -> Bool {
        Date().timeIntervalSince(lastDismissedAt) < seconds
    }

    /// Toggle helper for anchor buttons that open a popover. Clicking the same
    /// button that opened a popover should CLOSE it (and not reopen).
    ///
    /// The catch: a semitransient popover's outside-click monitor fires on the
    /// same mouseDown and dismisses it BEFORE the button's action runs, so by the
    /// time the handler checks `isVisible` it's already false and the handler
    /// would reopen. A recent dismissal belongs only to the anchor that opened
    /// that popover. Clicking another anchor opens its control immediately.
    /// Returns true when this anchor closed its own popover.
    static func toggleClosedIfOpen(anchorView: NSView? = nil) -> Bool {
        if toggleState.shouldClose(from: anchorView, isVisible: isVisible) {
            dismiss()
            return true
        }
        return false
    }

    static func willClose(_ popover: NSPopover) {
        (popover.contentViewController?.view as? ArrowCursorView)?.endCommandScope()
        guard activePopover === popover else { return }
        nativeFocus?.prepareToClose()
    }

    static func didClose(_ popover: NSPopover) {
        guard activePopover === popover else { return }
        toggleState.dismissed()
        let focus = nativeFocus
        nativeFocus = nil
        activePopover = nil
        removeOutsideClickMonitors()
        anchorView?.removeFromSuperview()
        anchorView = nil
        focus?.restore()
    }

    static var isVisible: Bool {
        if activeSubmenu?.isVisible == true { return true }
        return activePopover?.isShown == true
    }

    /// Resize cached content without reopening its popover or replacing its responder chain.
    static func resize(_ contentView: NSView, to size: NSSize) {
        if let submenu = activeSubmenu {
            submenu.resize(contentView, to: size)
            return
        }
        guard let popover = activePopover else { return }
        resize(contentView, to: size, in: popover)
    }

    static func resize(_ contentView: NSView, to size: NSSize, in popover: NSPopover) {
        guard let wrapper = popover.contentViewController?.view,
              contentView.superview === wrapper else { return }
        contentView.setFrameSize(size)
        wrapper.setFrameSize(size)
        popover.contentSize = size
    }

    static var isMouseInsidePopover: Bool {
        if let submenu = activeSubmenu { return submenu.contains(screenPoint: NSEvent.mouseLocation) }
        guard let popover = activePopover, popover.isShown,
              let popoverWindow = popover.contentViewController?.view.window else { return false }
        return popoverWindow.frame.contains(NSEvent.mouseLocation)
    }

    /// Overlay hit testing calls this before routing a click to its canvas.
    /// The point is in the caller's local coordinate space.
    static func hitTestInline(at point: NSPoint, in view: NSView) -> NSView? {
        return activeSubmenu?.hitTest(at: point, in: view)
    }

    static func containsInline(point: NSPoint, in view: NSView) -> Bool {
        return activeSubmenu?.contains(point: point, in: view) == true
    }

    /// Preserve a menu's keyboard ownership before it rebuilds or hides the
    /// focused control. A control in another window keeps its own responder.
    @discardableResult
    static func moveFocusBeforeChanging(_ owner: NSView) -> Bool {
        var ancestor = owner.superview
        while let view = ancestor {
            if view is ArrowCursorView || view === activeSubmenu?.wrapper {
                return ScreenshotKeyboardFocus.moveIfOwned(by: owner, to: view)
            }
            ancestor = view.superview
        }
        return false
    }

    private static func showInline(_ contentView: NSView, size: NSSize, relativeTo rect: NSRect,
                                   of view: NSView, preferredEdge: NSRectEdge,
                                   avoiding paperRect: NSRect? = nil, in referenceView: NSView? = nil) -> Bool {
        guard let submenu = ScreenshotSubmenuPresenter(contentView: contentView, size: size,
            relativeTo: rect, of: view, preferredEdge: preferredEdge,
            avoiding: paperRect, in: referenceView) else { return false }
        activeSubmenu = submenu
        toggleState.opened(from: view)
        submenu.onNeedsNativePresentation = { [weak submenu] in
            guard let submenu else { return }
            showNativeAfterWindowResize(submenu)
        }
        installOutsideClickMonitors()
        return true
    }

    /// A smaller window can stop fitting a menu that was already open. Retain
    /// its content controls while letting AppKit position the native popover.
    private static func showNativeAfterWindowResize(_ submenu: ScreenshotSubmenuPresenter) {
        guard activeSubmenu === submenu, let anchor = submenu.anchorView else { return }
        let responder = anchor.window.flatMap(ScreenshotSubmenuPresenter.editingResponder)
        let menuResponder = (responder as? NSView)?.isDescendant(of: submenu.contentView) == true ? responder : nil
        let focus = ScreenshotPopoverFocus(parentWindow: anchor.window,
            previousResponder: submenu.previousResponder)
        activeSubmenu = nil
        submenu.dismiss(restoreFocus: false)
        removeOutsideClickMonitors()

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = submenu.size
        popover.animates = true
        popover.appearance = ToolbarLayout.appearance
        let controller = NSViewController()
        controller.view = cursorWrapped(submenu.contentView, parentWindow: anchor.window)
        popover.contentViewController = controller
        popover.delegate = AnchorCleanupDelegate.shared
        activePopover = popover
        nativeFocus = focus
        popover.show(relativeTo: submenu.anchorRect, of: anchor, preferredEdge: submenu.preferredEdge)
        configureShownPopover(popover, parentWindow: anchor.window)
        if let menuResponder { submenu.contentView.window?.makeFirstResponder(menuResponder) }
        installOutsideClickMonitors()
    }

    /// Wrap content view so the popover always shows an arrow cursor regardless of active tool.
    /// Sets appearance to match toolbar background brightness.
    private static func cursorWrapped(_ contentView: NSView, parentWindow: NSWindow?) -> NSView {
        let wrapper = ArrowCursorView(frame: contentView.frame)
        wrapper.parentWindow = parentWindow
        wrapper.onCancel = { dismiss() }
        contentView.frame.origin = .zero
        wrapper.addSubview(contentView)
        return wrapper
    }

    /// Finish window-level setup after AppKit has created the private popover
    /// window. Capture popovers may open while macshot itself remains inactive.
    /// Making the popover window key lets its first click interact with controls
    /// and preserves the capture overlay's nonactivating behavior.
    private static func configureShownPopover(_ popover: NSPopover, parentWindow: NSWindow?) {
        guard popover.isShown,
              let popoverWindow = popover.contentViewController?.view.window else { return }

        let parentLevel = parentWindow?.level ?? .normal
        if parentLevel.rawValue > NSWindow.Level.normal.rawValue {
            popoverWindow.level = NSWindow.Level(parentLevel.rawValue + 1)
        }

        if let parentWindow {
            popoverWindow.collectionBehavior.formUnion(
                parentWindow.collectionBehavior.intersection([.canJoinAllSpaces, .fullScreenAuxiliary]))
        }

        (popover.contentViewController?.view as? ArrowCursorView)?.beginCommandScope()
        nativeFocus?.popoverWindow = popoverWindow
        popoverWindow.makeKey()
        if popoverWindow.firstResponder == nil || popoverWindow.firstResponder === popoverWindow {
            popoverWindow.makeFirstResponder(popover.contentViewController?.view)
        }
    }

    private static func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if shouldDismiss(forMouseDownAt: NSEvent.mouseLocation) {
                let parentWindow = activeSubmenu?.anchorView?.window
                    ?? (activePopover?.contentViewController?.view as? ArrowCursorView)?.parentWindow
                dismiss(restoreFocus: event.window === parentWindow)
            }
            return event
        }
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in
            DispatchQueue.main.async {
                if shouldDismiss(forMouseDownAt: NSEvent.mouseLocation) {
                    dismiss(restoreFocus: false)
                }
            }
        }
    }

    private static func removeOutsideClickMonitors() {
        if let localMouseDownMonitor {
            NSEvent.removeMonitor(localMouseDownMonitor)
            self.localMouseDownMonitor = nil
        }
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
    }

    private static func shouldDismiss(forMouseDownAt screenPoint: NSPoint) -> Bool {
        if let submenu = activeSubmenu {
            return submenu.isVisible && !submenu.contains(screenPoint: screenPoint)
        }
        guard let popover = activePopover, popover.isShown else { return false }
        guard let popoverWindow = popover.contentViewController?.view.window else { return true }
        return !popoverWindow.frame.contains(screenPoint)
    }
}

/// NSView that forces the arrow cursor over its entire bounds.
final class ArrowCursorView: ScreenshotPanelView {
    weak var parentWindow: NSWindow?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        beginCommandScope()
    }

    func beginCommandScope() {
        guard let window else { return }
        let commands = ScreenshotCommandResponder.install(in: window, editor: nil, startingAt: self)
        commands.linkEditor(from: parentWindow)
        commands.setTransientScope(owner: self) { [weak self] in self?.onCancel?() }
        ScreenshotCommandResponder.forWindow(parentWindow)?.setTransientScope(owner: self) { [weak self] in
            self?.onCancel?()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { endCommandScope() }
        super.viewWillMove(toWindow: newWindow)
    }

    func endCommandScope() {
        ScreenshotCommandResponder.forWindow(window)?.removeTransientScope(owner: self)
        ScreenshotCommandResponder.forWindow(parentWindow)?.removeTransientScope(owner: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if ScreenshotCommandResponder.forWindow(window)?.performEditorKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

}

// Cleans up the invisible anchor view when the popover closes
private class AnchorCleanupDelegate: NSObject, NSPopoverDelegate {
    static let shared = AnchorCleanupDelegate()
    func popoverWillClose(_ notification: Notification) {
        if let popover = notification.object as? NSPopover { PopoverHelper.willClose(popover) }
    }
    func popoverDidClose(_ notification: Notification) {
        if let popover = notification.object as? NSPopover { PopoverHelper.didClose(popover) }
    }
}
