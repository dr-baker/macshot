import AppKit
import QuartzCore

/// Keep the menu beside its anchor. A native popover can handle menus that need
/// more room than the existing screenshot window provides.
struct ScreenshotSubmenuPlacement {
    static let connectionSpacing: CGFloat = 12
    let frame: NSRect
    let edge: NSRectEdge

    static func make(size: NSSize, anchor: NSRect, bounds: NSRect,
                     preferredEdge: NSRectEdge, gap: CGFloat = 4, avoiding obstacles: [NSRect] = []) -> Self? {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= bounds.width, size.height <= bounds.height,
              bounds.intersects(anchor) else { return nil }

        let opposite: NSRectEdge
        let remaining: [NSRectEdge]
        switch preferredEdge {
        case .minY: opposite = .maxY; remaining = [.minX, .maxX]
        case .maxY: opposite = .minY; remaining = [.minX, .maxX]
        case .minX: opposite = .maxX; remaining = [.minY, .maxY]
        case .maxX: opposite = .minX; remaining = [.minY, .maxY]
        }

        // Only advance past panels connected to the clicked control. An
        // unrelated panel should make us try another side, rather than detach
        // the submenu from the toolbar that opened it.
        var connected = Array(repeating: false, count: obstacles.count)
        var frontier = [anchor]
        var next = 0
        while next < frontier.count {
            let source = frontier[next]
            next += 1
            for index in obstacles.indices where !connected[index] {
                let target = obstacles[index]
                let dx = max(source.minX - target.maxX, target.minX - source.maxX, 0)
                let dy = max(source.minY - target.maxY, target.minY - source.maxY, 0)
                if dx * dx + dy * dy <= connectionSpacing * connectionSpacing {
                    connected[index] = true
                    frontier.append(target)
                }
            }
        }

        for edge in [preferredEdge, opposite] + remaining {
            let origin: NSPoint
            switch edge {
            case .minY:
                origin = NSPoint(x: min(max(anchor.midX - size.width / 2, bounds.minX), bounds.maxX - size.width),
                                 y: anchor.minY - gap - size.height)
            case .maxY:
                origin = NSPoint(x: min(max(anchor.midX - size.width / 2, bounds.minX), bounds.maxX - size.width),
                                 y: anchor.maxY + gap)
            case .minX:
                origin = NSPoint(x: anchor.minX - gap - size.width,
                                 y: min(max(anchor.midY - size.height / 2, bounds.minY), bounds.maxY - size.height))
            case .maxX:
                origin = NSPoint(x: anchor.maxX + gap,
                                 y: min(max(anchor.midY - size.height / 2, bounds.minY), bounds.maxY - size.height))
            }
            var frame = NSRect(origin: origin, size: size)
            var crossesDisconnectedPanel = false
            for _ in obstacles.indices {
                let intersections = obstacles.indices.filter {
                    obstacles[$0].insetBy(dx: -gap, dy: -gap).intersects(frame)
                }
                guard !intersections.isEmpty else { break }
                if intersections.contains(where: { !connected[$0] }) {
                    crossesDisconnectedPanel = true
                    break
                }
                // Leave the rest of the toolbar reachable, with the same gap
                // at its whole panel edge as at a single anchor button.
                for index in intersections {
                    let obstacle = obstacles[index]
                    switch edge {
                    case .minY: frame.origin.y = min(frame.minY, obstacle.minY - gap - size.height)
                    case .maxY: frame.origin.y = max(frame.minY, obstacle.maxY + gap)
                    case .minX: frame.origin.x = min(frame.minX, obstacle.minX - gap - size.width)
                    case .maxX: frame.origin.x = max(frame.minX, obstacle.maxX + gap)
                    }
                }
            }
            if !crossesDisconnectedPanel, bounds.contains(frame),
               !obstacles.contains(where: { $0.insetBy(dx: -gap, dy: -gap).intersects(frame) }) {
                return Self(frame: frame, edge: edge)
            }
        }
        return nil
    }
}

