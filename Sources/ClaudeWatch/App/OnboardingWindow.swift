import AppKit
import SwiftUI

/// First-run onboarding: three steps, one screen each.
///
/// 1. What this does — the logo, one sentence, and the menu bar item cycling
///    its states so the user learns the language before they need it.
/// 2. Install hooks — one button. The app shows the exact JSON it will merge
///    into `~/.claude/settings.json`, merges it (never overwrites), and offers
///    to open the file afterwards. On failure it says exactly why and shows
///    the config to add by hand.
/// 3. Done — "Start Claude Code in a terminal and it shows up here." Then it
///    waits, live. When the first real event lands the glyph moves and the
///    window dismisses itself. That moment is the proof it works.
///
/// It reappears whenever the hooks go missing, opening straight on step 2.
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let model: IconModel

    init(model: IconModel) {
        self.model = model
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }

        let startStep: OnboardingStep = Preferences.shared.hasSeenOnboarding ? .install : .intro
        let view = OnboardingView(model: model, step: startStep) { [weak self] in self?.close() }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: host)
        window.title = "Claude Watch"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        // An accessory app is not frontmost by default, so the window would
        // otherwise appear behind whatever the user was doing.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        Preferences.shared.hasSeenOnboarding = true
        window?.close()
        window = nil
    }
}

enum OnboardingStep: Int, CaseIterable {
    case intro, install, done
}

struct OnboardingView: View {
    let model: IconModel
    @State var step: OnboardingStep
    let onDone: () -> Void

    // Step 2
    @State private var installed = HookInstaller.isInstalled
    @State private var preview: String = ""
    @State private var showPreview = false
    @State private var failure: HookInstaller.InstallError?
    @State private var copied = false

    /// The bundled installer, runnable by hand. Same script, same merge.
    private var terminalCommand: String {
        let path = Bundle.main.url(forResource: "install-hooks", withExtension: "py")?.path
            ?? "/Applications/ClaudeWatch.app/Contents/Resources/install-hooks.py"
        return "python3 \"\(path)\""
    }

    // Step 3: dismiss once the first real event lands.
    @State private var dismissTask: Task<Void, Never>?

