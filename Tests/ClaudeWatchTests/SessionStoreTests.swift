import XCTest
@testable import ClaudeWatch

final class SessionStoreTests: XCTestCase {

    /// The transcript tail decides two phase changes no hook reports.
    func testTranscriptTailOutcomes() {
        let t0 = Date(timeIntervalSince1970: 1789169160)   // 2026-09-11T23:26:00Z
        let interrupt = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working…"}]},"timestamp":"2026-09-11T23:26:01.000Z"}
        {"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"timestamp":"2026-09-11T23:26:03.402Z"}
        {"type":"attachment"}
        """
        XCTAssertEqual(TranscriptMonitor.outcome(inTail: interrupt, state: .working, since: t0), .interrupted)
        XCTAssertEqual(TranscriptMonitor.outcome(inTail: interrupt, state: .needsYou, since: t0), .interrupted,
                       "an interrupt while a question is open is still an interrupt")

        let superseded = interrupt + """

        {"type":"user","message":{"role":"user","content":"now do this instead"},"timestamp":"2026-09-11T23:27:00.000Z"}
        """
        XCTAssertNil(TranscriptMonitor.outcome(inTail: superseded, state: .working, since: t0))

        let answered = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion"}]},"timestamp":"2026-09-11T23:25:58.000Z"}
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"Yes"}]},"timestamp":"2026-09-11T23:26:12.000Z"}
        """
        XCTAssertEqual(TranscriptMonitor.outcome(inTail: answered, state: .needsYou, since: t0), .resumed)
        XCTAssertNil(TranscriptMonitor.outcome(inTail: answered, state: .working, since: t0),
                     "a tool result during working is just work")

        let stale = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]},"timestamp":"2026-09-11T23:25:00.000Z"}
        """
        XCTAssertNil(TranscriptMonitor.outcome(inTail: stale, state: .needsYou, since: t0),
                     "records from before the prompt do not count as an answer")
    }

    /// The row timer measures the turn, not the session's lifetime: it starts
    /// when work starts, survives a needs-you pause inside the turn, freezes
    /// at the turn's length when it ends, and restarts on the next prompt.
    func testTurnTimerTracksWorkingNotLifetime() throws {
        func file(_ state: String, at t: Double) throws -> SessionFile {
            let json = """
            {"session_id":"s1","state":"\(state)","cwd":"/tmp/p","updated_at":\(t)}
            """
            return try JSONDecoder().decode(SessionFile.self, from: Data(json.utf8))
        }
        let idle = try XCTUnwrap(try file("idle", at: 1000).session(previous: nil))
        XCTAssertNil(idle.workingSince)
        XCTAssertNil(idle.lastTurnDuration)

        let working = try XCTUnwrap(try file("working", at: 1060).session(previous: idle))
        XCTAssertEqual(working.workingSince, Date(timeIntervalSince1970: 1060))

        let paused = try XCTUnwrap(try file("needs_you", at: 1100).session(previous: working))
        XCTAssertEqual(paused.workingSince, working.workingSince, "a prompt mid-turn keeps the clock running")

        let resumed = try XCTUnwrap(try file("working", at: 1120).session(previous: paused))
        XCTAssertEqual(resumed.workingSince, working.workingSince)

        let done = try XCTUnwrap(try file("done", at: 1200).session(previous: resumed))
        XCTAssertNil(done.workingSince)
        XCTAssertEqual(done.lastTurnDuration, 140)

        let again = try XCTUnwrap(try file("working", at: 1500).session(previous: done))
        XCTAssertEqual(again.workingSince, Date(timeIntervalSince1970: 1500), "a new prompt restarts the clock")
        XCTAssertEqual(again.lastTurnDuration, 140, "the previous turn's length is kept until the new one ends")
    }

    // MARK: - Decoding

    func testDecodesWellFormedFile() throws {
        let json = """
        {"schema":1,"session_id":"abc","state":"working","chat_name":"Fix the parser",
         "project_name":"myapp","cwd":"/Users/me/myapp","owner_pid":4242,
         "term_program":"vscode","updated_at":1700000000}
        """.data(using: .utf8)!
        let file = try JSONDecoder().decode(SessionFile.self, from: json)
        XCTAssertEqual(file.sessionID, "abc")
        XCTAssertEqual(file.ownerPID, 4242)
        let session = try XCTUnwrap(file.session(previous: nil))
        XCTAssertEqual(session.state, .working)
        XCTAssertEqual(session.environment.label, "VS Code")
        XCTAssertTrue(session.environment.isEditor)
    }

    /// Malformed JSON, partial writes and unknown fields all happen in practice.
    func testMalformedInputsDoNotThrow() {
        let cases = [
            #"{}"#,
            #"{"session_id":"a"}"#,                       // everything else missing
            #"{"session_id":"a","state":"nonsense"}"#,    // unknown state
            #"{"session_id":"a","owner_pid":"not a number"}"#,
            #"{"session_id":"a","future_field":{"nested":true}}"#,
        ]
        for raw in cases {
            let data = raw.data(using: .utf8)!
            let file = try? JSONDecoder().decode(SessionFile.self, from: data)
            XCTAssertNotNil(file, "should decode leniently: \(raw)")
        }
    }

    func testUnknownStateFallsBackToIdle() throws {
        let data = #"{"session_id":"a","state":"teleporting","cwd":"/x/proj"}"#.data(using: .utf8)!
        let file = try JSONDecoder().decode(SessionFile.self, from: data)
        let session = try XCTUnwrap(file.session(previous: nil))
        XCTAssertEqual(session.state, .idle)
    }

    func testTruncatedJSONIsRejectedNotCrashing() {
        let data = #"{"session_id":"a","state":"wor"#.data(using: .utf8)!
        XCTAssertNil(try? JSONDecoder().decode(SessionFile.self, from: data))
    }

    // MARK: - Ordering and priority

    func testSortsByStatePriorityThenRecency() async {
        let store = SessionStore(liveness: FixedLiveness(alive: [1, 2, 3, 4, 5]))
        let now = Date()
        await store._inject([
            make("idle1",   .idle,     pid: 1, updated: now),
            make("done1",   .done,     pid: 2, updated: now),
            make("work1",   .working,  pid: 3, updated: now.addingTimeInterval(-60)),
            make("work2",   .working,  pid: 4, updated: now),
            make("needs1",  .needsYou, pid: 5, updated: now.addingTimeInterval(-600)),
        ])
        let snap = await firstSnapshot(store)
        XCTAssertEqual(snap.sessions.map(\.id), ["needs1", "work2", "work1", "done1", "idle1"],
                       "needs_you first, then working by recency, then done, then idle")
    }

    func testIconStatePriority() async {
        let store = SessionStore(liveness: FixedLiveness(alive: [1, 2]))
        await store._inject([make("a", .working, pid: 1), make("b", .needsYou, pid: 2)])
        var snap = await firstSnapshot(store)
        XCTAssertEqual(snap.iconState, .needsYou, "needs_you outranks working")

        let store2 = SessionStore(liveness: FixedLiveness(alive: [1, 2]))
        await store2._inject([make("a", .working, pid: 1), make("b", .failed, pid: 2)])
        snap = await firstSnapshot(store2)
        XCTAssertEqual(snap.iconState, .failed, "failed outranks working")
    }

    /// A finish must always reach the glyph, even while another session is
    /// busy — for `Motion.Done.holdDuration`, then working takes it back.
    func testDoneFlashOutranksWorkingBriefly() {
        let now = Date()
        let working = Session(id: "w", state: .working, chatName: "w", projectName: "p",
                              cwd: "/", ownerPID: 1,
                              environment: Environment(label: "T", isEditor: false, isRemote: false),
                              errorType: "", lastMessage: "", updatedAt: now,
                              firstSeen: now, doneAt: nil)
        let done = Session(id: "d", state: .done, chatName: "d", projectName: "p",
                           cwd: "/", ownerPID: 2,
                           environment: Environment(label: "T", isEditor: false, isRemote: false),
                           errorType: "", lastMessage: "", updatedAt: now,
                           firstSeen: now, doneAt: now)
        let snap = SessionStore.Snapshot(sessions: [working, done], unseenDone: ["d"])

        XCTAssertEqual(snap.iconState(at: now), .doneUnseen, "just finished: done shows")
        XCTAssertEqual(snap.iconState(at: now.addingTimeInterval(Motion.Done.holdDuration + 1)),
                       .working, "after the hold, working takes the glyph back")
        XCTAssertEqual(snap.iconState, .working, "steady state is unchanged")

        // Nothing else running: done holds until seen, no expiry.
        let alone = SessionStore.Snapshot(sessions: [done], unseenDone: ["d"])
        XCTAssertEqual(alone.iconState(at: now.addingTimeInterval(600)), .doneUnseen)
    }

    func testWorkingCountDrivesBadge() async {
        let store = SessionStore(liveness: FixedLiveness(alive: [1, 2, 3]))
        await store._inject([
            make("a", .working, pid: 1), make("b", .working, pid: 2), make("c", .idle, pid: 3),
        ])
        let snap = await firstSnapshot(store)
        XCTAssertEqual(snap.workingCount, 2)
    }

    // MARK: - Liveness

    /// kill -9 on a Claude Code process must remove its row.
    func testDeadProcessIsPruned() async {
        let store = SessionStore(liveness: FixedLiveness(alive: [100]))
        await store._inject([
            make("alive", .working, pid: 100),
            make("dead",  .working, pid: 999),   // not in the alive set
        ])
        await store.pruneDead()
        let snap = await firstSnapshot(store)
        XCTAssertEqual(snap.sessions.map(\.id), ["alive"],
                       "a session whose process is gone is removed regardless of recency")
    }

    /// A dead process is pruned even though it wrote an event one second ago:
    /// PID liveness beats time-based staleness.
    func testRecentlyActiveButDeadIsStillPruned() async {
        let store = SessionStore(liveness: FixedLiveness(alive: []))
        await store._inject([make("just_wrote", .working, pid: 777, updated: Date())])
        await store.pruneDead()
        let snap = await firstSnapshot(store)
        XCTAssertTrue(snap.sessions.isEmpty)
    }

    /// With no usable PID we fall back to time alone, so a live-but-unknown
    /// session is not deleted the moment it appears.
    func testUnknownPIDUsesTimeBackstop() async {
        let store = SessionStore(liveness: FixedLiveness(alive: []))
        await store._inject([
            make("fresh", .working, pid: 0, updated: Date()),
            make("ancient", .working, pid: 0,
                 updated: Date().addingTimeInterval(-Metrics.staleThreshold - 60)),
        ])
        await store.pruneDead()
        let snap = await firstSnapshot(store)
        XCTAssertEqual(snap.sessions.map(\.id), ["fresh"])
    }

    // MARK: - Unseen / done

    func testMarkAllSeenClearsGlow() async {
        let store = SessionStore(liveness: FixedLiveness(alive: [1]))
        await store._inject([make("a", .done, pid: 1)], unseen: ["a"])
        var snap = await firstSnapshot(store)
        XCTAssertEqual(snap.iconState, .doneUnseen)
        await store.markFinishedSeen()
        snap = await firstSnapshot(store)
        XCTAssertEqual(snap.iconState, .idle, "opening the panel clears the glow")
    }

    func testClearFinishedRemovesDoneAndFailedOnly() async {
        let store = SessionStore(liveness: FixedLiveness(alive: [1, 2, 3, 4]))
        await store._inject([
            make("w", .working, pid: 1), make("d", .done, pid: 2),
            make("f", .failed, pid: 3), make("i", .idle, pid: 4),
        ])
        await store.clearFinished()
        let snap = await firstSnapshot(store)
        XCTAssertEqual(Set(snap.sessions.map(\.id)), ["w", "i"])
    }

    // MARK: - Environment detection

    func testKnownEnvironmentsGetFriendlyLabels() {
        XCTAssertEqual(Environment.detect(termProgram: "vscode", ancestorName: "node", remote: "").label, "VS Code")
        XCTAssertEqual(Environment.detect(termProgram: "iTerm.app", ancestorName: "claude", remote: "").label, "iTerm")
        XCTAssertEqual(Environment.detect(termProgram: "Apple_Terminal", ancestorName: "claude", remote: "").label, "Terminal")
        XCTAssertEqual(Environment.detect(termProgram: "ghostty", ancestorName: "claude", remote: "").label, "Ghostty")
    }

    /// A user on a terminal we have never heard of must see its name, not "Unknown".
    func testUnknownTerminalShowsItsRawName() {
        let env = Environment.detect(termProgram: "SomeBrandNewTerm", ancestorName: "claude", remote: "")
        XCTAssertEqual(env.label, "SomeBrandNewTerm")
        XCTAssertFalse(env.isEditor)
    }

    func testRemoteIsDetected() {
        let env = Environment.detect(termProgram: "", ancestorName: "node", remote: "true")
        XCTAssertTrue(env.isRemote)
    }

    // MARK: - Naming

    func testDisplayNameNeverBlank() {
        var s = make("abcd1234", .idle, pid: 1)
        s.chatName = ""; s.projectName = ""
        XCTAssertFalse(s.displayName.isEmpty)
        XCTAssertTrue(s.displayName.contains(s.shortID))
    }

    func testShortIDDisambiguates() {
        let a = make("session-aaaa1111", .working, pid: 1)
        let b = make("session-bbbb2222", .working, pid: 2)
        XCTAssertNotEqual(a.shortID, b.shortID,
                          "two sessions in one project must be distinguishable")
    }

    // MARK: - Helpers

    private func make(_ id: String, _ state: SessionState, pid: pid_t,
                      updated: Date = Date(), project: String = "proj") -> Session {
        Session(id: id, state: state, chatName: "", projectName: project, cwd: "/tmp/\(project)",
                ownerPID: pid,
                environment: Environment(label: "Terminal", isEditor: false, isRemote: false),
                errorType: "", lastMessage: "", updatedAt: updated,
                firstSeen: updated, doneAt: state == .done ? updated : nil)
    }

    private func firstSnapshot(_ store: SessionStore) async -> SessionStore.Snapshot {
        for await snap in await store.snapshots() { return snap }
        return SessionStore.Snapshot()
    }
}

// MARK: - Icon system

/// The icon rules the design spec fixes, and the one implementation concern it
/// does not cover: the template / non-template split.
@MainActor
final class IconSystemTests: XCTestCase {

    /// Idle and working ship as template images so macOS inverts them to suit
    /// the menu bar; the three attention states carry colour and must not.
    func testTemplateSplitMatchesSpec() {
        XCTAssertTrue(IconPalette.isTemplate(.idle))
        XCTAssertTrue(IconPalette.isTemplate(.working))
        XCTAssertFalse(IconPalette.isTemplate(.doneUnseen))
        XCTAssertFalse(IconPalette.isTemplate(.needsYou))
        XCTAssertFalse(IconPalette.isTemplate(.failed))
    }

    /// The regression this guards: a monochrome state rasterised for the status
    /// item must be pure black (what `isTemplate` expects), but the same view
    /// drawn on screen must resolve to `.primary` — black ink on a dark window
    /// is invisible, which is exactly how this went wrong once.
    func testMonochromeInkDiffersByRenderPath() {
        XCTAssertEqual(IconPalette.ink(for: .idle, forTemplate: true), .black)
        XCTAssertEqual(IconPalette.ink(for: .idle, forTemplate: false), .primary)
        // Colour states are identical on both paths.
        for template in [true, false] {
            XCTAssertEqual(IconPalette.ink(for: .doneUnseen, forTemplate: template),
                           Palette.accent)
            XCTAssertEqual(IconPalette.ink(for: .failed, forTemplate: template),
                           Palette.failure)
        }
    }

    /// Failed never animates: a failure is finished, and animating it would
    /// imply something is still happening.
    func testOnlyTheRightStatesAnimate() {
        XCTAssertTrue(IconState.working.animates)
        XCTAssertTrue(IconState.needsYou.animates)
        XCTAssertTrue(IconState.doneUnseen.animates)
        XCTAssertFalse(IconState.failed.animates)
        XCTAssertFalse(IconState.idle.animates)
    }

    /// Every loop must be period-closed: the last frame equals the first, or
    /// the animation visibly restarts.
    ///
    /// The loop closes on the *quantised* period — a whole number of frames —
    /// which for 3.2s at 8fps is 26 frames, i.e. 3.25s. That is the length the
    /// animation actually repeats at, and it is what must close exactly.
    func testLoopsArePeriodClosed() {
        for period in [Motion.Precession.period, Motion.NeedsYou.period] {
            let frames = (period * Motion.fps).rounded()
            let quantised = frames / Motion.fps
            XCTAssertEqual(Motion.phase(at: 0, period: period),
                           Motion.phase(at: quantised, period: period),
                           accuracy: 0.0001,
                           "period \(period) does not close")
            // And the frame just before the wrap must not already be frame 0,
            // or the loop is shorter than it claims.
            XCTAssertNotEqual(Motion.phase(at: quantised - Motion.tickInterval,
                                           period: period), 0)
        }
    }

    /// A quarter turn of a fourfold-symmetric gem is loop-invariant: the mark
    /// at 90° is indistinguishable from the mark at 0°, so the spin can run for
    /// ten minutes with no visible restart.
    func testSpinIsLoopInvariant() {
        XCTAssertEqual(Motion.Precession.gemRotation, 90)
        XCTAssertEqual(360.truncatingRemainder(dividingBy: Motion.Precession.gemRotation), 0)
    }

    /// The frame index is quantised to the tick grid, so two times inside one
    /// frame produce identical geometry rather than sub-frame jitter.
    func testFrameIndexIsQuantised() {
        let period = Motion.Precession.period
        XCTAssertEqual(Motion.phase(at: 0.01, period: period),
                       Motion.phase(at: 0.5 / Motion.fps, period: period))
        XCTAssertNotEqual(Motion.phase(at: 0.01, period: period),
                          Motion.phase(at: 0.30, period: period))
    }

    /// Reduce Motion must show a *designed* static frame, never a paused phase
    /// 0 — which for working would be identical to idle.
    func testWorkingStaticFrameIsNotTheIdlePose() {
        // Idle is the gem upright at full size, so a static "working" frame has
        // to differ in angle or scale or it reads as idle.
        XCTAssertNotEqual(Motion.Precession.staticGemAngle, 0)
        // The attention states likewise hold a scale that is not the resting one.
        XCTAssertNotEqual(Motion.NeedsYou.staticScale, 1)
    }

    /// Quantising a period to whole frames must not shift it enough to notice.
    /// 3.2s and 0.9s do not land on whole frames at 8fps; the rounding is a few
    /// tens of milliseconds and each loop still closes on its own integer
    /// frame count, so nothing accumulates.
    func testPeriodQuantisationStaysImperceptible() {
        for period in [Motion.Precession.period, Motion.NeedsYou.period,
                       Motion.Done.period, Motion.WorkingDot.period] {
            let frames = (period * Motion.fps).rounded()
            let actual = frames / Motion.fps
            XCTAssertLessThan(abs(actual - period), 0.1,
                              "period \(period) quantises badly at \(Motion.fps)fps")
        }
    }
}
