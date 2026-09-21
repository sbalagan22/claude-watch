import AppKit
import SwiftUI

/// Owns the status item, the shared animation tick and the popover.
///
/// SwiftUI's `MenuBarExtra` is deliberately not used: it restricts the button to
/// an image, image + text, or text. No custom UI, no animation, and template
/// images cannot render colour. That restriction is the whole reason this app
/// needs AppKit — still true as of Xcode 26.
///
/// The icon is set as an `NSImage` rather than hosted as a live SwiftUI view,
/// because template inversion only applies to `NSImage.isTemplate`. See
/// `IconRenderer`.
@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    private let store = SessionStore()
    private let transcripts = TranscriptMonitor()
    private var transcriptTimer: Timer?
    private let gate = AnimationGate()
    /// Read by onboarding so its last step can watch for the first real event.
    let model = IconModel()

    private var watcher: DirectoryWatcher?
    private var tick: Timer?
    private var livenessTimer: Timer?
    private var snapshotTask: Task<Void, Never>?
    private var appearanceObserver: (any NSObjectProtocol)?

    /// Monotonic clock the frame index is derived from. Animation resumes at
    /// phase 0 after a suspension, as the spec requires.
    private var clockStart = Date()

    /// Working must hold for at least `Motion.workingDebounce` before the icon
    /// may leave it, so a burst of short tool calls does not flicker.
    private var workingSince: Date?
    private var pendingSnapshot: SessionStore.Snapshot?
    private var debounceTimer: Timer?
    /// Fires when the done flash ends, so working can take the glyph back.
    private var flashTimer: Timer?

    func start() {
        buildStatusItem()
        observeStore()
        startWatching()
        startLivenessTimer()
        startTranscriptMonitor()
        // Prune orphans left by crashed Claude Code processes before showing
        // anything: a stale row on launch is the most visible kind of wrong.
        Task { [store] in
            await store.reload()
            await store.pruneDead()
        }
    }

    func stop() {
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
        snapshotTask?.cancel()
        transcriptTimer?.invalidate()
        tick?.invalidate()
        debounceTimer?.invalidate()
        flashTimer?.invalidate()
        livenessTimer?.invalidate()
        watcher?.stop()
        gate.stop()
    }

    // MARK: - Status item

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePanel)
        button.imagePosition = .imageOnly

        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(
            rootView: PanelView(
                model: model,
                onClearFinished: { [weak self] in self?.clearFinished() },
                onOpenSession: { [weak self] session in self?.focus(session) },
                onQuit: { NSApp.terminate(nil) },
                onReinstallHooks: { [weak self] in self?.reinstallHooks() }
            )
        )
        // The popover tracks the SwiftUI content's ideal size, so it is
        // exactly as tall as the rows it holds and grows or shrinks as
        // sessions come and go. No fixed height anywhere.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        redraw()
        observePreferences()

        // The monochrome ink resolves differently on a light and a dark menu
        // bar, so cached frames must not outlive an appearance change.
        //
        // Observed by notification rather than KVO on `NSApp.effectiveAppearance`:
        // that key path fires during app activation and deadlocked the test
        // host, and this carries the same signal without touching NSApp's own
        // observation machinery.
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                IconRenderer.invalidate()
                self.onScreenFrame = nil
                self.redraw()
            }
        }
    }

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        // Opening the panel is what "looking at it" means.
        //
        // Done and failed clear here. Needs-you deliberately does NOT: it
        // clears only when the prompt is actually answered, because the panel
        // cannot answer it for you and dismissing the signal would lose the one
        // thing the user still has to do.
        Task { [store] in
            await store.pruneDead()   // liveness on every panel open
            await store.markFinishedSeen()
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Store observation

    private func observeStore() {
        snapshotTask = Task { [store, transcripts, weak self] in
            for await snapshot in await store.snapshots() {
                await transcripts.track(snapshot.sessions)
                self?.accept(snapshot)
            }
        }
    }

    /// Interrupts and permission decisions fire no hook, so mid-turn
    /// sessions' transcripts are watched for the records Claude Code writes.
    private func startTranscriptMonitor() {
        let timer = Timer(timeInterval: Metrics.transcriptPollInterval, repeats: true) { [store, transcripts] _ in
            Task {
                for (id, outcome) in await transcripts.poll() {
                    switch outcome {
                    case .interrupted: await store.markInterrupted(id)
                    case .resumed:     await store.markResumed(id)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        transcriptTimer = timer
    }

    /// Applies a snapshot, holding the working state open for the debounce
    /// window so bursty tool calls do not flicker the icon.
    private func accept(_ snapshot: SessionStore.Snapshot) {
        let now = Date()
        let wasWorking = model.iconState == .working
        let isWorking = snapshot.iconState(at: now) == .working

        if isWorking {
            if !wasWorking { workingSince = Date() }
            debounceTimer?.invalidate()
            debounceTimer = nil
            pendingSnapshot = nil
            apply(snapshot)
            return
        }

        // Leaving working: only allowed once the hold has elapsed.
        if wasWorking, let since = workingSince {
            let held = Date().timeIntervalSince(since)
            if held < Motion.workingDebounce {
                pendingSnapshot = snapshot
                debounceTimer?.invalidate()
                let timer = Timer(timeInterval: Motion.workingDebounce - held, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let pending = self.pendingSnapshot else { return }
                        self.pendingSnapshot = nil
                        self.workingSince = nil
                        self.apply(pending)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                debounceTimer = timer
                return
            }
        }
        workingSince = nil
        apply(snapshot)
    }

    private func apply(_ snapshot: SessionStore.Snapshot) {
        let now = Date()
        let previous = model.iconState
        announceFinishes(in: snapshot)
        model.apply(snapshot, at: now)
        // A state change restarts the clock, so one-shot gestures (the done
        // bloom) begin at their first frame rather than mid-way.
        if previous != model.iconState { clockStart = now }
        syncTick()
        redraw()
        scheduleFlashEnd(snapshot, now: now)
    }

    /// True once the first snapshot has been applied. Sessions that were
    /// already finished when the app launched must not play a sound: nothing
    /// just happened.
    private var hasAppliedSnapshot = false

    /// Plays the completion sound once per session that has newly finished.
    private func announceFinishes(in snapshot: SessionStore.Snapshot) {
        defer { hasAppliedSnapshot = true }
        guard hasAppliedSnapshot, Preferences.shared.playSoundOnDone else { return }
        let newlyDone = snapshot.unseenDone.subtracting(model.snapshot.unseenDone)
        if !newlyDone.isEmpty { DoneSound.play() }
    }

    /// While a done flash is outranking a working session, arrange to
    /// re-evaluate the moment it expires. Nothing else would prompt a redraw:
    /// no hook fires when a hold runs out.
    private func scheduleFlashEnd(_ snapshot: SessionStore.Snapshot, now: Date) {
        flashTimer?.invalidate()
        flashTimer = nil
        guard let remaining = snapshot.doneFlashRemaining(at: now),
              snapshot.workingCount > 0 else { return }
        let timer = Timer(timeInterval: remaining + Motion.tickInterval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(self.model.snapshot)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }

    private func startWatching() {
        let w = DirectoryWatcher(url: Paths.sessionsDirectory) { [store] in
            Task { await store.reload() }
        }
        watcher = w
        w.start()
    }

    private func startLivenessTimer() {
        let timer = Timer(timeInterval: Metrics.livenessInterval, repeats: true) { [store] _ in
            Task { await store.pruneDead() }
        }
        RunLoop.main.add(timer, forMode: .common)
        livenessTimer = timer
    }

    // MARK: - The shared tick

    /// One 12fps timer drives every animated state. It runs only while there is
    /// something to animate; when nothing is happening it is invalidated
    /// entirely rather than ticking a no-op, so idle CPU is genuinely zero.
    private func syncTick() {
        let allowed = gate.isAllowed && !gate.reduceMotion && model.iconState.animates
        model.isAnimating = allowed

        guard allowed else {
            tick?.invalidate()
            tick = nil
            return
        }
        guard tick == nil else { return }

        clockStart = Date()
        let timer = Timer(timeInterval: Motion.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    /// One frame: recompute the phase from the shared clock and redraw.
    private func frame() {
        let state = model.iconState
        let elapsed = Date().timeIntervalSince(clockStart)
        let period = state.period

        // Every animated state loops, done included (D51): the pulse keeps
        // going until the panel is opened. The old one-shot stop lived here
        // and is what made done look like it "pulsed for a moment".
        _ = state
        model.phase = Motion.phase(at: elapsed, period: period)
        redraw()
    }

    /// The frame currently on screen, so an unchanged one is not re-assigned.
    ///
    /// Assigning `button.image` makes AppKit re-lay-out and redraw the status
    /// item, which profiling showed to be the real cost of animating — not the
    /// drawing itself. At 12fps a slow rotation moves the gem's outermost point
    /// about a third of a pixel per frame, so most frames are visually
    /// identical to the one before; skipping those is free and invisible.
    private var onScreenFrame: GlyphDrawing.Frame?

    /// Rasterises the current frame into the status item's button.
    private func redraw() {
        guard let button = statusItem?.button else { return }

        let frame = GlyphDrawing.Frame(
            state: model.snapshot.iconState,
            phase: model.phase,
            isAnimating: model.isAnimating
        )
        let text = statusText(for: model.snapshot)
        guard frame != onScreenFrame || text != button.title else { return }
        onScreenFrame = frame

        button.font = Typography.statusBar
        button.title = text
        button.imagePosition = text.isEmpty ? .imageOnly : .imageLeading
        button.imageHugsTitle = true

        button.image = IconRenderer.image(
            state: model.iconState,
            phase: model.phase,
            workingCount: model.snapshot.workingCount,
            isAnimating: model.isAnimating
        )
    }

    /// Re-runs whenever a preference the icon depends on changes.
    ///
    /// `withObservationTracking` fires once per change, so it re-arms itself
    /// after each notification. This is what makes flipping a setting take
    /// effect in the bar immediately rather than on the next session event.
    private func observePreferences() {
        withObservationTracking {
            let p = Preferences.shared
            _ = p.animationEnabled
            _ = p.showStatusText
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.gate.settingsChanged()
                self.preferencesChanged()
                self.observePreferences()
            }
        }
    }

    /// The optional word beside the glyph. Idle is deliberately blank so a
    /// quiet bar stays quiet; the count appears only when it is informative.
    private func statusText(for snapshot: SessionStore.Snapshot) -> String {
        guard Preferences.shared.showStatusText else { return "" }
        switch model.iconState {
        case .idle:       return ""
        case .working:    return snapshot.workingCount > 1
                              ? "\(snapshot.workingCount) working" : "Working"
        case .needsYou:   return "Needs you"
        case .doneUnseen: return "Done"
        case .failed:     return "Failed"
        }
    }

    /// Re-reads settings that change how the icon draws, without waiting for a
    /// session event. Called when the user changes a preference.
    func preferencesChanged() {
        IconRenderer.invalidate()
        onScreenFrame = nil
        syncTick()
        redraw()
    }

    // MARK: - Actions

    private func clearFinished() {
        Task { [store] in await store.clearFinished() }
    }

    private func reinstallHooks() {
        HookInstaller.install()
    }

    private func focus(_ session: Session) {
        SessionFocuser.focus(session)
        popover.performClose(nil)
    }
}

/// The observable the menu bar and panel both read. Lives on the main actor;
/// the store hands it immutable snapshots.
@MainActor
@Observable
final class IconModel {
    var snapshot = SessionStore.Snapshot()
    /// The icon state as evaluated when the snapshot was applied. Stored
    /// rather than recomputed so every consumer in one frame agrees.
    private(set) var iconState: IconState = .idle
    /// 0..<1, quantised to the tick grid.
    var phase: Double = 0
    var isAnimating: Bool = false

    func apply(_ s: SessionStore.Snapshot, at now: Date = Date()) {
        snapshot = s
        iconState = s.iconState(at: now)
    }
}

extension IconState {
    /// Whether this state has motion at all. Failed never animates — a failure
    /// is finished, and animating it would imply something is still happening.
    var animates: Bool {
        switch self {
        case .working, .needsYou, .doneUnseen: true
        case .idle, .failed:                   false
        }
    }

    /// The loop period for each animated state.
    var period: TimeInterval {
        switch self {
        case .working:    Motion.Precession.period
        case .needsYou:   Motion.NeedsYou.period
        case .doneUnseen: Motion.Done.period
        case .idle, .failed: 1
        }
    }
}
