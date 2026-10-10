import AppKit

/// Omitted geometry on one surviving source edge. No removed pixels are stored.
struct StitchTrimStamp: Codable, Equatable {
    enum Edge: String, Codable, CaseIterable {
        case top, bottom, left, right
        var horizontal: Bool { self == .top || self == .bottom }
    }

    var cutID: UUID
    var edge: Edge
    var start: CGFloat
    var end: CGFloat
    var removedLength: CGFloat
    /// Maps source tangent coordinates into the shared coordinate of this cut.
    /// Matching this mapping prevents shifted or reordered faces from pairing.
    var tangentOffset: CGFloat = 0
    var tangentReversed = false

    func cutCoordinate(at sourceCoordinate: CGFloat) -> CGFloat {
        (tangentReversed ? -sourceCoordinate : sourceCoordinate) + tangentOffset
    }

    func isValid(on source: CGRect) -> Bool {
        let lo = edge.horizontal ? source.minX : source.minY
        let hi = edge.horizontal ? source.maxX : source.maxY
        return start.isFinite && end.isFinite && removedLength.isFinite && removedLength > 0
            && tangentOffset.isFinite && start >= lo && end <= hi && end > start
            && cutCoordinate(at: start).isFinite && cutCoordinate(at: end).isFinite
    }

    func mirrored(horizontal: Bool, imageSize: CGSize) -> Self {
        var result = self
        if horizontal {
            if edge == .left { result.edge = .right }
            else if edge == .right { result.edge = .left }
        } else {
            if edge == .top { result.edge = .bottom }
            else if edge == .bottom { result.edge = .top }
        }
        if edge.horizontal == horizontal {
            let length = horizontal ? imageSize.width : imageSize.height
            result.start = length - end
            result.end = length - start
            result.tangentOffset += tangentReversed ? -length : length
            result.tangentReversed.toggle()
        }
        return result
    }
}

/// Pixel coordinates with a top-left origin. Source images stay intact through cuts and undo.
struct StitchPiece {
    static let maximumTrimStamps = 512
    var id = UUID()
    var lineageID: UUID
    let image: CGImage
    var source: CGRect
    var origin: CGPoint
    var label: String
    var trimStamps: [StitchTrimStamp] = []
    var frame: CGRect { CGRect(origin: origin, size: source.size) }
    var hasValidTrimStamps: Bool {
        trimStamps.count <= Self.maximumTrimStamps && trimStamps.allSatisfy { $0.isValid(on: source) }
    }

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
        result.trimStamps = trimStamps.compactMap { stamp in
            let remainsExterior: Bool
            switch stamp.edge {
            case .top: remainsExterior = result.source.minY == source.minY
            case .bottom: remainsExterior = result.source.maxY == source.maxY
            case .left: remainsExterior = result.source.minX == source.minX
            case .right: remainsExterior = result.source.maxX == source.maxX
            }
            guard remainsExterior else { return nil }
            var clipped = stamp
            clipped.start = max(stamp.start, stamp.edge.horizontal ? result.source.minX : result.source.minY)
            clipped.end = min(stamp.end, stamp.edge.horizontal ? result.source.maxX : result.source.maxY)
            return clipped.end > clipped.start ? clipped : nil
        }
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

enum StitchTransition: String, CaseIterable, Codable {
    case wave, blend, torn, fold, accordion, breakLine

    var usesBlur: Bool { self == .wave || self == .blend || self == .breakLine }
    var hasEditableColor: Bool { self == .wave || self == .breakLine }
}

struct StitchStyle {
    /// One retains the original full-strength fold at the slider's midpoint.
    static let maximumFoldStrength: CGFloat = 2

    var transition: StitchTransition = .wave
    var color = NSColor(calibratedRed: 0.23, green: 0.28, blue: 0.34, alpha: 0.9)
    var lineWidth: CGFloat = 1.25
    var wave: CGFloat = 3
    var blur: CGFloat = 12
    /// Total width of the blur band, centered on the join, in source pixels.
    var feather: CGFloat = 64
    var tearWidth: CGFloat = 8
    var tearRoughness: CGFloat = 3
    var foldDepth: CGFloat = 18
    var foldStrength: CGFloat = 1
    var accordionWidth: CGFloat = 30
    var accordionPleats: CGFloat = 3
    /// Vertical camera tilt in degrees. Positive values view the sheet from above.
    var accordionPerspective: CGFloat = 14
    /// Horizontal camera rotation in degrees, independent of vertical tilt.
    var accordionYaw: CGFloat = 11.2
    var breakSize: CGFloat = 3
    var visible = true
}

struct StitchJoin {
    let axis: StitchAxis
    let position: CGFloat
    let start: CGFloat
    let end: CGFloat
    /// Nil means the touching faces do not prove an omitted source distance.
    let trimmedLength: CGFloat?

