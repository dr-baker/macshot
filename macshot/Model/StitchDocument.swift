import AppKit

/// Pixel coordinates with a top-left origin. Source images stay intact through cuts and undo.
struct StitchPiece {
    var id = UUID()
    var lineageID: UUID
    let image: CGImage
    var source: CGRect
    var origin: CGPoint
    var label: String
    var frame: CGRect { CGRect(origin: origin, size: source.size) }

    init(image: CGImage, origin: CGPoint = .zero, label: String = "Capture") {
        self.lineageID = id
        self.image = image
        self.source = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        self.origin = origin
        self.label = label
    }

    func slice(_ rect: CGRect, shift: CGPoint) -> StitchPiece {
        var result = self
        result.id = UUID()
        result.source = CGRect(x: source.minX + rect.minX - frame.minX,
                               y: source.minY + rect.minY - frame.minY,
                               width: rect.width, height: rect.height)
        result.origin = CGPoint(x: rect.minX + shift.x, y: rect.minY + shift.y)
        return result
    }
}

enum StitchAxis { case horizontal, vertical }

/// Automatic blends sampled background colors into gaps without changing captured pixels.
enum StitchBackground {
    case automatic
    case color(NSColor)
    case transparent

    /// Nil means the renderer supplies edge colors rather than a uniform fill.
    var fillColor: NSColor? {
        switch self {
        case .automatic: return nil
        case .color(let color): return color
        case .transparent: return .clear
        }
    }
}

enum StitchPlacement { case free, packed }

struct StitchStyle {
    var color = NSColor(calibratedRed: 0.23, green: 0.28, blue: 0.34, alpha: 0.9)
    var lineWidth: CGFloat = 1.25
    var wave: CGFloat = 3
    var blur: CGFloat = 12
    /// Total width of the blur band, centered on the join, in source pixels.
    var feather: CGFloat = 64
    var visible = true
}

struct StitchJoin {
    let axis: StitchAxis
    let position: CGFloat
    let start: CGFloat
    let end: CGFloat
}

struct StitchDocument {
    var pieces: [StitchPiece] = []
    var style = StitchStyle()
    var background: StitchBackground = .automatic
    private(set) var placement: StitchPlacement = .free
    private var packingAxis: StitchAxis = .horizontal
    private var packingLength: CGFloat = 0

    init(pieces: [StitchPiece] = [], style: StitchStyle = StitchStyle(),
         background: StitchBackground = .automatic) {
        self.pieces = pieces
        self.style = style
        self.background = background
    }
    var savedPackingState: (horizontal: Bool, length: CGFloat) {
        (packingAxis == .horizontal, packingLength)
    }

    mutating func restorePackingState(packed: Bool, horizontal: Bool, length: CGFloat) {
        placement = packed ? .packed : .free
        packingAxis = horizontal ? .horizontal : .vertical
        packingLength = packed ? length : 0
    }

    static let maximumPieces = 128
    static let maximumPixels: CGFloat = 100_000_000
    static let maximumDimension: CGFloat = 30_000

    var bounds: CGRect { pieces.reduce(CGRect.null) { $0.union($1.frame) } }
    var canRender: Bool {
        let b = bounds
        return pieces.count <= Self.maximumPieces && !b.isNull && b.width > 0 && b.height > 0 && b.width.isFinite && b.height.isFinite
            && b.width <= Self.maximumDimension && b.height <= Self.maximumDimension
            && b.width * b.height <= Self.maximumPixels
    }

    struct RemovalBand {
        let range: ClosedRange<CGFloat>
        let rect: CGRect
        var length: CGFloat { range.upperBound - range.lowerBound }
    }

    /// Round the proposed endpoints before clipping, identically for preview and commit.
    func removalBand(axis: StitchAxis, from: CGFloat, to: CGFloat) -> RemovalBand? {
        guard canRender, from.isFinite, to.isFinite else { return nil }
        let b = bounds
        let horizontal = axis == .horizontal
        let lower = horizontal ? b.minY : b.minX
        let upper = horizontal ? b.maxY : b.maxX
        let lo = max(lower, min(from, to).rounded())
        let hi = min(upper, max(from, to).rounded())
        guard hi - lo >= 2, upper - lower - (hi - lo) >= 2 else { return nil }
        let rect = horizontal
            ? CGRect(x: b.minX, y: lo, width: b.width, height: hi - lo)
            : CGRect(x: lo, y: b.minY, width: hi - lo, height: b.height)
        return RemovalBand(range: lo...hi, rect: rect)
    }

