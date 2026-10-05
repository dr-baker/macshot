import AppKit

/// A shallow Z fold: a small bend in the upper sheet, a thin return, and
/// a shadow beneath its lower landing. All dimensions are document pixels.
struct StitchFoldGeometry {
    let join: StitchJoin
    let strength: CGFloat
    let bendWidth: CGFloat
    let displacement: CGFloat
    let returnWidth: CGFloat
    let shadowWidth: CGFloat
    private let taper: CGFloat

    init?(join: StitchJoin, style: StitchStyle) {
        let length = join.end - join.start
        guard length > 0, style.foldDepth.isFinite, style.foldDepth > 0,
              style.foldStrength.isFinite, style.foldStrength > 0 else { return nil }
        let depth = min(style.foldDepth, length / 6)
        self.join = join
        strength = min(StitchStyle.maximumFoldStrength, style.foldStrength)
        bendWidth = depth * 0.22
        displacement = min(0.6, depth / 30) * strength
        returnWidth = min(1.5, depth * 0.08)
        shadowWidth = min(3, depth * 0.15)
        taper = min(8, length / 4)
    }

    var upperTurn: CGFloat { -returnWidth * 0.45 }
    var lowerLanding: CGFloat { returnWidth * 0.55 }

    static func extent(style: StitchStyle) -> CGFloat {
        guard style.foldDepth > 0, style.foldStrength > 0 else { return 0 }
        return max(style.foldDepth * 0.22,
            min(1.5, style.foldDepth * 0.08) * 0.55 + min(3, style.foldDepth * 0.15)) + 1
    }

    func envelope(at along: CGFloat) -> CGFloat {
        let t = min(1, max(0, min(along - join.start, join.end - along) / taper))
        return t * t * (3 - 2 * t)
    }

    /// Both boundaries remain fixed. The small inverse displacement bends
    /// captured detail without opening a gap or borrowing the lower sheet.
    func offset(at normal: CGFloat) -> CGFloat {
        let t = (normal + bendWidth) / bendWidth
        guard t > 0, t < 1 else { return 0 }
        let bend = sin(.pi * t)
        return displacement * bend * bend
    }

    func point(along: CGFloat, normal: CGFloat) -> CGPoint {
        join.axis == .horizontal ? CGPoint(x: along, y: join.position + normal)
            : CGPoint(x: join.position + normal, y: along)
    }

    func bounds(from upper: CGFloat, to lower: CGFloat) -> CGRect {
        join.axis == .horizontal
            ? CGRect(x: join.start, y: join.position + upper, width: join.end - join.start, height: lower - upper)
            : CGRect(x: join.position + upper, y: join.start, width: lower - upper, height: join.end - join.start)
    }

    func band(from upper: CGFloat, to lower: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let start = join.start, end = join.end
        path.move(to: point(along: start, normal: 0))
        path.addCurve(to: point(along: start + taper, normal: upper),
            control1: point(along: start + taper / 3, normal: 0),
            control2: point(along: start + taper * 2 / 3, normal: upper))
        path.addLine(to: point(along: end - taper, normal: upper))
        path.addCurve(to: point(along: end, normal: 0),
            control1: point(along: end - taper * 2 / 3, normal: upper),
            control2: point(along: end - taper / 3, normal: 0))
        path.addCurve(to: point(along: end - taper, normal: lower),
            control1: point(along: end - taper / 3, normal: 0),
            control2: point(along: end - taper * 2 / 3, normal: lower))
        path.addLine(to: point(along: start + taper, normal: lower))
        path.addCurve(to: point(along: start, normal: 0),
            control1: point(along: start + taper * 2 / 3, normal: lower),
            control2: point(along: start + taper / 3, normal: 0))
        path.closeSubpath()
        return path
    }
}