    init(axis: StitchAxis, position: CGFloat, start: CGFloat, end: CGFloat, trimmedLength: CGFloat? = nil) {
        self.axis = axis
        self.position = position
        self.start = start
        self.end = end
        self.trimmedLength = trimmedLength
    }
}

struct StitchDocument {
    let paperPaletteCache = StitchPaperSampler.Cache()
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
    static let maximumTrimStamps = 16_384
    /// Caps both model subdivision and the input passed to projection preparation.
    static let maximumContactSegments = 1_024
    static let maximumContactPreparationWork = 1_000_000

    var bounds: CGRect { pieces.reduce(CGRect.null) { $0.union($1.frame) } }
    var canRender: Bool {
        hasValidGeometryAndStamps && preparedContacts() != nil
    }

    private var hasValidGeometryAndStamps: Bool {
        guard !pieces.isEmpty, pieces.count <= Self.maximumPieces,
              pieces.allSatisfy({ $0.trimStamps.count <= StitchPiece.maximumTrimStamps }),
              pieces.reduce(0, { $0 + $1.trimStamps.count }) <= Self.maximumTrimStamps,
              pieces.allSatisfy(\.hasValidTrimStamps) else { return false }
        let b = bounds
        return !b.isNull && b.width > 0 && b.height > 0 && b.width.isFinite && b.height.isFinite
            && b.width <= Self.maximumDimension && b.height <= Self.maximumDimension
            && b.width * b.height <= Self.maximumPixels
    }