    // Demo clock for step 1 and the live glyph on step 3.
    private let tick = Timer.publish(every: Motion.tickInterval, on: .main, in: .common).autoconnect()
    @State private var elapsed: TimeInterval = 0

    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spaceXL) {
            progress
            Group {
                switch step {
                case .intro:   intro
                case .install: install
                case .done:    done
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footerRow
        }
        .padding(Metrics.spaceXL + Metrics.spaceM)
        .frame(width: Metrics.onboardingWidth)
        .background(Palette.panelBackground)
        .onReceive(tick) { _ in elapsed += Motion.tickInterval }
        .onChange(of: model.snapshot.isEmpty) { _, isEmpty in
            guard step == .done, !isEmpty else { return }
            scheduleDismiss()
        }
        .onChange(of: step) { _, new in
            // Already running sessions count as the first event too.
            if new == .done, !model.snapshot.isEmpty { scheduleDismiss() }
        }
    }

    // MARK: - Progress

    private var progress: some View {
        HStack(spacing: Metrics.spaceS) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Palette.accent : Palette.lightGray)
                    .frame(width: Metrics.progressSegmentWidth, height: Metrics.progressSegmentHeight)
            }
            Spacer()
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    // MARK: - Step 1

    private var intro: some View {
        VStack(alignment: .leading, spacing: Metrics.spaceXL) {
            HStack(alignment: .center, spacing: Metrics.spaceL) {
                BrandMark(size: Metrics.onboardingMarkSize)
                VStack(alignment: .leading, spacing: Metrics.spaceXS) {
                    Text("Claude Watch").font(Typography.onboardingTitle)
                    Text("Every Claude Code session, in your menu bar.")
                        .font(Typography.body)
                        .foregroundStyle(Palette.secondaryText)
                }
            }

            VStack(alignment: .leading, spacing: Metrics.spaceM) {
                Text("The menu bar item reads like this:")
                    .font(Typography.onboardingBody)
                    .foregroundStyle(Palette.secondaryText)
                MenuBarMock(state: demoState, phase: demoPhase, isAnimating: !reduceMotion)
                Text(demoCaption)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)
            }
        }
    }

    /// Cycle idle → working → needs you → done → failed.
    private static let demoStates: [IconState] = [.idle, .working, .needsYou, .doneUnseen, .failed]

    private var demoIndex: Int {
        Int(elapsed / Metrics.demoStateDuration) % Self.demoStates.count
    }
    private var demoState: IconState { Self.demoStates[demoIndex] }
    private var demoPhase: Double {
        let local = elapsed.truncatingRemainder(dividingBy: Metrics.demoStateDuration)
        return Motion.phase(at: local, period: demoState.period)
    }
    private var demoCaption: String {
        switch demoState {
        case .idle:       "Idle. Nothing running."
        case .working:    "Working. Claude is on a turn."
        case .needsYou:   "Needs you. A permission prompt or question is waiting."
        case .doneUnseen: "Done. A turn finished while you were away."
        case .failed:     "Failed. A turn ended on an error."
        }
    }

    // MARK: - Step 2

    private var install: some View {
        VStack(alignment: .leading, spacing: Metrics.spaceL) {
            Text("Install the hooks").font(Typography.onboardingTitle)

            if installed {
                Label("Hooks are installed.", systemImage: "checkmark.circle.fill")
                    .font(Typography.body)
                    .foregroundStyle(Palette.accent)
                Text("Claude Watch's handlers are in ~/.claude/settings.json. Everything that was already there is untouched.")
                    .font(Typography.onboardingBody)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open settings.json") { HookInstaller.openSettingsFile() }
                    .controlSize(.small)
            } else {
                Text("Claude Code fires a hook when a session starts, works, finishes, fails, or needs you. Claude Watch adds one small handler to each. Nothing to copy or edit: the button below merges them into ~/.claude/settings.json and keeps every hook you already have.")
                    .font(Typography.onboardingBody)
                    .foregroundStyle(Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let failure {
                    VStack(alignment: .leading, spacing: Metrics.spaceS) {
                        Text("Could not install.")
                            .font(Typography.rowTitle)
                            .foregroundStyle(Palette.failure)
                        Text(failure.reason)
                            .font(Typography.caption)
                            .foregroundStyle(Palette.failure)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text("Add this under \"hooks\" in ~/.claude/settings.json by hand, or fix the file and try again:")
                            .font(Typography.caption)
                            .foregroundStyle(Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: Metrics.spaceS) {
                    Text("Prefer the terminal? This does exactly what the button does:")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                    HStack(spacing: Metrics.spaceM) {
                        Text(terminalCommand)
                            .font(Typography.elapsed)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(terminalCommand, forType: .string)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                    .padding(Metrics.spaceM)
                    .background(RoundedRectangle(cornerRadius: Metrics.mockBarRadius)
                        .fill(Palette.lightGray.opacity(0.35)))
                }

                DisclosureGroup(isExpanded: $showPreview) {
                    ConfigPreview(text: preview)
                } label: {
                    Text(failure == nil ? "What it will add" : "Config to add manually")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.secondaryText)
                }
                .onChange(of: showPreview) { _, open in
                    if open, preview.isEmpty { preview = HookInstaller.configPreview() }
                }
                .onChange(of: failure) { _, f in
                    if f != nil { showPreview = true; if preview.isEmpty { preview = HookInstaller.configPreview() } }
                }
            }
        }
    }

    // MARK: - Step 3

    private var done: some View {
        VStack(alignment: .leading, spacing: Metrics.spaceL) {
            Text("That's it.").font(Typography.onboardingTitle)
            Text("Start Claude Code in a terminal and it shows up here.")
                .font(Typography.body)
                .fixedSize(horizontal: false, vertical: true)

            MenuBarMock(
                state: model.snapshot.isEmpty ? .idle : model.iconState,
                phase: model.phase,
                isAnimating: model.isAnimating
            )

            Text(model.snapshot.isEmpty
                 ? "Waiting for the first event. A session that is already running appears on its next turn."
                 : "There it is. This window closes itself in a moment.")
                .font(Typography.caption)
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scheduleDismiss() {
        guard dismissTask == nil else { return }
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Metrics.onboardingDismissDelay))
            guard !Task.isCancelled else { return }
            onDone()
        }
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack {
            Text("Not affiliated with Anthropic.")
                .font(Typography.disclaimer)
                .foregroundStyle(Palette.secondaryText)
            Spacer()
            switch step {
            case .intro:
                Button("Continue") { step = .install }
                    .keyboardShortcut(.defaultAction)
            case .install:
                Button("Not now", action: onDone)
                if installed {
                    Button("Continue") { step = .done }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Install hooks") {
                        switch HookInstaller.installDetailed() {
                        case .success:
                            failure = nil
                            installed = true
                        case .failure(let error):
                            failure = error
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .done:
                Button("Close", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// A faithful strip of menu bar with the real status item in it, at true
/// size. Shown as a demo of the thing itself, not as branding.
struct MenuBarMock: View {
    let state: IconState
    let phase: Double
    let isAnimating: Bool

    @SwiftUI.Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: Metrics.spaceL) {
            Spacer()
            StatusIconView(state: state, phase: phase, workingCount: 1, isAnimating: isAnimating)
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Metrics.spaceXS)
                    .fill(Palette.midGray.opacity(scheme == .dark ? 0.55 : 0.75))
                    .frame(width: Metrics.mockBarItemWidth, height: Metrics.spaceM)
            }
        }
        .padding(.horizontal, Metrics.spaceL)
        .frame(height: Metrics.mockBarHeight)
        .background(
            RoundedRectangle(cornerRadius: Metrics.mockBarRadius)
                .fill(scheme == .dark ? Palette.dark : Palette.light)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.mockBarRadius)
                .strokeBorder(Palette.separator, lineWidth: Metrics.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Menu bar preview")
    }
}

private struct ConfigPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "…" : text)
                .font(Typography.elapsed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.spaceM)
        }
        .frame(height: Metrics.configPreviewHeight)
        .background(RoundedRectangle(cornerRadius: Metrics.mockBarRadius).fill(Palette.lightGray.opacity(0.35)))
    }
}