/// Retains native menu controls in their screenshot window. The wrapper is a
/// sibling of the toolbar panels, so their shared glass backdrop can connect it.
@MainActor
final class ScreenshotSubmenuPresenter {
    let contentView: NSView
    let anchorRect: NSRect
    let preferredEdge: NSRectEdge
    private(set) weak var anchorView: NSView?
    private(set) var size: NSSize
    private(set) var wrapper: ScreenshotPanelView
    var onNeedsNativePresentation: (() -> Void)?

    private weak var root: NSView?
    private weak var parentWindow: NSWindow?
    private(set) weak var previousResponder: NSResponder?
    private var resizeObserver: NSObjectProtocol?
    private var closeObserver: NSObjectProtocol?

    init?(contentView: NSView, size: NSSize, relativeTo rect: NSRect,
          of anchorView: NSView, preferredEdge: NSRectEdge) {
        guard ScreenshotPanelStyle.load().material != .classic, ScreenshotGlassAvailability.isAvailable,
              let window = anchorView.window,
              window is ScreenshotGlassWindow || window is ScreenshotGlassPanel,
              let (root, placement) = Self.findPlacement(size: size, rect: rect,
                  anchorView: anchorView, window: window, preferredEdge: preferredEdge) else { return nil }

        self.contentView = contentView
        self.size = size
        self.anchorRect = rect
        self.anchorView = anchorView
        self.preferredEdge = preferredEdge
        self.root = root
        self.parentWindow = window
        self.previousResponder = Self.editingResponder(in: window)
        self.wrapper = ScreenshotSubmenuView(frame: placement.frame)
        wrapper.animatesGlassPresentation = true
        // Keep the submenu as its own shape. Sharing the toolbar's union ID
        // expands the union into a large rectangle around both control bounds.
        wrapper.identifier = NSUserInterfaceItemIdentifier("screenshot.submenu")
        wrapper.setAccessibilityRole(.group)
        wrapper.setAccessibilityLabel(L("Tool options"))
        contentView.frame = NSRect(origin: .zero, size: size)
        wrapper.addSubview(contentView)
        root.addSubview(wrapper, positioned: .above, relativeTo: nil)
        reveal(from: placement.edge, rootIsFlipped: root.isFlipped)

        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
            object: window, queue: .main) { [weak self] _ in
                self?.reposition()
            }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak self] _ in
                guard self?.isVisible == true else { return }
                PopoverHelper.dismiss()
            }
    }

    var isVisible: Bool {
        guard let parentWindow else { return false }
        return wrapper.superview != nil && wrapper.window === parentWindow
    }

    func contains(screenPoint: NSPoint) -> Bool {
        guard isVisible, let window = parentWindow else { return false }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return wrapper.bounds.contains(wrapper.convert(windowPoint, from: nil))
    }

    func contains(point: NSPoint, in view: NSView) -> Bool {
        guard isVisible, view.window === parentWindow else { return false }
        return wrapper.bounds.contains(wrapper.convert(point, from: view))
    }

    func hitTest(at point: NSPoint, in view: NSView) -> NSView? {
        guard contains(point: point, in: view), let root = wrapper.superview else { return nil }
        return wrapper.hitTest(root.convert(point, from: view))
    }

    /// A fitting resize changes frames only, including during native field editing.
    @discardableResult
    func resize(_ content: NSView, to size: NSSize) -> Bool {
        guard content === contentView, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return false }
        self.size = size
        contentView.setFrameSize(size)
        reposition()
        return true
    }

    func dismiss(restoreFocus: Bool = true) {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        resizeObserver = nil
        closeObserver = nil
        let window = parentWindow
        let responder = window.flatMap(Self.editingResponder)
        let wasEditingMenu = (responder as? NSView)?.isDescendant(of: wrapper) == true
        if restoreFocus, wasEditingMenu, let previousResponder,
           let previousView = previousResponder as? NSView, previousView.window === window {
            window?.makeFirstResponder(previousResponder)
        } else if wasEditingMenu {
            window?.makeFirstResponder(nil)
        }
        wrapper.removeFromSuperview()
        contentView.alphaValue = 1
        contentView.setFrameOrigin(.zero)
    }

    /// Native field editors live directly under the window, rather than below
    /// their text field. Use the editing control when saving and restoring focus.
    static func editingResponder(in window: NSWindow) -> NSResponder? {
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           let control = editor.delegate as? NSResponder { return control }
        return window.firstResponder
    }

    private func reposition() {
        guard let root, let anchorView, let window = parentWindow else { return }
        guard let placement = Self.placement(size: size, rect: anchorRect, anchorView: anchorView,
            root: root, window: window, preferredEdge: preferredEdge) else {
            onNeedsNativePresentation?()
            return
        }
        wrapper.frame = placement.frame
    }

    private func reveal(from edge: NSRectEdge, rootIsFlipped: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduceMotion {
            let verticalDirection: CGFloat = rootIsFlipped ? -1 : 1
            let offset: NSPoint
            switch edge {
            case .minY: offset = NSPoint(x: 0, y: 4 * verticalDirection)
            case .maxY: offset = NSPoint(x: 0, y: -4 * verticalDirection)
            case .minX: offset = NSPoint(x: 4, y: 0)
            case .maxX: offset = NSPoint(x: -4, y: 0)
            }
            contentView.setFrameOrigin(offset)
        }
        contentView.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.08 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().alphaValue = 1
            contentView.animator().setFrameOrigin(.zero)
        }
    }

    private static func findPlacement(size: NSSize, rect: NSRect, anchorView: NSView,
                                      window: NSWindow, preferredEdge: NSRectEdge) -> (NSView, ScreenshotSubmenuPlacement)? {
        var roots: [NSView] = []
        var ancestor: NSView? = anchorView
        while let view = ancestor {
            if view is ScreenshotPanelView, let parent = view.superview {
                roots.append(parent)
                break
            }
            ancestor = view.superview
        }
        if let content = window.contentView, !roots.contains(where: { $0 === content }) { roots.append(content) }
        for root in roots {
            if let placement = placement(size: size, rect: rect, anchorView: anchorView,
                root: root, window: window, preferredEdge: preferredEdge) { return (root, placement) }
        }
        return nil
    }

    private static func placement(size: NSSize, rect: NSRect, anchorView: NSView,
                                  root: NSView, window: NSWindow, preferredEdge: NSRectEdge) -> ScreenshotSubmenuPlacement? {
        guard let content = window.contentView else { return nil }
        let bounds = root.visibleRect.intersection(root.convert(content.bounds, from: content)).insetBy(dx: 8, dy: 8)
        var edge = preferredEdge
        if anchorView.isFlipped != root.isFlipped {
            if edge == .minY { edge = .maxY }
            else if edge == .maxY { edge = .minY }
        }
        let obstacles = root.subviews.compactMap { $0 as? ScreenshotPanelView }.filter {
            !($0 is ScreenshotSubmenuView) && !($0 is ScreenshotTooltipView)
                && !($0 is ScreenshotTextPanelView) && !$0.isHiddenOrHasHiddenAncestor
        }.map(\.frame)
        return ScreenshotSubmenuPlacement.make(size: size, anchor: root.convert(rect, from: anchorView),
            bounds: bounds, preferredEdge: edge, avoiding: obstacles)
    }
}

private final class ScreenshotSubmenuView: ScreenshotPanelView {
    override var joinsAdjacentGlass: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func cancelOperation(_ sender: Any?) { PopoverHelper.dismiss() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelOperation(self)
            return
        }
        super.keyDown(with: event)
    }
}
