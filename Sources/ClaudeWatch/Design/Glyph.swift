import SwiftUI

/// The mark: a four-point gem.
///
/// The gem path is transcribed from the design spec and unchanged. What differs
/// from the spec is that the tilted orbit is no longer drawn — see D29. Without
/// a ring around it the gem is scaled up to fill the bar, so the artwork
/// occupies 4…32 of the 36pt canvas rather than the spec's 8…28.
///
/// The orbit geometry is kept below because the panel's empty state still uses
/// it (a parked orbit reads as "nothing to do") and the `Pip` spinner style
/// travels along it.
enum Glyph {
    /// The design canvas every path below is expressed in.
    static let canvas: CGFloat = 36
    static let centre = CGPoint(x: 18, y: 18)

    /// How much the gem is enlarged now that no ring surrounds it.
    ///
    /// The spec's gem spans 8…28 (20pt) to leave room for the orbit. With the
    /// orbit gone that margin is dead space, so the gem is scaled to span
    /// 4…32 (28pt) and carries the mark on its own.
    static let gemFillScale: CGFloat = 28.0 / 20.0

    /// Orbit ellipse geometry.
    static let orbitRX: CGFloat = 11.5
    static let orbitRY: CGFloat = 5
    static let orbitTilt: Angle = .degrees(-20)

    /// The two arc endpoints, where the ellipse is cut into halves.
    /// Spec: `M7.19 21.93 A11.5 5 -20 0 1 28.81 14.07` and its reverse.
    static let arcStart = CGPoint(x: 7.19, y: 21.93)
    static let arcEnd   = CGPoint(x: 28.81, y: 14.07)

    // MARK: - Gem

    /// `M18 8C18.9 13.4 22.6 17.1 28 18C22.6 18.9 18.9 22.6 18 28C17.1 22.6
    ///  13.4 18.9 8 18C13.4 17.1 17.1 13.4 18 8Z`
    ///
    /// A single closed path with concave curved flanks: the waist of each spike
    /// pulls toward the centre, so it reads as a polished crystal rather than a
    /// star. Filled, never stroked, which is why it never fills in at 16pt.
    static func gemPath(in rect: CGRect, scale: CGFloat = gemFillScale) -> Path {
        let path = rawGemPath(in: rect)
        guard scale != 1 else { return path }
        let c = Glyph.scale(for: rect)(centre)
        return path.applying(
            CGAffineTransform(translationX: c.x, y: c.y)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -c.x, y: -c.y)
        )
    }

    /// The gem at the spec's original size, used where it still sits inside the
    /// orbit (the empty state, and the Pip style's hollow outline).
    static func rawGemPath(in rect: CGRect) -> Path {
        var p = Path()
        let s = scale(for: rect)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { s(CGPoint(x: x, y: y)) }

        p.move(to: pt(18, 8))
        p.addCurve(to: pt(28, 18), control1: pt(18.9, 13.4), control2: pt(22.6, 17.1))
        p.addCurve(to: pt(18, 28), control1: pt(22.6, 18.9), control2: pt(18.9, 22.6))
        p.addCurve(to: pt(8, 18),  control1: pt(17.1, 22.6), control2: pt(13.4, 18.9))
        p.addCurve(to: pt(18, 8),  control1: pt(13.4, 17.1), control2: pt(17.1, 13.4))
        p.closeSubpath()
        return p
    }

    // MARK: - Orbit

    /// Which half of the orbit to draw. The halves are the same arc traversed
    /// in opposite directions, so the gem can be drawn between them.
    enum ArcHalf {
        case back   // arcStart → arcEnd
        case front  // arcEnd → arcStart
    }

    /// One half of the orbit ellipse.
    ///
    /// `ry` is a parameter rather than a constant because the working animation
    /// tips the ring by animating exactly this number and nothing else.
    static func orbitPath(in rect: CGRect,
                          half: ArcHalf,
                          ry: CGFloat = orbitRY) -> Path {
        // Build the ellipse in its own unrotated space, take the half we want,
        // then apply the tilt. Sweeping an SVG elliptical arc directly is
        // needlessly awkward; the ellipse is symmetric, so half of it is
        // exactly the portion above or below the major axis.
        let s = scale(for: rect)
        let c = s(centre)
        let k = rect.width / canvas
        let rx = orbitRX * k
        let ryS = ry * k

        var p = Path()
        // Parameterise the ellipse: t ∈ [0, π] is one half, [π, 2π] the other.
        let steps = 48
        let range: (CGFloat, CGFloat) = half == .back ? (.pi, 2 * .pi) : (0, .pi)
        for i in 0...steps {
            let t = range.0 + (range.1 - range.0) * CGFloat(i) / CGFloat(steps)
            let point = CGPoint(x: c.x + rx * cos(t), y: c.y + ryS * sin(t))
            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
        }
        return p.applying(
            CGAffineTransform(translationX: c.x, y: c.y)
                .rotated(by: orbitTilt.radians)
                .translatedBy(x: -c.x, y: -c.y)
        )
    }

    /// The full orbit as a closed ellipse — used by the done halo and the
    /// needs-you ping, which are rings rather than arcs.
    static func ringPath(in rect: CGRect, radius: CGFloat) -> Path {
        let s = scale(for: rect)
        let c = s(centre)
        let r = radius * (rect.width / canvas)
        return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    // MARK: - Scaling

    /// Maps a point in the 36×36 design canvas onto `rect`.
    ///
    /// Uniform scale from the smaller dimension so the glyph never distorts in
    /// a non-square frame.
    static func scale(for rect: CGRect) -> (CGPoint) -> CGPoint {
        let k = min(rect.width, rect.height) / canvas
        let dx = rect.minX + (rect.width - canvas * k) / 2
        let dy = rect.minY + (rect.height - canvas * k) / 2
        return { CGPoint(x: dx + $0.x * k, y: dy + $0.y * k) }
    }

    /// Converts a design-canvas stroke weight to `rect`'s scale.
    static func strokeWidth(_ w: CGFloat, in rect: CGRect) -> CGFloat {
        w * (min(rect.width, rect.height) / canvas)
    }
}