    /// Remove a full-width row band or full-height column band, retaining original pixels.
    @discardableResult
    mutating func collapse(axis: StitchAxis, from: CGFloat, to: CGFloat) -> Bool {
        guard let band = removalBand(axis: axis, from: from, to: to) else { return false }
        let b = bounds
        let horizontal = axis == .horizontal
        let lo = band.range.lowerBound, hi = band.range.upperBound
        var result: [StitchPiece] = []
        for piece in pieces {
            let f = piece.frame
            let before = horizontal
                ? f.intersection(CGRect(x: b.minX, y: b.minY, width: b.width, height: lo - b.minY))
                : f.intersection(CGRect(x: b.minX, y: b.minY, width: lo - b.minX, height: b.height))
            let after = horizontal
                ? f.intersection(CGRect(x: b.minX, y: hi, width: b.width, height: b.maxY - hi))
                : f.intersection(CGRect(x: hi, y: b.minY, width: b.maxX - hi, height: b.height))
            if !before.isNull && before.width >= 1 && before.height >= 1 {
                result.append(piece.slice(before, shift: .zero))
            }
            if !after.isNull && after.width >= 1 && after.height >= 1 {
                result.append(piece.slice(after, shift: horizontal ? CGPoint(x: 0, y: lo - hi) : CGPoint(x: lo - hi, y: 0)))
            }
        }
        guard !result.isEmpty, result.count <= Self.maximumPieces else { return false }
        var next = self
        next.pieces = result
        // A global cut already closes its band. Reflowing the sliced fragments here
        // could move part of a lower row into an earlier row. Keep that geometry intact.
        if placement == .packed,
           (packingAxis == .horizontal && axis == .vertical)
            || (packingAxis == .vertical && axis == .horizontal) {
            next.packingLength = max(1, packingLength - (hi - lo))
        }
        self = next
        return true
    }

    /// Enter Packed using the existing arrangement's dominant flow and line length.
    /// Unequal pieces touch along each row/column; no uniform cell padding is introduced.
    @discardableResult
    mutating func pack() -> Bool {
        guard canRender else { return false }
        if placement == .packed { return reflowPacked() }
        var next = self
        let b = bounds
        let averageWidth = pieces.reduce(CGFloat(0)) { $0 + $1.frame.width } / CGFloat(pieces.count)
        let averageHeight = pieces.reduce(CGFloat(0)) { $0 + $1.frame.height } / CGFloat(pieces.count)
        next.packingAxis = b.width / averageWidth >= 0.8 * b.height / averageHeight ? .horizontal : .vertical
        next.packingLength = next.packingAxis == .horizontal ? b.width : b.height
        let horizontal = next.packingAxis == .horizontal
        // Stable geometric order on entry. Later moves preserve this explicit sequence.
        next.pieces = pieces.enumerated().sorted { lhs, rhs in
            let a = lhs.element.frame, b = rhs.element.frame
            let aLine = horizontal ? a.minY : a.minX
            let bLine = horizontal ? b.minY : b.minX
            if aLine != bLine { return aLine < bLine }
            let aAlong = horizontal ? a.minX : a.minY
            let bAlong = horizontal ? b.minX : b.minY
            if aAlong != bAlong { return aAlong < bAlong }
            return lhs.offset < rhs.offset
        }.map(\.element)
        next.placement = .packed
        guard next.reflowPacked() else { return false }
        self = next
        return true
    }

    @discardableResult
    mutating func setPlacement(_ value: StitchPlacement) -> Bool {
        if value == .packed { return pack() }
        placement = .free
        packingLength = 0
        return true
    }

    /// Reflow after adding, removing, or explicitly reordering pieces.
    @discardableResult
    mutating func reflowPacked() -> Bool {
        guard placement == .packed, !pieces.isEmpty else { return false }
        var next = self
        next.pieces = packedPieces(pieces, anchor: bounds.origin)
        guard next.canRender else { return false }
        self = next
        return true
    }

