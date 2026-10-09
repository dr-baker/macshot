import AppKit
import QuartzCore

/// Keep the menu beside its anchor. A native popover can handle menus that need
/// more room than the existing screenshot window provides.
struct ScreenshotSubmenuPlacement {
    static let connectionSpacing: CGFloat = 12
    let frame: NSRect
    let edge: NSRectEdge

    static func make(size: NSSize, anchor: NSRect, bounds: NSRect,
                     preferredEdge: NSRectEdge, gap: CGFloat = 4, avoiding obstacles: [NSRect] = [],
                     candidateEdges: [NSRectEdge]? = nil) -> Self? {
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

        for edge in candidateEdges ?? [preferredEdge, opposite] + remaining {
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
                let connectedIntersections = intersections.filter { connected[$0] }
                if connectedIntersections.isEmpty {
                    crossesDisconnectedPanel = true
                    break
                }
                // Leave the rest of the toolbar reachable, with the same gap
                // at its whole panel edge as at a single anchor button.
                for index in connectedIntersections {
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

    /// A toolbar tray extends away from the paper. Smaller windows retain the
    /// same controls in a scroll viewport instead of opening another window.
    static func makeToolbarTray(size: NSSize, anchor: NSRect, bounds: NSRect,
                                avoiding paper: NSRect, obstacles: [NSRect], gap: CGFloat = 4) -> Self? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0, bounds.intersects(anchor) else { return nil }
        let edges = outwardEdges(anchor: anchor, paper: paper)
        let fittedSize = NSSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        for edge in edges {
            if let placement = make(size: fittedSize, anchor: anchor, bounds: bounds,
                preferredEdge: edge, gap: gap, avoiding: obstacles, candidateEdges: [edge]),
               let clearPlacement = clearingPaper(placement, anchor: anchor, bounds: bounds,
                    paper: paper, obstacles: obstacles, gap: gap) {
                return clearPlacement
            }
        }

        let connected = connectedToolbarBounds(anchor: anchor, obstacles: obstacles)
        var candidates: [(Self, CGFloat)] = []
        for protectPaper in [true, false] {
            candidates.removeAll(keepingCapacity: true)
            for (priority, edge) in edges.enumerated() {
                let viewport = viewportSize(size: fittedSize, anchor: anchor, connected: connected,
                    bounds: bounds, paper: protectPaper ? paper : nil, edge: edge, gap: gap)
                // Keep a useful viewport wherever there is room. The final
                // pass also supports very short screens and full-window paper.
                let minimumWidth = min(size.width, protectPaper ? 120 : 44)
                let minimumHeight = min(size.height, protectPaper ? 96 : 44)
                guard viewport.width >= minimumWidth, viewport.height >= minimumHeight,
                      let placement = make(size: viewport, anchor: anchor, bounds: bounds,
                        preferredEdge: edge, gap: gap, avoiding: obstacles, candidateEdges: [edge]) else { continue }
                let intersection = placement.frame.intersection(paper)
                let coveredArea = intersection.isNull ? 0 : intersection.width * intersection.height
                if protectPaper && coveredArea > 0 { continue }
                let visibleFraction = viewport.width * viewport.height / (size.width * size.height)
                let coveredFraction = coveredArea / (viewport.width * viewport.height)
                let score = visibleFraction - coveredFraction * 4 - CGFloat(priority) * 0.015
                candidates.append((placement, score))
            }
            if let best = candidates.max(by: { $0.1 < $1.1 }) { return best.0 }
        }
        return nil
    }

    private static func clearingPaper(_ placement: Self, anchor: NSRect, bounds: NSRect,
                                       paper: NSRect, obstacles: [NSRect], gap: CGFloat) -> Self? {
        if !placement.frame.insetBy(dx: -gap, dy: -gap).intersects(paper) { return placement }
        var candidates = [placement.frame, placement.frame]
        if placement.edge == .minY || placement.edge == .maxY {
            candidates[0].origin.x = paper.minX - gap - placement.frame.width
            candidates[1].origin.x = paper.maxX + gap
        } else {
            candidates[0].origin.y = paper.minY - gap - placement.frame.height
            candidates[1].origin.y = paper.maxY + gap
        }
        for frame in candidates {
            let remainsAttached = placement.edge == .minY || placement.edge == .maxY
                ? frame.minX <= anchor.midX && frame.maxX >= anchor.midX
                : frame.minY <= anchor.midY && frame.maxY >= anchor.midY
            if remainsAttached, bounds.contains(frame), !frame.intersects(paper),
               !obstacles.contains(where: { $0.insetBy(dx: -gap, dy: -gap).intersects(frame) }) {
                return Self(frame: frame, edge: placement.edge)
            }
        }
        return nil
    }

    private static func outwardEdges(anchor: NSRect, paper: NSRect) -> [NSRectEdge] {
        let horizontal = anchor.midX < paper.midX ? NSRectEdge.minX : .maxX
        let vertical = anchor.midY < paper.midY ? NSRectEdge.minY : .maxY
        let primary: NSRectEdge
        if anchor.maxY <= paper.minY { primary = .minY }
        else if anchor.minY >= paper.maxY { primary = .maxY }
        else if anchor.maxX <= paper.minX { primary = .minX }
        else if anchor.minX >= paper.maxX { primary = .maxX }
        else {
            let distances: [(NSRectEdge, CGFloat)] = [(.minY, abs(anchor.midY - paper.minY)),
                (.maxY, abs(paper.maxY - anchor.midY)), (.minX, abs(anchor.midX - paper.minX)),
                (.maxX, abs(paper.maxX - anchor.midX))]
            primary = distances.min(by: { $0.1 < $1.1 })?.0 ?? .minY
        }
        let order: [NSRectEdge]
        switch primary {
        case .minY: order = [.minY, horizontal, horizontal == .minX ? .maxX : .minX, .maxY]
        case .maxY: order = [.maxY, horizontal, horizontal == .minX ? .maxX : .minX, .minY]
        case .minX: order = [.minX, vertical, vertical == .minY ? .maxY : .minY, .maxX]
        case .maxX: order = [.maxX, vertical, vertical == .minY ? .maxY : .minY, .minX]
        @unknown default: order = [.minY, .minX, .maxX, .maxY]
        }
        return order
    }

    private static func connectedToolbarBounds(anchor: NSRect, obstacles: [NSRect]) -> NSRect {
        var connected = anchor
        var remaining = obstacles
        var frontier = [anchor]
        while let source = frontier.popLast() {
            for index in remaining.indices.reversed() {
                let target = remaining[index]
                let dx = max(source.minX - target.maxX, target.minX - source.maxX, 0)
                let dy = max(source.minY - target.maxY, target.minY - source.maxY, 0)
                if dx * dx + dy * dy <= connectionSpacing * connectionSpacing {
                    connected = connected.union(target)
                    frontier.append(target)
                    remaining.remove(at: index)
                }
            }
        }
        return connected
    }

    private static func viewportSize(size: NSSize, anchor: NSRect, connected: NSRect, bounds: NSRect,
                                     paper: NSRect?, edge: NSRectEdge, gap: CGFloat) -> NSSize {
        var width = size.width
        var height = size.height
        if edge == .minY || edge == .maxY {
            let x = min(max(anchor.midX - width / 2, bounds.minX), bounds.maxX - width)
            let departure = edge == .minY ? connected.minY - gap : connected.maxY + gap
            var limit = edge == .minY ? bounds.minY : bounds.maxY
            if let paper, x + width > paper.minX - gap, x < paper.maxX + gap {
                if edge == .minY, departure > paper.minY - gap { limit = max(limit, paper.maxY + gap) }
                if edge == .maxY, departure < paper.maxY + gap { limit = min(limit, paper.minY - gap) }
            }
            height = min(height, max(0, edge == .minY ? departure - limit : limit - departure))
        } else {
            let y = min(max(anchor.midY - height / 2, bounds.minY), bounds.maxY - height)
            let departure = edge == .minX ? connected.minX - gap : connected.maxX + gap
            var limit = edge == .minX ? bounds.minX : bounds.maxX
            if let paper, y + height > paper.minY - gap, y < paper.maxY + gap {
                if edge == .minX, departure > paper.minX - gap { limit = max(limit, paper.maxX + gap) }
                if edge == .maxX, departure < paper.maxX + gap { limit = min(limit, paper.minX - gap) }
            }
            width = min(width, max(0, edge == .minX ? departure - limit : limit - departure))
        }
        return NSSize(width: width, height: height)
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
    private weak var paperReferenceView: NSView?
    private let paperRect: NSRect?
    private let scrollViewport: NSScrollView?
    var isToolbarTray: Bool { paperRect != nil }

    init?(contentView: NSView, size: NSSize, relativeTo rect: NSRect,
          of anchorView: NSView, preferredEdge: NSRectEdge,
          avoiding paperRect: NSRect? = nil, in paperReferenceView: NSView? = nil) {
        let isTray = paperRect != nil && paperReferenceView != nil
        guard (isTray || (ScreenshotPanelStyle.load().material != .classic && ScreenshotGlassAvailability.isAvailable)),
              let window = anchorView.window,
              (!isTray || paperReferenceView?.window === window),
              (isTray || window is ScreenshotGlassWindow || window is ScreenshotGlassPanel),
              let (root, placement) = Self.findPlacement(size: size, rect: rect,
                  anchorView: anchorView, window: window, preferredEdge: preferredEdge,
                  paperRect: paperRect, paperReferenceView: paperReferenceView) else { return nil }

        self.contentView = contentView
        self.size = size
        self.anchorRect = rect
        self.anchorView = anchorView
        self.preferredEdge = preferredEdge
        self.root = root
        self.parentWindow = window
        self.paperRect = isTray ? paperRect : nil
        self.paperReferenceView = paperReferenceView
        self.scrollViewport = isTray ? NSScrollView(frame: NSRect(origin: .zero, size: placement.frame.size)) : nil
        self.previousResponder = Self.editingResponder(in: window)
        self.wrapper = ScreenshotSubmenuView(frame: placement.frame)
        wrapper.animatesGlassPresentation = !isTray
        // Keep the submenu as its own shape. Sharing the toolbar's union ID
        // expands the union into a large rectangle around both control bounds.
        wrapper.identifier = NSUserInterfaceItemIdentifier(isTray ? "screenshot.toolbar-tray" : "screenshot.submenu")
        wrapper.setAccessibilityRole(.group)
        wrapper.setAccessibilityLabel(L("Tool options"))
        contentView.frame = NSRect(origin: .zero, size: size)
        if let scrollViewport {
            scrollViewport.drawsBackground = false
            scrollViewport.contentView.drawsBackground = false
            scrollViewport.borderType = .noBorder
            scrollViewport.scrollerStyle = .overlay
            scrollViewport.autohidesScrollers = true
            scrollViewport.documentView = contentView
            wrapper.addSubview(scrollViewport)
            configureViewport(firstPresentation: true)
        } else { wrapper.addSubview(contentView) }
        root.addSubview(wrapper, positioned: .above, relativeTo: nil)
        for group in root.subviews.compactMap({ $0 as? ScreenshotGlassGroupView }) {
            group.prepareForPresentation()
        }
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
        scrollViewport?.documentView = nil
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
            root: root, window: window, preferredEdge: preferredEdge,
            paperRect: paperRect, paperReferenceView: paperReferenceView) else {
            onNeedsNativePresentation?()
            return
        }
        wrapper.frame = placement.frame
        configureViewport(firstPresentation: false)
    }

    private func configureViewport(firstPresentation: Bool) {
        guard let scrollViewport else { return }
        scrollViewport.frame = wrapper.bounds
        scrollViewport.hasVerticalScroller = size.height > wrapper.bounds.height
        scrollViewport.hasHorizontalScroller = size.width > wrapper.bounds.width
        scrollViewport.tile()
        let clip = scrollViewport.contentView
        let maximumX = max(0, size.width - clip.bounds.width)
        let maximumY = max(0, size.height - clip.bounds.height)
        let origin = firstPresentation
            ? NSPoint(x: 0, y: contentView.isFlipped ? 0 : maximumY)
            : NSPoint(x: min(max(0, clip.bounds.minX), maximumX), y: min(max(0, clip.bounds.minY), maximumY))
        clip.scroll(to: origin)
        scrollViewport.reflectScrolledClipView(clip)
    }

    private func reveal(from edge: NSRectEdge, rootIsFlipped: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if isToolbarTray {
            // The shared material is ready at insertion. A small content reveal
            // gives the tray an anchor without fading glass and controls apart.
            guard !reduceMotion else { return }
            let content = scrollViewport ?? contentView
            let translation = CATransform3DMakeTranslation(edge == .minX ? 3 : edge == .maxX ? -3 : 0,
                edge == .minY ? 3 : edge == .maxY ? -3 : 0, 0)
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: translation)
            animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            animation.duration = 0.14
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            content.wantsLayer = true
            content.layer?.add(animation, forKey: "toolbar-tray-reveal")
            return
        }
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
                                      window: NSWindow, preferredEdge: NSRectEdge,
                                      paperRect: NSRect? = nil, paperReferenceView: NSView? = nil) -> (NSView, ScreenshotSubmenuPlacement)? {
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
                root: root, window: window, preferredEdge: preferredEdge,
                paperRect: paperRect, paperReferenceView: paperReferenceView) { return (root, placement) }
        }
        return nil
    }

    private static func placement(size: NSSize, rect: NSRect, anchorView: NSView,
                                  root: NSView, window: NSWindow, preferredEdge: NSRectEdge,
                                  paperRect: NSRect? = nil, paperReferenceView: NSView? = nil) -> ScreenshotSubmenuPlacement? {
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
        if let paperRect, let paperReferenceView, paperReferenceView.window === window {
            return ScreenshotSubmenuPlacement.makeToolbarTray(size: size, anchor: root.convert(rect, from: anchorView),
                bounds: bounds, avoiding: root.convert(paperRect, from: paperReferenceView), obstacles: obstacles)
        }
        return ScreenshotSubmenuPlacement.make(size: size, anchor: root.convert(rect, from: anchorView),
            bounds: bounds, preferredEdge: edge, avoiding: obstacles)
    }
}

private final class ScreenshotSubmenuView: ScreenshotPanelView {
    override var joinsAdjacentGlass: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        ScreenshotCommandResponder.install(in: window, editor: nil)
            .setTransientScope(owner: self) { [weak self] in
                guard self?.window != nil else { return }
                PopoverHelper.dismiss()
            }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            ScreenshotCommandResponder.forWindow(window)?.removeTransientScope(owner: self)
        }
        super.viewWillMove(toWindow: newWindow)
    }
}