    var hasAccordionFolds: Bool {
        style.visible && style.transition == .accordion && canRender && joins.contains {
            $0.trimmedLength.map { $0 > 0 } ?? (style.accordionWidth > 0)
        }
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
        let trimSegments = removalProvenance(axis: axis, band: band)
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
        Self.stampNewContact(in: &result, axis: axis, position: lo, segments: trimSegments)
        var next = self
        next.pieces = result
        guard next.canRender else { return false }
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

    private struct TrimSegment {
        let start: CGFloat
        var end: CGFloat
        let removedLength: CGFloat
    }

    /// Endpoint seams are absorbed too: removing right up to an existing cut
    /// leaves its omitted material between the newly adjacent surviving faces.
    private func removalProvenance(axis: StitchAxis, band: RemovalBand) -> [TrimSegment] {
        let crossed = joins.filter {
            $0.axis == axis && $0.position >= band.range.lowerBound - 0.001
                && $0.position <= band.range.upperBound + 0.001
        }
        let horizontal = axis == .horizontal
        let lower = horizontal ? bounds.minX : bounds.minY
        let upper = horizontal ? bounds.maxX : bounds.maxY
        let endpoints = Self.trimEndpoints([lower, upper] + crossed.flatMap { [max(lower, $0.start), min(upper, $0.end)] })
        var seamGroups: [[StitchJoin]] = []
        for join in crossed.sorted(by: { $0.position < $1.position }) {
            if let first = seamGroups.last?.first, abs(first.position - join.position) < 0.001 {
                seamGroups[seamGroups.count - 1].append(join)
            } else { seamGroups.append([join]) }
        }
        var segments: [TrimSegment] = []
        for (start, end) in zip(endpoints, endpoints.dropFirst()) where end > start {
            let middle = (start + end) / 2
            let omitted = seamGroups.reduce(CGFloat(0)) { total, group in
                // Coincident contacts describe one physical omitted interval.
                let length = group.reduce(CGFloat(0)) { largest, join in
                    guard join.start < middle, join.end > middle,
                          let length = join.trimmedLength, length > 0, length.isFinite else { return largest }
                    return max(largest, length)
                }
                return total + length
            }
            let length = band.length + omitted
            if let last = segments.last, last.end == start, last.removedLength == length {
                segments[segments.count - 1].end = end
            } else {
                segments.append(TrimSegment(start: start, end: end, removedLength: length))
            }
        }
        return segments
    }

    private static func stampNewContact(in pieces: inout [StitchPiece], axis: StitchAxis,
                                        position: CGFloat, segments: [TrimSegment]) {
        let horizontal = axis == .horizontal
        let beforeEdge: StitchTrimStamp.Edge = horizontal ? .bottom : .right
        let afterEdge: StitchTrimStamp.Edge = horizontal ? .top : .left
        let before = pieces.indices.filter {
            abs((horizontal ? pieces[$0].frame.maxY : pieces[$0].frame.maxX) - position) < 0.001
        }
        let after = pieces.indices.filter {
            abs((horizontal ? pieces[$0].frame.minY : pieces[$0].frame.minX) - position) < 0.001
        }
        for index in before { pieces[index].trimStamps.removeAll { $0.edge == beforeEdge } }
        for index in after { pieces[index].trimStamps.removeAll { $0.edge == afterEdge } }
        let cutID = UUID()
        for a in before {
            for b in after where a != b {
                let start = max(horizontal ? pieces[a].frame.minX : pieces[a].frame.minY,
                                horizontal ? pieces[b].frame.minX : pieces[b].frame.minY)
                let end = min(horizontal ? pieces[a].frame.maxX : pieces[a].frame.maxY,
                              horizontal ? pieces[b].frame.maxX : pieces[b].frame.maxY)
                guard end > start else { continue }
                for segment in segments {
                    let lo = max(start, segment.start), hi = min(end, segment.end)
                    guard hi > lo else { continue }
                    for (index, edge) in [(a, beforeEdge), (b, afterEdge)] {
                        let piece = pieces[index]
                        let offset = horizontal ? piece.frame.minX - piece.source.minX : piece.frame.minY - piece.source.minY
                        pieces[index].trimStamps.append(StitchTrimStamp(cutID: cutID, edge: edge,
                            start: lo - offset, end: hi - offset, removedLength: segment.removedLength,
                            tangentOffset: offset))
                    }
                }
            }
        }
        for index in pieces.indices {
            let sorted = pieces[index].trimStamps.sorted {
                if $0.edge != $1.edge { return $0.edge.rawValue < $1.edge.rawValue }
                return $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end
            }
            pieces[index].trimStamps = sorted.reduce(into: []) { result, stamp in
                if let last = result.last, last.edge == stamp.edge, last.cutID == stamp.cutID,
                   last.removedLength == stamp.removedLength, last.tangentOffset == stamp.tangentOffset,
                   last.tangentReversed == stamp.tangentReversed, stamp.start <= last.end {
                    result[result.count - 1].end = max(last.end, stamp.end)
                } else { result.append(stamp) }
            }
        }
    }

    private static func trimEndpoints(_ values: [CGFloat]) -> [CGFloat] {
        values.filter(\.isFinite).sorted().reduce(into: []) { result, value in
            if result.last.map({ abs($0 - value) > 0.000001 }) ?? true { result.append(value) }
        }
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
        guard hasValidGeometryAndStamps, let contacts = preparedContacts() else { return [] }
        var result: [StitchJoin] = []
        for contact in contacts {
            result += contactJoins(before: pieces[contact.before], after: pieces[contact.after], axis: contact.axis,
                position: contact.position, start: contact.start, end: contact.end)
        }
        return result
    }

    private struct PieceContact {
        let before: Int
        let after: Int
        let axis: StitchAxis
        let position: CGFloat
        let start: CGFloat
        let end: CGFloat
    }

    /// Cheap edge counts bound subdivision before any per-partition stamp scans.
    /// Counts include off-contact stamps conservatively; ordinary cuts use only a
    /// few intervals, while overlapping highly fragmented contacts fail closed.
    private func preparedContacts() -> [PieceContact]? {
        guard pieces.count <= Self.maximumPieces else { return nil }
        guard pieces.count > 1 else { return [] }
        let frames = pieces.map(\.frame)
        let hasStamps = pieces.contains { !$0.trimStamps.isEmpty }
        var edgeCounts: [[Int]] = []
        if hasStamps {
            edgeCounts = pieces.map { piece in
                var counts = [0, 0, 0, 0]
                for stamp in piece.trimStamps {
                    switch stamp.edge {
                    case .top: counts[0] += 1
                    case .bottom: counts[1] += 1
                    case .left: counts[2] += 1
                    case .right: counts[3] += 1
                    }
                }
                return counts
            }
        }
        var contacts: [PieceContact] = []
        var segments = 0
        var work = 0
        func append(before: Int, after: Int, axis: StitchAxis, position: CGFloat, start: CGFloat, end: CGFloat) -> Bool {
            if hasStamps {
                let horizontal = axis == .horizontal
                let count = edgeCounts[before][horizontal ? 1 : 3] + edgeCounts[after][horizontal ? 0 : 2]
                // Each stamp can introduce two endpoints. Filtering and checking
                // both active stamp sets require at most two scans per partition.
                let partitions = 1 + count * 2
                segments += partitions
                work += 2 * partitions * count + pieces[before].trimStamps.count + pieces[after].trimStamps.count
            } else {
                segments += 1
            }
            guard segments <= Self.maximumContactSegments else { return false }
            // Cumulative removal and projection can partition by every join's
            // endpoints and scan all joins at each interval. Reserve that worst
            // case here as well, before either consumer performs subdivision.
            let partitionWork = segments * (2 * segments - 1)
            guard work + partitionWork <= Self.maximumContactPreparationWork else { return false }
            contacts.append(PieceContact(before: before, after: after, axis: axis,
                                          position: position, start: start, end: end))
            return true
        }
        for i in pieces.indices {
            for j in pieces.indices where j > i {
                let a = frames[i], b = frames[j]
                let x0 = max(a.minX, b.minX), x1 = min(a.maxX, b.maxX)
                let y0 = max(a.minY, b.minY), y1 = min(a.maxY, b.maxY)
                if x1 > x0 {
                    if abs(a.maxY - b.minY) < 0.5 {
                        guard append(before: i, after: j, axis: .horizontal, position: a.maxY, start: x0, end: x1) else { return nil }
                    } else if abs(b.maxY - a.minY) < 0.5 {
                        guard append(before: j, after: i, axis: .horizontal, position: b.maxY, start: x0, end: x1) else { return nil }
                    }
                }
                if y1 > y0 {
                    if abs(a.maxX - b.minX) < 0.5 {
                        guard append(before: i, after: j, axis: .vertical, position: a.maxX, start: y0, end: y1) else { return nil }
                    } else if abs(b.maxX - a.minX) < 0.5 {
                        guard append(before: j, after: i, axis: .vertical, position: b.maxX, start: y0, end: y1) else { return nil }
                    }
                }
            }
        }
        return contacts
    }

    private struct ContactStamp {
        let stamp: StitchTrimStamp
        let start: CGFloat
        let end: CGFloat
        /// Source tangent = world tangent - sourceOffset.
        let sourceOffset: CGFloat

        func matches(_ other: Self, at worldCoordinate: CGFloat) -> Bool {
            stamp.cutID == other.stamp.cutID && stamp.removedLength == other.stamp.removedLength
                && stamp.tangentReversed == other.stamp.tangentReversed
                && abs(stamp.cutCoordinate(at: worldCoordinate - sourceOffset)
                       - other.stamp.cutCoordinate(at: worldCoordinate - other.sourceOffset)) < 0.000001
        }
    }

    private func contactJoins(before: StitchPiece, after: StitchPiece, axis: StitchAxis,
                              position: CGFloat, start: CGFloat, end: CGFloat) -> [StitchJoin] {
        let horizontal = axis == .horizontal
        func stamps(_ piece: StitchPiece, on edge: StitchTrimStamp.Edge) -> [ContactStamp] {
            let offset = horizontal ? piece.frame.minX - piece.source.minX : piece.frame.minY - piece.source.minY
            return piece.trimStamps.compactMap { stamp in
                guard stamp.edge == edge, stamp.isValid(on: piece.source) else { return nil }
                let lo = max(start, stamp.start + offset), hi = min(end, stamp.end + offset)
                return hi > lo ? ContactStamp(stamp: stamp, start: lo, end: hi, sourceOffset: offset) : nil
            }
        }
        let a = stamps(before, on: horizontal ? .bottom : .right)
        let b = stamps(after, on: horizontal ? .top : .left)
        let endpoints = Self.trimEndpoints([start, end] + (a + b).flatMap { [$0.start, $0.end] })
        let inferred: CGFloat?
        let beforeOffset = horizontal ? before.frame.minX - before.source.minX : before.frame.minY - before.source.minY
        let afterOffset = horizontal ? after.frame.minX - after.source.minX : after.frame.minY - after.source.minY
        if before.lineageID == after.lineageID, before.image === after.image,
           abs(beforeOffset - afterOffset) < 0.000001 {
            let gap = horizontal ? after.source.minY - before.source.maxY : after.source.minX - before.source.maxX
            inferred = gap.isFinite && gap >= 0 ? gap : nil
        } else { inferred = nil }

        var result: [StitchJoin] = []
        for (lo, hi) in zip(endpoints, endpoints.dropFirst()) where hi > lo {
            let middle = (lo + hi) / 2
            let activeA = a.filter { $0.start < middle && $0.end > middle }
            let activeB = b.filter { $0.start < middle && $0.end > middle }
            let length: CGFloat?
            if let firstA = activeA.first, let firstB = activeB.first,
               firstA.matches(firstB, at: middle),
               activeA.allSatisfy({ $0.matches(firstA, at: middle) }),
               activeB.allSatisfy({ $0.matches(firstB, at: middle) }) {
                length = firstA.stamp.removedLength
            } else if activeA.isEmpty && activeB.isEmpty {
                length = inferred
            } else { length = nil }
            if let last = result.last, last.end == lo, last.trimmedLength == length {
                result[result.count - 1] = StitchJoin(axis: axis, position: position,
                    start: last.start, end: hi, trimmedLength: length)
            } else {
                result.append(StitchJoin(axis: axis, position: position, start: lo, end: hi, trimmedLength: length))
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
