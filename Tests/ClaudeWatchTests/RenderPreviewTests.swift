import AppKit
import SwiftUI
import XCTest
@testable import ClaudeWatch

/// Renders the real views to PNGs so the design can be reviewed without needing
/// a free slot in the menu bar. Writes to $CW_PREVIEW_OUT when set; otherwise
/// it is a no-op, so this never slows a normal test run.
@MainActor
final class RenderPreviewTests: XCTestCase {

    /// Rendered previews go to a fixed location under the user's temp
    /// directory. `xcodebuild` does not forward the parent environment into the
    /// test process, so an env var is not a reliable switch here; instead the
    /// test writes only when the directory already exists, which the preview
    /// make target creates first.
    private var outputDirectory: String? {
        let dir = NSTemporaryDirectory() + "claudewatch-previews"
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }

    /// The three onboarding screens, light and dark, so the flow can be
    /// reviewed without resetting first-run state on a real machine.
    func testRenderOnboarding() throws {
        guard let out = outputDirectory else { throw XCTSkip("no preview directory") }
        let model = IconModel()
        for (i, step) in OnboardingStep.allCases.enumerated() {
            for dark in [false, true] {
                let view = OnboardingView(model: model, step: step, onDone: {})
                render(view, size: CGSize(width: Metrics.onboardingWidth, height: 420),
                       name: "onboarding-\(i + 1)-\(dark ? "dark" : "light")", dark: dark,
                       out: out, scale: 2)
            }
        }
    }

    func testRenderPreviews() throws {
        guard let out = outputDirectory else {
            throw XCTSkip("set CW_PREVIEW_OUT to render previews")
        }

        // Every state at true menu bar size, on a light and a dark bar, through
        // the real `IconRenderer` path — so this exercises template inversion
        // rather than just the SwiftUI view.
        //
        // 16pt is included deliberately: the spec says the glyph must stay
        // legible there, and if it muddies the geometry is wrong.
        let states: [(IconState, String)] = [
            (.idle, "idle"), (.working, "working"), (.needsYou, "needsyou"),
            (.failed, "failed"), (.doneUnseen, "done"),
        ]
        for (state, name) in states {
            for dark in [false, true] {
                for phase in [0.0, 0.25, 0.5, 0.75] {
                    let view = StatusIconView(
                        state: state, phase: phase, workingCount: 1,
                        isAnimating: true
                    )
                    render(iconStrip(view, dark: dark),
                           size: CGSize(width: 120, height: 40),
                           name: "icon-\(name)-\(dark ? "dark" : "light")-p\(Int(phase * 100))",
                           dark: dark, out: out)
                }
                // The designed static frame each state falls back to.
                let still = StatusIconView(
                    state: state, phase: 0, workingCount: 1,
                    isAnimating: false
                )
                render(iconStrip(still, dark: dark),
                       size: CGSize(width: 120, height: 40),
                       name: "icon-\(name)-\(dark ? "dark" : "light")-static",
                       dark: dark, out: out)
            }
        }

        // The panel dots, all five forms side by side — and desaturated, which
        // is the test that they separate by shape rather than colour.
        for dark in [false, true] {
            let dots = HStack(spacing: 12) {
                ForEach(SessionState.allCases, id: \.self) { state in
                    StateDot(state: state, reduceMotion: true)
                }
            }
            .padding(10)
            render(dots, size: CGSize(width: 140, height: 30),
                   name: "dots-\(dark ? "dark" : "light")", dark: dark, out: out)

            let icons = HStack(spacing: 12) {
                SmallIcon(kind: .terminal)
                SmallIcon(kind: .editor)
                SmallIcon(kind: .clear)
                SmallIcon(kind: .settings)
                SmallIcon(kind: .reveal)
            }
            .padding(10)
            render(icons, size: CGSize(width: 140, height: 36),
                   name: "smallicons-\(dark ? "dark" : "light")", dark: dark, out: out)
        }

        // Rows rendered directly, not through the panel's ScrollView: a
        // LazyVStack inside a ScrollView does not lay out under ImageRenderer
        // (nothing scrolls it into view), so the panel shot alone would hide a
        // broken row behind an empty list.
        for dark in [false, true] {
            let rows = VStack(spacing: Metrics.spaceXS) {
                ForEach(previewSessions(Date())) { s in
                    SessionRow(session: s, needsDisambiguation: s.projectName == "webapp",
                               now: Date(), reduceMotion: true, onOpen: {})
                }
            }
            .padding(Metrics.spaceM)
            .frame(width: Metrics.panelWidth)
            render(rows, size: CGSize(width: Metrics.panelWidth, height: 200),
                   name: "rows-\(dark ? "dark" : "light")", dark: dark, out: out)
        }

        // The panel with a representative mix, including two rows in one project.
        let now = Date()
        let sessions = previewSessions(now)
        for dark in [false, true] {
            let model = IconModel()
            model.apply(SessionStore.Snapshot(sessions: sessions, unseenDone: ["sess-cccc3333"]))
            let panel = PanelView(model: model, onClearFinished: {}, onOpenSession: { _ in },
                                  onQuit: {}, onReinstallHooks: {})
            render(panel, size: CGSize(width: Metrics.panelWidth, height: 300),
                   name: "panel-\(dark ? "dark" : "light")", dark: dark, out: out)
            // A shippable screenshot of the panel. Composed from the same
            // header, rows and footer the app draws, but with the rows in a
            // plain VStack: a LazyVStack inside a ScrollView lays out empty
            // under ImageRenderer, which would ship a blank panel.
            let shot = PanelScreenshot(sessions: sessions, now: now)
            render(shot, size: CGSize(width: Metrics.panelWidth, height: 320),
                   name: "site-panel-\(dark ? "dark" : "light")", dark: dark,
                   out: out, scale: 3)

            let empty = IconModel()
            let emptyPanel = PanelView(model: empty, onClearFinished: {}, onOpenSession: { _ in },
                                       onQuit: {}, onReinstallHooks: {})
            render(emptyPanel, size: CGSize(width: Metrics.panelWidth, height: 220),
                   name: "panel-empty-\(dark ? "dark" : "light")", dark: dark, out: out)

            let settings = SettingsPane(onReinstallHooks: {})
            render(settings, size: CGSize(width: Metrics.panelWidth, height: 380),
                   name: "panel-settings-\(dark ? "dark" : "light")", dark: dark, out: out)
        }
    }


