import SwiftUI

/// The per-session state dot. Drawn on an 8pt design box, shown at `Metrics.dotSize`.
///
/// Every state gets its own *form*, not just its own colour: hollow, dashed,
/// solid-round, solid-angular, struck. Roughly one in twelve men cannot
/// reliably separate orange from red, and in the panel these dots must separate
/// from each other rather than from a neutral ground. Desaturate the whole
/// column and nothing is lost.
struct StateDot: View {
    let state: SessionState
    /// Working is the only dot that moves; under Reduce Motion it parks.
    let reduceMotion: Bool

    @State private var elapsed: TimeInterval = 0

    private let tick = Timer.publish(every: Motion.tickInterval, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let rect = CGRect(origin: .zero, size: size)
            draw(&context, rect)
        }
        .frame(width: Metrics.dotSize, height: Metrics.dotSize)
        .onReceive(tick) { _ in
            guard state == .working, !reduceMotion else { return }
            elapsed += Motion.tickInterval
        }
        .accessibilityHidden(true)   // the row's label carries the state
    }

    /// Maps the 8pt design box onto the drawing rect.
    private func scale(_ rect: CGRect) -> CGFloat { rect.width / Metrics.dotCanvas }

    private func draw(_ c: inout GraphicsContext, _ rect: CGRect) {
        let k = scale(rect)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let colour = Palette.dot(for: state)

        switch state {
        case .idle:
            // Hollow circle r2.6 — session attached, nothing running.
            stroke(&c, circle(centre, r: 2.6 * k), colour, width: 1.2 * k)

        case .working:
            // Dashed ring, rotating 360° every 4s. The only dot that moves.
            let angle = reduceMotion
                ? 0
                : Motion.phase(at: elapsed, period: Motion.WorkingDot.period) * 2 * .pi
            var ring = c
            ring.translateBy(x: centre.x, y: centre.y)
            ring.rotate(by: .radians(angle))
            ring.translateBy(x: -centre.x, y: -centre.y)
            ring.stroke(
                circle(centre, r: Motion.WorkingDot.radius * k),
                with: .color(colour),
                style: StrokeStyle(lineWidth: Motion.WorkingDot.stroke * k, lineCap: .round,
                                   dash: Motion.WorkingDot.dash.map { $0 * k })
            )

        case .done:
            // Solid disc r3.1 — filled means finished.
            c.fill(circle(centre, r: 3.1 * k), with: .color(colour))

        case .needsYou:
            // Solid diamond: corners read as urgency at 8pt.
            var p = Path()
            p.move(to: CGPoint(x: centre.x, y: rect.minY + 0.7 * k))
            p.addLine(to: CGPoint(x: rect.minX + 7.3 * k, y: centre.y))
            p.addLine(to: CGPoint(x: centre.x, y: rect.minY + 7.3 * k))
            p.addLine(to: CGPoint(x: rect.minX + 0.7 * k, y: centre.y))
            p.closeSubpath()
            c.fill(p, with: .color(colour))

        case .failed:
            // Hollow circle plus a slash — struck through.
            stroke(&c, circle(centre, r: 2.9 * k), colour, width: 1.2 * k)
            var slash = Path()
            slash.move(to: CGPoint(x: rect.minX + 2.1 * k, y: rect.minY + 5.9 * k))
            slash.addLine(to: CGPoint(x: rect.minX + 5.9 * k, y: rect.minY + 2.1 * k))
            c.stroke(slash, with: .color(colour),
                     style: StrokeStyle(lineWidth: 1.2 * k, lineCap: .round))
        }
    }

    private func circle(_ centre: CGPoint, r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2))
    }

    private func stroke(_ c: inout GraphicsContext, _ path: Path,
                        _ colour: Color, width: CGFloat) {
        c.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width))
    }
}

