import AppKit
import CoreGraphics
import SwiftUI

/// Draws the glyph into a Core Graphics context.
///
/// This is the single implementation of the icon's geometry. It exists as plain
/// `CGContext` drawing rather than SwiftUI because the status item redraws
/// twelve times a second: rendering a SwiftUI view through `ImageRenderer` at
/// that rate rebuilds the whole view graph every frame and measured ~10% CPU,
/// where drawing the paths directly measures ~0.3%.
///
/// `StatusIconView` wraps this for on-screen use (the settings picker), so both
/// paths draw identical geometry from identical numbers.
enum GlyphDrawing {

    /// Everything a frame needs. A value type so it can be compared cheaply and
    /// a redraw skipped when nothing changed.
    struct Frame: Equatable {
        var state: IconState
        var phase: Double
        var isAnimating: Bool
    }

    // MARK: - Entry point

    static func draw(_ frame: Frame, in ctx: CGContext, rect: CGRect, ink: CGColor) {
        ctx.saveGState()
        // Core Graphics is y-up and the design canvas is y-down, so flip once
        // here rather than inverting every coordinate in the spec.
        ctx.translateBy(x: 0, y: rect.height)
        ctx.scaleBy(x: 1, y: -1)

        ctx.setStrokeColor(ink)
        ctx.setFillColor(ink)

        switch frame.state {
        case .idle:       drawIdle(ctx, rect, ink)
        case .working:    drawWorking(frame, ctx, rect)
        case .doneUnseen: drawDone(frame, ctx, rect, ink)
        case .needsYou:   drawNeedsYou(frame, ctx, rect, ink)
        case .failed:     drawFailed(ctx, rect, ink)
        }
        ctx.restoreGState()
    }

    // MARK: - Idle

    /// Solid at full alpha, no motion. The resting pose, and the shape every
    /// other state is a deviation from.
    private static func drawIdle(_ ctx: CGContext, _ rect: CGRect, _ ink: CGColor) {
        fill(ctx, Glyph.gemPath(in: rect))
    }

    // MARK: - Working

    /// The gem spins. With no ring around it the mark carries "busy" through
    /// rotation alone, which is the most legible motion available to a solid
    /// silhouette — nothing travels across the screen, so the eye is never
    /// pulled sideways into it.
    ///
    /// The gem is fourfold symmetric, so a quarter turn is loop-invariant: the
    /// animation closes with no restart to catch. Rotation stays linear, as the
    /// spec has it for the gem.
    private static func drawWorking(_ f: Frame, _ ctx: CGContext, _ rect: CGRect) {
        let gemAngle: Double = f.isAnimating
            ? f.phase * Motion.Precession.gemRotation
            : Motion.Precession.staticGemAngle
        fill(ctx, rotatedGem(in: rect, degrees: gemAngle))
    }

    // MARK: - Done

    /// The payoff. The gem overshoots to 1.20 and settles at 1.00 — one
    /// gesture, 900ms, then complete stillness in the accent colour.
    ///
    /// The overshoot is what makes it feel like an event rather than a colour
    /// swap; the stillness afterwards is what makes it safe to leave up,
    /// because a colour that stays put stops being urgent within seconds.
    private static func drawDone(_ f: Frame, _ ctx: CGContext,
                                 _ rect: CGRect, _ ink: CGColor) {
        let scale = f.isAnimating ? doneGemScale(f.phase) : Motion.Done.staticScale
        withScale(ctx, rect, scale) {
            fill(ctx, Glyph.gemPath(in: rect))
        }
    }

    /// One hard breath per period: min → max → min through ease-in-out.
    static func doneGemScale(_ phase: Double) -> CGFloat {
        Motion.lerp(Motion.Done.pulseMin, Motion.Done.pulseMax, Motion.pingPong(phase))
    }

    // MARK: - Needs you

