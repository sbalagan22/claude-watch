import SwiftUI

/// The menu bar glyph, in every state.
///
/// Drawn as a pure function of `phase` (0..<1, quantised to the 12fps grid by
/// `Motion.phase`). Nothing here uses SwiftUI's animation engine: the controller
/// advances the phase on one shared tick and re-renders. That keeps the frame
/// rate exactly where the spec puts it and lets each frame be rasterised to an
/// `NSImage` for the template states.
///
/// Colour appears only in the three states that are asking for the user's
/// attention. Idle and working are monochrome, so a glance learns "busy" from
/// movement and colour stays free to mean "your turn".
///
/// The mark is the gem alone — see D29.
struct StatusIconView: View {
    let state: IconState
    /// 0..<1. Ignored where the state is static.
    let phase: Double
    let workingCount: Int
    /// False under Reduce Motion or when animation is switched off: each state
    /// swaps to its designed static frame, never a paused phase 0.
    let isAnimating: Bool
    /// True when this frame is being rasterised into a template `NSImage`, so
    /// monochrome states must be pure black. False when drawing on screen,
    /// where they resolve to `.primary` and follow the appearance.
    var forTemplate: Bool = false

    /// Drawing offscreen there is no current appearance, so the view's own
    /// colour scheme decides how the monochrome ink resolves.
    @SwiftUI.Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            draw(in: &context, rect: rect)
        }
        .frame(width: Metrics.statusIconSize, height: Metrics.statusIconSize)
        // The glyph is one control, not five images.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Drawing

    /// Delegates to `GlyphDrawing`, the single implementation of the geometry,
    /// so this view and the status item's rasterised frames can never drift
    /// apart. `Canvas` gives direct access to the underlying `CGContext`.
    private func draw(in context: inout GraphicsContext, rect: CGRect) {
        let frame = GlyphDrawing.Frame(state: state, phase: phase,
                                       isAnimating: isAnimating)
        context.withCGContext { cg in
            GlyphDrawing.draw(frame, in: cg, rect: rect,
                              ink: IconPalette.cgInk(
                                  for: state,
                                  forTemplate: forTemplate,
                                  appearance: NSAppearance(
                                      named: colorScheme == .dark ? .darkAqua : .aqua)
                              ))
        }
    }

    private var accessibilityText: String {
        switch state {
        case .idle:       "Claude Code: no active sessions"
        case .working:    workingCount > 1
            ? "Claude Code: \(workingCount) sessions working"
            : "Claude Code: working"
        case .needsYou:   "Claude Code: needs your input"
        case .failed:     "Claude Code: a session failed"
        case .doneUnseen: "Claude Code: a session finished"
        }
    }
}
