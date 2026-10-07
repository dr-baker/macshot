import AppKit

/// Alternating front and return faces, measured in document pixels.
struct StitchAccordionGeometry {
    struct Face {
        let start: CGFloat
        let end: CGFloat
        let isReturn: Bool
    }

    let join: StitchJoin
    let width: CGFloat
    let pleats: Int
    private let taper: CGFloat

    init?(join: StitchJoin, style: StitchStyle) {
        let length = join.end - join.start
        guard length.isFinite, length > 0, style.accordionWidth.isFinite, style.accordionWidth > 0,
              style.accordionPleats.isFinite else { return nil }
        self.join = join
        width = min(80, style.accordionWidth, length / 3)
        pleats = Int(max(2, min(6, style.accordionPleats.rounded())))
        taper = min(width * 0.65, length / 4)
    }

    var faces: [Face] {
        let pitch = width / CGFloat(pleats)
        return (0..<pleats).flatMap { index in
            let start = -width / 2 + CGFloat(index) * pitch
            let ridge = start + pitch * 0.64
            return [Face(start: start, end: ridge, isReturn: false),
                    Face(start: ridge, end: start + pitch, isReturn: true)]
        }
    }

    func point(along: CGFloat, normal: CGFloat) -> CGPoint {
        join.axis == .horizontal ? CGPoint(x: along, y: join.position + normal)
            : CGPoint(x: join.position + normal, y: along)
    }

    func bounds(from start: CGFloat, to end: CGFloat) -> CGRect {
        join.axis == .horizontal
            ? CGRect(x: join.start, y: join.position + start, width: join.end - join.start, height: end - start)
            : CGRect(x: join.position + start, y: join.start, width: end - start, height: join.end - join.start)
    }

    /// All faces meet at the same endpoints so a partial join never leaves a rectangular patch.
    func band(from start: CGFloat, to end: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let a = join.start, b = join.end
        path.move(to: point(along: a, normal: 0))
        path.addCurve(to: point(along: a + taper, normal: start),
            control1: point(along: a + taper / 3, normal: 0),
            control2: point(along: a + taper * 2 / 3, normal: start))
        path.addLine(to: point(along: b - taper, normal: start))
        path.addCurve(to: point(along: b, normal: 0),
            control1: point(along: b - taper * 2 / 3, normal: start),
            control2: point(along: b - taper / 3, normal: 0))
        path.addCurve(to: point(along: b - taper, normal: end),
            control1: point(along: b - taper / 3, normal: 0),
            control2: point(along: b - taper * 2 / 3, normal: end))
        path.addLine(to: point(along: a + taper, normal: end))
        path.addCurve(to: point(along: a, normal: 0),
            control1: point(along: a + taper * 2 / 3, normal: end),
            control2: point(along: a + taper / 3, normal: 0))
        path.closeSubpath()
        return path
    }
}