    /// One glyph at its true menu bar size and at 16pt, beside a neighbouring
    /// system-item stand-in, the way the spec's own contact sheet shows it.
    private func iconStrip(_ view: StatusIconView, dark: Bool) -> some View {
        HStack(spacing: 14) {
            view.frame(width: 22, height: 22)
            view.frame(width: 16, height: 16)
            RoundedRectangle(cornerRadius: 2)
                .stroke(dark ? Color.white : Color.black, lineWidth: 1.4)
                .frame(width: 14, height: 10)
        }
        .padding(.horizontal, 12)
    }


    /// The panel as shipped, laid out eagerly so it renders offscreen.
    private struct PanelScreenshot: View {
        let sessions: [Session]
        let now: Date

        var body: some View {
            VStack(spacing: Metrics.none) {
                HStack {
                    Text("2 of 5 active")
                        .font(Typography.sectionHeader)
                        .foregroundStyle(Palette.secondaryText)
                    Spacer()
                    HStack(spacing: Metrics.spaceS) {
                        SmallIcon(kind: .clear)
                        Text("Clear finished").font(Typography.caption)
                    }
                    .foregroundStyle(Palette.secondaryText)
                }
                .padding(.horizontal, Metrics.spaceL)
                .padding(.vertical, Metrics.spaceM)

                Divider()

                VStack(spacing: Metrics.spaceXS) {
                    ForEach(sessions) { session in
                        SessionRow(session: session,
                                   needsDisambiguation: false,
                                   now: now, reduceMotion: true, onOpen: {})
                    }
                }
                .padding(.horizontal, Metrics.spaceM)
                .padding(.vertical, Metrics.spaceM)

                Divider()

                HStack(spacing: Metrics.spaceL) {
                    HStack(spacing: Metrics.spaceS) {
                        SmallIcon(kind: .settings)
                        Text("Settings").font(Typography.footer)
                    }
                    Spacer()
                    Text("Quit").font(Typography.footer)
                }
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, Metrics.spaceL)
                .padding(.vertical, Metrics.spaceM)
            }
            .frame(width: Metrics.panelWidth)
            .background(Palette.panelBackground)
        }
    }

    /// A representative mix: two rows sharing one project (so disambiguation
    /// shows), an unrecognised terminal, and every state.
    private func previewSessions(_ now: Date) -> [Session] {
        [
            session("sess-bbbb2222", .needsYou, "Add the migration", "webapp", "iTerm", now, 95),
            session("sess-aaaa1111", .working, "Refactor the parser", "webapp", "VS Code", now, 320),
            session("sess-dddd4444", .failed, "Generate client", "infra", "SomeNewTerm", now, 60),
            session("sess-cccc3333", .done, "Fix flaky test", "api", "Terminal", now, 1450),
            session("sess-eeee5555", .idle, "Scratch", "scratch", "Ghostty", now, 20),
        ]
    }

    private func session(_ id: String, _ state: SessionState, _ chat: String,
                         _ project: String, _ env: String, _ now: Date,
                         _ age: TimeInterval) -> Session {
        Session(id: id, state: state, chatName: chat, projectName: project,
                cwd: "/Users/me/code/\(project)", ownerPID: 1,
                environment: Environment(label: env, isEditor: env == "VS Code", isRemote: false),
                errorType: state == .failed ? "rate_limit" : "",
                lastMessage: "", updatedAt: now,
                firstSeen: now.addingTimeInterval(-age),
                doneAt: state == .done ? now : nil)
    }

    /// Renders at a high scale factor so fine geometry can actually be judged.
    /// The glyph's concave gem flanks and 1.3pt arcs do not survive being
    /// rasterised at 18pt and then blown up for review.
    private func render(_ view: some View, size: CGSize, name: String, dark: Bool,
                        out: String, scale: CGFloat = 6) {
        // An offscreen bitmap has no window behind it, so a view relying on the
        // window background renders on white whatever the appearance says.
        // Paint the ground explicitly for the preview only.
        let grounded = AnyView(
            ZStack {
                (dark ? Color(white: 0.11) : Color(white: 1.0)).ignoresSafeArea()
                view
            }
            .environment(\.colorScheme, dark ? .dark : .light)
        )
        let renderer = ImageRenderer(content: grounded.frame(width: size.width,
                                                             height: size.height))
        renderer.scale = scale
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
    }
}
