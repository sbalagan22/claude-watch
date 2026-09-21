import Foundation

/// The on-disk shape written by the hook script.
///
/// Every field is optional or defaulted. The hook script is a shell script
/// writing JSON by hand; a partial write, a truncated file or a field the app
/// has never seen must decode to *something*, or a single malformed file would
/// blank the whole panel.
struct SessionFile: Decodable, Sendable {
    var schema: Int = 1
    var sessionID: String = ""
    var state: String = "idle"
    var event: String = ""
    var chatName: String = ""
    var projectName: String = ""
    var cwd: String = ""
    var transcriptPath: String = ""
    var ownerPID: Int32 = 0
    var ancestorName: String = ""
    var termProgram: String = ""
    var termProgramVersion: String = ""
    var claudeCodeRemote: String = ""
    var termSessionID: String = ""
    var itermSessionID: String = ""
    var kittyWindowID: String = ""
    var weztermPane: String = ""
    var hostBundleID: String = ""
    var hostPID: Int32 = 0
    var ownerTTY: String = ""
    var notificationType: String = ""
    var errorType: String = ""
    var endReason: String = ""
    var lastMessage: String = ""
    var updatedAt: Double = 0

    private enum CodingKeys: String, CodingKey {
        case schema
        case sessionID = "session_id"
        case state, event
        case chatName = "chat_name"
        case projectName = "project_name"
        case cwd
        case transcriptPath = "transcript_path"
        case ownerPID = "owner_pid"
        case ancestorName = "ancestor_name"
        case termProgram = "term_program"
        case termProgramVersion = "term_program_version"
        case claudeCodeRemote = "claude_code_remote"
        case termSessionID = "term_session_id"
        case itermSessionID = "iterm_session_id"
        case kittyWindowID = "kitty_window_id"
        case weztermPane = "wezterm_pane"
        case hostBundleID = "host_bundle_id"
        case hostPID = "host_pid"
        case ownerTTY = "owner_tty"
        case notificationType = "notification_type"
        case errorType = "error_type"
        case endReason = "end_reason"
        case lastMessage = "last_message"
        case updatedAt = "updated_at"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String { (try? c.decode(String.self, forKey: k)) ?? "" }
        schema             = (try? c.decode(Int.self, forKey: .schema)) ?? 1
        sessionID          = str(.sessionID)
        state              = { let s = str(.state); return s.isEmpty ? "idle" : s }()
        event              = str(.event)
        chatName           = str(.chatName)
        projectName        = str(.projectName)
        cwd                = str(.cwd)
        transcriptPath     = str(.transcriptPath)
        ownerPID           = (try? c.decode(Int32.self, forKey: .ownerPID)) ?? 0
        ancestorName       = str(.ancestorName)
        termProgram        = str(.termProgram)
        termProgramVersion = str(.termProgramVersion)
        claudeCodeRemote   = str(.claudeCodeRemote)
        termSessionID      = str(.termSessionID)
        itermSessionID     = str(.itermSessionID)
        kittyWindowID      = str(.kittyWindowID)
        weztermPane        = str(.weztermPane)
        hostBundleID       = str(.hostBundleID)
        hostPID            = (try? c.decode(Int32.self, forKey: .hostPID)) ?? 0
        ownerTTY           = str(.ownerTTY)
        notificationType   = str(.notificationType)
        errorType          = str(.errorType)
        endReason          = str(.endReason)
        lastMessage        = str(.lastMessage)
        updatedAt          = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
    }

    /// Convert to the app's model, carrying `firstSeen` forward from any entry
    /// we already had so elapsed time survives a state change.
    func session(previous: Session?) -> Session? {
        guard !sessionID.isEmpty else { return nil }
        let newState = SessionState(rawValue: state) ?? .idle
        let updated = updatedAt > 0 ? Date(timeIntervalSince1970: updatedAt) : Date()
        let firstSeen = previous?.firstSeen
        let previousDoneAt = previous?.doneAt
        let previousState = previous?.state

        // Turn timing. A turn is working plus any needs-you pauses inside it.
        let inTurn = newState == .working || newState == .needsYou
        let workingSince: Date? = inTurn ? (previous?.workingSince ?? updated) : nil
        let lastTurnDuration: TimeInterval? = if inTurn {
            previous?.lastTurnDuration
        } else if let start = previous?.workingSince {
            max(0, updated.timeIntervalSince(start))
        } else {
            previous?.lastTurnDuration
        }

        // Mark the moment a session became done, for the panel's highlight sweep.
        let doneAt: Date? = if newState == .done {
            previousState == .done ? previousDoneAt : updated
        } else {
            nil
        }

        return Session(
            id: sessionID,
            state: newState,
            chatName: chatName,
            projectName: projectName.isEmpty
                ? (cwd as NSString).lastPathComponent
                : projectName,
            cwd: cwd,
            transcriptPath: transcriptPath,
            ownerPID: ownerPID,
            environment: Environment.detect(termProgram: termProgram,
                                            ancestorName: ancestorName,
                                            remote: claudeCodeRemote),
            focus: FocusHints(tty: ownerTTY,
                              termSessionID: termSessionID,
                              itermSessionID: itermSessionID,
                              kittyWindowID: kittyWindowID,
                              weztermPane: weztermPane,
                              hostBundleID: hostBundleID,
                              hostPID: hostPID),
            errorType: errorType,
            lastMessage: lastMessage,
            updatedAt: updated,
            firstSeen: firstSeen ?? updated,
            doneAt: doneAt,
            workingSince: workingSince,
            lastTurnDuration: lastTurnDuration
        )
    }
}
