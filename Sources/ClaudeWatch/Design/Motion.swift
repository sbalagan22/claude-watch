import Foundation

/// Every keyframe and timing in the icon system, transcribed from the design
/// spec. Views read these; they never contain timing numbers of their own.
///
/// One shared 12fps tick drives everything. The frame index is
/// `floor(t × 12) mod (duration × 12)`, so each animation is a pure function of
/// an integer frame — no interpolation state, no drift, and every loop is
/// period-closed (last keyframe == first).
enum Motion {
    /// The tick rate for the whole system.
    ///
    /// The spec calls for 12fps, which was sized for the tipping orbit whose
    /// stroke weight and `ry` changed on every frame. With the ring gone (D29)
    /// the working state is a slow rotation: at 18pt, 12fps moves the gem's
    /// outermost point about a third of a pixel per frame, so two thirds of
    /// those frames are visually identical to the one before.
    ///
    /// Each frame costs an AppKit re-layout of the status item — profiling put
    /// the cost in `stepTransactionFlush`, not in the drawing — so the surplus
    /// frames were pure waste. 8fps still moves the tip under half a pixel per
    /// frame, which is below the threshold where stepping is visible, and
    /// measured CPU drops by a third.
    static let fps: Double = 8
    static var tickInterval: TimeInterval { 1.0 / fps }

    // MARK: - Working: the spin

    /// The gem turns a quarter over five seconds. 5.000s at 8fps = 40 frames.
    ///
    /// Kept under the name `Precession` because that is what the setting is
    /// called and what the spec named the default style; with the orbit gone
    /// (D29) the motion itself is a plain rotation. The spec's 8s read as
    /// nearly static once the ring was gone, so the period was shortened (D37).
    enum Precession {
        static let period: TimeInterval = 2.5   // D50: halved again from 5s

        /// Fourfold symmetric, so 90° is loop-invariant: the animation closes
        /// with no restart to catch.
        static let gemRotation: Double = 90

        /// Reduce Motion static frame: caught mid-turn, plainly not the idle
        /// pose, so "busy" still lands with zero movement.
        static let staticGemAngle: Double = 34
    }

    // MARK: - Done

    /// One gesture, 900ms, then complete stillness. The overshoot is what makes
    /// it an event rather than a colour swap; the stillness afterwards is what
    /// makes it safe to leave up.
    enum Done {
        /// Done is a loop, not a one-shot (D51). One hard pulse per period —
        /// 10 frames at 8fps, so it closes — that keeps going until the panel
        /// is opened. The earlier 0.9s overshoot-then-freeze was invisible
        /// unless you happened to be looking at the bar in that second.
        static let period: TimeInterval = 1.25
        static let pulseMin: CGFloat = 0.72
        static let pulseMax: CGFloat = 1.28

        /// For this long after a session finishes, done outranks working on
        /// the menu bar glyph. Without it a finish is invisible whenever any
        /// other session is still busy — which, with several sessions open,
        /// is most of the time. After the hold, working takes the glyph back
        /// if anything is still running; if nothing is, done stays until seen.
        static let holdDuration: TimeInterval = 4.0

        /// Reduce Motion: full size, accent colour does the work.
        static let staticScale: CGFloat = 1.0
    }

    // MARK: - Needs you

    /// Keeps pinging until dealt with. Motion outranks hue for peripheral
    /// detection, which is why this is the state most likely to catch you.
    enum NeedsYou {
        static let period: TimeInterval = 3.2
        /// A deeper pulse than Quiet's breath, so "your turn" is legible from
        /// the corner of the eye where "busy" deliberately is not.
        static let pulseMin: CGFloat = 0.88
        static let pulseMax: CGFloat = 1.08

        /// Reduce Motion: held at its larger extreme, plainly not the idle pose.
        static let staticScale: CGFloat = 1.08
    }

    // MARK: - Failed

    /// Static, always. A failure is finished; animating it would imply
    /// something is still happening. The silhouette is broken — a user who
    /// cannot separate the red from the orange still sees a severed mark.
    enum Failed {
        /// The cut that severs the gem's upper-right spike from the body.
        ///
        /// A short bar laid across the spike's waist, angled to match the
        /// diagonal it sits on. It has to clear the waist entirely — a cut that
        /// stops short reads as a dent rather than a break — but stay far
        /// enough out that the body itself is untouched.
        static let notchWidth: CGFloat = 2.6
        static let notchLength: CGFloat = 13
        static let notchAngle: Double = -45
        static let notchOffset: CGFloat = 9.0
    }

    // MARK: - Idle

    enum Idle {
        /// Nothing to configure: the resting pose is the gem, filled and still.
    }

    // MARK: - Panel dot

    /// The only dot that moves: a dashed ring sweeping 360° every 4s.
    enum WorkingDot {
        static let period: TimeInterval = 4.0
        static let radius: CGFloat = 2.6
        static let stroke: CGFloat = 1.4
        static let dash: [CGFloat] = [4.1, 2.1]
    }

    // MARK: - State transitions

    /// Working must hold for at least this long before it may be left, so a
    /// burst of short tool calls does not flicker the icon.
    static let workingDebounce: TimeInterval = 0.8

    // MARK: - Frame indexing

    /// The frame index for a given elapsed time and period.
    /// `floor(t × fps) mod (period × fps)`.
    static func frameIndex(at time: TimeInterval, period: TimeInterval) -> Int {
        let total = max(1, Int((period * fps).rounded()))
        return Int(floor(time * fps)) % total
    }

    /// Normalised phase 0..<1 for a given elapsed time and period, quantised to
    /// the 12fps grid so every consumer sees the same discrete frames.
    static func phase(at time: TimeInterval, period: TimeInterval) -> Double {
        let total = max(1, Int((period * fps).rounded()))
        return Double(frameIndex(at: time, period: period)) / Double(total)
    }

    // MARK: - Easing

    /// The spec distinguishes eased from linear, and that distinction is the
    /// design: scale changes are ease-in-out so a pulse lingers at its extremes
    /// and passes quickly through the middle, which is where a linear version
    /// looks mechanical. Rotation stays linear.
    static func easeInOut(_ t: Double) -> Double {
        // Standard smoothstep-style ease-in-out; matches CSS ease-in-out
        // closely enough at 12fps that the difference is sub-frame.
        t < 0.5
            ? 2 * t * t
            : 1 - pow(-2 * t + 2, 2) / 2
    }

    /// A 0→1→0 triangle run through ease-in-out. The shape of one full breath
    /// or pulse: rest → extreme → rest.
    static func pingPong(_ phase: Double) -> Double {
        let t = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        return easeInOut(t)
    }

    /// Linear interpolation between two values.
    static func lerp<T: BinaryFloatingPoint>(_ a: T, _ b: T, _ t: Double) -> T {
        a + (b - a) * T(t)
    }
}
