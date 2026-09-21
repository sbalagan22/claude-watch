import AppKit
import SwiftUI

/// The popover's contents.
struct PanelView: View {
    @Bindable var model: IconModel
    let onClearFinished: () -> Void
    let onOpenSession: (Session) -> Void
    let onQuit: () -> Void
    let onReinstallHooks: () -> Void

    @State private var now = Date()
    @State private var showingSettings = false
    /// Drives the live elapsed-time counter. One timer for the whole list.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var sessions: [Session] { model.snapshot.sessions }
    /// Read from the system rather than plumbed through the icon model: the
    /// panel's motion is independent of whether the menu bar glyph is animating.
    // Fully qualified: the app has its own `Environment` type for terminal
    // detection, which shadows SwiftUI's property wrapper in this module.
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool {
        systemReduceMotion || !Preferences.shared.animationEnabled
    }

    /// Projects appearing more than once, so those rows can disambiguate.
    private var duplicatedProjects: Set<String> {
        var counts: [String: Int] = [:]
        for s in sessions { counts[s.projectName, default: 0] += 1 }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    var body: some View {
        VStack(spacing: Metrics.none) {
            header
            Divider()
            if showingSettings {
                SettingsPane(onReinstallHooks: onReinstallHooks)
                    .transition(reduceMotion ? .identity : .opacity)
            } else if sessions.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: Metrics.panelWidth)
        .background(Palette.panelBackground)
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Metrics.spaceM) {
            // The official logo identifies the product; the glyph in the bar
            // is a status indicator and never appears in here.
            BrandMark(size: Metrics.headerMarkSize)
            Text(headerTitle)
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.secondaryText)
            Spacer()
            if sessions.contains(where: { $0.state == .done || $0.state == .failed }) {
                Button(action: onClearFinished) {
                    HStack(spacing: Metrics.spaceS) {
                        SmallIcon(kind: .clear)
                        Text("Clear finished").font(Typography.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.secondaryText)
                .help("Drop all finished and failed rows")
            }
        }
        .padding(.horizontal, Metrics.spaceL)
        .padding(.vertical, Metrics.spaceM)
    }

    private var headerTitle: String {
        let active = sessions.count(where: { $0.state == .working || $0.state == .needsYou })
        return switch (sessions.count, active) {
        case (0, _): "No sessions"
        case (let total, 0): "\(total) session\(total == 1 ? "" : "s")"
        case (let total, let a): "\(a) of \(total) active"
        }
    }

    // MARK: - List

    /// The panel is as tall as its rows. Up to `Metrics.maxVisibleRows` the
    /// list is a plain stack and the popover sizes itself to it; past that it
    /// scrolls at a fixed height so a dozen sessions cannot push the footer
    /// off the bottom of the screen.
    private var list: some View {
        Group {
            if sessions.count > Metrics.maxVisibleRows {
                ScrollView { rows }
                    .frame(height: Metrics.panelMaxHeight)
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        VStack(spacing: Metrics.spaceXS) {
            ForEach(sessions) { session in
                SessionRow(
                    session: session,
                    needsDisambiguation: duplicatedProjects.contains(session.projectName),
                    now: now,
                    reduceMotion: reduceMotion,
                    onOpen: { onOpenSession(session) }
                )
                .transition(
                    reduceMotion
                        ? .identity
                        : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: -4)),
                            removal: .opacity.combined(with: .scale(scale: 0.97))
                          )
                )
            }
        }
        .padding(.horizontal, Metrics.spaceM)
        .padding(.vertical, Metrics.spaceM)
        // Rows insert and remove with a spring. Placed on the container, not
        // inside the conditional, so removals animate too.
        .animation(
            reduceMotion ? nil : .spring(response: Metrics.rowSpringResponse,
                                         dampingFraction: Metrics.rowSpringDamping),
            value: sessions.map(\.id)
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Metrics.spaceM) {
            EmptyState()
            // The one thing the designed empty state cannot say: that the app
            // is not actually wired up yet.
            if !HookInstaller.isInstalled {
                Text("Hooks are not installed yet. Open Settings and choose Reinstall hooks.")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.spaceXL)
            }
        }
        .padding(.bottom, Metrics.spaceL)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Metrics.spaceL) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    showingSettings.toggle()
                }
            } label: {
                HStack(spacing: Metrics.spaceS) {
                    if showingSettings {
                        Image(systemName: "chevron.left").font(Typography.footer)
                    } else {
                        SmallIcon(kind: .settings)
                    }
                    Text(showingSettings ? "Back" : "Settings").font(Typography.footer)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.secondaryText)

            Spacer()

            Button("Quit", action: onQuit)
                .buttonStyle(.plain)
                .font(Typography.footer)
                .foregroundStyle(Palette.secondaryText)
        }
        .padding(.horizontal, Metrics.spaceL)
        .padding(.vertical, Metrics.spaceM)
    }
}
