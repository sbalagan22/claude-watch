import Foundation

/// What a session is doing. Ordered by display priority: `needsYou` first,
/// because that is the only state where the user is blocking progress.
enum SessionState: String, Codable, Sendable, CaseIterable {
    case needsYou = "needs_you"
    case failed
    case working
    case done
    case idle

    /// Sort weight. Lower sorts first.
    var priority: Int {
        switch self {
        case .needsYou: 0
        case .failed:   1
        case .working:  2
        case .done:     3
        case .idle:     4
        }
    }

    var label: String {
        switch self {
        case .needsYou: "Needs you"
        case .failed:   "Failed"
        case .working:  "Working"
        case .done:     "Done"
        case .idle:     "Idle"
        }
    }
}

/// Where a session is running. Recognised environments get a friendly label;
/// anything else shows its raw TERM_PROGRAM rather than "Unknown", so a user on
/// a terminal we have never heard of still sees its name.
struct Environment: Equatable, Sendable {
    let label: String
    let isEditor: Bool
    let isRemote: Bool

    static func detect(termProgram: String,
                       ancestorName: String,
                       remote: String) -> Environment {
        let isRemote = remote.lowercased() == "true"

        // Deliberately not a closed list: the default arm keeps the raw value.
        let known: [String: (String, Bool)] = [
            "vscode":          ("VS Code", true),
            "cursor":          ("Cursor", true),
            "windsurf":        ("Windsurf", true),
            "apple_terminal":  ("Terminal", false),
            "iterm.app":       ("iTerm", false),
            "ghostty":         ("Ghostty", false),
            "warpterminal":    ("Warp", false),
            "hyper":           ("Hyper", false),
            "alacritty":       ("Alacritty", false),
            "wezterm":         ("WezTerm", false),
            "kitty":           ("kitty", false),
            "tabby":           ("Tabby", false),
            "rio":             ("Rio", false),
        ]

        let key = termProgram.lowercased()
        if let (label, isEditor) = known[key] {
            return Environment(label: label, isEditor: isEditor, isRemote: isRemote)
        }
        if isRemote {
            return Environment(label: "Remote", isEditor: false, isRemote: true)
        }
        if !termProgram.isEmpty {
            // Unrecognised terminal: show what it actually calls itself.
            return Environment(label: termProgram, isEditor: false, isRemote: false)
        }
        // Last resort: the ancestor process name, which is at least real.
        if !ancestorName.isEmpty, ancestorName != "claude" {
            return Environment(label: ancestorName, isEditor: false, isRemote: false)
        }
        return Environment(label: "Terminal", isEditor: false, isRemote: false)
    }
}

/// Handles the hook recorded so a click can land on the exact tab or window,
/// not just the right app. Every field is optional in practice; the focuser
/// uses whichever the session's terminal provides.
struct FocusHints: Equatable, Sendable {
    var tty: String = ""            // "ttys003" — Terminal.app tabs are found by tty
    var termSessionID: String = ""  // TERM_SESSION_ID
    var itermSessionID: String = "" // "w0t1p0:UUID" — iTerm2 sessions by unique id
    var kittyWindowID: String = ""  // KITTY_WINDOW_ID
    var weztermPane: String = ""    // WEZTERM_PANE
    var hostBundleID: String = ""   // __CFBundleIdentifier of the spawning GUI app
    var hostPID: Int32 = 0          // VSCODE_PID: the IDE's main process

    var itermUniqueID: String {
        itermSessionID.split(separator: ":").last.map(String.init) ?? ""
    }
}

/// One Claude Code session, as the app understands it.
struct Session: Identifiable, Equatable, Sendable {
    let id: String            // session_id
    var state: SessionState
    var chatName: String
    var projectName: String
    var cwd: String
    /// Claude Code's JSONL transcript for this session. Read only to notice
    /// an interrupt, which fires no hook.
    var transcriptPath: String = ""
    var ownerPID: pid_t
    var environment: Environment
    var focus: FocusHints = FocusHints()
    var errorType: String
    var lastMessage: String
    var updatedAt: Date
    /// When this session first became known to the app. Used to disambiguate
    /// two sessions in the same directory when names collide.
    var firstSeen: Date
    /// Set when the state last became `.done`, so the panel can sweep it.
    var doneAt: Date?
    /// When the current turn started — the moment the session went to work.
    /// Persists through `needsYou` (a permission prompt is part of the turn)
    /// and clears when the turn ends. The row's live timer counts from here,
    /// so it reads "how long this session has been working", not "how long
    /// it has existed".
    var workingSince: Date? = nil
    /// How long the last completed turn took, shown once it has finished.
    var lastTurnDuration: TimeInterval? = nil

    /// A short, stable suffix of the session id, for disambiguation.
    var shortID: String { String(id.suffix(4)) }

    /// The name to show. Never blank: the writer already falls back to the cwd
    /// folder name, and this is the final guard.
    var displayName: String {
        if !chatName.isEmpty { return chatName }
        if !projectName.isEmpty { return projectName }
        return "Session \(shortID)"
    }
}
