import SwiftUI

/// One session. State dot, chat name, project, elapsed time, environment.
struct SessionRow: View {
    let session: Session
    /// True when another visible row shares this project, so the row must add
    /// something that tells them apart.
    let needsDisambiguation: Bool
    let now: Date
    let reduceMotion: Bool
    let onOpen: () -> Void

    @State private var isHovering = false
    @State private var sweep = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Metrics.spaceL) {
                StateDot(state: session.state, reduceMotion: reduceMotion)

                VStack(alignment: .leading, spacing: Metrics.spaceXS) {
                    Text(session.displayName)
                        .font(Typography.rowTitle)
                        .foregroundStyle(Palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    HStack(spacing: Metrics.spaceS) {
                        Text(secondaryLine)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: Metrics.spaceM)

                VStack(alignment: .trailing, spacing: Metrics.spaceXS) {
                    Text(elapsed)
                        .font(Typography.elapsed)
                        .foregroundStyle(session.workingSince != nil
                                         ? Palette.primaryText : Palette.secondaryText)
                        .monospacedDigit()
                    Text(session.environment.label)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Metrics.spaceL)
            .padding(.vertical, Metrics.spaceM)
            .frame(minHeight: Metrics.rowHeight)
            .background {
                RoundedRectangle(cornerRadius: Metrics.rowCorner, style: .continuous)
                    .fill(isHovering ? Palette.rowHighlight.opacity(0.25) : .clear)
            }
            .overlay { finishSweep }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens this session's window")
    }

    /// Project name, plus whatever it takes to tell two rows apart.
    ///
    /// Two sessions in the same directory are common and would otherwise render
    /// as two identical rows. The fallback chain is: chat name (already the
    /// title), then a short session-id suffix, then start time.
    private var secondaryLine: String {
        guard needsDisambiguation else { return folder }
        if session.displayName != session.projectName {
            // The title already distinguishes them; the id still helps when two
            // chats opened with the same first message.
            return "\(folder) · \(session.shortID)"
        }
        return "\(session.projectName) · \(session.shortID) · \(startedAt)"
    }

    /// The session's root folder as a path, home abbreviated, so two projects
    /// with the same folder name in different places still read differently.
    private var folder: String {
        guard !session.cwd.isEmpty else { return session.projectName }
        let home = NSHomeDirectory()
        if session.cwd == home { return "~" }
        if session.cwd.hasPrefix(home + "/") {
            return "~" + session.cwd.dropFirst(home.count)
        }
        return session.cwd
    }

    private var startedAt: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: session.firstSeen)
    }

    /// The turn timer. Live while the session is working (or paused on a
    /// prompt mid-turn); frozen at the last turn's length once it finishes;
    /// blank for a session that has not worked yet.
    private var elapsed: String {
        if let start = session.workingSince {
            return Self.clock(now.timeIntervalSince(start))
        }
        if let last = session.lastTurnDuration {
            return Self.clock(last)
        }
        return ""
    }

    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// A brief highlight when a session finishes, so you can see which one
    /// without reading.
    @ViewBuilder
    private var finishSweep: some View {
        if session.state == .done, let doneAt = session.doneAt,
           now.timeIntervalSince(doneAt) < Metrics.highlightSweep, !reduceMotion {
            RoundedRectangle(cornerRadius: Metrics.rowCorner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.clear, Palette.accent.opacity(0.14), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .allowsHitTesting(false)
                .opacity(sweep ? 0 : 1)
                .onAppear {
                    withAnimation(.easeOut(duration: Metrics.highlightSweep)) { sweep = true }
                }
        }
    }

    private var helpText: String {
        session.cwd.isEmpty ? session.projectName : session.cwd
    }

    private var accessibilityText: String {
        var parts = [session.displayName, session.projectName, session.state.label]
        if session.state == .failed, !session.errorType.isEmpty {
            parts.append(session.errorType.replacingOccurrences(of: "_", with: " "))
        }
        parts.append(session.environment.label)
        if session.workingSince != nil {
            parts.append("working for \(elapsed)")
        } else if !elapsed.isEmpty {
            parts.append("last turn \(elapsed)")
        }
        return parts.joined(separator: ", ")
    }
}
