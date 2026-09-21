import Foundation

/// Notices the two turn changes that fire no hook.
///
/// **Interrupt.** Stopping a turn (Esc, or rejecting a tool call) fires no
/// Claude Code hook — the Stop hook is documented as not running on a user
/// interrupt. Claude Code does append a user record to the transcript:
///
///     {"type":"user","message":{"role":"user","content":[{"type":"text",
///      "text":"[Request interrupted by user]"}]}, "timestamp":"…"}
///
/// (or "…interrupted by user for tool use").
///
/// **Resume after needs-you.** Answering a permission dialog fires nothing
/// either, but the tool then runs and its `tool_result` lands in the transcript
/// as a `user` record. So while a session is at needs-you, any user record
/// newer than the moment it went there means the user acted.
///
/// For every mid-turn session the transcript's size is checked once a second;
/// the tail is read only when it grew. A stat per file per second is nothing.
actor TranscriptMonitor {
    enum Outcome: Equatable, Sendable { case interrupted, resumed }

    private struct Watched {
        var path: String
        var state: SessionState
        var since: Date
        var lastSize: UInt64
    }

    private var watched: [String: Watched] = [:]
    private let fileManager = FileManager.default

    /// Keep watching exactly the sessions that are mid-turn.
    func track(_ sessions: [Session]) {
        var next: [String: Watched] = [:]
        for s in sessions where s.workingSince != nil && !s.transcriptPath.isEmpty {
            // Needs-you is measured from when it began; working from the turn start.
            let since = s.state == .needsYou ? s.updatedAt : (s.workingSince ?? s.updatedAt)
            if let existing = watched[s.id], existing.since == since, existing.state == s.state {
                next[s.id] = existing
            } else {
                // A new phase: start from the current size so older records
                // are not re-read as this phase's.
                next[s.id] = Watched(path: s.transcriptPath, state: s.state, since: since,
                                     lastSize: size(of: s.transcriptPath) ?? 0)
            }
        }
        watched = next
    }

    /// Sessions whose transcripts show a change of phase since the last poll.
    func poll() -> [(String, Outcome)] {
        var results: [(String, Outcome)] = []
        for (id, w) in watched {
            guard let size = size(of: w.path), size > w.lastSize else { continue }
            watched[id]?.lastSize = size
            guard let tail = readTail(w.path, bytes: Metrics.transcriptTailBytes) else { continue }
            if let outcome = Self.outcome(inTail: tail, state: w.state, since: w.since) {
                results.append((id, outcome))
                watched[id] = nil
            }
        }
        return results
    }

    // MARK: - Parsing

    /// What the tail says about a session in `state` since `since`.
    nonisolated static func outcome(inTail tail: String, state: SessionState, since: Date) -> Outcome? {
        // Hook timestamps are whole seconds, floored; allow for that.
        let threshold = since.addingTimeInterval(-1)
        var newestUserText: (text: String, at: Date)?
        var sawNewUserRecord = false

        for raw in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard raw.contains("\"type\":\"user\"") else { continue }
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["type"] as? String == "user",
                  let message = obj["message"] as? [String: Any],
                  let stamp = obj["timestamp"] as? String,
                  let at = parseISO8601(stamp) else { continue }
            guard at >= threshold else { break }   // older than this phase; stop
            sawNewUserRecord = true
            if let text = promptText(message), newestUserText == nil {
                newestUserText = (text, at)
            }
        }

        if let newest = newestUserText, newest.text.hasPrefix("[Request interrupted by user") {
            return .interrupted
        }
        if state == .needsYou, sawNewUserRecord {
            return .resumed
        }
        return nil
    }

    /// The text of a user record that is a prompt (not tool results).
    private nonisolated static func promptText(_ message: [String: Any]) -> String? {
        if let s = message["content"] as? String { return s.isEmpty ? nil : s }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    // MARK: - Files

    private func size(of path: String) -> UInt64? {
        (try? fileManager.attributesOfItem(atPath: path))?[.size] as? UInt64
    }

    private func readTail(_ path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > UInt64(bytes) ? end - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Formatters are not Sendable, so they are made per call. This runs once per
/// transcript growth while mid-turn, not per frame.
private func parseISO8601(_ stamp: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
}
