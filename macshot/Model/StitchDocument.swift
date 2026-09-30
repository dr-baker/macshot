import AppKit

/// Pixel coordinates with a top-left origin. Source images stay intact through cuts and undo.
struct StitchPiece {
    var id = UUID()
    let image: CGImage
    var source: CGRect
    var origin: CGPoint
    var label: String
    var frame: CGRect { CGRect(origin: origin, size: source.size) }

    init(image: CGImage, origin: CGPoint = .zero, label: String = "Capture") {
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

/// Automatic extends the nearest covered edge pixel into gaps, without changing image pixels.
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

    /// Remove a full-width row band or full-height column band, retaining original pixels.
    @discardableResult
    mutating func collapse(axis: StitchAxis, from: CGFloat, to: CGFloat) -> Bool {
        guard canRender, from.isFinite, to.isFinite else { return false }
        let b = bounds
        let horizontal = axis == .horizontal
        let lower = horizontal ? b.minY : b.minX
        let upper = horizontal ? b.maxY : b.maxX
        let lo = max(lower, min(from, to).rounded())
        let hi = min(upper, max(from, to).rounded())
        guard hi - lo >= 2, upper - lower - (hi - lo) >= 2 else { return false }
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
        pieces = result
        return true
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
