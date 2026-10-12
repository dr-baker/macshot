import AppKit
import QuartzCore

/// Keep options beside their anchor, fitting a scroll viewport when necessary.
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

    /// Menus stay in the editor even when no full-size side fits. Prefer a
    /// smaller attached viewport, then use a movable panel within the bounds.
    static func makeFloatingPanel(size: NSSize, anchor: NSRect, bounds: NSRect,
                                  preferredEdge: NSRectEdge, obstacles: [NSRect], gap: CGFloat = 4) -> Self? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              anchor.minX.isFinite, anchor.minY.isFinite, anchor.width.isFinite, anchor.height.isFinite,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let fitted = NSSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        if let placement = make(size: fitted, anchor: anchor, bounds: bounds,
                                preferredEdge: preferredEdge, avoiding: obstacles) { return placement }
        let edges = edgeOrder(preferredEdge)
        let connected = connectedToolbarBounds(anchor: anchor, obstacles: obstacles)
        let candidates = edges.enumerated().compactMap { priority, edge -> (Self, CGFloat)? in
            let viewport = viewportSize(size: fitted, anchor: anchor, connected: connected,
                bounds: bounds, paper: nil, edge: edge, gap: gap)
            guard viewport.width >= min(44, size.width), viewport.height >= min(44, size.height),
                  let placement = make(size: viewport, anchor: anchor, bounds: bounds,
                    preferredEdge: edge, avoiding: obstacles, candidateEdges: [edge]) else { return nil }
            return (placement, viewport.width * viewport.height / (size.width * size.height) - CGFloat(priority) * 0.015)
        }
        if let best = candidates.max(by: { $0.1 < $1.1 }) { return best.0 }
        let origin: NSPoint
        switch preferredEdge {
        case .minY: origin = NSPoint(x: anchor.midX - fitted.width / 2, y: anchor.minY - gap - fitted.height)
        case .maxY: origin = NSPoint(x: anchor.midX - fitted.width / 2, y: anchor.maxY + gap)
        case .minX: origin = NSPoint(x: anchor.minX - gap - fitted.width, y: anchor.midY - fitted.height / 2)
        case .maxX: origin = NSPoint(x: anchor.maxX + gap, y: anchor.midY - fitted.height / 2)
        }
        return Self(frame: clamped(NSRect(origin: origin, size: fitted), to: bounds), edge: preferredEdge)
    }

    static func clamped(_ frame: NSRect, to bounds: NSRect) -> NSRect {
        let size = NSSize(width: min(frame.width, bounds.width), height: min(frame.height, bounds.height))
        return NSRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - size.width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - size.height),
                      width: size.width, height: size.height)
    }

    private static func edgeOrder(_ edge: NSRectEdge) -> [NSRectEdge] {
        switch edge {
        case .minY: return [.minY, .maxY, .minX, .maxX]
        case .maxY: return [.maxY, .minY, .minX, .maxX]
        case .minX: return [.minX, .maxX, .minY, .maxY]
        case .maxX: return [.maxX, .minX, .minY, .maxY]
        }
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

    private weak var root: NSView?
    private weak var parentWindow: NSWindow?
    private(set) weak var previousResponder: NSResponder?
    private var geometryObservers: [NSObjectProtocol] = []
    private var closeObserver: NSObjectProtocol?
    private weak var paperReferenceView: NSView?
    private let paperRect: NSRect?
    private let scrollViewport: NSScrollView
    private let dragHandle: ScreenshotSubmenuDragHandle
    private var manualTopLeft: NSPoint?
    private var dragStart: (point: NSPoint, topLeft: NSPoint)?
    var isToolbarTray: Bool { paperRect != nil }
    var isManuallyPositioned: Bool { manualTopLeft != nil }

    static let handleHeight: CGFloat = 18

    init?(contentView: NSView, size: NSSize, relativeTo rect: NSRect,
          of anchorView: NSView, preferredEdge: NSRectEdge,
          avoiding paperRect: NSRect? = nil, in paperReferenceView: NSView? = nil) {
        let isTray = paperRect != nil && paperReferenceView != nil
        let panelSize = NSSize(width: max(44, size.width), height: size.height + Self.handleHeight)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              let window = anchorView.window,
              (!isTray || paperReferenceView?.window === window),
              let (root, placement) = Self.findPlacement(size: panelSize, rect: rect,
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
        self.scrollViewport = NSScrollView(frame: .zero)
        self.dragHandle = ScreenshotSubmenuDragHandle(frame: .zero)
        self.previousResponder = Self.editingResponder(in: window)
        self.wrapper = ScreenshotSubmenuView(frame: placement.frame)
        wrapper.animatesGlassPresentation = !isTray
        // Keep the submenu as its own shape. Sharing the toolbar's union ID
        // expands the union into a large rectangle around both control bounds.
        wrapper.identifier = NSUserInterfaceItemIdentifier(isTray ? "screenshot.toolbar-tray" : "screenshot.submenu")
        wrapper.setAccessibilityRole(.group)
        wrapper.setAccessibilityLabel(L("Tool options"))
        contentView.frame = NSRect(origin: .zero, size: size)
        scrollViewport.drawsBackground = false
        scrollViewport.contentView.drawsBackground = false
        scrollViewport.borderType = .noBorder
        scrollViewport.scrollerStyle = .overlay
        scrollViewport.autohidesScrollers = true
        scrollViewport.documentView = contentView
        wrapper.addSubview(scrollViewport)
        wrapper.addSubview(dragHandle)
        dragHandle.onBeginDrag = { [weak self] point in self?.beginDragging(at: point) }
        dragHandle.onDrag = { [weak self] point in self?.drag(to: point) }
        dragHandle.onEndDrag = { [weak self] in self?.dragStart = nil }
        dragHandle.onMoveBy = { [weak self] offset in self?.move(by: offset) }
        configureViewport(firstPresentation: true)
        root.addSubview(wrapper, positioned: .above, relativeTo: nil)
        for group in root.subviews.compactMap({ $0 as? ScreenshotGlassGroupView }) {
            group.prepareForPresentation()
        }
        reveal(from: placement.edge, rootIsFlipped: root.isFlipped)

        root.postsFrameChangedNotifications = true
        root.postsBoundsChangedNotifications = true
        for (name, object) in [(NSWindow.didResizeNotification, window as Any),
                               (NSWindow.didMoveNotification, window as Any),
                               (NSWindow.didChangeScreenNotification, window as Any),
                               (NSView.frameDidChangeNotification, root as Any),
                               (NSView.boundsDidChangeNotification, root as Any)] {
            geometryObservers.append(NotificationCenter.default.addObserver(forName: name,
                object: object, queue: .main) { [weak self] _ in self?.reposition() })
        }
        geometryObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.reposition()
            })
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

    func cursor(at screenPoint: NSPoint) -> NSCursor? {
        guard isVisible, let window = parentWindow, let root else { return nil }
        if dragHandle.isDragging { return .closedHand }
        guard contains(screenPoint: screenPoint) else { return nil }
        let point = root.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return wrapper.hitTest(point) === dragHandle ? .openHand : .arrow
    }

    func keepAboveChrome(in parent: NSView) {
        guard wrapper.superview === parent,
              let index = parent.subviews.firstIndex(of: wrapper),
              parent.subviews.dropFirst(index + 1).contains(where: { $0 is ScreenshotPanelView }) else { return }
        parent.addSubview(wrapper, positioned: .above, relativeTo: nil)
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
        geometryObservers.forEach(NotificationCenter.default.removeObserver)
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        geometryObservers.removeAll()
        closeObserver = nil
        dragStart = nil
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
        scrollViewport.documentView = nil
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
        guard let root, let window = parentWindow else { return }
        if let manualTopLeft, let bounds = Self.usableBounds(root: root, window: window) {
            // Moving restores the natural panel size. Near an edge, clamp the
            // whole panel rather than making a drag resize its controls.
            let panelSize = NSSize(width: min(max(44, size.width), bounds.width),
                                   height: min(size.height + Self.handleHeight, bounds.height))
            let origin = NSPoint(x: manualTopLeft.x,
                y: root.isFlipped ? manualTopLeft.y : manualTopLeft.y - panelSize.height)
            wrapper.frame = ScreenshotSubmenuPlacement.clamped(NSRect(origin: origin, size: panelSize), to: bounds)
        } else {
            guard let anchorView else { return }
            guard let placement = Self.placement(size: NSSize(width: max(44, size.width), height: size.height + Self.handleHeight),
                rect: anchorRect, anchorView: anchorView, root: root, window: window, preferredEdge: preferredEdge,
                paperRect: paperRect, paperReferenceView: paperReferenceView) else { return }
            wrapper.frame = placement.frame
        }
        configureViewport(firstPresentation: false)
    }

    private func beginDragging(at windowPoint: NSPoint) {
        guard let root else { return }
        dragStart = (root.convert(windowPoint, from: nil),
                     NSPoint(x: wrapper.frame.minX, y: root.isFlipped ? wrapper.frame.minY : wrapper.frame.maxY))
    }

    private func drag(to windowPoint: NSPoint) {
        guard let root, let dragStart else { return }
        let point = root.convert(windowPoint, from: nil)
        let offset = NSPoint(x: point.x - dragStart.point.x, y: point.y - dragStart.point.y)
        guard offset != .zero else { return }
        ownMovedBackdrop()
        manualTopLeft = NSPoint(x: dragStart.topLeft.x + offset.x, y: dragStart.topLeft.y + offset.y)
        reposition()
        rememberManualPosition()
    }

    /// The keyboard offset follows the screen's directions in flipped hosts too.
    private func move(by offset: NSSize) {
        guard let root else { return }
        ownMovedBackdrop()
        rememberManualPosition()
        guard let manualTopLeft else { return }
        self.manualTopLeft = NSPoint(x: manualTopLeft.x + offset.width,
                                    y: manualTopLeft.y + (root.isFlipped ? -offset.height : offset.height))
        reposition()
        rememberManualPosition()
    }

    private func rememberManualPosition() {
        guard let root else { return }
        manualTopLeft = NSPoint(x: wrapper.frame.minX, y: root.isFlipped ? wrapper.frame.minY : wrapper.frame.maxY)
    }

    private func ownMovedBackdrop() {
        guard !wrapper.ownsGlassBackdrop else { return }
        wrapper.ownsGlassBackdrop = true
        for group in (root?.subviews ?? []) + wrapper.subviews {
            (group as? ScreenshotGlassGroupView)?.prepareForPresentation()
        }
    }

    private func configureViewport(firstPresentation: Bool) {
        let headerHeight = min(Self.handleHeight, wrapper.bounds.height)
        dragHandle.frame = NSRect(x: 0, y: wrapper.bounds.height - headerHeight,
                                  width: wrapper.bounds.width, height: headerHeight)
        scrollViewport.frame = NSRect(x: 0, y: 0, width: wrapper.bounds.width,
                                     height: max(0, wrapper.bounds.height - headerHeight))
        scrollViewport.hasVerticalScroller = size.height > scrollViewport.bounds.height
        scrollViewport.hasHorizontalScroller = size.width > scrollViewport.bounds.width
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
        // The material and handle are ready at insertion. Animate the viewport
        // without moving its document or fading controls separately from glass.
        guard !reduceMotion else { return }
        let verticalDirection: CGFloat = rootIsFlipped ? -1 : 1
        let translation = CATransform3DMakeTranslation(edge == .minX ? 3 : edge == .maxX ? -3 : 0,
            (edge == .minY ? 3 : edge == .maxY ? -3 : 0) * verticalDirection, 0)
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: translation)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = 0.14
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        scrollViewport.wantsLayer = true
        scrollViewport.layer?.add(animation, forKey: "toolbar-tray-reveal")
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
        guard let bounds = usableBounds(root: root, window: window) else { return nil }
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
            if let tray = ScreenshotSubmenuPlacement.makeToolbarTray(size: size, anchor: root.convert(rect, from: anchorView),
                bounds: bounds, avoiding: root.convert(paperRect, from: paperReferenceView), obstacles: obstacles) { return tray }
        }
        return ScreenshotSubmenuPlacement.makeFloatingPanel(size: size, anchor: root.convert(rect, from: anchorView),
            bounds: bounds, preferredEdge: edge, obstacles: obstacles)
    }

    private static func usableBounds(root: NSView, window: NSWindow) -> NSRect? {
        guard let content = window.contentView else { return nil }
        var bounds = root.visibleRect.intersection(root.convert(content.bounds, from: content))
        // Full-size content extends underneath a titled editor's traffic lights.
        bounds = bounds.intersection(root.convert(window.contentLayoutRect, from: nil))
        // Capture windows cover the whole display. Keep controls clear of the
        // menu bar, Dock, and notch, as well as a partially off-screen editor.
        if let screen = window.screen {
            bounds = bounds.intersection(root.convert(window.convertFromScreen(screen.visibleFrame), from: nil))
        }
        guard !bounds.isNull, bounds.width > 0, bounds.height > Self.handleHeight else { return nil }
        let inset = min(8, bounds.width / 4, (bounds.height - Self.handleHeight) / 4)
        return bounds.insetBy(dx: inset, dy: inset)
    }
}

