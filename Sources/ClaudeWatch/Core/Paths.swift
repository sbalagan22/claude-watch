import Foundation

/// Where things live on disk. Single source of truth, shared with the installer.
enum Paths {
    static let appSupportName = "claude_watch"

    static var supportDirectory: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/\(appSupportName)", directoryHint: .isDirectory)
    }

    static var sessionsDirectory: URL {
        supportDirectory.appending(path: "sessions", directoryHint: .isDirectory)
    }

    static var statusScript: URL {
        supportDirectory.appending(path: "claude-watch-status.sh")
    }

    static var claudeSettings: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: ".claude/settings.json")
    }
}