    /// Choose the closest valid insertion slot to a final drag origin, then close all slots.
    /// The caller keeps model origins unchanged during the drag so the anchor stays stable.
    @discardableResult
    mutating func movePacked(id: UUID, proposed: CGPoint) -> Bool {
        guard placement == .packed, proposed.x.isFinite, proposed.y.isFinite,
              let oldIndex = pieces.firstIndex(where: { $0.id == id }) else { return false }
        let moving = pieces[oldIndex]
        let target = CGPoint(x: proposed.x + moving.frame.width / 2,
                             y: proposed.y + moving.frame.height / 2)
        var remaining = pieces
        remaining.remove(at: oldIndex)
        var best: [StitchPiece]?
        var bestDistance = CGFloat.infinity
        var bestOrderDistance = Int.max
        for slot in 0...remaining.count {
            var order = remaining
            order.insert(moving, at: slot)
            let candidate = packedPieces(order, anchor: bounds.origin)
            var document = self
            document.pieces = candidate
            guard document.canRender else { continue }
            let frame = candidate[slot].frame
            let dx = frame.midX - target.x, dy = frame.midY - target.y
            let distance = dx * dx + dy * dy
            let orderDistance = abs(slot - oldIndex)
            if distance < bestDistance || (distance == bestDistance && orderDistance < bestOrderDistance) {
                best = candidate
                bestDistance = distance
                bestOrderDistance = orderDistance
            }
        }
        guard let best else { return false }
        pieces = best
        return true
    }

    private func packedPieces(_ order: [StitchPiece], anchor: CGPoint) -> [StitchPiece] {
        let horizontal = packingAxis == .horizontal
        let longest = order.map { horizontal ? $0.frame.width : $0.frame.height }.max() ?? 0
        let limit = max(packingLength, longest)
        var along: CGFloat = 0
        var line: CGFloat = 0
        var thickness: CGFloat = 0
        return order.map { piece in
            let length = horizontal ? piece.frame.width : piece.frame.height
            let depth = horizontal ? piece.frame.height : piece.frame.width
            if along > 0 && along + length > limit + 0.001 {
                line += thickness
                along = 0
                thickness = 0
            }
            var result = piece
            result.origin = horizontal
                ? CGPoint(x: anchor.x + along, y: anchor.y + line)
                : CGPoint(x: anchor.x + line, y: anchor.y + along)
            along += length
            thickness = max(thickness, depth)
            return result
        }
    }

    /// Joins follow actual touching edges, so they remain attached when pieces move.
    var joins: [StitchJoin] {
        guard pieces.count > 1 else { return [] }
        var result: [StitchJoin] = []
        for i in pieces.indices {
            for j in pieces.indices where j > i {
                let a = pieces[i].frame, b = pieces[j].frame
                let x0 = max(a.minX, b.minX), x1 = min(a.maxX, b.maxX)
                let y0 = max(a.minY, b.minY), y1 = min(a.maxY, b.maxY)
                if x1 > x0 {
                    if abs(a.maxY - b.minY) < 0.5 { result.append(.init(axis: .horizontal, position: a.maxY, start: x0, end: x1)) }
                    else if abs(b.maxY - a.minY) < 0.5 { result.append(.init(axis: .horizontal, position: b.maxY, start: x0, end: x1)) }
                }
                if y1 > y0 {
                    if abs(a.maxX - b.minX) < 0.5 { result.append(.init(axis: .vertical, position: a.maxX, start: y0, end: y1)) }
                    else if abs(b.maxX - a.minX) < 0.5 { result.append(.init(axis: .vertical, position: b.maxX, start: y0, end: y1)) }
                }
            }
        }
        return result
    }

    func snappedOrigin(for id: UUID, proposed: CGPoint, tolerance: CGFloat) -> CGPoint {
        guard let piece = pieces.first(where: { $0.id == id }) else { return proposed }
        var result = proposed
        var bestX = tolerance, bestY = tolerance
        for other in pieces where other.id != id {
            let f = other.frame
            for candidate in [f.minX, f.maxX, f.minX - piece.frame.width, f.maxX - piece.frame.width] {
                let delta = abs(proposed.x - candidate)
                if delta < bestX { result.x = candidate; bestX = delta }
            }
            for candidate in [f.minY, f.maxY, f.minY - piece.frame.height, f.maxY - piece.frame.height] {
                let delta = abs(proposed.y - candidate)
                if delta < bestY { result.y = candidate; bestY = delta }
            }
        }
        return CGPoint(x: result.x.rounded(), y: result.y.rounded())
    }
}