/// A narrow grip reserves its own hit target, leaving sliders and canvas drags
/// untouched. Keyboard users can focus it and nudge the same bounded panel.
final class ScreenshotSubmenuDragHandle: NSView {
    var onBeginDrag: ((NSPoint) -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onEndDrag: (() -> Void)?
    var onMoveBy: ((NSSize) -> Void)?
    private var tracking: NSTrackingArea?
    private var isHovered = false
    private(set) var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("screenshot.options.move")
        toolTip = L("Drag to move. Arrow keys move the focused panel.")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(L("Move tool options"))
        setAccessibilityHelp(toolTip)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next)
        tracking = next
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isDragging = true
        NSCursor.closedHand.set()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        onBeginDrag?(event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow) }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        onEndDrag?()
        window?.invalidateCursorRects(for: self)
        NSCursor.openHand.set()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let offset: NSSize
        switch event.keyCode {
        case 123: offset = NSSize(width: -step, height: 0)
        case 124: offset = NSSize(width: step, height: 0)
        case 125: offset = NSSize(width: 0, height: -step)
        case 126: offset = NSSize(width: 0, height: step)
        default: super.keyDown(with: event); return
        }
        onMoveBy?(offset)
    }

    override func accessibilityPerformPress() -> Bool { window?.makeFirstResponder(self) == true }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        screenshotForegroundColor.withAlphaComponent(isDragging || focused ? 0.75 : isHovered ? 0.5 : 0.28).setFill()
        NSBezierPath(roundedRect: NSRect(x: bounds.midX - 14, y: bounds.midY - 1.5, width: 28, height: 3),
                     xRadius: 1.5, yRadius: 1.5).fill()
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
