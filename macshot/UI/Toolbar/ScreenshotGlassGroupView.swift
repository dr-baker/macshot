import AppKit
import Combine
import SwiftUI

/// One persistent SwiftUI glass scene for sibling screenshot controls. AppKit
/// retains the controls and their responder chains; SwiftUI owns material joins.
final class ScreenshotGlassGroupView: NSView {
    private let panels = NSHashTable<ScreenshotPanelView>.weakObjects()
    private let model = ScreenshotGlassGroupModel()
    private lazy var host = ScreenshotGlassGroupHostingView(rootView: ScreenshotGlassGroupContent(model: model))
    private var updating = false

    static func attach(_ panel: ScreenshotPanelView, to parent: NSView) -> ScreenshotGlassGroupView {
        let group: ScreenshotGlassGroupView
        if let existing = parent.subviews.compactMap({ $0 as? ScreenshotGlassGroupView }).first {
            group = existing
        } else {
            group = ScreenshotGlassGroupView(frame: .zero)
            parent.addSubview(group, positioned: .below, relativeTo: parent === panel ? parent.subviews.first : panel)
        }
        group.panels.add(panel)
        group.placeBelowControls(in: parent)
        group.invalidate()
        return group
    }

    private func placeBelowControls(in parent: NSView) {
        // Recheck after insertion as well: viewDidMoveToSuperview can register a
        // panel before its caller finishes positioned:addSubview ordering.
        guard let first = parent.subviews.first(where: { $0 is ScreenshotPanelView }),
              let firstIndex = parent.subviews.firstIndex(of: first),
              let groupIndex = parent.subviews.firstIndex(of: self), groupIndex > firstIndex else { return }
        parent.addSubview(self, positioned: .below, relativeTo: first)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(false)
        host.setAccessibilityElement(false)
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func remove(_ panel: ScreenshotPanelView) {
        panels.remove(panel)
        invalidate()
    }

    func invalidate() {
        guard !updating else { return }
        if isHidden { isHidden = false }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !updating, let parent = superview else { return }
        updating = true
        defer { updating = false }
        placeBelowControls(in: parent)
        let visible = panels.allObjects.filter {
            ($0 === parent || $0.superview === parent) && !$0.isHiddenOrHasHiddenAncestor
                && $0.renderedGlassConfiguration != nil && !$0.frame.isEmpty
        }.sorted { $0.glassIdentity < $1.glassIdentity }
        // Keep one stable coordinate space through menu insertions. Resizing a
        // tight bounding box would move every existing glass identity mid-morph.
        let region = parent.bounds
        if frame != region { frame = region }
        if host.frame != bounds { host.frame = bounds }
        isHidden = visible.isEmpty
        let items = visible.compactMap { panel -> ScreenshotGlassGroupItem? in
            guard let configuration = panel.renderedGlassConfiguration else { return nil }
            let panelFrame = panel === parent ? panel.bounds : panel.frame
            let local = panelFrame.offsetBy(dx: -region.minX, dy: -region.minY)
            let rect = CGRect(x: local.minX,
                y: parent.isFlipped ? local.minY : region.height - local.maxY,
                width: local.width, height: local.height)
            return ScreenshotGlassGroupItem(id: panel.glassIdentity, unionID: panel.glassUnionIdentity, rect: rect,
                configuration: configuration, appearance: panel.materialAppearanceName,
                joinsAdjacentGlass: panel.joinsAdjacentGlass, animatesInsertion: panel.animatesGlassPresentation)
        }
        guard model.items != items else { return }
        // Movement and live resizing follow the pointer without spring lag.
        // Only the arrival/departure of a submenu requests a glass transition.
        let oldConnected = model.items.filter(\.joinsAdjacentGlass)
        let newConnected = items.filter(\.joinsAdjacentGlass)
        let oldIDs = Set(oldConnected.map(\.id))
        let newIDs = Set(newConnected.map(\.id))
        let changesMenu = newConnected.contains { $0.animatesInsertion && !oldIDs.contains($0.id) }
            || oldConnected.contains { $0.animatesInsertion && !newIDs.contains($0.id) }
        if #available(macOS 26.0, *), changesMenu && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.smooth(duration: 0.22)) { model.items = items }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { model.items = items }
        }
    }
}

private struct ScreenshotGlassGroupItem: Identifiable, Equatable {
    var id: String
    var unionID: String?
    var rect: CGRect
    var configuration: ScreenshotGlassConfiguration
    var appearance: NSAppearance.Name?
    var joinsAdjacentGlass: Bool
    var animatesInsertion: Bool
}

private final class ScreenshotGlassGroupModel: ObservableObject {
    @Published var items: [ScreenshotGlassGroupItem] = []
}

private struct ScreenshotGlassGroupContent: View {
    @ObservedObject var model: ScreenshotGlassGroupModel

    var body: some View {
        if #available(macOS 26.0, *) {
            ScreenshotNativeGlassGroupContent(model: model)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

@available(macOS 26.0, *)
private struct ScreenshotNativeGlassGroupContent: View {
    @ObservedObject var model: ScreenshotGlassGroupModel
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            GlassEffectContainer(spacing: ScreenshotSubmenuPlacement.connectionSpacing) {
                ZStack(alignment: .topLeading) {
                    ForEach(model.items.filter(\.joinsAdjacentGlass)) { item in
                        positionedGlass(for: item)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // Separate effects cannot enter the toolbar's native union, even
            // when a tooltip or a full-width editor bar is only a few points away.
            ForEach(model.items.filter { !$0.joinsAdjacentGlass }) { item in
                positionedGlass(for: item)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }

    private func positionedGlass(for item: ScreenshotGlassGroupItem) -> some View {
        glassSurface(for: item)
            .environment(\.colorScheme, item.appearance == .aqua ? .light : .dark)
            .frame(width: item.rect.width, height: item.rect.height)
            .position(x: item.rect.midX, y: item.rect.midY)
            .transaction { transaction in
                // Native controls move synchronously. Standalone hover panels
                // never request a morph of the connected drawing controls.
                if !item.joinsAdjacentGlass || !item.animatesInsertion { transaction.animation = nil }
            }
    }

    @ViewBuilder
    private func glassSurface(for item: ScreenshotGlassGroupItem) -> some View {
        if item.joinsAdjacentGlass {
            nativeGlass(for: item)
                .glassEffectID(item.id, in: namespace)
                .glassEffectUnion(id: item.unionID, namespace: namespace)
                .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
        } else {
            nativeGlass(for: item)
        }
    }

    private func nativeGlass(for item: ScreenshotGlassGroupItem) -> some View {
        Color.clear.glassEffect(glass(for: item.configuration),
            in: RoundedRectangle(cornerRadius: item.configuration.cornerRadius, style: .continuous))
    }

    private func glass(for configuration: ScreenshotGlassConfiguration) -> Glass {
        var glass: Glass = configuration.material == .regular ? .regular : .clear
        if let tint = configuration.tint, configuration.tintOpacity > 0 {
            glass = glass.tint(Color(nsColor: tint.nsColor).opacity(configuration.tintOpacity))
        }
        // Input is handled by the existing AppKit controls above this scene.
        return glass.interactive(false)
    }
}

private final class ScreenshotGlassGroupHostingView: NSHostingView<ScreenshotGlassGroupContent> {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
