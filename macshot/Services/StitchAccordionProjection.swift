import AppKit

/// Camera angles and native drag behavior, independent of the document and UI.
nonisolated struct StitchPaperCamera: Sendable, Equatable {
    static let defaultPerspective: CGFloat = 14
    static let defaultYaw: CGFloat = 11.2
    static let perspectiveRange: ClosedRange<CGFloat> = -30...30
    static let yawRange: ClosedRange<CGFloat> = -35...35

    let perspective: CGFloat
    let yaw: CGFloat

    init(perspective: CGFloat = defaultPerspective, yaw: CGFloat = defaultYaw) {
        self.perspective = Self.clamp(perspective, to: Self.perspectiveRange, fallback: Self.defaultPerspective)
        self.yaw = Self.clamp(yaw, to: Self.yawRange, fallback: Self.defaultYaw)
    }

    /// Displacement is in view points with positive y downward. Modifiers scale
    /// or constrain the full displacement from the drag origin.
    func dragged(by displacement: CGPoint, precision: Bool = false, axisLock: Bool = false) -> Self {
        guard displacement.x.isFinite, displacement.y.isFinite else { return self }
        var dx = displacement.x, dy = displacement.y
        if axisLock {
            if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 }
        }
        let degreesPerPoint: CGFloat = precision ? 0.0375 : 0.15
        return Self(perspective: perspective + dy * degreesPerPoint, yaw: yaw + dx * degreesPerPoint)
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>, fallback: CGFloat) -> CGFloat {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

/// A textured sheet in top-down document coordinates. Rendering and hit testing use
/// the same triangles, including the perspective denominator at every vertex.
nonisolated struct StitchAccordionProjection: Sendable {
    nonisolated struct Weights: Sendable {
        let x: CGFloat
        let y: CGFloat
        let z: CGFloat
    }

    nonisolated struct Vertex: Sendable {
        let source: CGPoint
        let projected: CGPoint
        /// Positive camera distance. Perspective-correct interpolation divides by this value.
        let depth: CGFloat
    }

    nonisolated struct Face: Sendable {
        let a: Vertex
        let b: Vertex
        let c: Vertex
        let shade: CGFloat
        let isFrontFacing: Bool
        /// Bit 0 is edge b-c, bit 1 c-a, and bit 2 a-b. Only exterior edges need antialiasing.
        let boundaryEdges: Int

        var vertices: [Vertex] { [a, b, c] }
        var projectedBounds: CGRect {
            CGRect(x: min(a.projected.x, b.projected.x, c.projected.x),
                   y: min(a.projected.y, b.projected.y, c.projected.y),
                   width: max(a.projected.x, b.projected.x, c.projected.x) - min(a.projected.x, b.projected.x, c.projected.x),
                   height: max(a.projected.y, b.projected.y, c.projected.y) - min(a.projected.y, b.projected.y, c.projected.y))
        }

        func project(_ point: CGPoint) -> CGPoint? {
            guard let weights = Self.weights(point, a.source, b.source, c.source) else { return nil }
            let wa = weights.x * a.depth, wb = weights.y * b.depth, wc = weights.z * c.depth
            let total = wa + wb + wc
            guard total > 0 else { return nil }
            return CGPoint(x: (wa * a.projected.x + wb * b.projected.x + wc * c.projected.x) / total,
                           y: (wa * a.projected.y + wb * b.projected.y + wc * c.projected.y) / total)
        }

        func unproject(_ point: CGPoint) -> (source: CGPoint, depth: CGFloat)? {
            guard let weights = Self.weights(point, a.projected, b.projected, c.projected),
                  min(weights.x, weights.y, weights.z) >= -0.000001 else { return nil }
            let wa = weights.x / a.depth, wb = weights.y / b.depth, wc = weights.z / c.depth
            let total = wa + wb + wc
            guard total > 0 else { return nil }
            return (CGPoint(x: (wa * a.source.x + wb * b.source.x + wc * c.source.x) / total,
                            y: (wa * a.source.y + wb * b.source.y + wc * c.source.y) / total), 1 / total)
        }

        static func weights(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Weights? {
            let denominator = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
            guard denominator.isFinite, abs(denominator) > 0.000000001 else { return nil }
            let wa = ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / denominator
            let wb = ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / denominator
            return Weights(x: wa, y: wb, z: 1 - wa - wb)
        }
    }

    /// Validated geometry without captured pixels or UI objects. Reusing it for
    /// animation frames avoids repeated join merging and mesh edge collection.
    nonisolated struct Source: Sendable {
        let documentBounds: CGRect
        let camera: StitchPaperCamera
        fileprivate let folds: [Fold]
        fileprivate let columns: [CGFloat]
        fileprivate let rows: [CGFloat]

        @MainActor
        init?(document: StitchDocument) {
            guard document.canRender else { return nil }
            let bounds = document.bounds.integral
            guard bounds.minX.isFinite, bounds.minY.isFinite,
                  bounds.maxX.isFinite, bounds.maxY.isFinite else { return nil }
            let style = document.style
            let active = style.visible && style.transition == .accordion && !document.joins.isEmpty && style.accordionWidth != 0
            let folds: [Fold]
            if active {
                guard style.accordionWidth.isFinite, style.accordionWidth > 0, style.accordionWidth <= 80,
                      style.accordionPleats.isFinite, (2...6).contains(style.accordionPleats),
                      style.accordionPerspective.isFinite, StitchPaperCamera.perspectiveRange.contains(style.accordionPerspective),
                      style.accordionYaw.isFinite, StitchPaperCamera.yawRange.contains(style.accordionYaw) else { return nil }
                let joins = StitchAccordionProjection.mergedJoins(document.joins, bounds: bounds)
                folds = joins.compactMap { join in
                    var room = min(join.position - (join.horizontal ? bounds.minY : bounds.minX),
                                   (join.horizontal ? bounds.maxY : bounds.maxX) - join.position)
                    for other in joins where other.horizontal == join.horizontal
                        && abs(other.position - join.position) > 0.001
                        && min(other.end, join.end) > max(other.start, join.start) {
                        room = min(room, abs(other.position - join.position))
                    }
                    // A narrow capture keeps most of each adjoining piece flat.
                    for piece in document.pieces {
                        let frame = piece.frame
                        let alongMin = join.horizontal ? frame.minX : frame.minY
                        let alongMax = join.horizontal ? frame.maxX : frame.maxY
                        guard min(alongMax, join.end) > max(alongMin, join.start) else { continue }
                        let lo = join.horizontal ? frame.minY : frame.minX
                        let hi = join.horizontal ? frame.maxY : frame.maxX
                        if abs(hi - join.position) < 0.5 { room = min(room, join.position - lo) }
                        if abs(lo - join.position) < 0.5 { room = min(room, hi - join.position) }
                    }
                    let halfWidth = min(style.accordionWidth * 2, room * 0.45, (join.end - join.start) * 0.4)
                    guard halfWidth.isFinite, halfWidth > 0.001, join.end - join.start > 0.001 else { return nil }
                    return Fold(join: join, halfWidth: halfWidth,
                                pleats: Int(style.accordionPleats.rounded()), bounds: bounds)
                }
            } else {
                folds = []
            }

            var xEdges = [bounds.minX, bounds.maxX], yEdges = [bounds.minY, bounds.maxY]
            for fold in folds {
                let normal = (0...fold.pleats * 2).map {
                    fold.join.position - fold.halfWidth + CGFloat($0) * fold.segmentLength
                }
                if fold.join.horizontal {
                    yEdges += normal
                    xEdges += fold.alongEdges
                } else {
                    xEdges += normal
                    yEdges += fold.alongEdges
                }
            }
            let columns = StitchAccordionProjection.uniqueEdges(xEdges)
            let rows = StitchAccordionProjection.uniqueEdges(yEdges)
            // Fragmented collages fail before allocating an oversized mesh.
            guard columns.count * rows.count <= 16_384 else { return nil }
            self.documentBounds = bounds
            self.camera = StitchPaperCamera(perspective: style.accordionPerspective, yaw: style.accordionYaw)
            self.folds = folds
            self.columns = columns
            self.rows = rows
        }

        func projection(progress: CGFloat = 1) -> StitchAccordionProjection? {
            StitchAccordionProjection(source: self, progress: progress)
        }
    }

    let source: Source
    let documentBounds: CGRect
    let hasProjectedOutput: Bool
    /// Source order is stable throughout an animation, including at progress zero.
    let faces: [Face]
    /// Useful for layer animation. The raster renderer also resolves actual depth per pixel.
    let drawingOrder: [Int]
    private let columns: [CGFloat]
    private let rows: [CGFloat]
    private let grid: [Vertex]

    @MainActor
    init?(document: StitchDocument, progress proposedProgress: CGFloat = 1) {
        guard let source = Source(document: document),
              let projection = Self(source: source, progress: proposedProgress) else { return nil }
        self = projection
    }

    init?(source: Source, progress proposedProgress: CGFloat = 1) {
        guard proposedProgress.isFinite else { return nil }
        let bounds = source.documentBounds
        let progress = max(0, min(1, proposedProgress))
        let folds = source.folds, columns = source.columns, rows = source.rows
        let angle = acos(CGFloat(0.45)) * progress
        let compression = cos(angle)
        let ridgeSlope = sin(angle)
        let camera = Camera(bounds: bounds,
                            perspective: folds.isEmpty ? 0 : source.camera.perspective * progress,
                            yaw: folds.isEmpty ? 0 : source.camera.yaw * progress)
        var sourcePoints: [CGPoint] = [], points3D: [Point3] = [], rawPoints: [(CGPoint, CGFloat)] = []
        sourcePoints.reserveCapacity(columns.count * rows.count)
        points3D.reserveCapacity(columns.count * rows.count)
        rawPoints.reserveCapacity(columns.count * rows.count)
        for y in rows {
            for x in columns {
                let source = CGPoint(x: x, y: y)
                var paper = Point3(x: x - bounds.midX, y: y - bounds.midY, z: 0)
                for fold in folds {
                    let along = fold.join.horizontal ? x : y
                    let normal = fold.join.horizontal ? y : x
                    let weight = fold.weight(at: along)
                    guard weight > 0 else { continue }
                    let distance = normal - (fold.join.position - fold.halfWidth)
                    let inside = max(0, min(fold.halfWidth * 2, distance))
                    let displacement = ((1 - compression) * (inside - fold.halfWidth)) * weight
                    if fold.join.horizontal { paper.y -= displacement } else { paper.x -= displacement }
                    if distance > 0 && distance < fold.halfWidth * 2 {
                        let phase = distance / fold.segmentLength
                        let whole = Int(floor(phase))
                        let fraction = phase - CGFloat(whole)
                        let height = whole.isMultiple(of: 2) ? fraction : 1 - fraction
                        paper.z += fold.segmentLength * ridgeSlope * height * weight
                    }
                }
                guard let projected = camera.project(paper) else { return nil }
                sourcePoints.append(source)
                points3D.append(paper)
                rawPoints.append(projected)
            }
        }

        let rawMinX = rawPoints.map { $0.0.x }.min()!, rawMaxX = rawPoints.map { $0.0.x }.max()!
        let rawMinY = rawPoints.map { $0.0.y }.min()!, rawMaxY = rawPoints.map { $0.0.y }.max()!
        let projectedWidth = rawMaxX - rawMinX, projectedHeight = rawMaxY - rawMinY
        guard projectedWidth > 0, projectedHeight > 0 else { return nil }
        let hasOutput = !folds.isEmpty && progress > 0
        let fit = hasOutput
            ? min(bounds.width / projectedWidth, bounds.height / projectedHeight) * (1 - 0.018 * progress) : 1
        let rawCenter = CGPoint(x: (rawMinX + rawMaxX) / 2, y: (rawMinY + rawMaxY) / 2)
        let grid = zip(sourcePoints, rawPoints).map { source, projected in
            Vertex(source: source,
                   projected: CGPoint(x: bounds.midX + (projected.0.x - rawCenter.x) * fit,
                                      y: bounds.midY + (projected.0.y - rawCenter.y) * fit),
                   depth: projected.1)
        }
        var faces: [Face] = []
        faces.reserveCapacity((columns.count - 1) * (rows.count - 1) * 2)
        func face(_ a: Int, _ b: Int, _ c: Int) -> Face {
            let normal = camera.rotate(Point3.cross(points3D[b] - points3D[a], points3D[c] - points3D[a])).normalized
            let flatNormal = camera.rotate(Point3(x: 0, y: 0, z: 1))
            let light = Point3(x: -0.25, y: -0.5, z: 0.83).normalized
            let shade = max(0.72, min(1.08, 1 + 0.32 * (normal.dot(light) - flatNormal.dot(light))))
            let mask = (Self.exteriorEdge(sourcePoints[b], sourcePoints[c], bounds) ? 1 : 0)
                | (Self.exteriorEdge(sourcePoints[c], sourcePoints[a], bounds) ? 2 : 0)
                | (Self.exteriorEdge(sourcePoints[a], sourcePoints[b], bounds) ? 4 : 0)
            let winding = (grid[b].projected.x - grid[a].projected.x) * (grid[c].projected.y - grid[a].projected.y)
                - (grid[b].projected.y - grid[a].projected.y) * (grid[c].projected.x - grid[a].projected.x)
            return Face(a: grid[a], b: grid[b], c: grid[c], shade: shade,
                        isFrontFacing: winding > 0.000000001, boundaryEdges: mask)
        }
        for row in 0..<rows.count - 1 {
            for column in 0..<columns.count - 1 {
                let a = row * columns.count + column, b = a + 1
                let d = a + columns.count, c = d + 1
                faces.append(face(a, b, c))
                faces.append(face(a, c, d))
            }
        }
        self.source = source
        self.documentBounds = bounds
        self.hasProjectedOutput = hasOutput
        self.columns = columns
        self.rows = rows
        self.grid = grid
        self.faces = faces
        self.drawingOrder = faces.indices.sorted {
            let a = faces[$0], b = faces[$1]
            let difference = a.a.depth + a.b.depth + a.c.depth - b.a.depth - b.b.depth - b.c.depth
            return abs(difference) > 0.000001 ? difference > 0 : $0 < $1
        }
    }

    func project(_ point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= documentBounds.minX, point.x <= documentBounds.maxX,
              point.y >= documentBounds.minY, point.y <= documentBounds.maxY else { return nil }
        let column = Self.cell(containing: point.x, edges: columns)
        let row = Self.cell(containing: point.y, edges: rows)
        let x = (point.x - columns[column]) / (columns[column + 1] - columns[column])
        let y = (point.y - rows[row]) / (rows[row + 1] - rows[row])
        return faces[(row * (columns.count - 1) + column) * 2 + (y <= x ? 0 : 1)].project(point)
    }

    /// The nearest visible face wins where perspective hides a return face.
    func unproject(_ point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        var nearest: (source: CGPoint, depth: CGFloat)?
        for face in faces where face.isFrontFacing {
            let bounds = face.projectedBounds.insetBy(dx: -0.000001, dy: -0.000001)
            guard bounds.contains(point), let value = face.unproject(point),
                  nearest == nil || value.depth < nearest!.depth else { continue }
            nearest = value
        }
        return nearest?.source
    }

    var paperPath: CGPath { path(for: documentBounds)! }

    /// Rectangle boundaries split at grid creases and triangle diagonals, so guides
    /// follow exactly the same projective edges as the rendered texture.
    func path(for proposedRect: CGRect) -> CGPath? {
        guard !proposedRect.isNull, proposedRect.origin.x.isFinite, proposedRect.origin.y.isFinite,
              proposedRect.width.isFinite, proposedRect.height.isFinite else { return nil }
        let rect = proposedRect.standardized.intersection(documentBounds)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        let top = edgePoints(from: rect.minX, to: rect.maxX, fixed: rect.minY, horizontal: true)
        let right = edgePoints(from: rect.minY, to: rect.maxY, fixed: rect.maxX, horizontal: false)
        let bottom = edgePoints(from: rect.minX, to: rect.maxX, fixed: rect.maxY, horizontal: true).reversed()
        let left = edgePoints(from: rect.minY, to: rect.maxY, fixed: rect.minX, horizontal: false).reversed()
        let path = CGMutablePath()
        var started = false
        for source in top + right + Array(bottom) + Array(left) {
            guard let point = project(source) else { return nil }
            if started { path.addLine(to: point) } else { path.move(to: point); started = true }
        }
        path.closeSubpath()
        return path
    }

    private func edgePoints(from: CGFloat, to: CGFloat, fixed: CGFloat, horizontal: Bool) -> [CGPoint] {
        let along = horizontal ? columns : rows, across = horizontal ? rows : columns
        let cell = Self.cell(containing: fixed, edges: across)
        let fraction = (fixed - across[cell]) / (across[cell + 1] - across[cell])
        var cuts = [from, to] + along.filter { $0 > from && $0 < to }
        for index in 0..<along.count - 1 {
            let diagonal = along[index] + fraction * (along[index + 1] - along[index])
            if diagonal > from && diagonal < to { cuts.append(diagonal) }
        }
        return Self.uniqueEdges(cuts).map {
            horizontal ? CGPoint(x: $0, y: fixed) : CGPoint(x: fixed, y: $0)
        }
    }

    private static func cell(containing value: CGFloat, edges: [CGFloat]) -> Int {
        var low = 0, high = edges.count - 1
        while low + 1 < high {
            let middle = (low + high) / 2
            if edges[middle] <= value { low = middle } else { high = middle }
        }
        return min(low, edges.count - 2)
    }

    private static func uniqueEdges(_ edges: [CGFloat]) -> [CGFloat] {
        edges.sorted().reduce(into: []) { result, value in
            if result.last.map({ abs($0 - value) > 0.000001 }) ?? true { result.append(value) }
        }
    }

    private static func exteriorEdge(_ a: CGPoint, _ b: CGPoint, _ bounds: CGRect) -> Bool {
        (abs(a.x - b.x) < 0.000001 && (abs(a.x - bounds.minX) < 0.000001 || abs(a.x - bounds.maxX) < 0.000001))
            || (abs(a.y - b.y) < 0.000001 && (abs(a.y - bounds.minY) < 0.000001 || abs(a.y - bounds.maxY) < 0.000001))
    }

    fileprivate nonisolated struct Join: Sendable {
        let horizontal: Bool
        let position: CGFloat
        let start: CGFloat
        var end: CGFloat
    }

    @MainActor
    private static func mergedJoins(_ input: [StitchJoin], bounds: CGRect) -> [Join] {
        let joins = input.compactMap { join -> Join? in
            let horizontal = join.axis == .horizontal
            let start = max(join.start, horizontal ? bounds.minX : bounds.minY)
            let end = min(join.end, horizontal ? bounds.maxX : bounds.maxY)
            guard start.isFinite, end.isFinite, join.position.isFinite, end > start else { return nil }
            return Join(horizontal: horizontal, position: join.position, start: start, end: end)
        }.sorted {
            if $0.horizontal != $1.horizontal { return $0.horizontal }
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end
        }
        return joins.reduce(into: []) { result, join in
            if let last = result.last, last.horizontal == join.horizontal,
               abs(last.position - join.position) < 0.001, join.start <= last.end + 0.001 {
                result[result.count - 1].end = max(last.end, join.end)
            } else { result.append(join) }
        }
    }

    fileprivate nonisolated struct Fold: Sendable {
        let join: Join
        let halfWidth: CGFloat
        let pleats: Int
        let startTaper: CGFloat
        let endTaper: CGFloat
        var segmentLength: CGFloat { halfWidth / CGFloat(pleats) }
        var alongEdges: [CGFloat] {
            [join.start, join.start + startTaper, join.end - endTaper, join.end]
        }
        init(join: Join, halfWidth: CGFloat, pleats: Int, bounds: CGRect) {
            self.join = join
            self.halfWidth = halfWidth
            self.pleats = pleats
            let taper = min(halfWidth * 1.25, (join.end - join.start) / 4)
            startTaper = abs(join.start - (join.horizontal ? bounds.minX : bounds.minY)) < 0.001 ? 0 : taper
            endTaper = abs(join.end - (join.horizontal ? bounds.maxX : bounds.maxY)) < 0.001 ? 0 : taper
        }
        func weight(at along: CGFloat) -> CGFloat {
            guard along >= join.start, along <= join.end else { return 0 }
            let before = startTaper > 0 ? min(1, (along - join.start) / startTaper) : 1
            let after = endTaper > 0 ? min(1, (join.end - along) / endTaper) : 1
            return max(0, min(before, after))
        }
    }

    private nonisolated struct Point3: Sendable {
        var x: CGFloat
        var y: CGFloat
        var z: CGFloat
        static func - (a: Self, b: Self) -> Self { Self(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
        static func cross(_ a: Self, _ b: Self) -> Self {
            Self(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
        }
        func dot(_ other: Self) -> CGFloat { x * other.x + y * other.y + z * other.z }
        var normalized: Self {
            let length = sqrt(x * x + y * y + z * z)
            return length > 0 ? Self(x: x / length, y: y / length, z: z / length) : Self(x: 0, y: 0, z: 1)
        }
    }

    private nonisolated struct Camera: Sendable {
        let distance: CGFloat
        let pitch: CGFloat
        let yaw: CGFloat
        init(bounds: CGRect, perspective: CGFloat, yaw: CGFloat) {
            distance = max(bounds.width, bounds.height) * 3.2
            pitch = -perspective * .pi / 180
            self.yaw = yaw * .pi / 180
        }
        func rotate(_ point: Point3) -> Point3 {
            let x = point.x * cos(yaw) + point.z * sin(yaw)
            let z = -point.x * sin(yaw) + point.z * cos(yaw)
            return Point3(x: x, y: point.y * cos(pitch) - z * sin(pitch),
                          z: point.y * sin(pitch) + z * cos(pitch))
        }
        func project(_ point: Point3) -> (CGPoint, CGFloat)? {
            let rotated = rotate(point)
            let depth = distance - rotated.z
            guard depth.isFinite, depth > distance * 0.2 else { return nil }
            return (CGPoint(x: rotated.x * distance / depth, y: rotated.y * distance / depth), depth)
        }
    }
}