    /// Same orange as done, deliberately — a second alert colour would make the
    /// palette ambiguous. The two are told apart by behaviour: done happened
    /// once and went still, needs-you keeps pulsing and will not stop until you
    /// deal with it. Motion outranks hue for peripheral detection.
    private static func drawNeedsYou(_ f: Frame, _ ctx: CGContext,
                                     _ rect: CGRect, _ ink: CGColor) {
        let scale: CGFloat = f.isAnimating
            ? Motion.lerp(Motion.NeedsYou.pulseMin, Motion.NeedsYou.pulseMax,
                          Motion.pingPong(f.phase))
            : Motion.NeedsYou.staticScale
        withScale(ctx, rect, scale) {
            fill(ctx, Glyph.gemPath(in: rect))
        }
    }

    // MARK: - Failed

    /// Muted red, fully static, and the silhouette is broken: a wedge is cut
    /// out of the gem's lower-right flank so the shape no longer closes.
    ///
    /// That break is the point — a user who cannot separate #C2564A from
    /// #D97757 still sees a severed mark. Static because a failure is finished;
    /// animating it would imply something is still happening.
    private static func drawFailed(_ ctx: CGContext, _ rect: CGRect, _ ink: CGColor) {
        ctx.saveGState()
        // Clip away the notch, then fill the gem through what remains.
        ctx.addRect(rect)
        ctx.addPath(notchPath(in: rect).cgPath)
        ctx.clip(using: .evenOdd)
        fill(ctx, Glyph.gemPath(in: rect))
        ctx.restoreGState()
    }

    /// The wedge removed from the failed mark, in design-canvas coordinates.
    private static func notchPath(in rect: CGRect) -> Path {
        let s = Glyph.scale(for: rect)
        let k = min(rect.width, rect.height) / Glyph.canvas
        let c = s(Glyph.centre)
        // A bar across the lower-right flank, rotated to cut the spike cleanly.
        let w = Motion.Failed.notchWidth * k
        let len = Motion.Failed.notchLength * k
        var p = Path()
        p.addRect(CGRect(x: -len / 2, y: -w / 2, width: len, height: w))
        return p.applying(
            CGAffineTransform(translationX: c.x, y: c.y)
                .rotated(by: .pi * Motion.Failed.notchAngle / 180)
                .translatedBy(x: Motion.Failed.notchOffset * k, y: 0)
        )
    }

    static func arcLength(of path: Path) -> CGFloat {
        var total: CGFloat = 0
        var previous: CGPoint?
        path.forEach { element in
            switch element {
            case .move(let to): previous = to
            case .line(let to):
                if let p = previous { total += hypot(to.x - p.x, to.y - p.y) }
                previous = to
            default: break
            }
        }
        return total
    }

    // MARK: - Primitives

    private static func strokeArc(_ ctx: CGContext, _ rect: CGRect,
                                  half: Glyph.ArcHalf, width: CGFloat,
                                  ry: CGFloat = Glyph.orbitRY,
                                  cap: CGLineCap = .round) {
        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.setLineCap(cap)
        ctx.addPath(Glyph.orbitPath(in: rect, half: half, ry: ry).cgPath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func fill(_ ctx: CGContext, _ path: Path) {
        ctx.addPath(path.cgPath)
        ctx.fillPath()
    }

    private static func withScale(_ ctx: CGContext, _ rect: CGRect,
                                  _ scale: CGFloat, _ body: () -> Void) {
        let c = Glyph.scale(for: rect)(Glyph.centre)
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -c.x, y: -c.y)
        body()
        ctx.restoreGState()
    }

    static func rotatedGem(in rect: CGRect, degrees: Double) -> Path {
        let c = Glyph.scale(for: rect)(Glyph.centre)
        return Glyph.gemPath(in: rect).applying(
            CGAffineTransform(translationX: c.x, y: c.y)
                .rotated(by: .pi * degrees / 180)
                .translatedBy(x: -c.x, y: -c.y)
        )
    }
}
