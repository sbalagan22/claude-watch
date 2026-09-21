import Foundation
import Observation

/// The single owner of session state. Everything else observes it.
///
/// This is an actor because hook writes arrive from a file-system event source
/// on its own queue while the menu bar and panel read from the main actor. The
/// actor serialises every mutation; the published snapshot is a value type, so
/// what crosses to the UI is immutable.
actor SessionStore {
    /// Snapshot handed to the UI. A plain Sendable value: no shared mutable state.
    struct Snapshot: Equatable, Sendable {
        var sessions: [Session] = []
        /// Sessions that finished and have not been looked at yet. This drives
        /// the icon's glow, and it is the only state the app remembers about
        /// the user rather than about Claude Code.
        var unseenDone: Set<String> = []

        var isEmpty: Bool { sessions.isEmpty }

        /// Steady-state icon priority: needs you → failed → working → done → idle.
        var iconState: IconState { iconState(at: .distantFuture) }

        /// Icon state at a moment in time.
        ///
        /// Same priority as `iconState`, with one exception: for
        /// `Motion.Done.holdDuration` after the most recent finish, done
        /// outranks working. That is the "done flash" — the moment a session
        /// completes is always shown, even when other sessions are still busy.
        func iconState(at now: Date) -> IconState {
            if sessions.contains(where: { $0.state == .needsYou }) { return .needsYou }
            if sessions.contains(where: { $0.state == .failed })   { return .failed }
            if doneFlashRemaining(at: now) != nil                   { return .doneUnseen }
            if sessions.contains(where: { $0.state == .working })  { return .working }
            if !unseenDone.isEmpty                                  { return .doneUnseen }
            return .idle
        }

        /// Seconds left of the done flash, or nil when no unseen finish is
        /// recent enough to outrank working.
        func doneFlashRemaining(at now: Date) -> TimeInterval? {
            let latest = sessions
                .filter { unseenDone.contains($0.id) }
                .compactMap(\.doneAt)
                .max()
            guard let latest else { return nil }
            let remaining = Motion.Done.holdDuration - now.timeIntervalSince(latest)
            return remaining > 0 ? remaining : nil
        }

        var workingCount: Int { sessions.count(where: { $0.state == .working }) }
    }

    private var sessions: [String: Session] = [:]
    private var unseenDone: Set<String> = []
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    private let fileManager = FileManager.default
    private let liveness: any LivenessChecking

    init(liveness: some LivenessChecking = ProcessLiveness()) {
        self.liveness = liveness
    }

    // MARK: - Interrupts

    /// The user stopped the turn. Claude Code fires no hook for that, so the
    /// transcript monitor calls this; the session file is rewritten to idle
    /// through the same path a hook would take, so nothing else needs to know.
    func markInterrupted(_ id: String) {
        rewrite(id, state: "idle", event: "Interrupted", from: [.working, .needsYou])
    }

    /// The user answered the question or the permission dialog. No hook says
    /// so for a permission decision, but the transcript moves again.
    func markResumed(_ id: String) {
        rewrite(id, state: "working", event: "Resumed", from: [.needsYou])
    }

    private func rewrite(_ id: String, state: String, event: String, from: Set<SessionState>) {
        guard let session = sessions[id], from.contains(session.state) else { return }
        let url = Paths.sessionsDirectory.appending(path: "\(id).json")
        guard let data = try? Data(contentsOf: url),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        object["state"] = state
        object["event"] = event
        object["updated_at"] = Int(Date().timeIntervalSince1970)
        guard let out = try? JSONSerialization.data(withJSONObject: object) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try out.write(to: tmp)
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? fileManager.removeItem(at: tmp)
            return
        }
        reload()
    }

    // MARK: - Observation

    /// A stream of snapshots. Each observer gets its own; the latest snapshot is
    /// yielded immediately on subscribe so a late observer is never blank.
    func snapshots() -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(currentSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func currentSnapshot() -> Snapshot {
        Snapshot(sessions: sortedSessions(), unseenDone: unseenDone)
    }

    private func publish() {
        let snap = currentSnapshot()
        for continuation in continuations.values {
            continuation.yield(snap)
        }
    }

    /// Rows sorted by state priority, then most recently active.
    private func sortedSessions() -> [Session] {
        sessions.values.sorted { a, b in
            if a.state.priority != b.state.priority {
                return a.state.priority < b.state.priority
            }
            if a.updatedAt != b.updatedAt {
                return a.updatedAt > b.updatedAt
            }
            return a.id < b.id
        }
    }

    // MARK: - Loading

    /// Re-read the sessions directory. Safe to call when it does not exist.
    func reload() {
        let dir = Paths.sessionsDirectory
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            // Directory missing is the normal pre-install state, not an error.
            if !sessions.isEmpty {
                sessions.removeAll()
                unseenDone.removeAll()
                publish()
            }
            return
        }

        var seen = Set<String>()
        var changed = false

        for url in entries where url.pathExtension == "json" {
            guard let file = decode(url) else { continue }
            guard !file.sessionID.isEmpty else { continue }
            seen.insert(file.sessionID)

            let previous = sessions[file.sessionID]
            guard let session = file.session(previous: previous) else { continue }

            if previous != session {
                sessions[file.sessionID] = session
                changed = true
            }

            // A session that just finished becomes unseen-done, unless the panel
            // is already open (the caller clears it on open).
            if session.state == .done, previous?.state != .done {
                unseenDone.insert(session.id)
                changed = true
            }
            // Leaving done clears the unseen mark.
            if session.state != .done, unseenDone.contains(session.id) {
                unseenDone.remove(session.id)
                changed = true
            }
        }

        // Files that vanished (SessionEnd removed them).
        for id in sessions.keys where !seen.contains(id) {
            sessions[id] = nil
            unseenDone.remove(id)
            changed = true
        }

        if changed { publish() }
    }

    private func decode(_ url: URL) -> SessionFile? {
        // A partial write is expected: the writer uses temp-file + rename, but a
        // reader can still race a file being replaced. Failure here is normal.
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(SessionFile.self, from: data)
    }

    // MARK: - Liveness

    /// Remove sessions whose owning process is gone, and prune orphan files.
    ///
    /// A crashed Claude Code never fires SessionEnd, so files accumulate. PID
    /// liveness is far more accurate than time alone: a session whose process is
    /// gone is dead immediately, however recently it wrote. Time is kept only as
    /// a backstop against a recycled PID.
    func pruneDead() {
        var removed: [String] = []
        let now = Date()

        for (id, session) in sessions {
            let pidAlive = session.ownerPID > 0 && liveness.isAlive(session.ownerPID)
            let stale = now.timeIntervalSince(session.updatedAt) > Metrics.staleThreshold

            // Dead when the process is gone. A PID of 0 means the writer could
            // not determine an owner, so fall back to time alone for those.
            let dead = if session.ownerPID > 0 { !pidAlive } else { stale }
            if dead || (stale && !pidAlive) {
                removed.append(id)
            }
        }

        guard !removed.isEmpty else { return }
        for id in removed {
            sessions[id] = nil
            unseenDone.remove(id)
            let url = Paths.sessionsDirectory.appending(path: "\(id).json")
            try? fileManager.removeItem(at: url)
        }
        publish()
    }

    // MARK: - User actions

    /// The user opened the panel: nothing is unseen any more.
    /// Opening the panel acknowledges the *finished* states — done and failed.
    ///
    /// Needs-you is deliberately excluded. Per the spec it "clears on the
    /// prompt being answered — not on the panel opening": the panel cannot
    /// answer a permission prompt for you, so clearing it here would discard
    /// the one signal the user still has to act on.
    func markFinishedSeen() {
        guard !unseenDone.isEmpty else { return }
        unseenDone.removeAll()
        publish()
    }

    /// Remove every finished session from the list and from disk.
    func clearFinished() {
        let finished = sessions.filter { $0.value.state == .done || $0.value.state == .failed }
        guard !finished.isEmpty else { return }
        for (id, _) in finished {
            sessions[id] = nil
            unseenDone.remove(id)
            try? fileManager.removeItem(at: Paths.sessionsDirectory.appending(path: "\(id).json"))
        }
        publish()
    }

    /// Test seam: inject sessions without touching the filesystem.
    func _inject(_ list: [Session], unseen: Set<String> = []) {
        for s in list { sessions[s.id] = s }
        unseenDone.formUnion(unseen)
        publish()
    }
}

/// The icon's overall state, derived from every session at once.
enum IconState: Equatable, Sendable {
    case idle
    case working
    case needsYou
    case failed
    case doneUnseen
}
