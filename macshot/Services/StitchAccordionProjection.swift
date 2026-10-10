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
        /// Texture coordinates in the compact, already-composited screenshot.
        let source: CGPoint
        /// Position on the full unfolded sheet, including the omitted paper.
        let rest: CGPoint
        /// Deformed paper before the camera transform, in document points.
        let world: Point3
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
        /// Omitted paper uses a dominant color sampled from this safe compact seam.
        /// Its source triangle is intentionally degenerate: it contains no removed pixels.
        let paperSample: CGPoint?

        var vertices: [Vertex] { [a, b, c] }
        var projectedBounds: CGRect {
            CGRect(x: min(a.projected.x, b.projected.x, c.projected.x),
                   y: min(a.projected.y, b.projected.y, c.projected.y),
                   width: max(a.projected.x, b.projected.x, c.projected.x) - min(a.projected.x, b.projected.x, c.projected.x),
                   height: max(a.projected.y, b.projected.y, c.projected.y) - min(a.projected.y, b.projected.y, c.projected.y))
        }

        func project(_ point: CGPoint) -> CGPoint? {
            guard let weights = Self.weights(point, a.source, b.source, c.source) else { return nil }
            return projectedPoint(weights)
        }

        func projectRest(_ point: CGPoint) -> CGPoint? {
            guard let weights = Self.weights(point, a.rest, b.rest, c.rest) else { return nil }
            return projectedPoint(weights)
        }

        private func projectedPoint(_ weights: Weights) -> CGPoint? {
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
        let unfoldedBounds: CGRect
        let camera: StitchPaperCamera
        fileprivate let folds: [Fold]
        fileprivate let columns: [CGFloat]
        fileprivate let rows: [CGFloat]

        @MainActor
        init?(document: StitchDocument) {
            guard document.canRender else { return nil }
            let bounds = document.bounds.integral
            guard StitchAccordionProjection.validBounds(bounds) else { return nil }
            let style = document.style
            let documentJoins = document.joins
            let active = style.visible && style.transition == .accordion && documentJoins.contains {
                $0.trimmedLength.map { $0 > 0 } ?? (style.accordionWidth != 0)
            }
            let folds: [Fold]
            if active {
                guard style.accordionWidth.isFinite, style.accordionWidth >= 0, style.accordionWidth <= 80,
                      style.accordionPleats.isFinite, (2...6).contains(style.accordionPleats),
                      style.accordionPerspective.isFinite, StitchPaperCamera.perspectiveRange.contains(style.accordionPerspective),
                      style.accordionYaw.isFinite, StitchPaperCamera.yawRange.contains(style.accordionYaw) else { return nil }
                let joins = StitchAccordionProjection.mergedJoins(documentJoins, bounds: bounds)
                var result: [Fold] = []
                for join in joins {
                    let length = join.trimmedLength ?? style.accordionWidth * 4
                    guard length.isFinite, length >= 0, length <= 30_000 else { return nil }
                    guard length > 0.001 else { continue }
                    result.append(Fold(join: join, paperLength: length, pleats: Int(style.accordionPleats.rounded())))
                }
                folds = result
            } else { folds = [] }

            var xEdges = [bounds.minX, bounds.maxX], yEdges = [bounds.minY, bounds.maxY]
            for fold in folds {
                if fold.join.horizontal {
                    yEdges.append(fold.join.position)
                    xEdges += [fold.join.start, fold.join.end]
                } else {
                    xEdges.append(fold.join.position)
                    yEdges += [fold.join.start, fold.join.end]
                }
            }
            let columns = StitchAccordionProjection.uniqueEdges(xEdges)
            let rows = StitchAccordionProjection.uniqueEdges(yEdges)
            guard columns.count * rows.count <= 16_384 else { return nil }
            let paperFaces = folds.reduce(0) { total, fold in
                let edges = fold.join.horizontal ? columns : rows
                let intervals = zip(edges, edges.dropFirst()).filter {
                    ($0.0 + $0.1) / 2 > fold.join.start && ($0.0 + $0.1) / 2 < fold.join.end
                }.count
                return total + intervals * fold.pleats * 4
            }
            guard (columns.count - 1) * (rows.count - 1) * 2 + paperFaces <= 32_768 else { return nil }
            // Check restored dimensions before allocating any vertex or triangle
            // buffers. Provenance can outlive the original captured image.
            let unfolded = StitchAccordionProjection.restBounds(bounds: bounds, folds: folds,
                                                                 columns: columns, rows: rows)
            guard StitchAccordionProjection.validBounds(unfolded) else { return nil }
            self.documentBounds = bounds
            self.unfoldedBounds = unfolded
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
    /// The compact texture domain. Annotations and redactions stay in this space.
    let documentBounds: CGRect
    /// The raster envelope in projected document points, independent of texture size.
    private(set) var outputBounds: CGRect
    let hasProjectedOutput: Bool
    /// Content triangles precede inserted paper triangles. Order is stable at every progress.
    let faces: [Face]
    let drawingOrder: [Int]
    private let columns: [CGFloat]
    private let rows: [CGFloat]

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
        let angle = acos(CGFloat(0.45)) * progress
        let mesh = Self.mesh(bounds: bounds, folds: source.folds, columns: source.columns,
                             rows: source.rows, compression: cos(angle), ridgeSlope: sin(angle))
        let points = mesh.flatMap { [$0.a.world, $0.b.world, $0.c.world] }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let camera = Camera(bounds: source.unfoldedBounds,
                            perspective: source.folds.isEmpty ? 0 : source.camera.perspective * progress,
                            yaw: source.folds.isEmpty ? 0 : source.camera.yaw * progress)
        func projected(_ vertex: MeshVertex) -> (CGPoint, CGFloat)? {
            camera.project(Point3(x: vertex.world.x - center.x, y: vertex.world.y - center.y, z: vertex.world.z))
        }
        var raw: [(a: (CGPoint, CGFloat), b: (CGPoint, CGFloat), c: (CGPoint, CGFloat))] = []
        raw.reserveCapacity(mesh.count)
        for triangle in mesh {
            guard let a = projected(triangle.a), let b = projected(triangle.b), let c = projected(triangle.c) else { return nil }
            raw.append((a, b, c))
        }
        let projectedPoints = raw.flatMap { [$0.a.0, $0.b.0, $0.c.0] }
        let rawMinX = projectedPoints.map(\.x).min()!, rawMaxX = projectedPoints.map(\.x).max()!
        let rawMinY = projectedPoints.map(\.y).min()!, rawMaxY = projectedPoints.map(\.y).max()!
        let rawCenter = CGPoint(x: (rawMinX + rawMaxX) / 2, y: (rawMinY + rawMaxY) / 2)
        func vertex(_ value: MeshVertex, _ projected: (CGPoint, CGFloat)) -> Vertex {
            Vertex(source: value.source, rest: value.rest, world: value.world,
                   projected: CGPoint(x: bounds.midX + projected.0.x - rawCenter.x,
                                      y: bounds.midY + projected.0.y - rawCenter.y), depth: projected.1)
        }
        var edgeCounts: [EdgeKey: Int] = [:]
        for triangle in mesh {
            for edge in triangle.edges { edgeCounts[edge, default: 0] += 1 }
        }
        let flatNormal = camera.rotate(Point3(x: 0, y: 0, z: 1))
        let light = Point3(x: -0.25, y: -0.5, z: 0.83).normalized
        let faces = zip(mesh, raw).map { triangle, raw -> Face in
            let a = vertex(triangle.a, raw.a), b = vertex(triangle.b, raw.b), c = vertex(triangle.c, raw.c)
            let winding = (b.projected.x - a.projected.x) * (c.projected.y - a.projected.y)
                - (b.projected.y - a.projected.y) * (c.projected.x - a.projected.x)
            var normal = camera.rotate(Point3.cross(triangle.b.world - triangle.a.world,
                                                   triangle.c.world - triangle.a.world)).normalized
            if triangle.paperSample != nil && winding < 0 { normal = Point3(x: -normal.x, y: -normal.y, z: -normal.z) }
            let shade = max(0.72, min(1.08, 1 + 0.32 * (normal.dot(light) - flatNormal.dot(light))))
            let edges = triangle.edges
            let mask = (edgeCounts[edges[0]] == 1 ? 1 : 0)
                | (edgeCounts[edges[1]] == 1 ? 2 : 0) | (edgeCounts[edges[2]] == 1 ? 4 : 0)
            return Face(a: a, b: b, c: c, shade: shade, isFrontFacing: winding > 0.000000001,
                        boundaryEdges: mask, paperSample: triangle.paperSample)
        }
        let naturalBounds = CGRect(x: bounds.midX + rawMinX - rawCenter.x,
                                   y: bounds.midY + rawMinY - rawCenter.y,
                                   width: rawMaxX - rawMinX, height: rawMaxY - rawMinY).integral
        guard Self.validBounds(naturalBounds) else { return nil }
        self.source = source
        self.documentBounds = bounds
        self.outputBounds = naturalBounds
        self.hasProjectedOutput = !source.folds.isEmpty
        self.columns = source.columns
        self.rows = source.rows
        self.faces = faces
        self.drawingOrder = faces.indices.sorted {
            let a = faces[$0], b = faces[$1]
            let difference = a.a.depth + a.b.depth + a.c.depth - b.a.depth - b.b.depth - b.c.depth
            return abs(difference) > 0.000001 ? difference > 0 : $0 < $1
        }
    }

    func outputPixelDimensions(pixelWidth: Int, pixelHeight: Int) -> (width: Int, height: Int)? {
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 30_000, pixelHeight <= 30_000,
              pixelWidth * pixelHeight <= 100_000_000 else { return nil }
        let width = ceil(outputBounds.width * CGFloat(pixelWidth) / documentBounds.width)
        let height = ceil(outputBounds.height * CGFloat(pixelHeight) / documentBounds.height)
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 30_000, height <= 30_000, width * height <= 100_000_000 else { return nil }
        return (Int(width), Int(height))
    }

    /// Animation frames share one envelope without scaling or moving the paper.
    func withOutputBounds(_ envelope: CGRect) -> Self? {
        guard Self.validBounds(envelope), envelope.contains(outputBounds) else { return nil }
        var result = self
        result.outputBounds = envelope.integral
        return result
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

    /// The nearest visible face wins. Paper return faces have the same sampled
    /// material on both sides, and map back to their compact seam for interaction.
    func unproject(_ point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        var nearest: (source: CGPoint, depth: CGFloat)?
        for face in faces where face.isFrontFacing || face.paperSample != nil {
            let bounds = face.projectedBounds.insetBy(dx: -0.000001, dy: -0.000001)
            guard bounds.contains(point), let value = face.unproject(point),
                  nearest == nil || value.depth < nearest!.depth else { continue }
            nearest = value
        }
        return nearest?.source
    }

    /// A union of visible triangles includes pleat ridges, slits and partial seams.
    var paperPath: CGPath {
        let path = CGMutablePath()
        for face in faces where face.isFrontFacing || face.paperSample != nil {
            path.move(to: face.a.projected)
            path.addLine(to: face.isFrontFacing ? face.b.projected : face.c.projected)
            path.addLine(to: face.isFrontFacing ? face.c.projected : face.b.projected)
            path.closeSubpath()
        }
        return path
    }

    /// Clip the source selection to each independent paper patch before projecting.
    /// This also follows inserted creases when a selection spans omitted space.
    func path(for proposedRect: CGRect) -> CGPath? {
        guard !proposedRect.isNull, proposedRect.origin.x.isFinite, proposedRect.origin.y.isFinite,
              proposedRect.width.isFinite, proposedRect.height.isFinite else { return nil }
        let rect = proposedRect.standardized.intersection(documentBounds)
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
        let path = CGMutablePath()
        for face in faces where face.isFrontFacing || face.paperSample != nil {
            var polygon = face.vertices.map { ClipPoint(source: $0.source, rest: $0.rest) }
            for (horizontal, edge, greater) in [(true, rect.minX, true), (true, rect.maxX, false),
                                                (false, rect.minY, true), (false, rect.maxY, false)] {
                polygon = Self.clip(polygon, horizontal: horizontal, edge: edge, greater: greater)
            }
            let points = polygon.compactMap { face.projectRest($0.rest) }
            guard points.count >= 3 else { continue }
            path.move(to: points[0])
            for point in (face.isFrontFacing ? Array(points.dropFirst()) : Array(points.dropFirst().reversed())) {
                path.addLine(to: point)
            }
            path.closeSubpath()
        }
        return path
    }

    private nonisolated struct ClipPoint {
        let source: CGPoint
        let rest: CGPoint
    }

    private static func clip(_ input: [ClipPoint], horizontal: Bool, edge: CGFloat, greater: Bool) -> [ClipPoint] {
        guard let last = input.last else { return [] }
        func coordinate(_ point: ClipPoint) -> CGFloat { horizontal ? point.source.x : point.source.y }
        func inside(_ point: ClipPoint) -> Bool { greater ? coordinate(point) >= edge : coordinate(point) <= edge }
        var result: [ClipPoint] = [], before = last
        for point in input {
            if inside(before) != inside(point) {
                let t = (edge - coordinate(before)) / (coordinate(point) - coordinate(before))
                result.append(ClipPoint(source: CGPoint(x: before.source.x + (point.source.x - before.source.x) * t,
                                                       y: before.source.y + (point.source.y - before.source.y) * t),
                                        rest: CGPoint(x: before.rest.x + (point.rest.x - before.rest.x) * t,
                                                      y: before.rest.y + (point.rest.y - before.rest.y) * t)))
            }
            if inside(point) { result.append(point) }
            before = point
        }
        return result
    }

    private static func validBounds(_ bounds: CGRect) -> Bool {
        !bounds.isNull && bounds.minX.isFinite && bounds.minY.isFinite && bounds.maxX.isFinite && bounds.maxY.isFinite
            && bounds.width > 0 && bounds.height > 0 && bounds.width <= 30_000 && bounds.height <= 30_000
            && bounds.width * bounds.height <= 100_000_000
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

    private static func translation(at point: CGPoint, folds: [Fold], compression: CGFloat) -> CGPoint {
        var result = CGPoint.zero
        for fold in folds {
            let along = fold.join.horizontal ? point.x : point.y
            let normal = fold.join.horizontal ? point.y : point.x
            guard along > fold.join.start, along < fold.join.end, normal > fold.join.position else { continue }
            if fold.join.horizontal { result.y += fold.paperLength * compression }
            else { result.x += fold.paperLength * compression }
        }
        return result
    }

    private static func restBounds(bounds: CGRect, folds: [Fold], columns: [CGFloat], rows: [CGFloat]) -> CGRect {
        var result = CGRect.null
        for row in 0..<rows.count - 1 {
            for column in 0..<columns.count - 1 {
                let rect = CGRect(x: columns[column], y: rows[row], width: columns[column + 1] - columns[column],
                                  height: rows[row + 1] - rows[row])
                let offset = translation(at: CGPoint(x: rect.midX, y: rect.midY), folds: folds, compression: 1)
                result = result.union(rect.offsetBy(dx: offset.x, dy: offset.y))
            }
        }
        return result
    }

    private nonisolated struct MeshVertex {
        let source: CGPoint
        let rest: CGPoint
        let world: Point3
    }

    private nonisolated struct Triangle {
        let a: MeshVertex
        let b: MeshVertex
        let c: MeshVertex
        let paperSample: CGPoint?
        var edges: [EdgeKey] { [EdgeKey(b.world, c.world), EdgeKey(c.world, a.world), EdgeKey(a.world, b.world)] }
    }

    private nonisolated struct PositionKey: Hashable, Comparable {
        let x: CGFloat
        let y: CGFloat
        let z: CGFloat
        init(_ point: Point3) {
            x = (point.x * 1_000_000).rounded() / 1_000_000
            y = (point.y * 1_000_000).rounded() / 1_000_000
            z = (point.z * 1_000_000).rounded() / 1_000_000
        }
        static func < (a: Self, b: Self) -> Bool {
            a.x != b.x ? a.x < b.x : (a.y != b.y ? a.y < b.y : a.z < b.z)
        }
    }

    private nonisolated struct EdgeKey: Hashable {
        let a: PositionKey
        let b: PositionKey
        init(_ first: Point3, _ second: Point3) {
            let first = PositionKey(first), second = PositionKey(second)
            a = min(first, second); b = max(first, second)
        }
    }

    private static func mesh(bounds: CGRect, folds: [Fold], columns: [CGFloat], rows: [CGFloat],
                             compression: CGFloat, ridgeSlope: CGFloat) -> [Triangle] {
        var result: [Triangle] = []
        func appendQuad(_ a: MeshVertex, _ b: MeshVertex, _ c: MeshVertex, _ d: MeshVertex, sample: CGPoint? = nil) {
            result.append(Triangle(a: a, b: b, c: c, paperSample: sample))
            result.append(Triangle(a: a, b: c, c: d, paperSample: sample))
        }
        // Every surviving cell is a rigid patch. It translates to make room for
        // actual omitted paper; no surviving screenshot pixels become pleats.
        for row in 0..<rows.count - 1 {
            for column in 0..<columns.count - 1 {
                let x0 = columns[column], x1 = columns[column + 1], y0 = rows[row], y1 = rows[row + 1]
                let midpoint = CGPoint(x: (x0 + x1) / 2, y: (y0 + y1) / 2)
                let restOffset = translation(at: midpoint, folds: folds, compression: 1)
                let offset = translation(at: midpoint, folds: folds, compression: compression)
                func vertex(_ x: CGFloat, _ y: CGFloat) -> MeshVertex {
                    MeshVertex(source: CGPoint(x: x, y: y), rest: CGPoint(x: x + restOffset.x, y: y + restOffset.y),
                               world: Point3(x: x + offset.x, y: y + offset.y, z: 0))
                }
                appendQuad(vertex(x0, y0), vertex(x1, y0), vertex(x1, y1), vertex(x0, y1))
            }
        }
        // Perpendicular creases are slit into independent strips at their
        // intersection. The central crossing is background, rather than a
        // sheared patch produced by adding two unrelated height fields.
        for fold in folds {
            let horizontal = fold.join.horizontal
            let alongEdges = horizontal ? columns : rows
            for (start, end) in zip(alongEdges, alongEdges.dropFirst()) {
                let midpoint = (start + end) / 2
                guard midpoint > fold.join.start, midpoint < fold.join.end else { continue }
                let reference = horizontal ? CGPoint(x: midpoint, y: fold.join.position - 0.00001)
                    : CGPoint(x: fold.join.position - 0.00001, y: midpoint)
                let restOffset = translation(at: reference, folds: folds, compression: 1)
                let offset = translation(at: reference, folds: folds, compression: compression)
                let sample = horizontal ? CGPoint(x: midpoint, y: fold.join.position)
                    : CGPoint(x: fold.join.position, y: midpoint)
                func vertex(_ along: CGFloat, _ segment: Int) -> MeshVertex {
                    let distance = CGFloat(segment) * fold.segmentLength
                    let height = segment.isMultiple(of: 2) ? 0 : fold.segmentLength * ridgeSlope
                    let source = horizontal ? CGPoint(x: along, y: fold.join.position)
                        : CGPoint(x: fold.join.position, y: along)
                    let rest = horizontal ? CGPoint(x: along + restOffset.x, y: fold.join.position + restOffset.y + distance)
                        : CGPoint(x: fold.join.position + restOffset.x + distance, y: along + restOffset.y)
                    let world = horizontal ? Point3(x: along + offset.x, y: fold.join.position + offset.y + distance * compression, z: height)
                        : Point3(x: fold.join.position + offset.x + distance * compression, y: along + offset.y, z: height)
                    return MeshVertex(source: source, rest: rest, world: world)
                }
                for segment in 0..<fold.pleats * 2 {
                    if horizontal {
                        appendQuad(vertex(start, segment), vertex(end, segment), vertex(end, segment + 1),
                                   vertex(start, segment + 1), sample: sample)
                    } else {
                        appendQuad(vertex(start, segment), vertex(start, segment + 1), vertex(end, segment + 1),
                                   vertex(end, segment), sample: sample)
                    }
                }
            }
        }
        return result
    }

    fileprivate nonisolated struct Join: Sendable {
        let horizontal: Bool
        let position: CGFloat
        let start: CGFloat
        var end: CGFloat
        let trimmedLength: CGFloat?
    }

    @MainActor
    private static func mergedJoins(_ input: [StitchJoin], bounds: CGRect) -> [Join] {
        let joins = input.compactMap { join -> Join? in
            let horizontal = join.axis == .horizontal
            let start = max(join.start, horizontal ? bounds.minX : bounds.minY)
            let end = min(join.end, horizontal ? bounds.maxX : bounds.maxY)
            let normalMin = horizontal ? bounds.minY : bounds.minX, normalMax = horizontal ? bounds.maxY : bounds.maxX
            guard start.isFinite, end.isFinite, join.position.isFinite, end > start,
                  join.position > normalMin, join.position < normalMax else { return nil }
            return Join(horizontal: horizontal, position: join.position, start: start, end: end,
                        trimmedLength: join.trimmedLength)
        }.sorted {
            if $0.horizontal != $1.horizontal { return $0.horizontal }
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end
        }
        var result: [Join] = [], group: [Join] = []
        func appendGroup() {
            guard let first = group.first else { return }
            let edges = uniqueEdges(group.flatMap { [$0.start, $0.end] })
            for index in 0..<edges.count - 1 {
                let start = edges[index], end = edges[index + 1], midpoint = (edges[index] + edges[index + 1]) / 2
                let overlapping = group.filter { $0.start < midpoint && $0.end > midpoint }
                guard !overlapping.isEmpty else { continue }
                let segment = Join(horizontal: first.horizontal, position: first.position, start: start, end: end,
                                   trimmedLength: overlapping.compactMap(\.trimmedLength).max())
                if let last = result.last, last.horizontal == segment.horizontal,
                   abs(last.position - segment.position) < 0.001, abs(last.end - segment.start) < 0.001,
                   last.trimmedLength == segment.trimmedLength {
                    result[result.count - 1].end = end
                } else { result.append(segment) }
            }
        }
        for join in joins {
            if let first = group.first,
               first.horizontal != join.horizontal || abs(first.position - join.position) >= 0.001 {
                appendGroup(); group.removeAll(keepingCapacity: true)
            }
            group.append(join)
        }
        appendGroup()
        return result
    }

    fileprivate nonisolated struct Fold: Sendable {
        let join: Join
        let paperLength: CGFloat
        let pleats: Int
        var segmentLength: CGFloat { paperLength / CGFloat(pleats * 2) }
    }

    nonisolated struct Point3: Sendable, Equatable {
        let x: CGFloat
        let y: CGFloat
        let z: CGFloat
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
            let rotated = rotate(point), depth = distance - rotated.z
            guard depth.isFinite, depth > distance * 0.2 else { return nil }
            return (CGPoint(x: rotated.x * distance / depth, y: rotated.y * distance / depth), depth)
        }
    }
}