/// The 16×16pt row and header icons.
///
/// Uniform 1.3 stroke, round caps and joins, 1.3pt optical margin inside the
/// box, solid fill only where a stroke would close up at 16pt.
struct SmallIcon: View {
    enum Kind {
        case terminal   // focus the session's terminal window
        case editor     // open the working directory in the editor
        case clear      // header: drop all done + failed rows
        case settings   // header: spinner style and launch options
        case reveal     // shown on done rows, where the output is the point
    }

    let kind: Kind

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let k = size.width / Metrics.smallIconSize
            var c = context
            c.scaleBy(x: k, y: k)
            draw(&c)
        }
        .frame(width: Metrics.smallIconSize, height: Metrics.smallIconSize)
    }

    private var style: StrokeStyle {
        StrokeStyle(lineWidth: Metrics.smallIconStroke, lineCap: .round, lineJoin: .round)
    }

    private func draw(_ c: inout GraphicsContext) {
        let ink = GraphicsContext.Shading.color(Palette.secondaryText)

        switch kind {
        case .terminal:
            c.stroke(rounded(1.3, 2.7, 13.4, 10.6, 2.2), with: ink, style: style)
            var chevron = Path()
            chevron.move(to: CGPoint(x: 4.7, y: 6.7))
            chevron.addLine(to: CGPoint(x: 6.3, y: 8))
            chevron.addLine(to: CGPoint(x: 4.7, y: 9.3))
            c.stroke(chevron, with: ink, style: style)
            c.fill(rounded(7.6, 9, 3.7, 1.2, 0.6), with: ink)

        case .editor:
            c.stroke(rounded(1.3, 2.7, 13.4, 10.6, 2.2), with: ink, style: style)
            var gutter = Path()
            gutter.move(to: CGPoint(x: 4.7, y: 2.9))
            gutter.addLine(to: CGPoint(x: 4.7, y: 13.1))
            c.stroke(gutter, with: ink, style: style)
            var brackets = Path()
            brackets.move(to: CGPoint(x: 8.4, y: 6.6))
            brackets.addLine(to: CGPoint(x: 6.9, y: 8))
            brackets.addLine(to: CGPoint(x: 8.4, y: 9.4))
            brackets.move(to: CGPoint(x: 10.8, y: 6.6))
            brackets.addLine(to: CGPoint(x: 12.3, y: 8))
            brackets.addLine(to: CGPoint(x: 10.8, y: 9.4))
            c.stroke(brackets, with: ink, style: style)

        case .clear:
            var lines = Path()
            for (y, x2) in [(4.1, 9.4), (7.6, 8.2), (11.1, 5.8)] {
                lines.move(to: CGPoint(x: 2.2, y: y))
                lines.addLine(to: CGPoint(x: x2, y: y))
            }
            c.stroke(lines, with: ink, style: style)
            var check = Path()
            check.move(to: CGPoint(x: 8.7, y: 10.4))
            check.addLine(to: CGPoint(x: 10.6, y: 12.3))
            check.addLine(to: CGPoint(x: 14.1, y: 8.4))
            c.stroke(check, with: ink,
                     style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

        case .settings:
            var lines = Path()
            for y in [4.2, 8.0, 11.8] {
                lines.move(to: CGPoint(x: 2, y: y))
                lines.addLine(to: CGPoint(x: 14, y: y))
            }
            c.stroke(lines, with: ink, style: style)
            for (x, y) in [(5.6, 4.2), (10.4, 8.0), (7.2, 11.8)] {
                c.fill(dot(x, y, 1.8), with: ink)
            }

        case .reveal:
            c.stroke(rounded(2, 2, 12, 12, 2.8), with: ink, style: style)
            var arrow = Path()
            arrow.move(to: CGPoint(x: 6.1, y: 9.9))
            arrow.addLine(to: CGPoint(x: 10, y: 6))
            arrow.move(to: CGPoint(x: 6.9, y: 6))
            arrow.addLine(to: CGPoint(x: 10, y: 6))
            arrow.addLine(to: CGPoint(x: 10, y: 9.1))
            c.stroke(arrow, with: ink, style: style)
        }
    }

    private func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                         _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }

    private func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
}
