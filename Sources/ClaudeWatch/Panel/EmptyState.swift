import SwiftUI

/// Shown when no sessions are attached.
///
/// The gem in outline only, with one accent pip resting below it — nothing is
/// *broken* here, it is simply at rest, which is the difference between
/// "nothing to do" and "something went wrong". The outline treatment is what
/// separates it from the filled idle mark in the bar.
///
/// Deliberately small and low-contrast: an empty panel is the normal state of a
/// monitoring tool, not a failure, so it neither apologises nor fills the space
/// with encouragement.
struct EmptyState: View {
    var body: some View {
        VStack(spacing: Metrics.spaceL) {
            Canvas(rendersAsynchronously: false) { context, size in
                draw(&context, CGRect(origin: .zero, size: size))
            }
            .frame(width: Metrics.emptyGlyphSize, height: Metrics.emptyGlyphSize)

            VStack(spacing: Metrics.spaceS) {
                Text("Nothing running")
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.primaryText)
                Text("Start Claude Code in a terminal and it shows up here.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.spaceXL)
        .accessibilityElement(children: .combine)
    }

    private func draw(_ c: inout GraphicsContext, _ rect: CGRect) {
        let ink = GraphicsContext.Shading.color(
            Palette.primaryText.opacity(Metrics.emptyGlyphStrokeOpacity)
        )
        // Outline only — the gem is stroked here, not filled, which is what
        // makes the mark read as dormant beside the filled one in the bar.
        c.stroke(Glyph.gemPath(in: rect), with: ink,
                 style: StrokeStyle(lineWidth: Glyph.strokeWidth(1.1, in: rect), lineJoin: .round))

        // The pip at rest, just below the gem.
        let s = Glyph.scale(for: rect)
        let k = min(rect.width, rect.height) / Glyph.canvas
        let centre = s(CGPoint(x: 18, y: 31))
        let r = 1.7 * k
        c.fill(
            Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
            with: .color(Palette.accent.opacity(Metrics.emptyGlyphPipOpacity))
        )
    }
}
